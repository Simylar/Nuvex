#!/usr/bin/env bash
# Publica una versión de Nuvex. Es una acción pública: comprueba todo antes.
#
# Uso: scripts/publicar.sh [--beta] [--simular | --local | --ci]
#   (por defecto)  Comprueba la versión y sube la etiqueta vX.Y.Z. GitHub
#                  Actions compila, firma y publica (.github/workflows/publicar.yml).
#   --local        Compila, firma y publica desde esta Mac.
#   --simular      Compila, empaqueta y genera el appcast sin subir nada.
#   --ci           Lo usa GitHub Actions sobre la etiqueta ya subida.
#   --beta         Canal beta: solo lo reciben quienes lo activan.
set -euo pipefail

RAIZ_APP="$(cd "$(dirname "$0")/.." && pwd)"
RAIZ="$(cd "$RAIZ_APP/.." && pwd)"
REPO="Simylar/Nuvex"
FEED="https://simylar.github.io/Nuvex/appcast.xml"
SPARKLE_BIN="$RAIZ_APP/.build/artifacts/sparkle/Sparkle/bin"
SALIDA="$RAIZ/.build-cache/publicaciones"
PAGINAS="$RAIZ/.build-cache/gh-pages"
IDENTIDAD="Nuvex Release"
BETA=false
MODO=etiqueta
for argumento in "$@"; do
  case "$argumento" in
    --beta) BETA=true ;;
    --simular) MODO=simular ;;
    --local) MODO=local ;;
    --ci) MODO=ci ;;
    *) echo "Uso: $0 [--beta] [--simular | --local | --ci]" >&2; exit 2 ;;
  esac
done

paso() { printf '\n==> %s\n' "$*"; }
falla() { printf 'publicar: %s\n' "$*" >&2; exit 1; }
cd "$RAIZ"

VERSION="$(tr -d '[:space:]' < "$RAIZ_APP/VERSION")"
ETIQUETA="v$VERSION"

# MARK: Comprobaciones comunes

paso "Comprobaciones"
git fetch --tags --quiet origin 2>/dev/null || true
[ -z "$(git status --porcelain)" ] || falla "hay cambios sin commit"
grep -qE "^## \[$VERSION\] - [0-9]{4}-[0-9]{2}-[0-9]{2}" CHANGELOG.md \
  || falla "CHANGELOG.md necesita la sección «## [$VERSION] - AAAA-MM-DD» con las novedades"
CLAVE="$(tr -d '[:space:]' < "$RAIZ_APP/Resources/sparkle_ed_public_key" 2>/dev/null || true)"
[ -n "$CLAVE" ] || falla "falta Resources/sparkle_ed_public_key; ejecuta scripts/configurar-publicacion.sh"
ANTERIOR="$(git tag -l 'v*' --sort=-v:refname | grep -vx "$ETIQUETA" | head -1 || true)"
if [ -n "$ANTERIOR" ]; then
  [ "$(printf '%s\n%s\n' "${ANTERIOR#v}" "$VERSION" | sort -V | tail -1)" = "$VERSION" ] \
    || falla "la versión $VERSION no es mayor que la última publicada ($ANTERIOR)"
fi

if [ "$MODO" = ci ]; then
  [ "$(git rev-parse "refs/tags/$ETIQUETA^{commit}" 2>/dev/null)" = "$(git rev-parse HEAD)" ] \
    || falla "la etiqueta $ETIQUETA no apunta a este commit"
  [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ] || falla "falta el secreto SPARKLE_ED_PRIVATE_KEY"
else
  RAMA="$(git branch --show-current)"
  $BETA || [ "$RAMA" = main ] || falla "las versiones estables se publican desde main (estás en $RAMA); usa --beta para otra rama"
  git rev-parse -q --verify "refs/tags/$ETIQUETA" >/dev/null && falla "la etiqueta $ETIQUETA ya existe; sube la versión en Nuvex/VERSION"
  [ "$MODO" = simular ] || gh auth status >/dev/null 2>&1 || falla "inicia sesión con gh auth login"
fi

# MARK: Modo por defecto: subir la etiqueta

if [ "$MODO" = etiqueta ]; then
  [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$RAMA" 2>/dev/null)" ] \
    || falla "sube antes la rama $RAMA (git push); la etiqueta debe apuntar a un commit publicado"
  gh secret list --repo "$REPO" 2>/dev/null | grep -q SPARKLE_ED_PRIVATE_KEY \
    || falla "faltan los secretos en GitHub; ejecuta scripts/configurar-publicacion.sh"
  paso "Compilación de Nuvex para preparar las bibliotecas de prueba"
  NUVEX_CANAL=publicada "$RAIZ_APP/build.sh"
  paso "Pruebas"
  python3 -m unittest discover -s tests >/dev/null 2>&1 || falla "fallaron las pruebas de Python"
  for prueba in tests/test_*.sh; do bash "$prueba" >/dev/null || falla "falló $(basename "$prueba")"; done
  paso "Etiqueta $ETIQUETA"
  MENSAJE="Nuvex $VERSION"
  $BETA && MENSAJE="$MENSAJE (beta)"
  git tag -a "$ETIQUETA" -m "$MENSAJE"
  git push --quiet origin "$ETIQUETA"
  printf '\nEtiqueta %s subida. GitHub Actions compila y publica la versión.\nProgreso: gh run watch --repo %s\n' "$ETIQUETA" "$REPO"
  exit 0
fi

# MARK: Compilación y publicación (local, simulada o en GitHub Actions)

if [ "$MODO" != ci ]; then
  security find-identity -p codesigning | grep -qF "\"$IDENTIDAD\"" \
    || falla "falta la identidad «$IDENTIDAD»; ejecuta scripts/configurar-publicacion.sh"
  [ "$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" = "$CLAVE" ] \
    || falla "la clave EdDSA del llavero no coincide con Resources/sparkle_ed_public_key"
  paso "Compilación de Nuvex para preparar las bibliotecas de prueba"
  NUVEX_CANAL=publicada "$RAIZ_APP/build.sh"
  paso "Pruebas"
  python3 -m unittest discover -s tests >/dev/null 2>&1 || falla "fallaron las pruebas de Python"
  for prueba in tests/test_*.sh; do bash "$prueba" >/dev/null || falla "falló $(basename "$prueba")"; done
fi

paso "Compilación de Nuvex $VERSION"
NUVEX_CANAL=publicada "$RAIZ_APP/build.sh"
APP="$RAIZ_APP/Nuvex.app"
IDENTIDAD_HASH="$(security find-identity -p codesigning | awk -v identidad="$IDENTIDAD" 'index($0, "\"" identidad "\"") { print $2; exit }')"
[ -n "$IDENTIDAD_HASH" ] || falla "no se encontró la identidad de firma «${IDENTIDAD}»"
REQUISITO_FIRMA="$(codesign -d -r- "$APP" 2>&1)"
IDENTIDAD_HASH="$(printf '%s' "$IDENTIDAD_HASH" | tr '[:upper:]' '[:lower:]')"
case "$REQUISITO_FIRMA" in
  *"certificate leaf = H\"$IDENTIDAD_HASH\""*) ;;
  *) falla "la app no quedó firmada con «${IDENTIDAD}»" ;;
esac
COMPILACION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
OPENSSL_VERSION="$(brew list --versions openssl@3 | awk '{print $2}')"
MOTOR="$(shasum -a 256 "$APP/Contents/Resources/openfortivpn" | cut -d' ' -f1) openssl-$OPENSSL_VERSION"

# Un motor distinto obliga a todos a reautorizar el ayudante: solo se acepta
# si cambió su código o se actualizó OpenSSL.
if [ -n "$ANTERIOR" ] && [ "$MODO" != simular ]; then
  MOTOR_ANTERIOR="$(gh release download "$ANTERIOR" --repo "$REPO" --pattern motor.sha256 --output - 2>/dev/null | head -1 || true)"
  if [ -n "$MOTOR_ANTERIOR" ] && [ "$MOTOR_ANTERIOR" != "$MOTOR" ] \
     && [ "${MOTOR_ANTERIOR#* }" = "${MOTOR#* }" ] \
     && git diff --quiet "$ANTERIOR" HEAD -- vendor/openfortivpn; then
    falla "el motor cambió sin cambios en vendor/openfortivpn ni en OpenSSL; revisa la compilación del motor"
  fi
fi

paso "Empaquetado"
mkdir -p "$SALIDA"
# Se parte del appcast publicado y del archivo de la versión anterior, para
# conservar el historial y generar la actualización delta.
[ -f "$SALIDA/appcast.xml" ] || curl -fsSL "$FEED" -o "$SALIDA/appcast.xml" 2>/dev/null || rm -f "$SALIDA/appcast.xml"
if [ -n "$ANTERIOR" ] && ! ls "$SALIDA"/Nuvex-"${ANTERIOR#v}".zip >/dev/null 2>&1; then
  gh release download "$ANTERIOR" --repo "$REPO" --pattern "Nuvex-${ANTERIOR#v}.zip" --dir "$SALIDA" 2>/dev/null || true
fi
ZIP="$SALIDA/Nuvex-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
# Las notas de la versión son la sección del CHANGELOG; la app las muestra en
# «Actualización de software» y en «Novedades».
awk -v v="$VERSION" '
  /^## \[/ { dentro = index($0, "## [" v "]") == 1; next }
  dentro { print }
' CHANGELOG.md | sed -e '/./,$!d' > "$SALIDA/Nuvex-$VERSION.md"
printf '%s\n' "$MOTOR" > "$SALIDA/motor.sha256"

paso "Appcast firmado"
OPCIONES=(--download-url-prefix "https://github.com/$REPO/releases/download/$ETIQUETA/"
          --embed-release-notes --maximum-deltas 3 --link "https://github.com/$REPO")
$BETA && OPCIONES+=(--channel beta)
if [ "$MODO" = ci ]; then
  # La clave privada llega por la entrada estándar, nunca en argumentos.
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${OPCIONES[@]}" "$SALIDA"
else
  "$SPARKLE_BIN/generate_appcast" "${OPCIONES[@]}" "$SALIDA"
fi
grep -q "sparkle:edSignature" "$SALIDA/appcast.xml" || falla "el appcast no quedó firmado"
DELTAS=()
while IFS= read -r delta; do DELTAS+=("$delta"); done < <(find "$SALIDA" -maxdepth 1 -name "*-$COMPILACION.delta")

if [ "$MODO" = simular ]; then
  printf '\nSimulación completa. Se publicaría:\n  %s\n  %s\n' "$ZIP" "$SALIDA/appcast.xml"
  for delta in ${DELTAS[@]+"${DELTAS[@]}"}; do printf '  %s\n' "$delta"; done
  exit 0
fi

paso "Publicación en GitHub"
NOTAS="$SALIDA/Nuvex-$VERSION.md"
BANDERAS=(--title "Nuvex $VERSION" --notes-file "$NOTAS")
if [ "$MODO" = ci ]; then BANDERAS+=(--verify-tag); else BANDERAS+=(--target "$(git rev-parse HEAD)"); fi
$BETA && BANDERAS+=(--prerelease)
gh release create "$ETIQUETA" --repo "$REPO" "${BANDERAS[@]}" "$ZIP" "$SALIDA/motor.sha256" ${DELTAS[@]+"${DELTAS[@]}"}

paso "Aviso de actualización (GitHub Pages)"
# La rama gh-pages se trabaja en un árbol aparte del mismo repositorio, así
# hereda las credenciales con las que se subió el código.
git worktree remove --force "$PAGINAS" 2>/dev/null || rm -rf "$PAGINAS"
if git fetch --quiet origin gh-pages 2>/dev/null; then
  git worktree add --quiet -B gh-pages "$PAGINAS" FETCH_HEAD
else
  git worktree add --quiet --detach "$PAGINAS"
  git -C "$PAGINAS" checkout --quiet --orphan gh-pages
  git -C "$PAGINAS" rm -rf --quiet . 2>/dev/null || true
fi
cp "$SALIDA/appcast.xml" "$PAGINAS/appcast.xml"
touch "$PAGINAS/.nojekyll"
git -C "$PAGINAS" add appcast.xml .nojekyll
git -C "$PAGINAS" commit --quiet -m "appcast: Nuvex $VERSION"
git -C "$PAGINAS" push --quiet origin gh-pages
git worktree remove --force "$PAGINAS"
if [ "$MODO" != ci ]; then
  gh api "repos/$REPO/pages" >/dev/null 2>&1 \
    || gh api -X POST "repos/$REPO/pages" -f "source[branch]=gh-pages" -f "source[path]=/" >/dev/null
fi

printf '\nNuvex %s publicado. Las apps instaladas lo verán en su próxima búsqueda diaria.\n' "$VERSION"
