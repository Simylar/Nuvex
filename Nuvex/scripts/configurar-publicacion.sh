#!/usr/bin/env bash
# Configuración única de la Mac que publica versiones de Nuvex:
#   1. Identidad de firma estable «Nuvex Release» (certificado autofirmado de
#      10 años). Mantiene los permisos del Llavero entre versiones.
#   2. Clave EdDSA de Sparkle, que firma cada actualización.
#   3. Los secretos de GitHub Actions para publicar automáticamente.
# Ambas quedan en tu llavero de inicio de sesión. El script deja una copia de
# cada una en el Escritorio para que la guardes en tu gestor de contraseñas.
# Si se pierden, las actualizaciones dejan de poder firmarse con la misma
# identidad. Consulta docs/publicar.md.
set -euo pipefail

RAIZ_APP="$(cd "$(dirname "$0")/.." && pwd)"
IDENTIDAD="Nuvex Release"
LLAVERO="$HOME/Library/Keychains/login.keychain-db"
CLAVE_PUBLICA="$RAIZ_APP/Resources/sparkle_ed_public_key"
GENERATE_KEYS="$RAIZ_APP/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
TEMPORAL=""
TEMPORAL_CLAVE=""

limpiar_temporales() {
  local estado=$?
  trap - EXIT INT TERM
  if [ -n "$TEMPORAL_CLAVE" ] && [ -d "$TEMPORAL_CLAVE" ]; then
    [ ! -f "$TEMPORAL_CLAVE/clave" ] || rm -P "$TEMPORAL_CLAVE/clave" 2>/dev/null || rm -f "$TEMPORAL_CLAVE/clave"
    rm -rf "$TEMPORAL_CLAVE"
  fi
  if [ -n "$TEMPORAL" ] && [ -d "$TEMPORAL" ]; then
    [ ! -f "$TEMPORAL/clave.pem" ] || rm -P "$TEMPORAL/clave.pem" 2>/dev/null || rm -f "$TEMPORAL/clave.pem"
    [ ! -f "$TEMPORAL/nuvex-release.p12" ] || rm -P "$TEMPORAL/nuvex-release.p12" 2>/dev/null || rm -f "$TEMPORAL/nuvex-release.p12"
    rm -rf "$TEMPORAL"
  fi
  exit "$estado"
}
trap limpiar_temporales EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -x "$GENERATE_KEYS" ]; then
  (cd "$RAIZ_APP" && swift package resolve >/dev/null)
fi

printf '1. Identidad de firma «%s»\n' "$IDENTIDAD"
if security find-identity -p codesigning "$LLAVERO" | grep -qF "\"$IDENTIDAD\""; then
  echo "   Ya existe; no se cambia."
else
  read -r -s -p "   Frase para proteger la copia del certificado: " FRASE; echo
  read -r -s -p "   Repítela: " FRASE2; echo
  [ "$FRASE" = "$FRASE2" ] && [ ${#FRASE} -ge 12 ] || { echo "Las frases no coinciden o tienen menos de 12 caracteres." >&2; exit 1; }
  TEMPORAL="$(mktemp -d)"
  "$OPENSSL" req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
    -keyout "$TEMPORAL/clave.pem" -out "$TEMPORAL/certificado.pem" -subj "/CN=$IDENTIDAD" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  # La frase viaja por el entorno, no por los argumentos visibles en ps.
  export FRASE_P12="$FRASE"
  # Cifrado que el Llavero de macOS sabe importar.
  "$OPENSSL" pkcs12 -export -inkey "$TEMPORAL/clave.pem" -in "$TEMPORAL/certificado.pem" \
    -name "$IDENTIDAD" -out "$TEMPORAL/nuvex-release.p12" -passout env:FRASE_P12 \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
  unset FRASE_P12
  echo "   macOS pedirá la misma frase para importar el certificado."
  security import "$TEMPORAL/nuvex-release.p12" -k "$LLAVERO" -T /usr/bin/codesign >/dev/null
  COPIA="$HOME/Desktop/Nuvex-Release-certificado.p12"
  install -m 600 "$TEMPORAL/nuvex-release.p12" "$COPIA"
  FRASE_CERTIFICADO="$FRASE"
  unset FRASE FRASE2
  echo "   Creada e importada. Copia protegida con tu frase: $COPIA"
fi

printf '\n2. Clave EdDSA de actualizaciones\n'
if PUBLICA="$("$GENERATE_KEYS" -p 2>/dev/null)" && [ -n "$PUBLICA" ]; then
  echo "   Ya existe en el llavero; se reutiliza."
else
  "$GENERATE_KEYS" >/dev/null
  PUBLICA="$("$GENERATE_KEYS" -p)"
  COPIA_CLAVE="$HOME/Desktop/Nuvex-EdDSA-clave-privada.txt"
  (umask 077; "$GENERATE_KEYS" -x "$COPIA_CLAVE")
  echo "   Creada. Copia de la clave privada: $COPIA_CLAVE"
fi
printf '%s\n' "$PUBLICA" > "$CLAVE_PUBLICA"
echo "   Clave pública guardada en Resources/sparkle_ed_public_key (se publica con el código)."

printf '\n3. Secretos para publicar con GitHub Actions\n'
REPO="Simylar/Nuvex"
if ! gh auth status >/dev/null 2>&1; then
  echo "   Omitido: inicia sesión con «gh auth login» y vuelve a ejecutar este script."
else
  CERTIFICADO="${COPIA:-$HOME/Desktop/Nuvex-Release-certificado.p12}"
  if [ ! -f "$CERTIFICADO" ]; then
    read -r -p "   Ruta de la copia del certificado (.p12): " CERTIFICADO
  fi
  [ -f "$CERTIFICADO" ] || { echo "No se encontró el certificado .p12." >&2; exit 1; }
  if [ -z "${FRASE_CERTIFICADO:-}" ]; then
    read -r -s -p "   Frase de la copia del certificado: " FRASE_CERTIFICADO; echo
  fi
  # Los valores pasan a gh por la entrada estándar: no quedan en pantalla ni en ps.
  base64 -i "$CERTIFICADO" | gh secret set NUVEX_CERTIFICADO_P12 --repo "$REPO"
  printf '%s' "$FRASE_CERTIFICADO" | gh secret set NUVEX_CERTIFICADO_FRASE --repo "$REPO"
  unset FRASE_CERTIFICADO
  TEMPORAL_CLAVE="$(mktemp -d)"
  (umask 077; "$GENERATE_KEYS" -x "$TEMPORAL_CLAVE/clave" >/dev/null)
  gh secret set SPARKLE_ED_PRIVATE_KEY --repo "$REPO" < "$TEMPORAL_CLAVE/clave"
  rm -P "$TEMPORAL_CLAVE/clave" 2>/dev/null || rm -f "$TEMPORAL_CLAVE/clave"
  rmdir "$TEMPORAL_CLAVE"
  TEMPORAL_CLAVE=""
  echo "   Guardados en GitHub: NUVEX_CERTIFICADO_P12, NUVEX_CERTIFICADO_FRASE y SPARKLE_ED_PRIVATE_KEY."
fi

cat <<'FIN'

Siguiente paso:
  - Guarda las copias del Escritorio en tu gestor de contraseñas y bórralas
    del Escritorio. Sin ellas no podrás publicar desde otra Mac.
  - Haz commit de Nuvex/Resources/sparkle_ed_public_key.
  - Instala con scripts/instalar.sh: la app quedará firmada con «Nuvex Release»
    y buscará actualizaciones sola.
  - Para publicar una versión: scripts/publicar.sh (sube la etiqueta y
    GitHub Actions hace el resto).
FIN
