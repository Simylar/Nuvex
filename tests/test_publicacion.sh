#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
temporal="$(mktemp -d)"
trap 'rm -rf "$temporal"' EXIT

raiz_falsa="$temporal/repositorio/Nuvex"
mkdir -p "$raiz_falsa/scripts" "$raiz_falsa/Resources" \
  "$raiz_falsa/.build/artifacts/sparkle/Sparkle/bin" \
  "$temporal/bin" "$temporal/home/Desktop" "$temporal/tmp"
cp "$ROOT/Nuvex/scripts/configurar-publicacion.sh" "$raiz_falsa/scripts/"

printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$OPENSSL_PRUEBA"\n' > "$temporal/bin/brew"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = find-identity ]; then printf "  1) ABC \\"Nuvex Release\\"\\n"; fi\n' \
  > "$temporal/bin/security"
printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  auth) exit 0 ;;\n  secret) [ "${3:-}" != SPARKLE_ED_PRIVATE_KEY ] ;;\n  *) exit 0 ;;\nesac\n' > "$temporal/bin/gh"
printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  -p) printf "clave-publica-prueba\\n" ;;\n  -x) printf "clave-privada-prueba\\n" > "$2" ;;\n  *) exit 1 ;;\nesac\n' \
  > "$raiz_falsa/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
chmod 755 "$temporal/bin/brew" "$temporal/bin/security" "$temporal/bin/gh" \
  "$raiz_falsa/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
printf 'certificado de prueba\n' > "$temporal/home/Desktop/Nuvex-Release-certificado.p12"

if HOME="$temporal/home" TMPDIR="$temporal/tmp" OPENSSL_PRUEBA="$temporal/openssl" \
  FRASE_CERTIFICADO='frase-de-prueba-no-real' PATH="$temporal/bin:$PATH" \
  bash "$raiz_falsa/scripts/configurar-publicacion.sh" >/dev/null 2>&1; then
  echo 'La configuración simulada debía fallar al guardar la clave EdDSA' >&2
  exit 1
fi

if find "$temporal/tmp" -mindepth 1 -print -quit | grep -q .; then
  echo 'La clave privada temporal no se limpió después del fallo simulado' >&2
  exit 1
fi

publicador="$ROOT/Nuvex/scripts/publicar.sh"
linea_limpieza="$(grep -nF 'rm -rf "$SALIDA"' "$publicador" | head -1 | cut -d: -f1)"
linea_motor="$(grep -nF 'if [ -n "$ANTERIOR" ] && git diff' "$publicador" | cut -d: -f1)"
linea_version_motor="$(grep -nF 'comparar_versiones.py" --mayor-o-igual' "$publicador" | cut -d: -f1)"
linea_extraccion_motor="$(grep -nF 'MOTOR_EXTRAIDO="$(mktemp -d' "$publicador" | cut -d: -f1)"
linea_notas="$(grep -nF 'for paquete in "$SALIDA"/Nuvex-*.zip' "$publicador" | cut -d: -f1)"
linea_appcast="$(grep -nF 'git fetch --quiet origin gh-pages' "$publicador" | head -1 | cut -d: -f1)"
linea_appcast_obligatorio="$(grep -nF 'no se pudo recuperar el appcast publicado' "$publicador" | cut -d: -f1)"
linea_generacion="$(grep -nF '"$SPARKLE_BIN/generate_appcast" "${OPCIONES[@]}" "$SALIDA"' "$publicador" | tail -1 | cut -d: -f1)"
linea_ajuste="$(grep -nF 'scripts/ajustar_appcast.py' "$publicador" | cut -d: -f1)"
linea_validacion="$(grep -nF 'scripts/verificar_appcast.py' "$publicador" | cut -d: -f1)"
[ "$linea_limpieza" -lt "$linea_motor" ]
[ "$linea_motor" -lt "$linea_version_motor" ]
[ "$linea_version_motor" -lt "$linea_extraccion_motor" ]
[ "$linea_appcast" -lt "$linea_appcast_obligatorio" ]
[ "$linea_appcast_obligatorio" -lt "$linea_notas" ]
[ "$linea_notas" -lt "$linea_generacion" ]
[ "$linea_generacion" -lt "$linea_ajuste" ]
[ "$linea_ajuste" -lt "$linea_validacion" ]
! grep -qF '|| rm -f "$SALIDA/appcast.xml"' "$publicador"

echo 'Publicación: limpieza, notas, URL y validación conservan el orden seguro'
