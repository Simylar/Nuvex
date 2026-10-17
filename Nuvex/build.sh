#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
APP="Nuvex.app"
ROOT="$(cd .. && pwd)"
ENGINE_DIR="$ROOT/vendor/openfortivpn"
OPENSSL_PREFIX="$(brew --prefix openssl@3)"

# macOS 27 SDK y Command Line Tools pueden estar desincronizados en esta Mac.
if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build-cache/clang}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

# Versión: X.Y.Z sale de VERSION; el número de compilación del historial de
# Git, que crece con cada commit y ordena las actualizaciones de Sparkle.
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION debe tener la forma X.Y.Z" >&2; exit 1; }
# La base 100 deja atrás los números escritos a mano hasta la 3.0 (CFBundleVersion 3).
BUILD_NUMBER="$((100 + $(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)))"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo desconocido)"
CANAL="${NUVEX_CANAL:-desarrollo}"

# Firma: una identidad estable mantiene los permisos del Llavero entre
# versiones. Sin ella se firma en modo ad hoc y macOS volverá a preguntar.
IDENTIDAD="${NUVEX_IDENTIDAD:-Nuvex Release}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTIDAD\""; then
  FIRMA="$IDENTIDAD"
else
  FIRMA="-"
  printf 'Aviso: no se encontró la identidad «%s»; se firma en modo ad hoc.\n' "$IDENTIDAD" >&2
  printf '       Créala con scripts/configurar-publicacion.sh para que el Llavero no vuelva a pedir permiso.\n' >&2
fi

# Motor: el ayudante verifica el hash exacto de openfortivpn y OpenSSL. Se
# reutilizan los mismos bytes mientras no cambien su código ni OpenSSL, así
# actualizar Nuvex no obliga a reinstalar el ayudante.
MOTOR_CLAVE="$({
  git -C "$ROOT" rev-parse HEAD:vendor/openfortivpn 2>/dev/null || echo sin-git
  git -C "$ROOT" diff HEAD -- vendor/openfortivpn 2>/dev/null
  git -C "$ROOT" ls-files --others --exclude-standard -- vendor/openfortivpn 2>/dev/null
  brew list --versions openssl@3
  echo "motor-1"
} | shasum -a 256 | cut -c1-16)"
MOTOR_CACHE="$ROOT/.build-cache/motor/$MOTOR_CLAVE"

if [ -f "$MOTOR_CACHE/openfortivpn" ] && [ -f "$MOTOR_CACHE/libssl.3.dylib" ] && [ -f "$MOTOR_CACHE/libcrypto.3.dylib" ]; then
  printf '==> Motor Fortinet sin cambios (%s)\n' "$MOTOR_CLAVE"
else
  printf '==> Compilando motor Fortinet incluido\n'
  if [ ! -f "$ENGINE_DIR/Makefile" ]; then
    if [ ! -x "$ENGINE_DIR/configure" ]; then
      (cd "$ENGINE_DIR" && ./autogen.sh)
    fi
    (cd "$ENGINE_DIR" && PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig" ./configure \
      --enable-legacy-pppd --with-pppd=/usr/sbin/pppd)
  fi
  make -C "$ENGINE_DIR" -j4
  TEMP_MOTOR="$(mktemp -d "$ROOT/.build-cache/motor-XXXXXX")"
  cp "$ENGINE_DIR/openfortivpn" "$TEMP_MOTOR/openfortivpn"
  cp "$OPENSSL_PREFIX/lib/libssl.3.dylib" "$TEMP_MOTOR/libssl.3.dylib"
  cp "$OPENSSL_PREFIX/lib/libcrypto.3.dylib" "$TEMP_MOTOR/libcrypto.3.dylib"
  chmod 755 "$TEMP_MOTOR/openfortivpn"
  chmod 644 "$TEMP_MOTOR/libssl.3.dylib" "$TEMP_MOTOR/libcrypto.3.dylib"
  BIN="$TEMP_MOTOR/openfortivpn"
  SSL="$TEMP_MOTOR/libssl.3.dylib"
  CRYPTO="$TEMP_MOTOR/libcrypto.3.dylib"
  OLD_SSL="$(otool -L "$BIN" | awk '/libssl\.3\.dylib/ {print $1; exit}')"
  OLD_CRYPTO="$(otool -L "$BIN" | awk '/libcrypto\.3\.dylib/ {print $1; exit}')"
  OLD_SSL_CRYPTO="$(otool -L "$SSL" | awk '/libcrypto\.3\.dylib/ {print $1; exit}')"
  install_name_tool -change "$OLD_SSL" @loader_path/libssl.3.dylib "$BIN" 2>/dev/null
  install_name_tool -change "$OLD_CRYPTO" @loader_path/libcrypto.3.dylib "$BIN" 2>/dev/null
  install_name_tool -change "$OLD_SSL_CRYPTO" @loader_path/libcrypto.3.dylib "$SSL" 2>/dev/null
  install_name_tool -id @loader_path/libssl.3.dylib "$SSL" 2>/dev/null
  install_name_tool -id @loader_path/libcrypto.3.dylib "$CRYPTO" 2>/dev/null
  # La firma ad hoc es determinista: mismos bytes, mismo hash.
  codesign --force --sign - "$BIN" "$SSL" "$CRYPTO"
  mkdir -p "$(dirname "$MOTOR_CACHE")"
  rm -rf "$MOTOR_CACHE"
  mv "$TEMP_MOTOR" "$MOTOR_CACHE"
fi

printf '==> Compilando Nuvex %s (%s)\n' "$VERSION" "$BUILD_NUMBER"
swift build --build-system native -c release --disable-sandbox
SPARKLE="$(find .build -type d -path '*macos-arm64_x86_64/Sparkle.framework' -prune 2>/dev/null | head -1)"
[ -n "$SPARKLE" ] || { echo "No se encontró Sparkle.framework tras compilar" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Frameworks"
cp .build/release/Nuvex "$APP/Contents/MacOS/Nuvex"
if [ -f .build/release/nuvex-cli ]; then
  cp .build/release/nuvex-cli "$APP/Contents/Resources/bin/nuvex"
fi
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/Nuvex" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Nuvex"
fi
cp "$MOTOR_CACHE/openfortivpn" "$MOTOR_CACHE/libssl.3.dylib" "$MOTOR_CACHE/libcrypto.3.dylib" "$APP/Contents/Resources/"
cp "$ROOT/nuvexctl.sh" "$ROOT/nuvexconfig.py" "$ROOT/nuvexconnect.py" "$APP/Contents/Resources/"
cp scripts/install_helper.applescript "$APP/Contents/Resources/"
cp Resources/prepa-ca-bundle.pem Resources/nuvex_mark.svg Resources/nuvex_logo.svg Resources/nuvex_wordmark.svg "$APP/Contents/Resources/"
for extra in Resources/nuvex-vpn-SKILL.md; do
  [ -f "$extra" ] && cp "$extra" "$APP/Contents/Resources/"
done
cp "$ROOT/CHANGELOG.md" "$APP/Contents/Resources/CHANGELOG.md"
cp "$ENGINE_DIR/LICENSE" "$APP/Contents/Resources/openfortivpn-LICENSE.txt"
cp "$OPENSSL_PREFIX/LICENSE.txt" "$APP/Contents/Resources/OpenSSL-LICENSE.txt"
chmod 755 "$APP/Contents/Resources/openfortivpn" "$APP/Contents/Resources/nuvexctl.sh"

ICONSET="$ROOT/.build-cache/Nuvex.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift scripts/rasterize_svg.swift Resources/nuvex_mark.svg "$ICONSET"
python3 scripts/make_icns.py "$ICONSET" "$APP/Contents/Resources/Nuvex.icns"

# La clave pública EdDSA autentica las actualizaciones. Sin ella, la app
# compila igual pero no busca actualizaciones automáticas.
CLAVE_PUBLICA="$(tr -d '[:space:]' < Resources/sparkle_ed_public_key 2>/dev/null || true)"
SPARKLE_PLIST=""
if [ -n "$CLAVE_PUBLICA" ]; then
  SPARKLE_PLIST="  <key>SUFeedURL</key><string>https://simylar.github.io/Nuvex/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$CLAVE_PUBLICA</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>SUAllowsAutomaticUpdates</key><true/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>"
else
  printf 'Aviso: falta Resources/sparkle_ed_public_key; esta compilación no buscará actualizaciones.\n' >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Nuvex</string>
  <key>CFBundleDisplayName</key><string>Nuvex</string>
  <key>CFBundleIdentifier</key><string>local.gertcode.nuvex</string>
  <key>CFBundleExecutable</key><string>Nuvex</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>NuvexCanal</key><string>$CANAL</string>
  <key>NuvexCommit</key><string>$COMMIT</string>
  <key>CFBundleIconFile</key><string>Nuvex.icns</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Nuvex</string>
    <key>CFBundleURLSchemes</key><array><string>nuvex</string></array>
  </dict></array>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>local.gertcode.nuvex.exportacion</string>
    <key>UTTypeDescription</key><string>Conexiones de Nuvex</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeTagSpecification</key><dict>
      <key>public.filename-extension</key><array><string>nuvexvpn</string></array>
    </dict>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Conexiones de Nuvex</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>local.gertcode.nuvex.exportacion</string></array>
  </dict></array>
  <key>NSUserNotificationAlertStyle</key><string>alert</string>
  <key>NSUserNotificationUsageDescription</key><string>Nuvex te avisa si una VPN activa se desconecta.</string>
  <key>NSFaceIDUsageDescription</key><string>Nuvex confirma tu identidad antes de usar una contraseña VPN guardada.</string>
$SPARKLE_PLIST
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Sparkle llega firmado por sus autores y se conserva tal cual. Sin --deep, la
# firma de la app no toca el motor ni las bibliotecas, que quedan selladas
# como recursos con su firma ad hoc estable.
codesign --force --sign "$FIRMA" "$APP"
codesign --verify --strict "$APP"
printf 'Lista: %s/%s · %s (%s) · firma: %s · motor: %s\n' "$(pwd)" "$APP" "$VERSION" "$BUILD_NUMBER" \
  "$([ "$FIRMA" = - ] && echo 'ad hoc' || echo "$FIRMA")" "$(shasum -a 256 "$APP/Contents/Resources/openfortivpn" | cut -c1-12)"
