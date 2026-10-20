#!/usr/bin/env python3
"""Restaura las URL históricas que generate_appcast asigna al tag actual."""

from __future__ import annotations

import argparse
import os
import re
import tempfile
from pathlib import Path


SEMVER = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"


def ajustar(ruta: Path, repositorio: str, version_actual: str) -> int:
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repositorio) is None:
        raise ValueError("el repositorio debe tener la forma propietario/proyecto")
    if re.fullmatch(SEMVER, version_actual) is None:
        raise ValueError(f"versión SemVer inválida: {version_actual}")
    try:
        contenido = ruta.read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError(f"no se pudo leer el appcast: {error}") from error

    prefijo = f"https://github.com/{repositorio}/releases/download/v{version_actual}/Nuvex-"
    patron = re.compile(re.escape(prefijo) + f"(?P<version>{SEMVER})\\.zip")
    cambios = 0

    def reemplazar(coincidencia: re.Match[str]) -> str:
        nonlocal cambios
        version = coincidencia.group("version")
        if version == version_actual:
            return coincidencia.group(0)
        cambios += 1
        return (
            f"https://github.com/{repositorio}/releases/download/v{version}/"
            f"Nuvex-{version}.zip"
        )

    ajustado = patron.sub(reemplazar, contenido)
    if ajustado == contenido:
        return 0

    temporal: Path | None = None
    try:
        descriptor, nombre = tempfile.mkstemp(prefix=f".{ruta.name}.", dir=ruta.parent)
        temporal = Path(nombre)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as archivo:
            archivo.write(ajustado)
            archivo.flush()
            os.fsync(archivo.fileno())
        os.replace(temporal, ruta)
    except OSError as error:
        if temporal is not None:
            temporal.unlink(missing_ok=True)
        raise ValueError(f"no se pudo actualizar el appcast: {error}") from error
    return cambios


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("appcast", type=Path)
    parser.add_argument("repositorio")
    parser.add_argument("version")
    argumentos = parser.parse_args()
    try:
        ajustar(argumentos.appcast, argumentos.repositorio, argumentos.version)
    except ValueError as error:
        parser.exit(1, f"appcast: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
