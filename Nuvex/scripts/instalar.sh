#!/usr/bin/env bash
# Instala en /Applications la versión compilada desde el código sin perder
# datos. Las conexiones, contraseñas y ajustes viven fuera de la app, y las VPN
# activas siguen conectadas: los túneles los mantiene el ayudante, no la app.
#
# Uso: scripts/instalar.sh [--sin-pruebas] [--forzar]
set -euo pipefail

RAIZ_APP="$(cd "$(dirname "$0")/.." && pwd)"
RAIZ="$(cd "$RAIZ_APP/.." && pwd)"
DESTINO="/Applications/Nuvex.app"
VERSIONES="$HOME/Library/Application Support/Nuvex/Versiones"
CONSERVAR=3
PRUEBAS=true
FORZAR=false
for argumento in "$@"; do
  case "$argumento" in
    --sin-pruebas) PRUEBAS=false ;;
    --forzar) FORZAR=true ;;
    *) echo "Uso: $0 [--sin-pruebas] [--forzar]" >&2; exit 2 ;;
  esac
done

paso() { printf '\n==> %s\n' "$*"; }
falla() { printf 'nuvex: %s\n' "$*" >&2; exit 1; }
leer_plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

[ -w /Applications ] || falla "tu usuario no puede escribir en /Applications"

paso "Compilación"
"$RAIZ_APP/build.sh"
NUEVA="$RAIZ_APP/Nuvex.app"
codesign --verify --strict "$NUEVA" || falla "la firma de la app compilada no es válida"

if $PRUEBAS; then
  paso "Pruebas"
  (cd "$RAIZ" && python3 -m unittest discover -s tests >/dev/null 2>&1) || falla "fallaron las pruebas de Python (python3 -m unittest discover -s tests)"
  for prueba in "$RAIZ"/tests/test_*.sh; do
    bash "$prueba" >/dev/null || falla "falló $(basename "$prueba")"
  done
  echo "Todas las pruebas pasan."
fi

VERSION_NUEVA="$(leer_plist "$NUEVA" CFBundleShortVersionString)"
COMPILACION_NUEVA="$(leer_plist "$NUEVA" CFBundleVersion)"
if [ -d "$DESTINO" ]; then
  VERSION_ACTUAL="$(leer_plist "$DESTINO" CFBundleShortVersionString)"
  COMPILACION_ACTUAL="$(leer_plist "$DESTINO" CFBundleVersion)"
  if ! $FORZAR && [ "${COMPILACION_NUEVA:-0}" -lt "${COMPILACION_ACTUAL:-0}" ]; then
    falla "la versión instalada ($VERSION_ACTUAL, $COMPILACION_ACTUAL) es más nueva que la compilada ($VERSION_NUEVA, $COMPILACION_NUEVA). Usa --forzar para instalarla igualmente."
  fi
  printf 'Instalada: %s (%s) → nueva: %s (%s)\n' "$VERSION_ACTUAL" "$COMPILACION_ACTUAL" "$VERSION_NUEVA" "$COMPILACION_NUEVA"
fi

# El ayudante necesita autorización si cambió el motor. Se avisa antes, para
# hacerlo ahora y no estando fuera de casa.
MOTOR_INSTALADO="/Library/PrivilegedHelperTools/Nuvex/openfortivpn"
if [ -f "$MOTOR_INSTALADO" ] && ! cmp -s "$MOTOR_INSTALADO" "$NUEVA/Contents/Resources/openfortivpn"; then
  echo "Aviso: el motor cambió. Al abrir Nuvex, pulsa «Autorizar» para actualizar el ayudante de red."
fi

# No se reinicia en medio de una conexión o esperando un código.
NUVEX_INSTALADO="$DESTINO/Contents/Resources/bin/nuvex"
if ! $FORZAR && [ -x "$NUVEX_INSTALADO" ] && pgrep -f "^$DESTINO/Contents/MacOS/Nuvex$" >/dev/null; then
  if "$NUVEX_INSTALADO" estado --json 2>/dev/null | grep -qE '"estado":"(conectando|esperando_codigo)"'; then
    falla "hay una VPN conectándose o esperando un código; espera a que termine o usa --forzar"
  fi
fi

paso "Cierre de Nuvex"
# Todas las copias en ejecución, incluidas las de otras carpetas: dos Nuvex a
# la vez compiten por el ayudante y los avisos.
PIDS="$(pgrep -f '/Nuvex\.app/Contents/MacOS/Nuvex$' || true)"
for pid in $PIDS; do
  ruta="$(ps -p "$pid" -o command= 2>/dev/null | sed 's|/Contents/MacOS/Nuvex$||')"
  if [ "$ruta" != "$DESTINO" ]; then
    echo "Cerrando otra copia de Nuvex en uso: $ruta"
  fi
  kill -TERM "$pid" 2>/dev/null || true
done
for _ in $(seq 1 20); do
  pgrep -f '/Nuvex\.app/Contents/MacOS/Nuvex$' >/dev/null || break
  sleep 0.5
done
pgrep -f '/Nuvex\.app/Contents/MacOS/Nuvex$' >/dev/null && falla "Nuvex no se cerró; ciérralo desde su menú y vuelve a intentarlo"

paso "Instalación"
if [ -d "$DESTINO" ]; then
  mkdir -p "$VERSIONES"
  chmod 700 "$VERSIONES"
fi
# Las versiones guardadas por instaladores anteriores eran paquetes .app y
# podían aparecer en la búsqueda de aplicaciones. Se archivan de la más antigua
# a la más reciente para conservar su orden antes de guardar la versión actual.
while IFS= read -r antigua; do
  archivo="${antigua%.app}.zip"
  [ ! -e "$archivo" ] || falla "ya existe $archivo; no se reemplazó $antigua"
  "$RAIZ_APP/scripts/guardar-respaldo.sh" "$antigua" "$archivo" \
    || falla "no se pudo archivar $antigua"
  rm -rf "$antigua"
done < <(ls -1tr "$VERSIONES"/Nuvex-*.app 2>/dev/null || true)
if [ -d "$DESTINO" ]; then
  RESPALDO="$VERSIONES/Nuvex-${VERSION_ACTUAL:-anterior}-${COMPILACION_ACTUAL:-0}-$(date +%Y%m%d-%H%M%S).zip"
  "$RAIZ_APP/scripts/guardar-respaldo.sh" "$DESTINO" "$RESPALDO" \
    || falla "no se pudo guardar la versión anterior"
  echo "Versión anterior guardada en: $RESPALDO"
fi
# Conserva las versiones más recientes.
if ls "$VERSIONES"/Nuvex-*.zip >/dev/null 2>&1; then
  ls -1dt "$VERSIONES"/Nuvex-*.zip | tail -n +$((CONSERVAR + 1)) | while IFS= read -r vieja; do
    rm -f "$vieja"
  done
fi
TEMPORAL="/Applications/.Nuvex.nueva.app"
rm -rf "$TEMPORAL"
ditto "$NUEVA" "$TEMPORAL"
if [ -d "$DESTINO" ]; then
  mv "$DESTINO" "/Applications/.Nuvex.anterior.app"
fi
mv "$TEMPORAL" "$DESTINO"
rm -rf "/Applications/.Nuvex.anterior.app"

paso "Apertura"
open "$DESTINO"
for _ in $(seq 1 20); do
  pgrep -f "^$DESTINO/Contents/MacOS/Nuvex$" >/dev/null && break
  sleep 0.5
done
pgrep -f "^$DESTINO/Contents/MacOS/Nuvex$" >/dev/null || falla "Nuvex no se abrió; ábrelo desde Aplicaciones"
if [ -x "$DESTINO/Contents/Resources/bin/nuvex" ]; then
  "$DESTINO/Contents/Resources/bin/nuvex" doctor || true
else
  "$DESTINO/Contents/Resources/nuvexctl.sh" list | python3 -c '
import json, sys
for vpn in json.load(sys.stdin):
    print(("● " if vpn["connected"] else "○ ") + vpn["name"] + (" (conectada)" if vpn["connected"] else ""))
' || true
fi

# La compilación es otra app con el mismo identificador. Tras comprobar
# la copia instalada, se retira para evitar duplicados en la búsqueda de apps.
if diferencias=$(rsync -r -l -p -c -n --delete --itemize-changes "$NUEVA/" "$DESTINO/" 2>/dev/null) \
   && [ -z "$diferencias" ]; then
  rm -rf "$NUEVA"
else
  echo "Aviso: se conservó la compilación porque no coincide con la app instalada."
fi
printf '\nNuvex %s (%s) instalado. Para volver a la versión anterior: %s/scripts/revertir.sh\n' \
  "$VERSION_NUEVA" "$COMPILACION_NUEVA" "$RAIZ_APP"
