import contextlib
import importlib.util
import io
import json
import socket
import subprocess
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("live_vpn_check.py")
spec = importlib.util.spec_from_file_location("live_vpn_check", MODULE_PATH)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class LiveVPNCheckTests(unittest.TestCase):
    def test_status_requires_a_connected_profile(self):
        profile = {"id": "vpn-test", "enabled": True, "configured": True,
                   "helperReady": True, "connected": True}
        other = dict(profile, id="vpn-other")
        result = subprocess.CompletedProcess([], 0, json.dumps([profile, other]), "")
        with mock.patch.object(check.subprocess, "run", return_value=result):
            self.assertEqual(check.profile_status("vpn-test"), ["vpn-other"])
        profile["connected"] = False
        result = subprocess.CompletedProcess([], 0, json.dumps([profile]), "")
        with mock.patch.object(check.subprocess, "run", return_value=result):
            with self.assertRaises(check.ValidationError):
                check.profile_status("vpn-test")

    def test_status_uses_real_home_without_overriding_explicit_config(self):
        profile = {"id": "vpn-test", "enabled": True, "configured": True,
                   "connected": True}
        result = subprocess.CompletedProcess([], 0, json.dumps([profile]), "")
        with mock.patch.dict(check.os.environ, {"XDG_CONFIG_HOME": "/tmp/vpn-config"}), \
                mock.patch.object(check.subprocess, "run", return_value=result) as run:
            self.assertEqual(check.profile_status("vpn-test"), [])
        self.assertEqual(run.call_args.kwargs["env"]["XDG_CONFIG_HOME"], "/tmp/vpn-config")

    def test_route_lookup_selects_address_family(self):
        result = subprocess.CompletedProcess([], 0, "interface: ppp2\n", "")
        with mock.patch.object(check.subprocess, "run", return_value=result) as run:
            self.assertEqual(check.route_interface("2001:db8::1", socket.AF_INET6), "ppp2")
        self.assertEqual(run.call_args.args[0],
                         ["/sbin/route", "-n", "get", "-inet6", "2001:db8::1"])

    def test_status_only_is_explicitly_incomplete(self):
        output = io.StringIO()
        with mock.patch.object(check, "profile_status", return_value=["vpn-other"]), \
                contextlib.redirect_stdout(output):
            self.assertEqual(check.main(["vpn-test", "--status-only"]), 2)
        self.assertIn("sin verificar", output.getvalue())

    def test_other_active_vpn_cannot_validate_a_resource(self):
        errors = io.StringIO()
        with mock.patch.object(check, "profile_status", return_value=["vpn-other"]), \
                mock.patch.object(check, "check_resource") as resource, \
                contextlib.redirect_stderr(errors):
            self.assertEqual(check.main(["vpn-test", "--host", "internal.example.org",
                                         "--port", "443"]), 1)
        resource.assert_not_called()
        self.assertIn("otras VPN", errors.getvalue())

    def test_resource_probe_uses_a_working_ppp_route(self):
        addresses = [
            (socket.AF_INET6, socket.SOCK_STREAM, 0, "", ("2001:db8::1", 443, 0, 0)),
            (socket.AF_INET, socket.SOCK_STREAM, 0, "", ("192.0.2.1", 443)),
        ]

        class FakeSocket:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return None

            def settimeout(self, _timeout):
                pass

            def connect(self, _address):
                pass

        with mock.patch.object(check.socket, "getaddrinfo", return_value=addresses), \
                mock.patch.object(check, "route_interface",
                                  side_effect=[check.ValidationError("sin ruta"), "ppp0"]), \
                mock.patch.object(check.socket, "socket", return_value=FakeSocket()):
            self.assertEqual(check.check_resource("internal.example.org", 443, 5), "ppp0")

    def test_public_route_does_not_count_as_vpn_access(self):
        addresses = [(socket.AF_INET, socket.SOCK_STREAM, 0, "", ("192.0.2.1", 443))]
        with mock.patch.object(check.socket, "getaddrinfo", return_value=addresses), \
                mock.patch.object(check, "route_interface", return_value="en0"), \
                mock.patch.object(check.socket, "socket") as connection:
            with self.assertRaises(check.ValidationError):
                check.check_resource("internal.example.org", 443, 5)
        connection.assert_not_called()


if __name__ == "__main__":
    unittest.main()
