#!/usr/bin/env python3
"""Comprueba un túnel real sin leer contraseñas ni registrar destinos internos."""

import argparse
import json
import os
import pwd
import re
import socket
import subprocess
import sys
from pathlib import Path


CONTROL = Path(__file__).resolve().parents[1] / "nuvexctl.sh"
PROFILE_ID = re.compile(r"[a-z][a-z0-9-]{0,47}\Z")
ROUTE_INTERFACE = re.compile(r"^\s*interface:\s*(\S+)", re.MULTILINE)


class ValidationError(Exception):
    pass


def profile_status(profile_id):
    environment = dict(os.environ)
    environment.setdefault("XDG_CONFIG_HOME", pwd.getpwuid(os.getuid()).pw_dir + "/.config")
    try:
        result = subprocess.run([str(CONTROL), "list"], env=environment,
                                text=True, capture_output=True, timeout=20)
        profiles = json.loads(result.stdout) if result.returncode == 0 else []
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        raise ValidationError("No se pudo consultar el estado de Nuvex.") from error
    if result.returncode != 0 or not isinstance(profiles, list):
        raise ValidationError("No se pudo consultar el estado de Nuvex.")
    profile = next((item for item in profiles if isinstance(item, dict) and
                    item.get("id") == profile_id), None)
    if profile is None:
        raise ValidationError("La conexión indicada no existe en Nuvex.")
    if not profile.get("enabled") or not profile.get("configured"):
        raise ValidationError("La conexión está desactivada o incompleta.")
    if not profile.get("connected"):
        raise ValidationError("Nuvex no informa un túnel activo para esta conexión.")
    return [item["id"] for item in profiles if isinstance(item, dict) and
            item.get("connected") and item.get("id") != profile_id]


def route_interface(address, family):
    address_family = "-inet6" if family == socket.AF_INET6 else "-inet"
    try:
        result = subprocess.run(["/sbin/route", "-n", "get", address_family, address],
                                text=True, capture_output=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValidationError("No se pudo consultar la ruta del destino.") from error
    match = ROUTE_INTERFACE.search(result.stdout)
    if result.returncode != 0 or not match:
        raise ValidationError("No se pudo consultar la ruta del destino.")
    return match.group(1)


def check_resource(host, port, timeout):
    try:
        addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except OSError as error:
        raise ValidationError("No se pudo resolver el destino interno.") from error
    if not addresses:
        raise ValidationError("El destino interno no resolvió ninguna dirección.")
    route_checked = False
    for family, kind, protocol, _, address in addresses:
        try:
            interface = route_interface(address[0], family)
        except ValidationError:
            continue
        route_checked = True
        if not re.fullmatch(r"ppp\d+", interface):
            continue
        try:
            with socket.socket(family, kind, protocol) as connection:
                connection.settimeout(timeout)
                connection.connect(address)
            return interface
        except OSError:
            continue
    if not route_checked:
        raise ValidationError("No se pudo comprobar la ruta de ninguna dirección del destino.")
    raise ValidationError("Ninguna dirección respondió por TCP a través de una interfaz PPP.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", help="identificador de la conexión guardada en Nuvex")
    parser.add_argument("--host", help="host o IP de un recurso interno, sin URL ni credenciales")
    parser.add_argument("--port", type=int, help="puerto TCP del recurso interno")
    parser.add_argument("--timeout", type=float, default=5.0, help="segundos por dirección (1–30)")
    parser.add_argument("--status-only", action="store_true",
                        help="comprueba solo el túnel; no cuenta como prueba de acceso interno")
    args = parser.parse_args(argv)
    if not PROFILE_ID.fullmatch(args.profile):
        parser.error("identificador de conexión inválido")
    if not 1 <= args.timeout <= 30:
        parser.error("timeout fuera de rango")
    if args.status_only:
        if args.host or args.port:
            parser.error("--status-only no acepta destino")
    elif not args.host or not args.port or not 1 <= args.port <= 65535:
        parser.error("indica --host y --port para comprobar acceso interno")
    elif any(ord(character) < 33 or character in "/@" for character in args.host):
        parser.error("--host debe ser un host o IP sin ruta ni credenciales")
    try:
        other_active = profile_status(args.profile)
        if args.status_only:
            print("Túnel activo; acceso interno aún sin verificar.")
            return 2
        if other_active:
            raise ValidationError("Desconecta las otras VPN de Nuvex para atribuir la ruta a esta conexión.")
        interface = check_resource(args.host, args.port, args.timeout)
        print("Túnel activo y recurso interno accesible por TCP mediante " + interface + ".")
        return 0
    except ValidationError as error:
        print("Validación incompleta: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
