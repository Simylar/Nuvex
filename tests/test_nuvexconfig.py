import getpass
import json
import selectors
import time
import importlib.util
import io
import os
import shlex
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "nuvexconfig.py"
CONTROL = ROOT / "nuvexctl.sh"
spec = importlib.util.spec_from_file_location("nuvexconnect", ROOT / "nuvexconnect.py")
CONNECT = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CONNECT)


class NuvexConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = dict(os.environ, XDG_CONFIG_HOME=self.tmp.name)
        self.seed_profiles()

    def seed_profiles(self):
        profiles = [
            {"id": "sicert", "name": "VPN de prueba A", "server": "vpn-a.example.org:443",
             "username": "test.a", "trust": "sha256:" + "a" * 64, "realm": "",
             "manageRoutes": True, "manageDNS": True, "enabled": True},
            {"id": "prepa", "name": "VPN de prueba B", "server": "vpn-b.example.org:443",
             "username": "test.b", "trust": "bundle", "realm": "",
             "manageRoutes": True, "manageDNS": True, "enabled": True},
        ]
        path = Path(self.tmp.name) / "nuvex" / "profiles.json"
        path.parent.mkdir(mode=0o700, exist_ok=True)
        path.write_text(json.dumps({"version": 2, "profiles": profiles}))
        path.chmod(0o600)

    def run_config(self, *args, expected=0):
        result = subprocess.run(["/usr/bin/python3", str(CONFIG), *args],
                                env=self.env, text=True, input="", capture_output=True)
        self.assertEqual(result.returncode, expected, result.stderr)
        return result.stdout

    def test_default_profiles_and_safe_roundtrip(self):
        path = Path(self.tmp.name) / "nuvex" / "profiles.json"
        path.unlink()
        self.assertEqual(json.loads(self.run_config("list")), [])
        self.assertEqual(json.loads(self.run_config("status-json", "false")), [])
        self.assertEqual(self.run_config("ids"), "\n")
        self.seed_profiles()
        profiles = json.loads(self.run_config("list"))
        self.assertEqual([p["id"] for p in profiles], ["sicert", "prepa"])
        self.assertNotIn("otp", profiles[1])
        self.run_config("set", "sicert", "username", "test.user")
        self.assertEqual(self.run_config("get", "sicert", "username").strip(), "test.user")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("password", path.read_text().lower())

    def test_rejects_untrusted_input(self):
        self.run_config("set", "sicert", "server", "vpn.example; rm -rf /", expected=1)
        self.run_config("set", "sicert", "trust", "sha256:invalid", expected=1)
        self.run_config("set", "sicert", "name", "bad\nname", expected=1)
        self.assertEqual(self.run_config("get", "sicert", "server").strip(), "vpn-a.example.org:443")

    def test_legacy_username_whitespace_can_be_read_but_not_saved_again(self):
        profiles = json.loads(self.run_config("list"))
        profiles[0]["username"] = "test.user   "
        path = Path(self.tmp.name) / "nuvex" / "profiles.json"
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps({"version": 2, "profiles": profiles}))

        self.assertEqual(self.run_config("get", "sicert", "username"), "test.user   \n")
        self.run_config("set-all", json.dumps(profiles), expected=1)
        profiles[0]["username"] = "test.user"
        self.run_config("set-all", json.dumps(profiles))
        self.assertEqual(self.run_config("get", "sicert", "username"), "test.user\n")

    def test_add_remove_and_migrate_profiles(self):
        path = Path(self.tmp.name) / "nuvex" / "profiles.json"
        path.parent.mkdir(exist_ok=True)
        original = json.loads(self.run_config("list"))
        path.write_text(json.dumps({"version": 1, "profiles": [
            dict({key: value for key, value in profile.items()
                  if key not in ("realm", "manageRoutes", "manageDNS")},
                 otp=profile["id"] == "prepa") for profile in original
        ]}))
        migrated = json.loads(self.run_config("list"))
        self.assertEqual(migrated, original)
        third = dict(original[0], id="vpn-tercera", name="Tercera", trust="system")
        self.run_config("set-profile", third["id"], json.dumps(third))
        self.assertEqual(len(json.loads(self.run_config("list"))), 3)
        self.assertEqual(self.run_config("ids").strip(), "sicert prepa vpn-tercera")
        status = json.loads(self.run_config("status-json", "false"))
        self.assertEqual([p["id"] for p in status], ["sicert", "prepa", "vpn-tercera"])
        self.assertFalse(any(p["helperReady"] for p in status))
        self.run_config("delete", "sicert")
        self.assertEqual([p["id"] for p in json.loads(self.run_config("list"))], ["prepa", "vpn-tercera"])
        self.assertEqual(json.loads(path.read_text())["version"], 2)
        self.run_config("set-all", json.dumps([third, third]), expected=1)
        self.assertEqual(len(json.loads(self.run_config("list"))), 2)
        self.run_config("set-all", "[]")
        self.assertEqual(json.loads(self.run_config("list")), [])

    def test_bundled_ca_is_available_for_new_connection_ids(self):
        profile = dict(json.loads(self.run_config("list"))[1], id="vpn-custom")
        self.run_config("set-profile", profile["id"], json.dumps(profile))
        self.assertEqual(self.run_config("get", profile["id"], "trust").strip(), "bundle")

    def test_first_connection_can_be_prepared_from_empty_install(self):
        path = Path(self.tmp.name) / "nuvex" / "profiles.json"
        path.unlink()
        profile = {"id": "vpn-first", "name": "VPN de prueba", "server": "vpn.example.org:443",
                   "username": "new.user", "trust": "system", "realm": "",
                   "manageRoutes": True, "manageDNS": True, "enabled": True}
        self.run_config("set-profile", profile["id"], json.dumps(profile))
        statuses = json.loads(self.run_config("status-json", "false"))
        self.assertEqual(len(statuses), 1)
        self.assertTrue(statuses[0]["configured"])
        self.assertFalse(statuses[0]["helperReady"])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

        helper = Path(self.tmp.name) / "helper"
        result = subprocess.run([str(CONTROL), "gen-helper", str(helper)],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("vpn-first) set --", helper.read_text())
        self.assertEqual(subprocess.run(["/bin/bash", "-n", str(helper)]).returncode, 0)

    def test_helper_quotes_names_and_keeps_password_out_of_arguments(self):
        app_engine = ROOT / "Nuvex" / "Nuvex.app" / "Contents" / "Resources" / "openfortivpn"
        if not app_engine.exists():
            self.skipTest("Build Nuvex before running helper test")
        self.run_config("set", "sicert", "username", "O'Brien")
        self.run_config("set", "prepa", "username", "test.user")
        helper = Path(self.tmp.name) / "helper"
        result = subprocess.run([str(CONTROL), "gen-helper", str(helper)],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        syntax = subprocess.run(["/bin/bash", "-n", str(helper)], capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        source = helper.read_text()
        self.assertIn("O'\\''Brien", source)
        self.assertIn("--trusted-cert=", source)
        self.assertIn("--ca-file=", source)
        self.assertIn("# ca-sha256:", source)
        self.assertIn("# ssl-sha256:", source)
        self.assertIn("# crypto-sha256:", source)
        self.assertIn("# helper-version: 3", source)
        self.assertIn("NUVEX_TLS_VERIFY_FAILED", source)
        self.assertNotIn("--password=", source)
        self.assertNotIn("--otp=", source)

    def test_generated_helper_accepts_added_profile_and_installer_is_valid(self):
        self.run_config("set", "sicert", "username", "person")
        self.run_config("set", "prepa", "username", "person")
        profile = {"id": "vpn-tercera", "name": "Tercera", "server": "vpn.example.org:443",
                   "username": "person", "trust": "system", "realm": "oficina",
                   "manageRoutes": False, "manageDNS": False, "enabled": True}
        self.run_config("set-profile", profile["id"], json.dumps(profile))
        helper = Path(self.tmp.name) / "helper"
        generated = subprocess.run([str(CONTROL), "gen-helper", str(helper)], env=self.env,
                                   text=True, capture_output=True)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        source = helper.read_text()
        self.assertIn("vpn-tercera) set --", source)
        self.assertIn("--realm=oficina", source)
        self.assertIn("--no-routes", source)
        self.assertIn("--no-dns", source)
        self.assertIn("__all__) [ \"$ACTION\" = list-status ]", source)
        syntax = subprocess.run(["/bin/bash", "-n", str(helper)], capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        staged = subprocess.run([str(CONTROL), "install-helper", "--dry-run"], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(staged.returncode, 0, staged.stderr)
        installer = Path(staged.stdout.strip())
        self.addCleanup(lambda: __import__("shutil").rmtree(installer.parent, ignore_errors=True))
        self.assertEqual(subprocess.run(["/bin/bash", "-n", str(installer)]).returncode, 0)
        installer_source = installer.read_text()
        self.assertIn("/Library/PrivilegedHelperTools/Nuvex", installer_source)
        self.assertIn('"$ROOT_STAGE/helper"', installer_source)
        self.assertIn("HELPER_ONLY='false'", installer_source)
        self.assertIn('NEW_HELPER=$(/usr/bin/mktemp "$TARGET/.helper.XXXXXX")', installer_source)

    def test_installer_cleans_stage_after_success(self):
        if not (ROOT / "Nuvex" / "Nuvex.app").exists():
            self.skipTest("Build Nuvex before running installer test")
        self.run_config("set", "sicert", "username", "test.sicert")
        self.run_config("set", "prepa", "username", "test.prepa")
        source = CONTROL.read_text()
        replacements = {
            'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"':
                f'SCRIPT_DIR={shlex.quote(str(ROOT))}',
            'ENGINE_DIR="/Library/PrivilegedHelperTools/Nuvex"':
                f'ENGINE_DIR={shlex.quote(str(Path(self.tmp.name) / "engine"))}',
            '/usr/bin/osascript "$INSTALLER_SCRIPT" "$temp/install.sh" "$installer_digest" || die "se canceló o falló la autorización de macOS"':
                'true # Simula una autorización exitosa sin instalar nada como root.',
            'helper_is_current || die "el ayudante no quedó instalado correctamente"':
                'true # La copia privilegiada se omite en esta prueba.',
        }
        for original, replacement in replacements.items():
            self.assertEqual(source.count(original), 1, original)
            source = source.replace(original, replacement)
        control = Path(self.tmp.name) / "control-test.sh"
        control.write_text(source)
        control.chmod(0o700)
        env = dict(self.env, TMPDIR=self.tmp.name)
        result = subprocess.run([str(control), "install-helper"], env=env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Ayudante instalado", result.stdout)
        self.assertFalse(list(Path(self.tmp.name).glob("nuvex-install.*")))

    def test_active_tunnel_blocks_connection_changes_but_allows_unchanged_save(self):
        source = CONTROL.read_text()
        original = 'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"'
        self.assertEqual(source.count(original), 1)
        source = source.replace(original, f'SCRIPT_DIR={shlex.quote(str(ROOT))}')
        original = 'ENGINE_DIR="/Library/PrivilegedHelperTools/Nuvex"'
        self.assertEqual(source.count(original), 1)
        engine_dir = Path(self.tmp.name) / "engine"
        source = source.replace(original, f'ENGINE_DIR={shlex.quote(str(engine_dir))}')
        control = Path(self.tmp.name) / "control-test.sh"
        control.write_text(source)
        control.chmod(0o700)

        engine_dir.mkdir()
        helper = engine_dir / f"helper-{os.getuid()}"
        helper.write_text("#!/bin/bash\n"
                          "[ \"$1\" = __all__ ] && [ \"$2\" = list-status ] && echo 'prepa 123'\n")
        helper.chmod(0o700)
        bin_dir = Path(self.tmp.name) / "bin"
        bin_dir.mkdir()
        sudo = bin_dir / "sudo"
        sudo.write_text("#!/bin/bash\n[ \"$1\" = -n ] && shift\n\"$@\"\n")
        sudo.chmod(0o700)
        env = dict(self.env, PATH=f"{bin_dir}:{os.environ['PATH']}")
        profiles = json.loads(self.run_config("list"))
        changed = [dict(profile) for profile in profiles]
        changed[0]["name"] = "Nombre nuevo"

        rejected = subprocess.run([str(control), "config", "set-all", json.dumps(changed)],
                                  env=env, text=True, capture_output=True)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("desconecta la VPN activa", rejected.stderr)
        self.assertEqual(json.loads(self.run_config("list")), profiles)
        rejected_field = subprocess.run([str(control), "config", "set", "sicert", "name", "Otro"],
                                        env=env, text=True, capture_output=True)
        self.assertNotEqual(rejected_field.returncode, 0)

        unchanged = subprocess.run([str(control), "config", "set-all", json.dumps(profiles)],
                                   env=env, text=True, capture_output=True)
        self.assertEqual(unchanged.returncode, 0, unchanged.stderr)

    def test_helper_requests_otp_after_password(self):
        app_engine = ROOT / "Nuvex" / "Nuvex.app" / "Contents" / "Resources" / "openfortivpn"
        if not app_engine.exists():
            self.skipTest("Build Nuvex before running helper test")
        self.run_config("set", "sicert", "username", "test.sicert")
        self.run_config("set", "prepa", "username", "test.prepa")
        helper_path = Path(self.tmp.name) / "generated-helper"
        result = subprocess.run([str(CONTROL), "gen-helper", str(helper_path)],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        fake = Path(self.tmp.name) / "fake-engine"
        fake.write_text("#!/bin/bash\nIFS= read -r password\n"
                        "printf 'NUVEX_OTP_REQUIRED\\n'\nIFS= read -r otp\n"
                        "printf 'Tunnel is up and running.\\n'\nsleep 1\n")
        fake.chmod(0o755)
        source = helper_path.read_text().replace(
            "ENGINE='/Library/PrivilegedHelperTools/Nuvex/openfortivpn'", f"ENGINE='{fake}'"
        ).replace(
            'STATE="/var/run/nuvex/$(id -u "${SUDO_USER:-root}")/${PROFILE}"',
            f'STATE="{self.tmp.name}/state/${{PROFILE}}"'
        )
        helper_path.write_text(source)
        env = dict(self.env, SUDO_USER=getpass.getuser())
        process = subprocess.Popen([str(helper_path), "prepa", "start"],
                                   stdin=subprocess.PIPE, stderr=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True, env=env)
        process.stdin.write("test-password\n")
        process.stdin.flush()
        selector = selectors.DefaultSelector()
        selector.register(process.stderr, selectors.EVENT_READ)
        self.assertTrue(selector.select(5), "no se solicitó el código")
        self.assertEqual(process.stderr.readline().strip(), "NUVEX_OTP_REQUIRED")
        process.stdin.write("123456\n")
        process.stdin.close()
        self.assertEqual(process.wait(timeout=5), 0)
        process.stdout.close()
        process.stderr.close()
        selector.close()
        time.sleep(1.1)  # El motor simulado termina antes de borrar el directorio temporal.

    def test_failed_engine_does_not_leave_app_waiting_for_otp(self):
        if not (ROOT / "Nuvex" / "Nuvex.app").exists():
            self.skipTest("Build Nuvex before running helper test")
        self.run_config("set", "sicert", "username", "test.sicert")
        self.run_config("set", "prepa", "username", "test.prepa")
        helper = Path(self.tmp.name) / "helper"
        generated = subprocess.run([str(CONTROL), "gen-helper", str(helper)], env=self.env,
                                   text=True, capture_output=True)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        engine = Path(self.tmp.name) / "fake-engine"
        engine.write_text("#!/bin/bash\nprintf 'simulated VPN failure\\n' >&2\nexit 7\n")
        engine.chmod(0o700)
        source = helper.read_text().replace(
            "ENGINE='/Library/PrivilegedHelperTools/Nuvex/openfortivpn'",
            f"ENGINE={shlex.quote(str(engine))}"
        ).replace(
            'STATE="/var/run/nuvex/$(id -u "${SUDO_USER:-root}")/${PROFILE}"',
            f'STATE={shlex.quote(self.tmp.name)}/state/${{PROFILE}}'
        )
        helper.write_text(source)
        runner = Path(self.tmp.name) / "run-connect.py"
        runner.write_text(
            "import importlib.util,sys\n"
            "spec=importlib.util.spec_from_file_location('connect',sys.argv[1])\n"
            "module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)\n"
            "sys.exit(module.connect([sys.argv[2],'sicert','start'],'app'))\n"
        )
        env = dict(self.env, SUDO_USER=getpass.getuser())
        process = subprocess.Popen(["/usr/bin/python3", str(runner), str(ROOT / "nuvexconnect.py"), str(helper)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, env=env)
        try:
            process.stdin.write("test-password\n")
            process.stdin.flush()
            self.assertNotEqual(process.wait(timeout=8), 0)
            self.assertIn("simulated VPN failure", process.stderr.read())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()

    def test_generated_helper_allows_two_active_tunnels(self):
        self.run_config("set", "sicert", "username", "test.sicert")
        self.run_config("set", "prepa", "username", "test.prepa")
        helper = Path(self.tmp.name) / "helper"
        generated = subprocess.run([str(CONTROL), "gen-helper", str(helper)], env=self.env,
                                   text=True, capture_output=True)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        engine = Path(self.tmp.name) / "fake-engine"
        engine.write_text("#!/usr/bin/python3\nimport sys, time\n"
                          "sys.stdin.readline()\n"
                          "print('Tunnel is up and running.', flush=True)\n"
                          "time.sleep(10)\n")
        engine.chmod(0o700)
        source = helper.read_text().replace(
            "ENGINE='/Library/PrivilegedHelperTools/Nuvex/openfortivpn'",
            f"ENGINE={shlex.quote(str(engine))}"
        ).replace(
            'STATE="/var/run/nuvex/$(id -u "${SUDO_USER:-root}")/${PROFILE}"',
            f'STATE={shlex.quote(self.tmp.name)}/state/${{PROFILE}}'
        )
        helper.write_text(source)
        env = dict(self.env, SUDO_USER=getpass.getuser())
        try:
            for profile in ("prepa", "sicert"):
                started = subprocess.run([str(helper), profile, "start"], input="secret\n",
                                         env=env, text=True, capture_output=True, timeout=5)
                self.assertEqual(started.returncode, 0, started.stderr)
            for profile in ("prepa", "sicert"):
                pid = int((Path(self.tmp.name) / "state" / profile / "openfortivpn.pid").read_text())
                os.kill(pid, 0)
        finally:
            for pidfile in Path(self.tmp.name).glob("state/*/openfortivpn.pid"):
                try:
                    os.kill(int(pidfile.read_text()), 15)
                except (OSError, ValueError):
                    pass

    def test_otp_is_requested_only_when_server_challenges(self):
        no_challenge = Path(self.tmp.name) / "no-challenge"
        no_challenge.write_text("#!/bin/bash\nIFS= read -r password\n"
                                "[ \"$password\" = secret ]\n")
        no_challenge.chmod(0o755)
        errors = io.StringIO()
        self.assertEqual(CONNECT.connect([str(no_challenge)], "app", io.StringIO("secret\n"), errors), 0)
        self.assertNotIn("NUVEX_OTP_REQUIRED", errors.getvalue())

        fake = Path(self.tmp.name) / "fake-helper"
        fake.write_text("#!/bin/bash\nIFS= read -r password\n"
                        "printf 'NUVEX_OTP_REQUIRED\\n' >&2\n"
                        "IFS= read -r token\n"
                        "[ \"$password\" = secret ] && [ \"$token\" = 123456 ]\n")
        fake.chmod(0o755)
        errors = io.StringIO()
        self.assertEqual(CONNECT.connect([str(fake)], "app", io.StringIO("secret\n123456\n"), errors), 0)
        self.assertEqual(errors.getvalue().count("NUVEX_OTP_REQUIRED"), 1)

    def test_connection_failure_returns_without_waiting_for_optional_code(self):
        fake = Path(self.tmp.name) / "rejected-helper"
        fake.write_text("#!/bin/bash\nIFS= read -r password\n"
                        "for i in {1..16}; do echo \"detalle $i\" >&2; done\n"
                        "echo 'No se pudo iniciar el túnel' >&2\nexit 7\n")
        fake.chmod(0o755)

        class PasswordOnly(io.StringIO):
            def readline(self, *args):
                self.test_case.assertEqual(self.read_count, 0,
                                           "se esperó un código sin desafío del servidor")
                self.read_count += 1
                return super().readline(*args)

        source = PasswordOnly("secret\n")
        source.test_case = self
        source.read_count = 0
        errors = io.StringIO()
        self.assertEqual(CONNECT.connect([str(fake)], "app", source, errors), 7)
        self.assertEqual(source.read_count, 1)
        self.assertIn("detalle 16", errors.getvalue())
        self.assertIn("No se pudo iniciar el túnel", errors.getvalue())

    def test_connection_reports_missing_or_early_exiting_helper(self):
        errors = io.StringIO()
        self.assertEqual(CONNECT.connect(["/no-existe/nuvex-helper"], "app",
                                         io.StringIO("secret\n"), errors), 5)
        self.assertIn("No se pudo iniciar el ayudante", errors.getvalue())

        class ClosedInput:
            closed = False

            def write(self, _value):
                raise BrokenPipeError()

            def close(self):
                self.closed = True

        class ExitedHelper:
            stdin = ClosedInput()
            stderr = io.StringIO("El ayudante rechazó el inicio.\n")

            def wait(self):
                return 7

        errors = io.StringIO()
        with mock.patch.object(CONNECT.subprocess, "Popen", return_value=ExitedHelper()):
            self.assertEqual(CONNECT.connect(["helper"], "app",
                                             io.StringIO("secret\n"), errors), 7)
        self.assertIn("El ayudante rechazó el inicio.", errors.getvalue())

    def test_status_is_json_without_privileged_install(self):
        result = subprocess.run([str(CONTROL), "list"], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        profiles = json.loads(result.stdout)
        self.assertEqual(len(profiles), 2)
        self.assertFalse(any(p["helperReady"] for p in profiles))


if __name__ == "__main__":
    unittest.main()
