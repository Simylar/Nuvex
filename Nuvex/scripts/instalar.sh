#!/usr/bin/env bash
# Instala en /Applications la versión compilada desde el código sin perder
# datos. Las conexiones, contraseñas y ajustes viven fuera de la app, y las VPN
# activas siguen conectadas: los túneles los mantiene el ayudante, no la app.
#
# Uso: scripts/instalar.sh [--sin-pruebas] [--forzar]
set -euo pipefail

RAIZ_APP="$(cd "$(dirname "$0")/.." && pwd)"
RAIZ="$(cd "$RAIZ_APP/.." && pwd)"
. "$RAIZ_APP/scripts/transaccion-app.sh"
. "$RAIZ_APP/scripts/ciclo-app.sh"
DESTINO="/Applications/Nuvex.app"
VERSIONES="$HOME/Library/Application Support/Nuvex/Versiones"
CONSERVAR=3
PRUEBAS=true
FORZAR=false
RESPALDO_NUEVO=""
INSTALACION_CONFIRMADA=false
REABRIR_TRAS_FALLO=false
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

recuperar_instalacion() {
  local estado=$?
  local recuperada=true
  trap - EXIT
  if [ "$estado" -ne 0 ] && $NUVEX_TRANSACCION_ACTIVA; then
    nuvex_cerrar_app "$DESTINO" || true
    if nuvex_revertir_reemplazo && [ -d "$DESTINO" ]; then
      echo "Se restauró automáticamente la versión anterior de Nuvex." >&2
    else
      recuperada=false
      echo "No se pudo restaurar automáticamente Nuvex; el respaldo se conservó." >&2
    fi
  fi
  if [ "$estado" -ne 0 ] && $REABRIR_TRAS_FALLO && [ -d "$DESTINO" ]; then
    if ! open "$DESTINO" >/dev/null 2>&1; then
      echo "No se pudo volver a abrir Nuvex automáticamente; ábrelo desde Aplicaciones." >&2
    fi
  fi
  if [ "$estado" -ne 0 ] && ! $INSTALACION_CONFIRMADA && $recuperada \
    && [ -n "$RESPALDO_NUEVO" ] && [ -f "$RESPALDO_NUEVO" ]; then
    rm -f "$RESPALDO_NUEVO"
  fi
  exit "$estado"
}
trap recuperar_instalacion EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ -w /Applications ] || falla "tu usuario no puede escribir en /Applications"

paso "Compilación"
"$RAIZ_APP/build.sh"
NUEVA="$RAIZ_APP/Nuvex.app"
codesign --verify --deep --strict "$NUEVA" || falla "la firma de la app compilada no es válida"

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
if ! $FORZAR; then
  if nuvex_app_abierta "$DESTINO"; then
    if nuvex_estado_operacion_vpn "$NUVEX_INSTALADO"; then
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

paso "Cierre de Nuvex"
# Solo se cierra la copia instalada. Una compilación o copia de respaldo que la
# persona tenga abierta no pertenece a esta operación.
nuvex_cerrar_app "$DESTINO" \
  || falla "la copia instalada de Nuvex no se cerró; ciérrala desde su menú y vuelve a intentarlo"
[ ! -d "$DESTINO" ] || REABRIR_TRAS_FALLO=true

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
  RESPALDO_NUEVO="$VERSIONES/Nuvex-${VERSION_ACTUAL:-anterior}-${COMPILACION_ACTUAL:-0}-$(date +%Y%m%d-%H%M%S).zip"
  "$RAIZ_APP/scripts/guardar-respaldo.sh" "$DESTINO" "$RESPALDO_NUEVO" \
    || falla "no se pudo guardar la versión anterior"
  echo "Versión anterior guardada en: $RESPALDO_NUEVO"
fi
nuvex_preparar_reemplazo "$NUEVA" "$DESTINO" \
  || falla "no se pudo preparar el reemplazo recuperable de la aplicación"

paso "Apertura"
open "$DESTINO"
for _ in $(seq 1 20); do
  nuvex_app_abierta "$DESTINO" && break
  sleep 0.5
done
nuvex_app_abierta "$DESTINO" || falla "Nuvex no se abrió; ábrelo desde Aplicaciones"
codesign --verify --deep --strict "$DESTINO" || falla "la app instalada no superó la verificación de firma"
[ "$(leer_plist "$DESTINO" CFBundleShortVersionString)" = "$VERSION_NUEVA" ] \
  && [ "$(leer_plist "$DESTINO" CFBundleVersion)" = "$COMPILACION_NUEVA" ] \
  || falla "la versión instalada no coincide con la compilación preparada"

COMANDO_INSTALADO="$DESTINO/Contents/Resources/bin/nuvex"
[ -x "$COMANDO_INSTALADO" ] || falla "la app instalada no incluye el comando de diagnóstico"
RESPONDIO=false
for _ in $(seq 1 20); do
  if nuvex_control_responde "$COMANDO_INSTALADO"; then
    RESPONDIO=true
    break
  fi
  sleep 0.5
done
$RESPONDIO || falla "Nuvex abrió, pero no respondió correctamente al diagnóstico de la instalación"
nuvex_confirmar_reemplazo || falla "no se pudo cerrar la transacción de instalación"
INSTALACION_CONFIRMADA=true
REABRIR_TRAS_FALLO=false
# Solo una instalación confirmada puede desplazar respaldos históricos.
if ls "$VERSIONES"/Nuvex-*.zip >/dev/null 2>&1; then
  ls -1dt "$VERSIONES"/Nuvex-*.zip | tail -n +$((CONSERVAR + 1)) | while IFS= read -r vieja; do
    rm -f "$vieja"
  done
fi
"$COMANDO_INSTALADO" doctor || true

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
