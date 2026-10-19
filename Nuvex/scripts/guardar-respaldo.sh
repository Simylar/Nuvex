#!/usr/bin/env bash
# Empaqueta una app y comprueba que el ZIP conserva archivos, enlaces y permisos.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "Uso: $0 origen.app respaldo.zip" >&2; exit 2; }
ORIGEN="$1"
ARCHIVO="$2"
[ -d "$ORIGEN" ] && [ -f "$ORIGEN/Contents/Info.plist" ] \
  || { echo "Respaldo inválido: $ORIGEN" >&2; exit 1; }
[ ! -e "$ARCHIVO" ] && [ ! -L "$ARCHIVO" ] \
  || { echo "Ya existe: $ARCHIVO" >&2; exit 1; }

TEMPORAL="$(mktemp -d "$(dirname "$ARCHIVO")/.empaquetar.XXXXXX")"
COMPLETO=false
limpiar() {
  rm -rf "$TEMPORAL"
  $COMPLETO || rm -f "$ARCHIVO"
}
trap limpiar EXIT

ditto "$ORIGEN" "$TEMPORAL/Nuvex.app"
ditto -c -k --sequesterRsrc --keepParent "$TEMPORAL/Nuvex.app" "$ARCHIVO"
mkdir "$TEMPORAL/verificacion"
ditto -x -k "$ARCHIVO" "$TEMPORAL/verificacion"
diferencias=$(rsync -r -l -p -c -n --delete --itemize-changes \
  "$ORIGEN/" "$TEMPORAL/verificacion/Nuvex.app/")
[ -z "$diferencias" ] || { echo "El ZIP no coincide con $ORIGEN" >&2; exit 1; }
COMPLETO=true
