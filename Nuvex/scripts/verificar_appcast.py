#!/usr/bin/env python3
"""Comprueba el contrato publicable de una versión en un appcast de Sparkle."""

from __future__ import annotations

import argparse
import base64
import binascii
import sys
import urllib.parse
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def _validar_firma(elemento: ET.Element, descripcion: str) -> None:
    firma = elemento.get(f"{{{SPARKLE}}}edSignature", "").strip()
    if not firma:
        raise ValueError(f"{descripcion} no tiene firma EdDSA")
    try:
        firma_cruda = base64.b64decode(firma, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError(f"la firma EdDSA de {descripcion} no es Base64 válido") from error
    if len(firma_cruda) != 64:
        raise ValueError(
            f"la firma EdDSA de {descripcion} no tiene la longitud Ed25519 esperada"
        )


def _validar_descarga(
    elemento: ET.Element,
    descripcion: str,
    extension: str,
    direccion_esperada: str | None = None,
    archivo: Path | None = None,
) -> tuple[str, int]:
    direccion = elemento.get("url", "")
    partes = urllib.parse.urlparse(direccion)
    if (
        partes.scheme != "https"
        or not partes.netloc
        or partes.username is not None
        or partes.password is not None
        or partes.query
        or partes.fragment
        or not partes.path.endswith(extension)
    ):
        raise ValueError(
            f"la descarga de {descripcion} debe ser un archivo {extension} servido mediante HTTPS"
        )
    if direccion_esperada is not None and direccion != direccion_esperada:
        raise ValueError(f"la descarga no apunta al archivo esperado: {direccion}")
    try:
        tamano = int(elemento.get("length", ""))
    except ValueError as error:
        raise ValueError(f"el tamaño de {descripcion} no es numérico") from error
    if tamano <= 0:
        raise ValueError(f"el tamaño de {descripcion} debe ser mayor que cero")
    if archivo is not None:
        try:
            tamano_real = archivo.stat().st_size
        except OSError as error:
            raise ValueError(f"no se pudo leer {descripcion}: {error}") from error
        if not archivo.is_file():
            raise ValueError(f"{descripcion} no es un archivo regular")
        if tamano != tamano_real:
            raise ValueError(
                f"el tamaño declarado ({tamano}) no coincide con {descripcion} ({tamano_real})"
            )
    _validar_firma(elemento, descripcion)
    return direccion, tamano


def verificar(
    ruta: Path,
    version: str,
    compilacion: str,
    canal: str = "",
    direccion_esperada: str | None = None,
    archivo: Path | None = None,
    directorio_archivos: Path | None = None,
) -> None:
    try:
        raiz = ET.parse(ruta).getroot()
    except (ET.ParseError, OSError) as error:
        raise ValueError(f"no se pudo leer el appcast: {error}") from error

    items = raiz.findall("./channel/item")
    candidatos: list[ET.Element] = []
    for item in items:
        build = item.findtext(f"{{{SPARKLE}}}version", "").strip()
        corta = item.findtext(f"{{{SPARKLE}}}shortVersionString", "").strip()
        if build == compilacion and corta == version:
            candidatos.append(item)
        elif build == compilacion:
            raise ValueError(
                f"la compilación {compilacion} también está asociada a la versión {corta or 'vacía'}"
            )
        elif corta == version:
            raise ValueError(
                f"la versión {version} también está asociada a la compilación {build or 'vacía'}"
            )
    if len(candidatos) != 1:
        raise ValueError(
            f"se esperaba exactamente una entrada para Nuvex {version} ({compilacion}) y se encontraron {len(candidatos)}"
        )

    item = candidatos[0]
    canal_publicado = item.findtext(f"{{{SPARKLE}}}channel", "").strip()
    if canal_publicado != canal:
        esperado = canal or "estable"
        encontrado = canal_publicado or "estable"
        raise ValueError(f"canal incorrecto: se esperaba {esperado} y se encontró {encontrado}")

    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("la versión no contiene un archivo descargable")
    direccion, _ = _validar_descarga(
        enclosure,
        "el ZIP publicado",
        ".zip",
        direccion_esperada,
        archivo,
    )

    prefijo_actual = direccion.rsplit("/", 1)[0] + "/"
    deltas = item.findall(f"{{{SPARKLE}}}deltas/enclosure")
    origenes: set[str] = set()
    referenciados: set[str] = set()
    for delta in deltas:
        origen = delta.get(f"{{{SPARKLE}}}deltaFrom", "").strip()
        if not origen:
            raise ValueError("una actualización delta no declara su compilación de origen")
        if origen == compilacion:
            raise ValueError("una actualización delta no puede partir de su propia compilación")
        if origen in origenes:
            raise ValueError(f"hay más de un delta desde la compilación {origen}")
        origenes.add(origen)

        ruta_delta: Path | None = None
        direccion_delta = delta.get("url", "")
        nombre = urllib.parse.unquote(urllib.parse.urlparse(direccion_delta).path.rsplit("/", 1)[-1])
        if not nombre or "/" in nombre or "\\" in nombre or nombre in {".", ".."}:
            raise ValueError("una actualización delta tiene un nombre de archivo inválido")
        if not nombre.startswith(f"Nuvex{compilacion}-") or not nombre.endswith(".delta"):
            raise ValueError(
                f"el delta desde la compilación {origen} no corresponde a la compilación nueva"
            )
        if nombre in referenciados:
            raise ValueError(f"el archivo delta {nombre} aparece más de una vez")
        if directorio_archivos is not None:
            ruta_delta = directorio_archivos / nombre
        direccion_validada, _ = _validar_descarga(
            delta,
            f"el delta desde la compilación {origen}",
            ".delta",
            archivo=ruta_delta,
        )
        if not direccion_validada.startswith(prefijo_actual):
            raise ValueError(
                f"el delta desde la compilación {origen} no pertenece a la publicación actual"
            )
        referenciados.add(nombre)

    if directorio_archivos is not None:
        try:
            presentes = {ruta.name for ruta in directorio_archivos.glob("*.delta") if ruta.is_file()}
            paquetes = [
                ruta for ruta in directorio_archivos.glob("Nuvex-*.zip") if ruta.is_file()
            ]
        except OSError as error:
            raise ValueError(f"no se pudo revisar el directorio de publicación: {error}") from error
        sobrantes = presentes - referenciados
        if sobrantes:
            raise ValueError(
                "hay archivos delta que el appcast no referencia: " + ", ".join(sorted(sobrantes))
            )
        for paquete in paquetes:
            entradas: list[tuple[ET.Element, ET.Element]] = []
            for entrada in items:
                descarga = entrada.find("enclosure")
                if descarga is None:
                    continue
                nombre_descarga = urllib.parse.unquote(
                    urllib.parse.urlparse(descarga.get("url", "")).path.rsplit("/", 1)[-1]
                )
                if nombre_descarga == paquete.name:
                    entradas.append((entrada, descarga))
            if len(entradas) != 1:
                raise ValueError(
                    f"el ZIP local {paquete.name} debe aparecer exactamente una vez en el appcast"
                )
            entrada, descarga = entradas[0]
            version_local = paquete.name.removeprefix("Nuvex-").removesuffix(".zip")
            version_declarada = entrada.findtext(
                f"{{{SPARKLE}}}shortVersionString", ""
            ).strip()
            if version_declarada != version_local:
                raise ValueError(
                    f"el ZIP local {paquete.name} declara la versión "
                    f"{version_declarada or 'vacía'}"
                )
            canal_local = entrada.findtext(f"{{{SPARKLE}}}channel", "").strip()
            es_previa = "-" in version_local.split("+", 1)[0]
            canal_esperado = "beta" if es_previa else ""
            if canal_local != canal_esperado:
                esperado = canal_esperado or "estable"
                encontrado = canal_local or "estable"
                raise ValueError(
                    f"el ZIP local {paquete.name} tiene canal {encontrado}; "
                    f"se esperaba {esperado}"
                )
            _validar_descarga(descarga, f"el ZIP local {paquete.name}", ".zip", archivo=paquete)
            descripcion = entrada.find("description")
            notas = "" if descripcion is None else "".join(descripcion.itertext()).strip()
            if not notas:
                raise ValueError(f"el ZIP local {paquete.name} no conserva sus notas de versión")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("appcast", type=Path)
    parser.add_argument("version")
    parser.add_argument("compilacion")
    parser.add_argument("--canal", default="", choices=("", "beta"))
    parser.add_argument("--url-esperada")
    parser.add_argument("--archivo", type=Path)
    parser.add_argument("--directorio-archivos", type=Path)
    argumentos = parser.parse_args()
    try:
        verificar(
            argumentos.appcast,
            argumentos.version,
            argumentos.compilacion,
            argumentos.canal,
            argumentos.url_esperada,
            argumentos.archivo,
            argumentos.directorio_archivos,
        )
    except ValueError as error:
        print(f"appcast: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
