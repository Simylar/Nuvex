#!/usr/bin/env python3
"""Compara versiones SemVer sin depender del orden particular de `sort -V`."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from functools import total_ordering


PATRON = re.compile(
    r"^(?P<mayor>0|[1-9][0-9]*)\."
    r"(?P<menor>0|[1-9][0-9]*)\."
    r"(?P<parche>0|[1-9][0-9]*)"
    r"(?:-(?P<pre>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+(?P<build>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


@total_ordering
@dataclass(frozen=True)
class Version:
    mayor: int
    menor: int
    parche: int
    pre: tuple[str, ...] | None

    @classmethod
    def analizar(cls, texto: str) -> "Version":
        coincidencia = PATRON.fullmatch(texto)
        if coincidencia is None:
            raise ValueError(f"versión SemVer inválida: {texto}")
        pre_texto = coincidencia.group("pre")
        pre = tuple(pre_texto.split(".")) if pre_texto is not None else None
        if pre is not None and any(
            identificador.isdigit()
            and len(identificador) > 1
            and identificador.startswith("0")
            for identificador in pre
        ):
            raise ValueError(f"versión SemVer inválida: {texto}")
        return cls(
            int(coincidencia.group("mayor")),
            int(coincidencia.group("menor")),
            int(coincidencia.group("parche")),
            pre,
        )

    def __lt__(self, otra: object) -> bool:
        if not isinstance(otra, Version):
            return NotImplemented
        base = (self.mayor, self.menor, self.parche)
        otra_base = (otra.mayor, otra.menor, otra.parche)
        if base != otra_base:
            return base < otra_base
        if self.pre is None:
            return False
        if otra.pre is None:
            return True
        for izquierda, derecha in zip(self.pre, otra.pre):
            if izquierda == derecha:
                continue
            izquierda_numerica = izquierda.isdigit()
            derecha_numerica = derecha.isdigit()
            if izquierda_numerica and derecha_numerica:
                return int(izquierda) < int(derecha)
            if izquierda_numerica != derecha_numerica:
                return izquierda_numerica
            return izquierda < derecha
        return len(self.pre) < len(otra.pre)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("nueva", nargs="?")
    parser.add_argument("anterior", nargs="?")
    parser.add_argument(
        "--mayor",
        action="store_true",
        help="imprime la mayor versión leída de la entrada estándar",
    )
    parser.add_argument(
        "--mayor-o-igual",
        action="store_true",
        help="acepta si la primera versión es mayor o igual que la segunda",
    )
    argumentos = parser.parse_args()
    try:
        if argumentos.mayor:
            if argumentos.nueva is not None or argumentos.anterior is not None:
                parser.error("--mayor no acepta versiones como argumentos")
            versiones: list[tuple[Version, str]] = []
            for linea in sys.stdin:
                original = linea.strip()
                if not original:
                    continue
                texto = original[1:] if original.startswith("v") else original
                versiones.append((Version.analizar(texto), original))
            if versiones:
                print(max(versiones, key=lambda elemento: elemento[0])[1])
            return 0
        if argumentos.nueva is None or argumentos.anterior is None:
            parser.error("se requieren la versión nueva y la anterior")
        nueva = Version.analizar(argumentos.nueva)
        anterior = Version.analizar(argumentos.anterior)
        if argumentos.mayor_o_igual:
            if nueva < anterior:
                print(
                    f"la versión {argumentos.nueva} es menor que {argumentos.anterior}",
                    file=sys.stderr,
                )
                return 1
            return 0
        if nueva <= anterior:
            print(
                f"la versión {argumentos.nueva} no es mayor que {argumentos.anterior}",
                file=sys.stderr,
            )
            return 1
        return 0
    except ValueError as error:
        print(f"versiones: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
