#!/usr/bin/env bash
# Configuración única de la Mac que publica versiones de Nuvex:
#   1. Identidad de firma estable «Nuvex Release» (certificado autofirmado de
#      10 años). Mantiene los permisos del Llavero entre versiones.
#   2. Clave EdDSA de Sparkle, que firma cada actualización.
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
  trap 'rm -rf "$TEMPORAL"' EXIT
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

cat <<'FIN'

Siguiente paso:
  - Guarda las copias del Escritorio en tu gestor de contraseñas y bórralas
    del Escritorio. Sin ellas no podrás publicar desde otra Mac.
  - Haz commit de Nuvex/Resources/sparkle_ed_public_key.
  - Compila con build.sh: la app quedará firmada con «Nuvex Release».
FIN
