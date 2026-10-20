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
codesign --verify --deep --strict "$temporal/extraido/Nuvex.app"
[ -L "$temporal/extraido/Nuvex.app/Contents/ejecutable" ]
[ "$(readlink "$temporal/extraido/Nuvex.app/Contents/ejecutable")" = MacOS/Nuvex ]
[ -x "$temporal/extraido/Nuvex.app/Contents/MacOS/Nuvex" ]

# El reemplazo conserva la app anterior hasta que el llamador confirma la
# nueva. Si la comprobación falla, la restaura sin depender del ZIP manual.
. "$ROOT/Nuvex/scripts/transaccion-app.sh"
transaccion="$temporal/transaccion"
mkdir "$transaccion"
anterior="$transaccion/anterior.app"
nueva="$transaccion/nueva.app"
destino="$transaccion/Nuvex.app"
ditto "$origen" "$anterior"
ditto "$origen" "$nueva"
mkdir -p "$anterior/Contents/Resources" "$nueva/Contents/Resources"
printf 'anterior\n' > "$anterior/Contents/Resources/version-prueba"
printf 'nueva\n' > "$nueva/Contents/Resources/version-prueba"
codesign --force --deep --sign - "$anterior" >/dev/null
codesign --force --deep --sign - "$nueva" >/dev/null
ditto "$anterior" "$destino"
nuvex_preparar_reemplazo "$nueva" "$destino"
[ "$(cat "$destino/Contents/Resources/version-prueba")" = nueva ]
[ -d "$transaccion/.Nuvex.anterior.app" ]
nuvex_revertir_reemplazo
[ "$(cat "$destino/Contents/Resources/version-prueba")" = anterior ]
[ ! -e "$transaccion/.Nuvex.anterior.app" ]
nuvex_preparar_reemplazo "$nueva" "$destino"
nuvex_confirmar_reemplazo
[ "$(cat "$destino/Contents/Resources/version-prueba")" = nueva ]
[ ! -e "$transaccion/.Nuvex.anterior.app" ]

# Una ejecución nueva recupera primero una app que quedó apartada por una
# interrupción ocurrida entre los dos movimientos del reemplazo.
interrumpida="$temporal/interrumpida"
mkdir "$interrumpida"
destino_interrumpido="$interrumpida/Nuvex.app"
anterior_interrumpida="$interrumpida/.Nuvex.anterior.app"
ditto "$anterior" "$anterior_interrumpida"
nuvex_preparar_reemplazo "$nueva" "$destino_interrumpido"
[ "$(cat "$destino_interrumpido/Contents/Resources/version-prueba")" = nueva ]
[ "$(cat "$anterior_interrumpida/Contents/Resources/version-prueba")" = anterior ]
nuvex_revertir_reemplazo
[ "$(cat "$destino_interrumpido/Contents/Resources/version-prueba")" = anterior ]
[ ! -e "$anterior_interrumpida" ]

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
linea_respaldo_actual="$(grep -nF 'RESPALDO_NUEVO="$VERSIONES/Nuvex-' "$instalador" | cut -d: -f1)"
linea_reemplazo="$(grep -nF 'nuvex_preparar_reemplazo "$NUEVA" "$DESTINO"' "$instalador" | cut -d: -f1)"
linea_reabrir="$(grep -nF 'REABRIR_TRAS_FALLO=true' "$instalador" | cut -d: -f1)"
linea_respuesta="$(grep -nF 'nuvex_control_responde "$COMANDO_INSTALADO"' "$instalador" | cut -d: -f1)"
linea_confirmacion="$(grep -nF 'nuvex_confirmar_reemplazo || falla' "$instalador" | cut -d: -f1)"
linea_rotacion="$(grep -nF 'tail -n +$((CONSERVAR + 1))' "$instalador" | cut -d: -f1)"
[ "$linea_compilacion" -lt "$linea_pruebas" ]
[ "$linea_migracion" -lt "$linea_respaldo_actual" ]
[ "$linea_respaldo_actual" -lt "$linea_reemplazo" ]
[ "$linea_reabrir" -lt "$linea_reemplazo" ]
[ "$linea_reemplazo" -lt "$linea_respuesta" ]
[ "$linea_respuesta" -lt "$linea_confirmacion" ]
[ "$linea_confirmacion" -lt "$linea_rotacion" ]

transaccion_lib="$ROOT/Nuvex/scripts/transaccion-app.sh"
linea_activar="$(grep -nF 'NUVEX_TRANSACCION_ACTIVA=true' "$transaccion_lib" | cut -d: -f1)"
linea_apartar="$(grep -nF 'mv "$destino" "$NUVEX_TRANSACCION_ANTERIOR"' "$transaccion_lib" | cut -d: -f1)"
[ "$linea_activar" -lt "$linea_apartar" ]

restaurador="$ROOT/Nuvex/scripts/revertir.sh"
linea_permiso_restauracion="$(grep -nF '[ -w /Applications ] || falla' "$restaurador" | cut -d: -f1)"
linea_guardia_restauracion="$(grep -nF 'nuvex_estado_operacion_vpn "$COMANDO_INSTALADO"' "$restaurador" | cut -d: -f1)"
linea_cierre_restauracion="$(grep -nF 'nuvex_cerrar_app "$DESTINO"' "$restaurador" | tail -1 | cut -d: -f1)"
linea_reabrir_restauracion="$(grep -nF 'REABRIR_TRAS_FALLO=true' "$restaurador" | cut -d: -f1)"
linea_reemplazo_restauracion="$(grep -nF 'nuvex_preparar_reemplazo "$FUENTE" "$DESTINO"' "$restaurador" | cut -d: -f1)"
[ "$linea_permiso_restauracion" -lt "$linea_guardia_restauracion" ]
[ "$linea_guardia_restauracion" -lt "$linea_cierre_restauracion" ]
[ "$linea_reabrir_restauracion" -lt "$linea_reemplazo_restauracion" ]
! grep -qF "'/Nuvex\\.app/Contents/MacOS/Nuvex$'" "$instalador" "$restaurador"
echo 'Versiones: respaldo íntegro y reemplazo recuperable'
