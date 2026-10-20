#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE="$ROOT/Nuvex/.build/artifacts/sparkle/Sparkle/bin"
GENERAR="$SPARKLE/generate_appcast"
APP_COMPILADA="$ROOT/Nuvex/Nuvex.app"

if [ ! -x "$GENERAR" ] || [ ! -d "$APP_COMPILADA" ]; then
  echo 'Falta la app compilada o Sparkle; ejecuta primero ./build.sh.' >&2
  exit 1
fi

if [ -z "${SDKROOT:-}" ]; then
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
fi
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build-cache/clang}"
export SDKROOT CLANG_MODULE_CACHE_PATH
mkdir -p "$CLANG_MODULE_CACHE_PATH"

temporal="$(mktemp -d /private/tmp/nuvex-actualizacion.XXXXXX)"
trap 'rm -rf "$temporal"' EXIT
comprobador="$temporal/firma-actualizacion-checks"
swiftc -parse-as-library -sdk "$SDKROOT" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$ROOT/Nuvex/Tests/FirmaActualizacionChecks.swift" -o "$comprobador"

privada="$temporal/clave-privada"
publica="$temporal/clave-publica"
"$comprobador" crear-clave "$privada" "$publica"
[ "$(stat -f '%Lp' "$privada")" = 600 ]

actualizaciones="$temporal/actualizaciones"
mkdir "$actualizaciones"

crear_app() {
  local version="$1"
  local compilacion="$2"
  local app="$temporal/Nuvex.app"
  local info="$app/Contents/Info.plist"
  rm -rf "$app"
  ditto "$APP_COMPILADA" "$app"
  plutil -replace CFBundleIdentifier -string mx.edu.iebo.nuvex.prueba "$info"
  plutil -replace CFBundleShortVersionString -string "$version" "$info"
  plutil -replace CFBundleVersion -string "$compilacion" "$info"
  plutil -replace SUFeedURL -string 'https://example.invalid/nuvex/appcast.xml' "$info"
  plutil -replace SUPublicEDKey -string "$(tr -d '\n' < "$publica")" "$info"
  codesign --force --deep --sign - "$app" >/dev/null
  ditto -c -k --sequesterRsrc --keepParent "$app" \
    "$actualizaciones/Nuvex-$version.zip"
  printf 'Notas de la versión %s\n' "$version" > "$actualizaciones/Nuvex-$version.md"
}

crear_app 9.9.0 900
crear_app 9.9.1 901

usuario_temporal="$temporal/usuario"
mkdir -p "$usuario_temporal/Library/Caches"
CFFIXED_USER_HOME="$usuario_temporal" "$GENERAR" --ed-key-file "$privada" \
  --download-url-prefix 'https://example.invalid/nuvex/' \
  --embed-release-notes --maximum-versions 2 --maximum-deltas 1 \
  "$actualizaciones" >/dev/null

appcast="$actualizaciones/appcast.xml"
test -f "$appcast"
python3 "$ROOT/Nuvex/scripts/verificar_appcast.py" "$appcast" 9.9.1 901 \
  --url-esperada 'https://example.invalid/nuvex/Nuvex-9.9.1.zip' \
  --archivo "$actualizaciones/Nuvex-9.9.1.zip" \
  --directorio-archivos "$actualizaciones"

firma="$(python3 -c '
import sys
import xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
for item in ET.parse(sys.argv[1]).getroot().findall("./channel/item"):
    if item.findtext("sparkle:version", default="", namespaces=ns) == "901":
        enclosure = item.find("enclosure")
        if enclosure is not None:
            print(enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", ""))
            break
' "$appcast")"
test -n "$firma"

datos_delta="$(python3 -c '
import sys
import urllib.parse
import xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
for item in ET.parse(sys.argv[1]).getroot().findall("./channel/item"):
    if item.findtext("sparkle:version", default="", namespaces=ns) != "901":
        continue
    for enclosure in item.findall("sparkle:deltas/enclosure", namespaces=ns):
        if enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}deltaFrom") == "900":
            nombre = urllib.parse.urlparse(enclosure.get("url", "")).path.rsplit("/", 1)[-1]
            firma_delta = enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", "")
            print(nombre + "|" + firma_delta)
            break
' "$appcast")"
IFS='|' read -r nombre_delta firma_delta <<< "$datos_delta"
test -n "$nombre_delta"
test -n "$firma_delta"
test -f "$actualizaciones/$nombre_delta"
"$comprobador" verificar "$publica" "$actualizaciones/$nombre_delta" "$firma_delta"

zip="$actualizaciones/Nuvex-9.9.1.zip"
"$comprobador" verificar "$publica" "$zip" "$firma"
alterado="$temporal/Nuvex-alterado.zip"
cp "$zip" "$alterado"
printf '\0' >> "$alterado"
if "$comprobador" verificar "$publica" "$alterado" "$firma" >/dev/null 2>&1; then
  echo 'La firma aceptó un ZIP alterado' >&2
  exit 1
fi

echo 'Actualización firmada: ZIP y delta válidos; alteración rechazada'
