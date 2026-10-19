#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
temporal="$(mktemp -d)"
trap 'rm -rf "$temporal"' EXIT
origen="$temporal/Nuvex.app"
mkdir -p "$origen/Contents/MacOS"
printf '<plist><dict/></plist>\n' > "$origen/Contents/Info.plist"
printf '#!/bin/sh\nexit 0\n' > "$origen/Contents/MacOS/Nuvex"
chmod 755 "$origen/Contents/MacOS/Nuvex"
ln -s MacOS/Nuvex "$origen/Contents/ejecutable"
codesign --force --sign - "$origen" >/dev/null

archivo="$temporal/version.zip"
"$ROOT/Nuvex/scripts/guardar-respaldo.sh" "$origen" "$archivo"
unzip -tq "$archivo" >/dev/null
mkdir "$temporal/extraido"
ditto -x -k "$archivo" "$temporal/extraido"
cmp "$origen/Contents/MacOS/Nuvex" "$temporal/extraido/Nuvex.app/Contents/MacOS/Nuvex"
codesign --verify --strict "$temporal/extraido/Nuvex.app"
[ -L "$temporal/extraido/Nuvex.app/Contents/ejecutable" ]
[ "$(readlink "$temporal/extraido/Nuvex.app/Contents/ejecutable")" = MacOS/Nuvex ]
[ -x "$temporal/extraido/Nuvex.app/Contents/MacOS/Nuvex" ]

antes="$(shasum -a 256 "$archivo")"
if "$ROOT/Nuvex/scripts/guardar-respaldo.sh" "$origen" "$archivo" >/dev/null 2>&1; then
  echo 'Se sobrescribió un respaldo existente' >&2
  exit 1
fi
[ "$(shasum -a 256 "$archivo")" = "$antes" ]

instalador="$ROOT/Nuvex/scripts/instalar.sh"
linea_compilacion="$(grep -nF '"$RAIZ_APP/build.sh"' "$instalador" | cut -d: -f1)"
linea_pruebas="$(grep -nF 'if $PRUEBAS; then' "$instalador" | cut -d: -f1)"
linea_migracion="$(grep -nF 'while IFS= read -r antigua; do' "$instalador" | cut -d: -f1)"
linea_respaldo_actual="$(grep -nF 'RESPALDO="$VERSIONES/Nuvex-' "$instalador" | cut -d: -f1)"
[ "$linea_compilacion" -lt "$linea_pruebas" ]
[ "$linea_migracion" -lt "$linea_respaldo_actual" ]
echo 'Versiones: respaldo ZIP íntegro y sin sobrescritura'
