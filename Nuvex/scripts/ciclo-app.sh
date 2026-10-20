#!/usr/bin/env bash
# Operaciones compartidas para cerrar y comprobar exclusivamente una copia de
# Nuvex. Se carga con `source` desde instalar.sh y revertir.sh.

nuvex_ejecutable_app() {
  [ "$#" -eq 1 ] || return 2
  case "$1" in
    /*.app) printf '%s/Contents/MacOS/Nuvex\n' "$1" ;;
    *) return 2 ;;
  esac
}

nuvex_pids_app() {
  [ "$#" -eq 1 ] || return 2
  local ejecutable patron salida estado
  ejecutable="$(nuvex_ejecutable_app "$1")" || return 2
  patron="$(python3 -c 'import re, sys; print(re.escape(sys.argv[1]))' "$ejecutable")" \
    || return 2
  # La ruta completa queda anclada; solo se permiten argumentos posteriores
  # que LaunchServices pueda añadir. Otra copia en otra carpeta queda intacta.
  if salida="$(pgrep -f "^${patron}([[:space:]].*)?$" 2>/dev/null)"; then
    printf '%s\n' "$salida"
  else
    estado=$?
    [ "$estado" -eq 1 ] || return 2
  fi
}

nuvex_app_abierta() {
  local pids
  pids="$(nuvex_pids_app "$1")" || return 2
  [ -n "$pids" ]
}

nuvex_cerrar_app() {
  [ "$#" -eq 1 ] || return 2
  local pid pids intento
  for intento in $(seq 1 20); do
    pids="$(nuvex_pids_app "$1")" || return 2
    [ -n "$pids" ] || return 0
    for pid in $pids; do
      case "$pid" in
        ''|*[!0-9]*) return 2 ;;
      esac
      kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.5
  done
  return 1
}

# Devuelve 0 si alguna conexión está arrancando o esperando código, 1 si es
# seguro continuar y 2 si no se pudo determinar. El llamador debe tratar 2
# como bloqueo, salvo que la persona haya usado --forzar explícitamente.
nuvex_estado_operacion_vpn() {
  [ "$#" -eq 1 ] && [ -x "$1" ] || return 2
  local salida
  salida="$("$1" estado --json 2>/dev/null)" || return 2
  printf '%s\n' "$salida" | python3 -c '
import json
import sys

try:
    mensajes = [json.loads(linea) for linea in sys.stdin if linea.strip()]
    if any(not isinstance(mensaje, dict) for mensaje in mensajes):
        raise ValueError
    resultados = [mensaje for mensaje in mensajes if mensaje.get("tipo") == "resultado"]
    if not resultados or resultados[-1].get("salida") != 0:
        raise ValueError
    conexiones = resultados[-1].get("conexiones")
    if not isinstance(conexiones, list) or any(
        not isinstance(conexion, dict) or not isinstance(conexion.get("estado"), str)
        for conexion in conexiones
    ):
        raise ValueError
except Exception:
    raise SystemExit(2)
estados = {conexion["estado"] for conexion in conexiones}
raise SystemExit(0 if estados & {"conectando", "esperando_codigo"} else 1)
'
}

nuvex_control_responde() {
  local estado
  if nuvex_estado_operacion_vpn "$1"; then
    return 0
  else
    estado=$?
  fi
  [ "$estado" -eq 1 ]
}
