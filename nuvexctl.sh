#!/bin/bash
# Nuvex: configuracion no secreta, estado y puente al motor Fortinet incluido.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_TOOL="${SCRIPT_DIR}/nuvexconfig.py"
CONNECT_TOOL="${SCRIPT_DIR}/nuvexconnect.py"
PYTHON="/usr/bin/python3"
ENGINE_SOURCE="${SCRIPT_DIR}/openfortivpn"
SSL_SOURCE="${SCRIPT_DIR}/libssl.3.dylib"
CRYPTO_SOURCE="${SCRIPT_DIR}/libcrypto.3.dylib"
CA_SOURCE="${SCRIPT_DIR}/prepa-ca-bundle.pem"
INSTALLED_RESOURCES="/Applications/Nuvex.app/Contents/Resources"
if [ ! -x "$ENGINE_SOURCE" ]; then
  ENGINE_SOURCE="${SCRIPT_DIR}/Nuvex/Nuvex.app/Contents/Resources/openfortivpn"
  SSL_SOURCE="${SCRIPT_DIR}/Nuvex/Nuvex.app/Contents/Resources/libssl.3.dylib"
  CRYPTO_SOURCE="${SCRIPT_DIR}/Nuvex/Nuvex.app/Contents/Resources/libcrypto.3.dylib"
  CA_SOURCE="${SCRIPT_DIR}/Nuvex/Resources/prepa-ca-bundle.pem"
fi
if [ ! -x "$ENGINE_SOURCE" ]; then
  ENGINE_SOURCE="${SCRIPT_DIR}/vendor/openfortivpn/openfortivpn"
fi
if { [ ! -x "$ENGINE_SOURCE" ] || [ ! -r "$SSL_SOURCE" ] \
     || [ ! -r "$CRYPTO_SOURCE" ] || [ ! -r "$CA_SOURCE" ]; } \
   && [ -x "$INSTALLED_RESOURCES/openfortivpn" ] \
   && [ -r "$INSTALLED_RESOURCES/libssl.3.dylib" ] \
   && [ -r "$INSTALLED_RESOURCES/libcrypto.3.dylib" ] \
   && [ -r "$INSTALLED_RESOURCES/prepa-ca-bundle.pem" ]; then
  ENGINE_SOURCE="$INSTALLED_RESOURCES/openfortivpn"
  SSL_SOURCE="$INSTALLED_RESOURCES/libssl.3.dylib"
  CRYPTO_SOURCE="$INSTALLED_RESOURCES/libcrypto.3.dylib"
  CA_SOURCE="$INSTALLED_RESOURCES/prepa-ca-bundle.pem"
fi
ENGINE_DIR="/Library/PrivilegedHelperTools/Nuvex"
ENGINE="${ENGINE_DIR}/openfortivpn"
HELPER="${ENGINE_DIR}/helper-$(id -u)"
HELPER_VERSION=3
INSTALLER_SCRIPT="${SCRIPT_DIR}/install_helper.applescript"
if [ ! -r "$INSTALLER_SCRIPT" ]; then
  INSTALLER_SCRIPT="${SCRIPT_DIR}/Nuvex/scripts/install_helper.applescript"
fi

config() { "$PYTHON" "$CONFIG_TOOL" "$@"; }
die() { printf 'nuvex: %s\n' "$*" >&2; exit 1; }
PROFILES=$(config ids) || die "no se pudo leer la configuración"
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
valid_profile() { case " $PROFILES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
profile() { config get "$1" "$2"; }
profile_enabled() { [ "$(profile "$1" enabled)" = true ]; }
profile_keychain() { printf 'nuvex.%s\n' "$1"; }
profile_state_dir() { printf '/var/run/nuvex/%s/%s\n' "$(id -u)" "$1"; }
source_hash() { shasum -a 256 "$ENGINE_SOURCE" | awk '{print $1}'; }
file_hash() { shasum -a 256 "$1" | awk '{print $1}'; }
config_hash() { config fingerprint; }

active_tunnel() {
  [ -x "$HELPER" ] || return 1
  [ -n "$(sudo -n "$HELPER" __all__ list-status 2>/dev/null || true)" ]
}

cmd_config() {
  local changed
  case "${1:-}" in
    set-all)
      if [ "$#" -eq 2 ]; then
        if changed=$("$PYTHON" -c 'import json,sys; print(str(json.loads(sys.argv[1]) != json.loads(sys.argv[2])).lower())' \
          "$2" "$(config list)" 2>/dev/null); then
          if [ "$changed" = true ] && active_tunnel; then
            die "desconecta la VPN activa antes de cambiar las conexiones"
          fi
        fi
      fi
      ;;
    set|set-profile|delete)
      if active_tunnel; then
        die "desconecta la VPN activa antes de cambiar las conexiones"
      fi
      ;;
  esac
  config "$@"
}

helper_components_current() {
  [ -x "$HELPER" ] || return 1
  [ ! -L "$ENGINE_DIR" ] && [ ! -L "$HELPER" ] && [ ! -L "$ENGINE" ] || return 1
  [ "$(stat -f '%u' "$ENGINE_DIR")" = 0 ] || return 1
  [ "$(stat -f '%u' "$HELPER")" = 0 ] || return 1
  [ "$(stat -f '%u' "$ENGINE")" = 0 ] || return 1
  [ "$(stat -f '%Lp' "$ENGINE_DIR")" = 755 ] || return 1
  [ "$(stat -f '%Lp' "$HELPER")" = 755 ] || return 1
  [ "$(stat -f '%Lp' "$ENGINE")" = 755 ] || return 1
  [ "$(sed -n '2s/^# config-sha256: //p' "$HELPER")" = "$(config_hash)" ] || return 1
  [ "$(sed -n '3s/^# engine-sha256: //p' "$HELPER")" = "$(source_hash)" ] || return 1
  [ -r "$CA_SOURCE" ] && [ -r "$SSL_SOURCE" ] && [ -r "$CRYPTO_SOURCE" ] || return 1
  [ "$(sed -n '4s/^# ca-sha256: //p' "$HELPER")" = "$(file_hash "$CA_SOURCE")" ] || return 1
  [ "$(sed -n '5s/^# ssl-sha256: //p' "$HELPER")" = "$(file_hash "$SSL_SOURCE")" ] || return 1
  [ "$(sed -n '6s/^# crypto-sha256: //p' "$HELPER")" = "$(file_hash "$CRYPTO_SOURCE")" ] || return 1
  [ -x "$ENGINE" ] || return 1
  [ "$(file_hash "$ENGINE")" = "$(source_hash)" ] || return 1
  for component in prepa-ca-bundle.pem libssl.3.dylib libcrypto.3.dylib; do
    [ -f "$ENGINE_DIR/$component" ] && [ ! -L "$ENGINE_DIR/$component" ] || return 1
  done
  [ "$(file_hash "$ENGINE_DIR/prepa-ca-bundle.pem")" = "$(file_hash "$CA_SOURCE")" ] || return 1
  [ "$(file_hash "$ENGINE_DIR/libssl.3.dylib")" = "$(file_hash "$SSL_SOURCE")" ] || return 1
  [ "$(file_hash "$ENGINE_DIR/libcrypto.3.dylib")" = "$(file_hash "$CRYPTO_SOURCE")" ]
}

helper_is_current() {
  helper_components_current || return 1
  [ "$(sed -n '7s/^# helper-version: //p' "$HELPER")" = "$HELPER_VERSION" ]
}

require_profile() {
  valid_profile "$1" || die "perfil desconocido"
  profile_enabled "$1" || die "perfil desactivado"
  [ -n "$(profile "$1" username)" ] || die "falta el usuario de $1"
  [ -n "$(profile "$1" server)" ] || die "falta el servidor de $1"
  [ -x "$ENGINE_SOURCE" ] || die "falta el motor VPN incluido; ejecuta build.sh"
  [ -r "$SSL_SOURCE" ] && [ -r "$CRYPTO_SOURCE" ] || die "faltan las bibliotecas TLS incluidas"
  if [ "$(profile "$1" trust)" = bundle ]; then
    [ -r "$CA_SOURCE" ] || die "falta el certificado CA de Prepa"
  fi
}

cmd_list() {
  local statuses ready=false
  helper_is_current && ready=true
  if [ -x "$HELPER" ] && statuses=$(sudo -n "$HELPER" __all__ list-status 2>/dev/null); then
    printf '%s\n' "$statuses" | config status-json "$ready"
  else
    config status-json false </dev/null
  fi
}

profile_engine_args() {
  local p="$1" server trust
  server=$(profile "$p" server)
  server="${server#https://}"
  server="${server%/}"
  trust=$(profile "$p" trust)
  printf '%s\n' '--config=/dev/null' "--username=$(profile "$p" username)" '--pppd-use-peerdns=0'
  [ -z "$(profile "$p" realm)" ] || printf '%s\n' "--realm=$(profile "$p" realm)"
  [ "$(profile "$p" manageRoutes)" = true ] || printf '%s\n' '--no-routes'
  [ "$(profile "$p" manageDNS)" = true ] || printf '%s\n' '--no-dns'
  case "$trust" in
    bundle) printf '%s\n' "--ca-file=${ENGINE_DIR}/prepa-ca-bundle.pem" ;;
    sha256:*) printf '%s\n' "--trusted-cert=${trust#sha256:}" ;;
    system) printf '%s\n' '--ca-file=/etc/ssl/cert.pem' ;;
  esac
  printf '%s\n' "$server"
}

cmd_gen_helper() {
  local out="${1:-/tmp/nuvex-helper}" p a
  [ -x "$ENGINE_SOURCE" ] || die "falta compilar openfortivpn"
  for p in $PROFILES; do profile_enabled "$p" && require_profile "$p"; done
  {
    printf '#!/bin/bash\n# config-sha256: %s\n# engine-sha256: %s\n# ca-sha256: %s\n# ssl-sha256: %s\n# crypto-sha256: %s\n# helper-version: %s\n' \
      "$(config_hash)" "$(source_hash)" "$(file_hash "$CA_SOURCE")" \
      "$(file_hash "$SSL_SOURCE")" "$(file_hash "$CRYPTO_SOURCE")" "$HELPER_VERSION"
    printf 'PROFILE_IDS=%s\n' "$(shq "$PROFILES")"
    cat <<'HEAD'
set -euo pipefail
PROFILE="${1:-}"
ACTION="${2:-}"
HEAD
    printf 'case "$PROFILE" in\n  __all__) [ "$ACTION" = list-status ] || exit 2 ;;\n'
    for p in $PROFILES; do printf '  %s) ;;\n' "$p"; done
    cat <<'HEAD'
  *) exit 2 ;;
esac
case "$ACTION" in start|stop|status|ip|list-status) ;; *) exit 2 ;; esac
ENGINE='/Library/PrivilegedHelperTools/Nuvex/openfortivpn'
STATE="/var/run/nuvex/$(id -u "${SUDO_USER:-root}")/${PROFILE}"
# SUDO_USER se establece por sudo; rechazar cualquier invocacion directa de root.
[ -n "${SUDO_USER:-}" ] || exit 2
PIDFILE="${STATE}/openfortivpn.pid"
LOGFILE="${STATE}/openfortivpn.log"
live_pid() {
  [ -r "$PIDFILE" ] || return 1
  local pid command
  pid=$(cat "$PIDFILE")
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in "${ENGINE}"*) printf '%s\n' "$pid" ;; *) return 1 ;; esac
}
if [ "$ACTION" = list-status ] && [ "$PROFILE" = __all__ ]; then
  for item in $PROFILE_IDS; do
    STATE="/var/run/nuvex/$(id -u "$SUDO_USER")/${item}"
    PIDFILE="${STATE}/openfortivpn.pid"
    LOGFILE="${STATE}/openfortivpn.log"
    pid=$(live_pid) || continue
    [ -r "$LOGFILE" ] && grep -q 'Tunnel is up and running\.' "$LOGFILE" || continue
    printf '%s %s\n' "$item" "$pid"
  done
  exit 0
fi
[ "$ACTION" != list-status ] || exit 2
if [ "$ACTION" = status ]; then
  pid=$(live_pid) || exit 1
  [ -r "$LOGFILE" ] && grep -q 'Tunnel is up and running\.' "$LOGFILE" || exit 1
  printf '%s\n' "$pid"
  exit 0
fi
if [ "$ACTION" = ip ]; then exit 0; fi
if [ "$ACTION" = stop ]; then
  pid=$(live_pid) || exit 0
  kill "$pid"
  for i in {1..10}; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  rm -f "$PIDFILE"
  exit 0
fi
if live_pid >/dev/null 2>&1; then echo 'la VPN ya esta activa' >&2; exit 6; fi
mkdir -p "$STATE"
chmod 700 "$STATE"
rm -f "$PIDFILE" "$LOGFILE"
(umask 077; : > "$LOGFILE")
IFS= read -r PASSWORD || exit 3
[ -n "$PASSWORD" ] || exit 3
HEAD
    printf 'case "$PROFILE" in\n'
    for p in $PROFILES; do
      if ! profile_enabled "$p"; then
        printf '  %s) echo "perfil desactivado" >&2; exit 2 ;;\n' "$p"
        continue
      fi
      printf '  %s) set --' "$p"
      while IFS= read -r a; do printf ' %s' "$(shq "$a")"; done < <(profile_engine_args "$p")
      printf ' ;;\n'
    done
    printf 'esac\n'
    cat <<'TAIL'
# La contraseña y el código viajan por stdin, nunca en argumentos ni logs.
{ printf '%s\n' "$PASSWORD"; cat; } 2>/dev/null | /usr/bin/nohup "$ENGINE" "$@" >"$LOGFILE" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$PIDFILE"
unset PASSWORD
asked=0
for i in {1..300}; do
  if [ "$asked" = 0 ] && grep -q 'NUVEX_OTP_REQUIRED' "$LOGFILE"; then
    printf 'NUVEX_OTP_REQUIRED\n' >&2
    asked=1
  fi
  if grep -q 'Tunnel is up and running\.' "$LOGFILE"; then exit 0; fi
  state=$(ps -p "$pid" -o state= 2>/dev/null | tr -d '[:space:]' || true)
  if ! kill -0 "$pid" 2>/dev/null || [ "${state#Z}" != "$state" ]; then
    if grep -q 'Gateway certificate validation failed' "$LOGFILE"; then
      printf 'NUVEX_TLS_VERIFY_FAILED\n' >&2
    fi
    tail -n 8 "$LOGFILE" >&2
    rm -f "$PIDFILE"
    exit 5
  fi
  sleep 1
done
echo 'la VPN no establecio el tunel en 300 segundos' >&2
kill "$pid" 2>/dev/null || true
rm -f "$PIDFILE"
exit 5
TAIL
  } > "$out"
  chmod 755 "$out"
  printf '%s\n' "$out"
}

# Se prepara una copia privada y se verifica cada archivo antes de instalarlo.
# La contraseña de administrador la solicita macOS, no Nuvex.
cmd_install_helper() {
  local temp username file digest installer_digest helper_only=false active_status
  if helper_is_current; then
    printf 'El ayudante ya está actualizado.\n'
    return
  fi
  [ -r "$INSTALLER_SCRIPT" ] || die "falta el instalador de macOS"
  if [ -x "$HELPER" ]; then
    active_status=$(sudo -n "$HELPER" __all__ list-status 2>/dev/null || true)
    if [ -n "$active_status" ]; then
      helper_components_current || die "desconecta las VPN activas antes de actualizar el motor o la configuración"
      helper_only=true
    fi
  fi
  local old_helper="/usr/local/libexec/nuvex/helper-$(id -u)" old_profile
  if [ -x "$old_helper" ]; then
    for old_profile in sicert prepa; do
      if sudo -n "$old_helper" "$old_profile" status >/dev/null 2>&1; then
        die "desconecta la VPN $old_profile antes de migrar el ayudante"
      fi
    done
  fi
  username=$(id -un)
  [[ "$username" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || die "nombre de usuario no compatible"
  temp=$(mktemp -d "${TMPDIR:-/tmp}/nuvex-install.XXXXXX")
  chmod 700 "$temp"
  # El trap se ejecuta cuando la función ya terminó y sus variables locales
  # desaparecieron; fijar la ruta ahora evita un error con set -u.
  trap "rm -rf -- $(shq "$temp")" EXIT
  cmd_gen_helper "$temp/helper" >/dev/null
  cp "$ENGINE_SOURCE" "$temp/openfortivpn"
  cp "$SSL_SOURCE" "$temp/libssl.3.dylib"
  cp "$CRYPTO_SOURCE" "$temp/libcrypto.3.dylib"
  cp "$CA_SOURCE" "$temp/prepa-ca-bundle.pem"

  {
    printf '#!/bin/bash\nset -euo pipefail\n'
    printf 'STAGE=%s\nTARGET=%s\nHELPER=%s\nUSERNAME=%s\n' \
      "$(shq "$temp")" "$(shq "$ENGINE_DIR")" "$(shq "$HELPER")" "$(shq "$username")"
    printf 'HELPER_ONLY=%s\n' "$(shq "$helper_only")"
    cat <<'INSTALL'
[ "$(id -u)" = 0 ] || exit 1
[ -d "$STAGE" ] && [ ! -L "$STAGE" ] || exit 1
ROOT_STAGE=$(mktemp -d /private/var/tmp/nuvex-stage.XXXXXX)
chmod 700 "$ROOT_STAGE"
trap 'rm -rf "$ROOT_STAGE"' EXIT
for component in openfortivpn helper libssl.3.dylib libcrypto.3.dylib prepa-ca-bundle.pem; do
  [ -f "$STAGE/$component" ] && [ ! -L "$STAGE/$component" ] || exit 1
  /usr/bin/install -o root -g wheel -m 600 "$STAGE/$component" "$ROOT_STAGE/$component"
done
INSTALL
    for file in openfortivpn helper libssl.3.dylib libcrypto.3.dylib prepa-ca-bundle.pem; do
      digest=$(shasum -a 256 "$temp/$file" | awk '{print $1}')
      printf '[ "$(/usr/bin/shasum -a 256 "$ROOT_STAGE/%s" | /usr/bin/awk '\''{print $1}'\'')" = %s ] || exit 1\n' \
        "$file" "$(shq "$digest")"
    done
    cat <<'INSTALL'
if [ "$HELPER_ONLY" = true ]; then
  [ -d "$TARGET" ] && [ ! -L "$TARGET" ] || exit 1
  [ -f "$HELPER" ] && [ ! -L "$HELPER" ] || exit 1
  [ "$(/usr/bin/stat -f '%u' "$TARGET")" = 0 ] || exit 1
  [ "$(/usr/bin/stat -f '%u' "$HELPER")" = 0 ] || exit 1
  [ "$(/usr/bin/sed -n '2s/^# config-sha256: //p' "$HELPER")" = \
    "$(/usr/bin/sed -n '2s/^# config-sha256: //p' "$ROOT_STAGE/helper")" ] || exit 1
  for component in openfortivpn libssl.3.dylib libcrypto.3.dylib prepa-ca-bundle.pem; do
    [ -f "$TARGET/$component" ] && [ ! -L "$TARGET/$component" ] || exit 1
    /usr/bin/cmp -s "$TARGET/$component" "$ROOT_STAGE/$component" || exit 1
  done
  NEW_HELPER=$(/usr/bin/mktemp "$TARGET/.helper.XXXXXX")
  trap 'rm -rf "$ROOT_STAGE"; rm -f "$NEW_HELPER"' EXIT
  /usr/bin/install -o root -g wheel -m 755 "$ROOT_STAGE/helper" "$NEW_HELPER"
  /bin/mv -f "$NEW_HELPER" "$HELPER"
  exit 0
fi
[ ! -L "$TARGET" ] || exit 1
/usr/bin/install -d -o root -g wheel -m 755 "$TARGET"
[ "$(/usr/bin/stat -f '%u' "$TARGET")" = 0 ] || exit 1
chmod 755 "$TARGET"
for component in openfortivpn "$(basename "$HELPER")" libssl.3.dylib libcrypto.3.dylib prepa-ca-bundle.pem; do
  [ ! -L "$TARGET/$component" ] || exit 1
done
/usr/bin/install -o root -g wheel -m 755 "$ROOT_STAGE/openfortivpn" "$TARGET/openfortivpn"
/usr/bin/install -o root -g wheel -m 755 "$ROOT_STAGE/helper" "$HELPER"
/usr/bin/install -o root -g wheel -m 644 "$ROOT_STAGE/libssl.3.dylib" "$TARGET/libssl.3.dylib"
/usr/bin/install -o root -g wheel -m 644 "$ROOT_STAGE/libcrypto.3.dylib" "$TARGET/libcrypto.3.dylib"
/usr/bin/install -o root -g wheel -m 644 "$ROOT_STAGE/prepa-ca-bundle.pem" "$TARGET/prepa-ca-bundle.pem"
rule=$(mktemp /etc/sudoers.d/.nuvex.XXXXXX)
trap 'rm -rf "$ROOT_STAGE"; rm -f "$rule"' EXIT
printf '%s ALL=(root) NOPASSWD: %s\n' "$USERNAME" "$HELPER" > "$rule"
chmod 440 "$rule"
/usr/sbin/visudo -cf "$rule" >/dev/null
mv "$rule" "/etc/sudoers.d/nuvex-$USERNAME"
INSTALL
  } > "$temp/install.sh"
  chmod 700 "$temp/install.sh"
  if [ "${1:-}" = '--dry-run' ]; then
    trap - EXIT
    printf '%s\n' "$temp/install.sh"
    return
  fi
  installer_digest=$(shasum -a 256 "$temp/install.sh" | awk '{print $1}')
  /usr/bin/osascript "$INSTALLER_SCRIPT" "$temp/install.sh" "$installer_digest" || die "se canceló o falló la autorización de macOS"
  helper_is_current || die "el ayudante no quedó instalado correctamente"
  printf 'Ayudante instalado y listo para conectar.\n'
}

cmd_connect() {
  local p="$1" password
  require_profile "$p"
  helper_is_current || die "instala o actualiza el ayudante desde Configuración"
  if [ "${2:-}" = '--password-stdin' ]; then
    "$PYTHON" "$CONNECT_TOOL" "$HELPER" "$p" app
  else
    password=$(security find-generic-password -s "$(profile_keychain "$p")" -a "$(profile "$p" username)" -w) || die "falta la contraseña en el Llavero"
    [ -n "$password" ] || die "contraseña vacía"
    printf '%s\n' "$password" | "$PYTHON" "$CONNECT_TOOL" "$HELPER" "$p" terminal
  fi
  unset password
  printf 'conectada\n'
}

cmd_stop() {
  valid_profile "$1" || die "perfil desconocido"
  [ -x "$HELPER" ] || die "falta el ayudante"
  sudo -n "$HELPER" "$1" stop
  printf 'desconectada\n'
}

case "${1:-list}" in
  list) cmd_list ;;
  config) shift; cmd_config "$@" ;;
  connect) shift; [ $# -ge 1 ] || die "falta perfil"; cmd_connect "$@" ;;
  stop) shift; [ $# -ge 1 ] || die "falta perfil"; cmd_stop "$1" ;;
  gen-helper) cmd_gen_helper "${2:-/tmp/nuvex-helper}" ;;
  install-helper) shift; cmd_install_helper "${1:-}" ;;
  *) die "comando desconocido" ;;
esac
