#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$(cd "$ROOT/.." && pwd)"
if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PROJECT/.build-cache/clang}"

DESTINATION="${1:-$PROJECT/.build-cache/capturas}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$DESTINATION"
DESTINATION="$(cd "$DESTINATION" && pwd)"
cd "$ROOT"
swift build --build-system native --disable-sandbox
"$ROOT/.build/debug/Nuvex" --captura "$DESTINATION"
printf 'Capturas: %s\n' "$DESTINATION"
