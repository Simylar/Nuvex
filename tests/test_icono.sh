#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${SDKROOT:-}" ]; then
  if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  else
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  fi
fi
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build-cache/clang}"
export SDKROOT CLANG_MODULE_CACHE_PATH
mkdir -p "$CLANG_MODULE_CACHE_PATH"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

swift "$ROOT/Nuvex/scripts/rasterize_svg.swift" \
  "$ROOT/Nuvex/Resources/nuvex_mark.svg" "$tmp/Nuvex.iconset"
swiftc -sdk "$SDKROOT" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$ROOT/Nuvex/Tests/IconoChecks.swift" -o "$tmp/icono-checks"
"$tmp/icono-checks" "$tmp/Nuvex.iconset" --completo
python3 "$ROOT/Nuvex/scripts/make_icns.py" \
  "$tmp/Nuvex.iconset" "$tmp/Nuvex.icns"
file "$tmp/Nuvex.icns" | grep -q 'Mac OS X icon'
iconutil -c iconset -o "$tmp/extraido.iconset" "$tmp/Nuvex.icns"
"$tmp/icono-checks" "$tmp/extraido.iconset"
