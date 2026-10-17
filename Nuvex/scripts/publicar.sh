#!/usr/bin/env bash
# Publica una versión de Nuvex en GitHub Releases y actualiza el aviso de
# Sparkle (appcast.xml en GitHub Pages). Es una acción pública: comprueba todo
# antes de subir nada.
#
# Uso: scripts/publicar.sh [--beta] [--simular]
#   --beta      Publica en el canal beta (solo lo reciben quienes lo activan).
#   --simular   Compila, empaqueta y genera el appcast, pero no sube nada.
set -euo pipefail

RAIZ_APP="$(cd "$(dirname "$0")/.." && pwd)"
RAIZ="$(cd "$RAIZ_APP/.." && pwd)"
REPO="Simylar/Nuvex"
SPARKLE_BIN="$RAIZ_APP/.build/artifacts/sparkle/Sparkle/bin"
SALIDA="$RAIZ/.build-cache/publicaciones"
PAGINAS="$RAIZ/.build-cache/gh-pages"
IDENTIDAD="Nuvex Release"
BETA=false
SIMULAR=false
for argumento in "$@"; do
  case "$argumento" in
    --beta) BETA=true ;;
    --simular) SIMULAR=true ;;
    *) echo "Uso: $0 [--beta] [--simular]" >&2; exit 2 ;;
  esac
done

paso() { printf '\n==> %s\n' "$*"; }
falla() { printf 'publicar: %s\n' "$*" >&2; exit 1; }
cd "$RAIZ"

VERSION="$(tr -d '[:space:]' < "$RAIZ_APP/VERSION")"
ETIQUETA="v$VERSION"

paso "Comprobaciones"
git fetch --tags --quiet origin 2>/dev/null || true
[ -z "$(git status --porcelain)" ] || falla "hay cambios sin commit"
RAMA="$(git branch --show-current)"
$BETA || [ "$RAMA" = main ] || falla "las versiones estables se publican desde main (estás en $RAMA); usa --beta para otra rama"
git rev-parse -q --verify "refs/tags/$ETIQUETA" >/dev/null && falla "la etiqueta $ETIQUETA ya existe; sube la versión en Nuvex/VERSION"
ANTERIOR="$(git tag -l 'v*' --sort=-v:refname | head -1)"
if [ -n "$ANTERIOR" ]; then
  [ "$(printf '%s\n%s\n' "${ANTERIOR#v}" "$VERSION" | sort -V | tail -1)" = "$VERSION" ] \
    || falla "la versión $VERSION no es mayor que la última publicada ($ANTERIOR)"
fi
grep -qE "^## \[$VERSION\] - [0-9]{4}-[0-9]{2}-[0-9]{2}" CHANGELOG.md \
  || falla "CHANGELOG.md necesita la sección «## [$VERSION] - AAAA-MM-DD» con las novedades"
security find-identity -p codesigning | grep -qF "\"$IDENTIDAD\"" \
  || falla "falta la identidad «$IDENTIDAD»; ejecuta scripts/configurar-publicacion.sh"
CLAVE="$(tr -d '[:space:]' < "$RAIZ_APP/Resources/sparkle_ed_public_key" 2>/dev/null || true)"
[ -n "$CLAVE" ] || falla "falta Resources/sparkle_ed_public_key; ejecuta scripts/configurar-publicacion.sh"
[ "$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" = "$CLAVE" ] \
  || falla "la clave EdDSA del llavero no coincide con Resources/sparkle_ed_public_key"
$SIMULAR || gh auth status >/dev/null 2>&1 || falla "inicia sesión con gh auth login"

paso "Pruebas"
python3 -m unittest discover -s tests >/dev/null 2>&1 || falla "fallaron las pruebas de Python"
for prueba in tests/test_*.sh; do bash "$prueba" >/dev/null || falla "falló $(basename "$prueba")"; done

paso "Compilación de Nuvex $VERSION"
NUVEX_CANAL=publicada "$RAIZ_APP/build.sh"
APP="$RAIZ_APP/Nuvex.app"
codesign -dvv "$APP" 2>&1 | grep -qF "Authority=$IDENTIDAD" || falla "la app no quedó firmada con «$IDENTIDAD»"
COMPILACION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
MOTOR="$(shasum -a 256 "$APP/Contents/Resources/openfortivpn" | cut -d' ' -f1)"

# Un motor distinto obliga a todos a reautorizar el ayudante: solo se acepta
# si cambió su código.
if [ -n "$ANTERIOR" ] && ! $SIMULAR; then
  MOTOR_ANTERIOR="$(gh release download "$ANTERIOR" --repo "$REPO" --pattern motor.sha256 --output - 2>/dev/null || true)"
  if [ -n "$MOTOR_ANTERIOR" ] && [ "$MOTOR_ANTERIOR" != "$MOTOR" ] \
     && git diff --quiet "$ANTERIOR" HEAD -- vendor/openfortivpn; then
    falla "el motor cambió sin cambios en vendor/openfortivpn; revisa la caché del motor antes de publicar"
  fi
fi

paso "Empaquetado"
mkdir -p "$SALIDA"
if [ ! -f "$SALIDA/appcast.xml" ]; then
  # Se parte del appcast publicado para conservar el historial y las deltas.
  curl -fsSL "https://simylar.github.io/Nuvex/appcast.xml" -o "$SALIDA/appcast.xml" 2>/dev/null || rm -f "$SALIDA/appcast.xml"
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
"$SPARKLE_BIN/generate_appcast" "${OPCIONES[@]}" "$SALIDA"
DELTAS=()
while IFS= read -r delta; do DELTAS+=("$delta"); done < <(find "$SALIDA" -maxdepth 1 -name "*-$COMPILACION.delta")

if $SIMULAR; then
  printf '\nSimulación completa. Se publicaría:\n  %s\n  %s\n  %s\n' "$ZIP" "$SALIDA/appcast.xml" "${DELTAS[@]+"${DELTAS[@]}"}"
  exit 0
fi

paso "Publicación en GitHub"
NOTAS="$SALIDA/Nuvex-$VERSION.md"
BANDERAS=(--title "Nuvex $VERSION" --notes-file "$NOTAS" --target "$(git rev-parse HEAD)")
$BETA && BANDERAS+=(--prerelease)
gh release create "$ETIQUETA" --repo "$REPO" "${BANDERAS[@]}" "$ZIP" "$SALIDA/motor.sha256" ${DELTAS[@]+"${DELTAS[@]}"}

paso "Aviso de actualización (GitHub Pages)"
if [ ! -d "$PAGINAS/.git" ]; then
  rm -rf "$PAGINAS"
  if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
    git clone --quiet --branch gh-pages --single-branch "$(git remote get-url origin)" "$PAGINAS"
  else
    git clone --quiet "$(git remote get-url origin)" "$PAGINAS"
    git -C "$PAGINAS" switch --orphan gh-pages
    git -C "$PAGINAS" rm -rf --quiet . 2>/dev/null || true
  fi
fi
git -C "$PAGINAS" pull --quiet --ff-only 2>/dev/null || true
cp "$SALIDA/appcast.xml" "$PAGINAS/appcast.xml"
touch "$PAGINAS/.nojekyll"
git -C "$PAGINAS" add appcast.xml .nojekyll
git -C "$PAGINAS" commit --quiet -m "appcast: Nuvex $VERSION"
git -C "$PAGINAS" push --quiet origin gh-pages
gh api "repos/$REPO/pages" >/dev/null 2>&1 \
  || gh api -X POST "repos/$REPO/pages" -f "source[branch]=gh-pages" -f "source[path]=/" >/dev/null

printf '\nNuvex %s publicado. Las apps instaladas lo verán en su próxima búsqueda diaria.\n' "$VERSION"
