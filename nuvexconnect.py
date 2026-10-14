#!/usr/bin/env python3
"""Puente de entrada estándar entre Nuvex, sudo y el desafío OTP del servidor."""

import getpass
import subprocess
import sys


OTP_MARKER = "NUVEX_OTP_REQUIRED"


def connect(command, mode, source=sys.stdin, errors=sys.stderr):
    password = source.readline().rstrip("\n")
    if not password:
        print("Falta la contraseña de la VPN.", file=errors)
        return 3
    try:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.PIPE, text=True, bufsize=1)
    except OSError as error:
        print(f"No se pudo iniciar el ayudante VPN: {error.strerror or error}", file=errors)
        return 5
    try:
        process.stdin.write(password + "\n")
        process.stdin.flush()
    except BrokenPipeError:
        # El ayudante puede rechazar el inicio antes de leer la contraseña.
        try:
            process.stdin.close()
        except BrokenPipeError:
            pass
    password = ""
    asked = False
    try:
        for line in process.stderr:
            if OTP_MARKER in line and not asked and not process.stdin.closed:
                asked = True
                if mode == "app":
                    print(OTP_MARKER, file=errors, flush=True)
                    token = source.readline().rstrip("\n")
                else:
                    try:
                        token = getpass.getpass("Código solicitado por la VPN: ")
                    except (EOFError, KeyboardInterrupt):
                        token = ""
                if token:
                    try:
                        process.stdin.write(token + "\n")
                        process.stdin.flush()
                    except BrokenPipeError:
                        pass
                try:
                    process.stdin.close()
                except BrokenPipeError:
                    pass
            else:
                errors.write(line)
                errors.flush()
        if not process.stdin.closed:
            try:
                process.stdin.close()
            except BrokenPipeError:
                pass
        return process.wait()
    finally:
        process.stderr.close()


def main(args):
    if len(args) != 3 or args[2] not in ("app", "terminal"):
        print("Uso: nuvexconnect.py AYUDANTE PERFIL app|terminal", file=sys.stderr)
        return 2
    helper, profile, mode = args
    return connect(["/usr/bin/sudo", "-n", helper, profile, "start"], mode)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
