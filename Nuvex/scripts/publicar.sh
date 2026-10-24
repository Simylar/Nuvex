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
MOTOR_EXTRAIDO=""
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
limpiar_publicacion() {
  if [ -n "$MOTOR_EXTRAIDO" ] && [ -d "$MOTOR_EXTRAIDO" ]; then
    case "$MOTOR_EXTRAIDO" in
      /private/tmp/nuvex-motor-publicado.*) rm -rf "$MOTOR_EXTRAIDO" ;;
    esac
  fi
}
trap limpiar_publicacion EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cd "$RAIZ"

VERSION="$(tr -d '[:space:]' < "$RAIZ_APP/VERSION")"
ETIQUETA="v$VERSION"
COMMIT_INICIAL="$(git rev-parse HEAD)"
COMMIT_CORTO="$(git rev-parse --short HEAD)"
COMPILACION_ESPERADA="$((100 + $(git rev-list --count HEAD)))"

verificar_candidato_congelado() {
  [ "$(git rev-parse HEAD)" = "$COMMIT_INICIAL" ] \
    || falla "HEAD cambió durante la preparación; vuelve a iniciar el release"
  [ -z "$(git status --porcelain)" ] \
    || falla "el árbol cambió durante la preparación; vuelve a iniciar el release"
}

# MARK: Comprobaciones comunes

paso "Comprobaciones"
git fetch --tags --quiet origin \
  || falla "no se pudieron actualizar las etiquetas remotas"
[ -z "$(git status --porcelain)" ] || falla "hay cambios sin commit"
grep -qE "^## \[$VERSION\] - [0-9]{4}-[0-9]{2}-[0-9]{2}" CHANGELOG.md \
  || falla "CHANGELOG.md necesita la sección «## [$VERSION] - AAAA-MM-DD» con las novedades"
CLAVE="$(tr -d '[:space:]' < "$RAIZ_APP/Resources/sparkle_ed_public_key" 2>/dev/null || true)"
[ -n "$CLAVE" ] || falla "falta Resources/sparkle_ed_public_key; ejecuta scripts/configurar-publicacion.sh"
ANTERIOR="$(git tag -l 'v*' | awk -v actual="$ETIQUETA" '$0 != actual' \
  | python3 "$RAIZ_APP/scripts/comparar_versiones.py" --mayor)" \
  || falla "no se pudieron ordenar semánticamente las etiquetas publicadas"
if [ -n "$ANTERIOR" ]; then
  python3 "$RAIZ_APP/scripts/comparar_versiones.py" "$VERSION" "${ANTERIOR#v}" \
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

# Cada intento parte de un conjunto cerrado de artefactos. Así una simulación
# anterior no puede contaminar el appcast ni los archivos que se publiquen.
[ "$SALIDA" = "$RAIZ/.build-cache/publicaciones" ] \
  || falla "la ruta de salida de publicaciones no es la esperada"
rm -rf "$SALIDA"
mkdir -p "$SALIDA"

# Motor: si su código no cambió y la versión publicada de OpenSSL es igual o
# más nueva que la local, se reutilizan los bytes ya publicados. Compilarlo en
# otra máquina o degradar OpenSSL daría otro hash y obligaría a todos a volver
# a autorizar el ayudante. Solo una actualización real de OpenSSL justifica un
# motor nuevo.
if [ -n "$ANTERIOR" ] && git diff --quiet "$ANTERIOR" HEAD -- vendor/openfortivpn; then
  MOTOR_PREVIO="$(gh release download "$ANTERIOR" --repo "$REPO" --pattern motor.sha256 --output - 2>/dev/null | head -1 || true)"
  OPENSSL_ACTUAL="$(brew list --versions openssl@3 | awk '{print $2}')"
  OPENSSL_PREVIO="${MOTOR_PREVIO#* openssl-}"
  if [ -n "$MOTOR_PREVIO" ] && [ "$OPENSSL_PREVIO" != "$MOTOR_PREVIO" ] \
     && python3 "$RAIZ_APP/scripts/comparar_versiones.py" --mayor-o-igual \
       "$OPENSSL_PREVIO" "$OPENSSL_ACTUAL" >/dev/null 2>&1; then
    # Siempre el zip publicado, nunca una copia local que pueda ser distinta.
    MOTOR_EXTRAIDO="$(mktemp -d /private/tmp/nuvex-motor-publicado.XXXXXX)"
    gh release download "$ANTERIOR" --repo "$REPO" --pattern "Nuvex-${ANTERIOR#v}.zip" --dir "$MOTOR_EXTRAIDO" \
      || falla "no se pudo descargar Nuvex-${ANTERIOR#v}.zip para reutilizar su motor"
    mkdir -p "$SALIDA"
    cp "$MOTOR_EXTRAIDO/Nuvex-${ANTERIOR#v}.zip" "$SALIDA/"
    ditto -x -k "$MOTOR_EXTRAIDO/Nuvex-${ANTERIOR#v}.zip" "$MOTOR_EXTRAIDO"
    export NUVEX_MOTOR_PUBLICADO="$MOTOR_EXTRAIDO/Nuvex.app/Contents/Resources"
    [ "$(shasum -a 256 "$NUVEX_MOTOR_PUBLICADO/openfortivpn" | cut -d' ' -f1)" = "${MOTOR_PREVIO%% *}" ] \
      || falla "el motor de Nuvex-${ANTERIOR#v}.zip no coincide con su motor.sha256"
    codesign --verify --strict "$NUVEX_MOTOR_PUBLICADO/openfortivpn" \
      || falla "la firma del motor de Nuvex-${ANTERIOR#v}.zip no es válida"
    paso "Motor reutilizado de $ANTERIOR (${MOTOR_PREVIO%% *})"
  elif [ -n "$MOTOR_PREVIO" ] && [ "$OPENSSL_PREVIO" != "$MOTOR_PREVIO" ]; then
    python3 "$RAIZ_APP/scripts/comparar_versiones.py" "$OPENSSL_ACTUAL" "$OPENSSL_PREVIO" >/dev/null \
      || falla "las versiones de OpenSSL del motor publicado o del entorno no son comparables"
    paso "Motor nuevo por actualización de OpenSSL ($OPENSSL_PREVIO → $OPENSSL_ACTUAL)"
  elif [ -n "$MOTOR_PREVIO" ]; then
    falla "motor.sha256 de $ANTERIOR no declara una versión de OpenSSL válida"
  fi
fi

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
verificar_candidato_congelado
codesign --verify --deep --strict "$APP" \
  || falla "la app compilada no superó la verificación profunda de firma"
IDENTIDAD_HASH="$(security find-identity -p codesigning | awk -v identidad="$IDENTIDAD" 'index($0, "\"" identidad "\"") { print $2; exit }')"
[ -n "$IDENTIDAD_HASH" ] || falla "no se encontró la identidad de firma «${IDENTIDAD}»"
REQUISITO_FIRMA="$(codesign -d -r- "$APP" 2>&1)"
IDENTIDAD_HASH="$(printf '%s' "$IDENTIDAD_HASH" | tr '[:upper:]' '[:lower:]')"
case "$REQUISITO_FIRMA" in
  *"certificate leaf = H\"$IDENTIDAD_HASH\""*) ;;
  *) falla "la app no quedó firmada con «${IDENTIDAD}»" ;;
esac
PLIST="$APP/Contents/Info.plist"
VERSION_PAQUETE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
COMPILACION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
COMMIT_PAQUETE="$(/usr/libexec/PlistBuddy -c 'Print :NuvexCommit' "$PLIST")"
CANAL_PAQUETE="$(/usr/libexec/PlistBuddy -c 'Print :NuvexCanal' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
ARQUITECTURAS="$(lipo -archs "$APP/Contents/MacOS/Nuvex")"
[ "$VERSION_PAQUETE" = "$VERSION" ] \
  || falla "la app declara versión $VERSION_PAQUETE y se esperaba $VERSION"
[ "$COMPILACION" = "$COMPILACION_ESPERADA" ] \
  || falla "la app declara build $COMPILACION y se esperaba $COMPILACION_ESPERADA"
[ "$COMMIT_PAQUETE" = "$COMMIT_CORTO" ] \
  || falla "la app declara commit $COMMIT_PAQUETE y se esperaba $COMMIT_CORTO"
[ "$CANAL_PAQUETE" = publicada ] \
  || falla "la app no fue compilada para el canal publicado"
[ "$BUNDLE_ID" = local.gertcode.nuvex ] \
  || falla "la app declara un identificador inesperado: $BUNDLE_ID"
[ "$ARQUITECTURAS" = arm64 ] \
  || falla "el artefacto oficial debe declarar explícitamente su arquitectura arm64: $ARQUITECTURAS"
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
# Se parte del appcast publicado y del archivo de la versión anterior, para
# conservar el historial y generar la actualización delta.
if [ -n "$ANTERIOR" ]; then
  rm -f "$SALIDA/appcast.xml"
  if git fetch --quiet origin gh-pages 2>/dev/null \
     && git show FETCH_HEAD:appcast.xml > "$SALIDA/appcast.xml" 2>/dev/null \
     && [ -s "$SALIDA/appcast.xml" ]; then
    paso "Appcast anterior recuperado de gh-pages"
  else
    rm -f "$SALIDA/appcast.xml"
    curl -fsSL "$FEED" -o "$SALIDA/appcast.xml" 2>/dev/null || true
  fi
  [ -s "$SALIDA/appcast.xml" ] \
    || falla "no se pudo recuperar el appcast publicado; se cancela para no perder su historial"
else
  rm -f "$SALIDA/appcast.xml"
fi
# Para el delta hace falta el zip publicado exacto, no una compilación local.
if [ -n "$ANTERIOR" ] && [ "$MODO" != simular ] && [ -z "${NUVEX_MOTOR_PUBLICADO:-}" ]; then
  rm -f "$SALIDA/Nuvex-${ANTERIOR#v}.zip"
  gh release download "$ANTERIOR" --repo "$REPO" --pattern "Nuvex-${ANTERIOR#v}.zip" --dir "$SALIDA" 2>/dev/null || true
elif [ -n "$ANTERIOR" ] && ! ls "$SALIDA"/Nuvex-"${ANTERIOR#v}".zip >/dev/null 2>&1; then
  gh release download "$ANTERIOR" --repo "$REPO" --pattern "Nuvex-${ANTERIOR#v}.zip" --dir "$SALIDA" 2>/dev/null || true
fi
ZIP="$SALIDA/Nuvex-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
# Sparkle vuelve a generar todas las entradas de los ZIP presentes. Por eso
# cada una necesita sus propias notas; de otro modo borraría las históricas.
for paquete in "$SALIDA"/Nuvex-*.zip; do
  version_notas="$(basename "$paquete" .zip)"
  version_notas="${version_notas#Nuvex-}"
  notas="$SALIDA/Nuvex-$version_notas.md"
  awk -v v="$version_notas" '
    /^## \[/ { dentro = index($0, "## [" v "]") == 1; next }
    dentro { print }
  ' CHANGELOG.md | sed -e '/./,$!d' > "$notas"
  [ -s "$notas" ] || falla "CHANGELOG.md no contiene notas para Nuvex $version_notas"
done
printf '%s\n' "$MOTOR" > "$SALIDA/motor.sha256"
MANIFIESTO="$SALIDA/release-manifest.txt"
printf '%s\n' \
  "version=$VERSION" \
  "build=$COMPILACION" \
  "commit=$COMMIT_INICIAL" \
  "bundle_id=$BUNDLE_ID" \
  "architectures=$ARQUITECTURAS" \
  "channel=$CANAL_PAQUETE" \
  "engine_sha256=${MOTOR%% *}" \
  "openssl=$OPENSSL_VERSION" > "$MANIFIESTO"

paso "Artefactos Sparkle firmados"
OPCIONES=(--download-url-prefix "https://github.com/$REPO/releases/download/$ETIQUETA/"
          --embed-release-notes --maximum-deltas 3 --link "https://github.com/$REPO")
$BETA && OPCIONES+=(--channel beta)
if [ "$MODO" = ci ]; then
  # La clave privada llega por la entrada estándar, nunca en argumentos.
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${OPCIONES[@]}" "$SALIDA"
else
  "$SPARKLE_BIN/generate_appcast" "${OPCIONES[@]}" "$SALIDA"
fi
CANAL_APPCAST=""
$BETA && CANAL_APPCAST="beta"
# generate_appcast pone el prefijo de esta versión a todos los zip; los de
# versiones anteriores viven en la publicación de su propia etiqueta.
python3 "$RAIZ_APP/scripts/ajustar_appcast.py" "$SALIDA/appcast.xml" "$REPO" "$VERSION" \
  || falla "no se pudieron restaurar las URL históricas del appcast"
# Los delta se llaman Nuvex<nueva>-<anterior>.delta y se suben con esta versión.
DELTAS=()
while IFS= read -r delta; do DELTAS+=("$delta"); done < <(find "$SALIDA" -maxdepth 1 -name "Nuvex$COMPILACION-*.delta")
python3 "$RAIZ_APP/scripts/verificar_appcast.py" "$SALIDA/appcast.xml" "$VERSION" "$COMPILACION" \
  --canal "$CANAL_APPCAST" \
  --url-esperada "https://github.com/$REPO/releases/download/$ETIQUETA/Nuvex-$VERSION.zip" \
  --archivo "$ZIP" \
  --directorio-archivos "$SALIDA" || falla "el appcast nuevo no cumple el contrato de actualización"
verificar_candidato_congelado

SUMAS="$SALIDA/SHA256SUMS"
(
  cd "$SALIDA"
  archivos=("Nuvex-$VERSION.zip" "Nuvex-$VERSION.md" appcast.xml motor.sha256 release-manifest.txt)
  while IFS= read -r delta; do archivos+=("$(basename "$delta")"); done \
    < <(find . -maxdepth 1 -name "Nuvex$COMPILACION-*.delta" -type f | LC_ALL=C sort)
  shasum -a 256 "${archivos[@]}"
) > "$SUMAS"
(cd "$SALIDA" && shasum -a 256 -c "$(basename "$SUMAS")" >/dev/null) \
  || falla "no se pudieron verificar los checksums del release"

if [ "$MODO" = simular ]; then
  printf '\nSimulación completa. Se publicaría:\n  %s\n  %s\n  %s\n  %s\n' \
    "$ZIP" "$SALIDA/appcast.xml" "$MANIFIESTO" "$SUMAS"
  for delta in ${DELTAS[@]+"${DELTAS[@]}"}; do printf '  %s\n' "$delta"; done
  exit 0
fi

paso "Publicación en GitHub"
NOTAS="$SALIDA/Nuvex-$VERSION.md"
BANDERAS=(--title "Nuvex $VERSION" --notes-file "$NOTAS")
if [ "$MODO" = ci ]; then BANDERAS+=(--verify-tag); else BANDERAS+=(--target "$(git rev-parse HEAD)"); fi
$BETA && BANDERAS+=(--prerelease)
gh release create "$ETIQUETA" --repo "$REPO" "${BANDERAS[@]}" \
  "$ZIP" "$SALIDA/motor.sha256" "$MANIFIESTO" "$SUMAS" \
  ${DELTAS[@]+"${DELTAS[@]}"}

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
