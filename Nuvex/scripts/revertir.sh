#!/usr/bin/env bash
# Vuelve a una versión anterior guardada por instalar.sh. Los datos no se
# tocan; si la versión más nueva cambió el formato de los ajustes, la anterior
# los abre en modo de solo lectura y avisa.
#
# Uso: scripts/revertir.sh [--forzar] [ruta a Nuvex-X.Y.Z-N-fecha.zip]
set -euo pipefail

RAIZ_APP="$(cd "$(dirname "$0")/.." && pwd)"
. "$RAIZ_APP/scripts/transaccion-app.sh"
. "$RAIZ_APP/scripts/ciclo-app.sh"
DESTINO="/Applications/Nuvex.app"
VERSIONES="$HOME/Library/Application Support/Nuvex/Versiones"
EXTRAIDO=""
FORZAR=false
ANTERIOR=""
REABRIR_TRAS_FALLO=false
falla() { printf 'nuvex: %s\n' "$*" >&2; exit 1; }
leer_plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

for argumento in "$@"; do
  case "$argumento" in
    --forzar) FORZAR=true ;;
    -*) echo "Uso: $0 [--forzar] [ruta a Nuvex-X.Y.Z-N-fecha.zip]" >&2; exit 2 ;;
    *)
      [ -z "$ANTERIOR" ] || { echo "Uso: $0 [--forzar] [ruta a Nuvex-X.Y.Z-N-fecha.zip]" >&2; exit 2; }
      ANTERIOR="$argumento"
      ;;
  esac
done

recuperar_reversion() {
  local estado=$?
  trap - EXIT
  if [ "$estado" -ne 0 ] && $NUVEX_TRANSACCION_ACTIVA; then
    nuvex_cerrar_app "$DESTINO" || true
    if nuvex_revertir_reemplazo && [ -d "$DESTINO" ]; then
      echo "Se restauró automáticamente la versión que estaba instalada." >&2
    else
      echo "No se pudo recuperar automáticamente la versión instalada; se conservó el reemplazo temporal." >&2
    fi
  fi
  if [ "$estado" -ne 0 ] && $REABRIR_TRAS_FALLO && [ -d "$DESTINO" ]; then
    if ! open "$DESTINO" >/dev/null 2>&1; then
      echo "No se pudo volver a abrir Nuvex automáticamente; ábrelo desde Aplicaciones." >&2
    fi
  fi
  case "$EXTRAIDO" in
    /private/tmp/nuvex-restaurar.*) rm -rf "$EXTRAIDO" ;;
  esac
  exit "$estado"
}
trap recuperar_reversion EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ -w /Applications ] || falla "tu usuario no puede escribir en /Applications"

ANTERIOR="${ANTERIOR:-$(ls -1dt "$VERSIONES"/Nuvex-*.zip "$VERSIONES"/Nuvex-*.app 2>/dev/null | head -1 || true)}"
[ -n "$ANTERIOR" ] && [ -e "$ANTERIOR" ] || falla "no hay versiones guardadas en $VERSIONES"
if [ -f "$ANTERIOR" ] && [[ "$ANTERIOR" == *.zip ]]; then
  EXTRAIDO="$(mktemp -d /private/tmp/nuvex-restaurar.XXXXXX)" || falla "no se pudo preparar la restauración"
  ditto -x -k "$ANTERIOR" "$EXTRAIDO" || falla "no se pudo extraer $ANTERIOR"
  FUENTE="$EXTRAIDO/Nuvex.app"
else
  FUENTE="$ANTERIOR" # Compatibilidad con respaldos .app anteriores.
fi
[ -d "$FUENTE" ] || falla "el respaldo no contiene Nuvex.app"
codesign --verify --deep --strict "$FUENTE" || falla "la firma de $FUENTE no es válida"

VERSION="$(leer_plist "$FUENTE" CFBundleShortVersionString)"
COMPILACION="$(leer_plist "$FUENTE" CFBundleVersion)"
echo "Volviendo a Nuvex $VERSION desde $ANTERIOR"

COMANDO_INSTALADO="$DESTINO/Contents/Resources/bin/nuvex"
if ! $FORZAR; then
  if nuvex_app_abierta "$DESTINO"; then
    if nuvex_estado_operacion_vpn "$COMANDO_INSTALADO"; then
      falla "hay una VPN conectándose o esperando un código; espera a que termine o usa --forzar"
    else
      ESTADO_VPN=$?
      [ "$ESTADO_VPN" -eq 1 ] \
        || falla "no se pudo comprobar si hay una conexión en curso; revisa que Nuvex responda o usa --forzar"
    fi
  else
    ESTADO_APP=$?
    [ "$ESTADO_APP" -eq 1 ] \
      || falla "no se pudo comprobar el proceso instalado de Nuvex; usa --forzar solo si confirmaste que no hay una conexión en curso"
  fi
fi

nuvex_cerrar_app "$DESTINO" \
  || falla "la copia instalada de Nuvex no se cerró; ciérrala desde su menú y vuelve a intentarlo"
[ ! -d "$DESTINO" ] || REABRIR_TRAS_FALLO=true

nuvex_preparar_reemplazo "$FUENTE" "$DESTINO" \
  || falla "no se pudo preparar la restauración recuperable"
open "$DESTINO"
for _ in $(seq 1 20); do
  nuvex_app_abierta "$DESTINO" && break
  sleep 0.5
done
nuvex_app_abierta "$DESTINO" \
  || falla "la versión restaurada no se abrió"
codesign --verify --deep --strict "$DESTINO" || falla "la versión restaurada no superó la verificación de firma"
[ "$(leer_plist "$DESTINO" CFBundleShortVersionString)" = "$VERSION" ] \
  && [ "$(leer_plist "$DESTINO" CFBundleVersion)" = "$COMPILACION" ] \
  || falla "la versión restaurada no coincide con el respaldo"
if [ -x "$DESTINO/Contents/Resources/bin/nuvex" ]; then
  RESPONDIO=false
  for _ in $(seq 1 20); do
    if nuvex_control_responde "$DESTINO/Contents/Resources/bin/nuvex"; then
      RESPONDIO=true
      break
    fi
    sleep 0.5
  done
  $RESPONDIO || falla "la versión restaurada abrió, pero no respondió al control local"
fi
nuvex_confirmar_reemplazo || falla "no se pudo cerrar la transacción de restauración"
REABRIR_TRAS_FALLO=false
echo "Listo: Nuvex $VERSION está instalado. Si el motor cambió, Nuvex pedirá autorizar el ayudante."
