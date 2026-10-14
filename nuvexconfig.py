#!/usr/bin/env python3
"""Validated, password-free configuration shared by Nuvex and nuvexctl."""

import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path


CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "nuvex"
CONFIG_FILE = CONFIG_DIR / "profiles.json"
FIELDS = {"name", "server", "username", "trust", "realm", "manageRoutes", "manageDNS", "enabled"}
BOOLEAN_FIELDS = {"enabled", "manageRoutes", "manageDNS"}
PROFILE_ID = re.compile(r"[a-z][a-z0-9-]{0,47}\Z")


def defaults():
    return {"version": 2, "profiles": []}


def validate(profile, *, require_trimmed_username=False):
    if not isinstance(profile, dict) or set(profile) != FIELDS | {"id"} or not isinstance(profile["id"], str) or not PROFILE_ID.fullmatch(profile["id"]):
        raise ValueError("estructura de perfil inválida")
    for field in ("name", "server", "username", "trust", "realm"):
        if not isinstance(profile[field], str):
            raise ValueError(field + " debe ser texto")
        if any(ord(c) < 32 or ord(c) == 127 for c in profile[field]):
            raise ValueError(field + " contiene caracteres de control")
    if not profile["name"].strip() or len(profile["name"]) > 60:
        raise ValueError("nombre inválido")
    if len(profile["username"]) > 128 or len(profile["server"]) > 255 or len(profile["realm"]) > 128:
        raise ValueError("usuario, servidor o realm demasiado largo")
    if require_trimmed_username and profile["username"] != profile["username"].strip():
        raise ValueError("el usuario no puede empezar ni terminar con espacios")
    if profile["server"]:
        match = re.fullmatch(r"(?:https://)?(?:[A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9a-fA-F:]+\])(?::([0-9]{1,5}))?/?", profile["server"])
        if not match or (match.group(1) and not 1 <= int(match.group(1)) <= 65535):
            raise ValueError("servidor inválido; usa host:puerto o https://host:puerto/")
    if profile["trust"] not in ("system", "bundle") and not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", profile["trust"]):
        raise ValueError("confianza inválida; usa system, bundle o sha256:<huella hexadecimal>")
    if any(not isinstance(profile[field], bool) for field in BOOLEAN_FIELDS):
        raise ValueError("enabled, manageRoutes y manageDNS deben ser booleanos")


def validate_data(data, *, require_trimmed_usernames=False):
    if not isinstance(data, dict) or data.get("version") != 2 or set(data) != {"version", "profiles"}:
        raise ValueError("versión de configuración no compatible")
    profiles = data["profiles"]
    if not isinstance(profiles, list) or len(profiles) > 64:
        raise ValueError("configura entre 0 y 64 conexiones")
    for profile in profiles:
        validate(profile, require_trimmed_username=require_trimmed_usernames)
    ids = [profile["id"] for profile in profiles]
    if len(ids) != len(set(ids)):
        raise ValueError("los identificadores de conexión deben ser únicos")


def load():
    if not CONFIG_FILE.exists():
        return defaults()
    data = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    if isinstance(data, dict) and data.get("version") == 1 and set(data) == {"version", "profiles"}:
        if not isinstance(data["profiles"], list) or not all(isinstance(p, dict) for p in data["profiles"]):
            raise ValueError("configuración anterior inválida")
        data = {"version": 2, "profiles": [
            dict({key: value for key, value in profile.items() if key != "otp"},
                 realm="", manageRoutes=True, manageDNS=True)
            for profile in data["profiles"]
        ]}
    validate_data(data)
    return data


def save(data):
    validate_data(data, require_trimmed_usernames=True)
    CONFIG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)
    fd, path = tempfile.mkstemp(prefix=".profiles-", dir=CONFIG_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(data, out, ensure_ascii=False, indent=2)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.chmod(path, 0o600)
        os.replace(path, CONFIG_FILE)
    finally:
        if os.path.exists(path):
            os.unlink(path)


def main(args):
    data = load()
    profiles = {p["id"]: p for p in data["profiles"]}
    command = args[0] if args else "list"
    if command == "list" and len(args) == 1:
        print(json.dumps(data["profiles"], ensure_ascii=False))
    elif command == "ids" and len(args) == 1:
        print(" ".join(p["id"] for p in data["profiles"]))
    elif command == "status-json" and len(args) == 2 and args[1] in ("true", "false"):
        connected = {}
        for line in sys.stdin:
            parts = line.split()
            if len(parts) == 2 and PROFILE_ID.fullmatch(parts[0]) and parts[1].isdigit():
                connected[parts[0]] = int(parts[1])
        print(json.dumps([{
            "id": profile["id"], "name": profile["name"],
            "connected": profile["id"] in connected,
            "enabled": profile["enabled"],
            "configured": bool(profile["username"] and profile["server"]),
            "helperReady": args[1] == "true", "pid": connected.get(profile["id"], 0),
            "ip": "", "iface": "", "networks": [],
        } for profile in data["profiles"]], ensure_ascii=False))
    elif command == "get" and len(args) == 3:
        profile = profiles[args[1]]
        value = profile[args[2]] if args[2] in FIELDS else None
        if value is None:
            raise ValueError("campo inválido")
        print(str(value).lower() if isinstance(value, bool) else value)
    elif command == "set" and len(args) == 4:
        profile = profiles[args[1]]
        field, value = args[2:]
        if field not in FIELDS:
            raise ValueError("campo inválido")
        if field in BOOLEAN_FIELDS and value not in ("true", "false"):
            raise ValueError(field + " debe ser true o false")
        profile[field] = value == "true" if field in BOOLEAN_FIELDS else value
        validate(profile)
        save(data)
        print("guardado")
    elif command == "set-profile" and len(args) == 3:
        candidate = json.loads(args[2])
        if not isinstance(candidate, dict) or candidate.get("id") != args[1]:
            raise ValueError("perfil inválido")
        validate(candidate)
        if args[1] in profiles:
            profiles[args[1]].update(candidate)
        else:
            data["profiles"].append(candidate)
        save(data)
        print("guardado")
    elif command == "delete" and len(args) == 2:
        if args[1] not in profiles:
            raise ValueError("conexión desconocida")
        data["profiles"] = [profile for profile in data["profiles"] if profile["id"] != args[1]]
        save(data)
        print("eliminada")
    elif command == "set-all" and len(args) == 2:
        candidates = json.loads(args[1])
        data["profiles"] = candidates
        save(data)
        print("guardado")
    elif command == "fingerprint" and len(args) == 1:
        canonical = json.dumps(data, sort_keys=True, separators=(",", ":")).encode()
        print(hashlib.sha256(canonical).hexdigest())
    else:
        raise ValueError("uso: list | ids | status-json true|false | get ID CAMPO | set ID CAMPO VALOR | set-profile ID JSON | delete ID | set-all JSON | fingerprint")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print("nuvexconfig: " + str(error), file=sys.stderr)
        sys.exit(1)
