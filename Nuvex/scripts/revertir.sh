#!/usr/bin/env bash
# Vuelve a una versión anterior guardada por instalar.sh. Los datos no se
# tocan; si la versión más nueva cambió el formato de los ajustes, la anterior
# los abre en modo de solo lectura y avisa.
#
# Uso: scripts/revertir.sh [ruta a Nuvex-X.Y.Z-N-fecha.app]
set -euo pipefail

DESTINO="/Applications/Nuvex.app"
VERSIONES="$HOME/Library/Application Support/Nuvex/Versiones"
falla() { printf 'nuvex: %s\n' "$*" >&2; exit 1; }

ANTERIOR="${1:-$(ls -1dt "$VERSIONES"/Nuvex-*.app 2>/dev/null | head -1 || true)}"
[ -n "$ANTERIOR" ] && [ -d "$ANTERIOR" ] || falla "no hay versiones guardadas en $VERSIONES"
codesign --verify --strict "$ANTERIOR" || falla "la firma de $ANTERIOR no es válida"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ANTERIOR/Contents/Info.plist")"
echo "Volviendo a Nuvex $VERSION desde $ANTERIOR"

for pid in $(pgrep -f '/Nuvex\.app/Contents/MacOS/Nuvex$' || true); do kill -TERM "$pid" 2>/dev/null || true; done
for _ in $(seq 1 20); do pgrep -f '/Nuvex\.app/Contents/MacOS/Nuvex$' >/dev/null || break; sleep 0.5; done
pgrep -f '/Nuvex\.app/Contents/MacOS/Nuvex$' >/dev/null && falla "Nuvex no se cerró; ciérralo desde su menú y vuelve a intentarlo"

TEMPORAL="/Applications/.Nuvex.nueva.app"
rm -rf "$TEMPORAL"
ditto "$ANTERIOR" "$TEMPORAL"
[ -d "$DESTINO" ] && mv "$DESTINO" "/Applications/.Nuvex.anterior.app"
mv "$TEMPORAL" "$DESTINO"
rm -rf "/Applications/.Nuvex.anterior.app"
open "$DESTINO"
echo "Listo: Nuvex $VERSION está instalado. Si el motor cambió, Nuvex pedirá autorizar el ayudante."
