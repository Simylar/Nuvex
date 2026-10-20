#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Nuvex/scripts/ciclo-app.sh"

temporal="$(mktemp -d /private/tmp/nuvex-ciclo-app.XXXXXX)"
pid_instalada=""
pid_otra=""
limpiar() {
  if [ -n "$pid_instalada" ]; then
    kill -TERM "$pid_instalada" 2>/dev/null || true
  fi
  if [ -n "$pid_otra" ]; then
    kill -TERM "$pid_otra" 2>/dev/null || true
  fi
  rm -rf "$temporal"
}
trap limpiar EXIT

instalada="$temporal/Aplicaciones/Nuvex.app"
otra="$temporal/Descargas/Nuvex.app"
mkdir -p "$instalada/Contents/MacOS" "$otra/Contents/MacOS"
printf '%s\n' '#include <unistd.h>' 'int main(void) { sleep(30); return 0; }' \
  > "$temporal/proceso.c"
clang "$temporal/proceso.c" -o "$temporal/proceso"
cp "$temporal/proceso" "$instalada/Contents/MacOS/Nuvex"
cp "$temporal/proceso" "$otra/Contents/MacOS/Nuvex"

pid_instalada="$(python3 -c '
import subprocess
import sys
print(subprocess.Popen([sys.argv[1], "--prueba"], stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       start_new_session=True).pid)
' "$instalada/Contents/MacOS/Nuvex")"
pid_otra="$(python3 -c '
import subprocess
import sys
print(subprocess.Popen([sys.argv[1], "--otra"], stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       start_new_session=True).pid)
' "$otra/Contents/MacOS/Nuvex")"
for _ in $(seq 1 20); do
  nuvex_app_abierta "$instalada" && nuvex_app_abierta "$otra" && break
  sleep 0.1
done
[ "$(nuvex_pids_app "$instalada")" = "$pid_instalada" ]
[ "$(nuvex_pids_app "$otra")" = "$pid_otra" ]

nuvex_cerrar_app "$instalada"
! kill -0 "$pid_instalada" 2>/dev/null
pid_instalada=""
kill -0 "$pid_otra" 2>/dev/null

pgrep() { return 2; }
if nuvex_app_abierta "$instalada"; then
  echo 'Un fallo al inspeccionar procesos se clasificó como app cerrada' >&2
  exit 1
else
  [ "$?" -eq 2 ]
fi
unset -f pgrep

comando="$temporal/nuvex"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "$ESTADO_PRUEBA" in' \
  '  conectando) printf '\''{"tipo":"resultado","salida":0,"conexiones":[{"estado":"conectando"}]}\n'\'' ;;' \
  '  segura) printf '\''{"tipo":"resultado","salida":0,"conexiones":[{"estado":"conectada"}]}\n'\'' ;;' \
  '  forma) printf '\''[]\n'\'' ;;' \
  '  *) printf '\''no es json\n'\'' ;;' \
  'esac' > "$comando"
chmod 755 "$comando"

ESTADO_PRUEBA=conectando nuvex_estado_operacion_vpn "$comando"
ESTADO_PRUEBA=conectando nuvex_control_responde "$comando"
if ESTADO_PRUEBA=segura nuvex_estado_operacion_vpn "$comando"; then
  echo 'Una conexión estable se clasificó como operación en curso' >&2
  exit 1
else
  [ "$?" -eq 1 ]
fi
ESTADO_PRUEBA=segura nuvex_control_responde "$comando"
if ESTADO_PRUEBA=invalida nuvex_estado_operacion_vpn "$comando"; then
  echo 'Una respuesta inválida se clasificó como segura' >&2
  exit 1
else
  [ "$?" -eq 2 ]
fi
if ESTADO_PRUEBA=invalida nuvex_control_responde "$comando"; then
  echo 'Un control local inválido se clasificó como disponible' >&2
  exit 1
fi
if ESTADO_PRUEBA=forma nuvex_estado_operacion_vpn "$comando"; then
  echo 'Una respuesta con esquema inválido se clasificó como segura' >&2
  exit 1
else
  [ "$?" -eq 2 ]
fi

echo 'Ciclo de app: proceso exacto y estado VPN comprobados'
