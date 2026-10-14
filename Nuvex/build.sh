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

printf '==> Compilando motor Fortinet incluido\n'
if [ ! -f "$ENGINE_DIR/Makefile" ]; then
  if [ ! -x "$ENGINE_DIR/configure" ]; then
    (cd "$ENGINE_DIR" && ./autogen.sh)
  fi
  (cd "$ENGINE_DIR" && PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig" ./configure \
    --enable-legacy-pppd --with-pppd=/usr/sbin/pppd)
fi
make -C "$ENGINE_DIR" -j4

printf '==> Compilando Nuvex\n'
swift build --build-system native -c release --disable-sandbox
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Nuvex "$APP/Contents/MacOS/Nuvex"
cp "$ENGINE_DIR/openfortivpn" "$APP/Contents/Resources/openfortivpn"
cp "$OPENSSL_PREFIX/lib/libssl.3.dylib" "$APP/Contents/Resources/libssl.3.dylib"
cp "$OPENSSL_PREFIX/lib/libcrypto.3.dylib" "$APP/Contents/Resources/libcrypto.3.dylib"
cp "$ROOT/nuvexctl.sh" "$ROOT/nuvexconfig.py" "$ROOT/nuvexconnect.py" "$APP/Contents/Resources/"
cp scripts/install_helper.applescript "$APP/Contents/Resources/"
cp Resources/prepa-ca-bundle.pem Resources/nuvex_mark.svg Resources/nuvex_logo.svg Resources/nuvex_wordmark.svg "$APP/Contents/Resources/"
cp "$ENGINE_DIR/LICENSE" "$APP/Contents/Resources/openfortivpn-LICENSE.txt"
cp "$OPENSSL_PREFIX/LICENSE.txt" "$APP/Contents/Resources/OpenSSL-LICENSE.txt"
chmod 755 "$APP/Contents/Resources/openfortivpn" "$APP/Contents/Resources/nuvexctl.sh"

BIN="$APP/Contents/Resources/openfortivpn"
SSL="$APP/Contents/Resources/libssl.3.dylib"
CRYPTO="$APP/Contents/Resources/libcrypto.3.dylib"
OLD_SSL="$(otool -L "$BIN" | awk '/libssl\.3\.dylib/ {print $1; exit}')"
OLD_CRYPTO="$(otool -L "$BIN" | awk '/libcrypto\.3\.dylib/ {print $1; exit}')"
OLD_SSL_CRYPTO="$(otool -L "$SSL" | awk '/libcrypto\.3\.dylib/ {print $1; exit}')"
install_name_tool -change "$OLD_SSL" @loader_path/libssl.3.dylib "$BIN"
install_name_tool -change "$OLD_CRYPTO" @loader_path/libcrypto.3.dylib "$BIN"
install_name_tool -change "$OLD_SSL_CRYPTO" @loader_path/libcrypto.3.dylib "$SSL"
install_name_tool -id @loader_path/libssl.3.dylib "$SSL"
install_name_tool -id @loader_path/libcrypto.3.dylib "$CRYPTO"

ICONSET="$ROOT/.build-cache/Nuvex.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift scripts/rasterize_svg.swift Resources/nuvex_mark.svg "$ICONSET"
python3 scripts/make_icns.py "$ICONSET" "$APP/Contents/Resources/Nuvex.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Nuvex</string>
  <key>CFBundleDisplayName</key><string>Nuvex</string>
  <key>CFBundleIdentifier</key><string>local.gertcode.nuvex</string>
  <key>CFBundleExecutable</key><string>Nuvex</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>3.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleIconFile</key><string>Nuvex.icns</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Nuvex</string>
    <key>CFBundleURLSchemes</key><array><string>nuvex</string></array>
  </dict></array>
  <key>NSUserNotificationUsageDescription</key><string>Nuvex te avisa si una VPN activa se desconecta.</string>
  <key>NSFaceIDUsageDescription</key><string>Nuvex confirma tu identidad antes de usar una contraseña VPN guardada.</string>
</dict></plist>
PLIST

codesign --force --sign - "$BIN" "$SSL" "$CRYPTO"
codesign --force --deep --sign - "$APP"
printf 'Lista: %s/%s\n' "$(pwd)" "$APP"
