#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build-cache/clang}"
# No ejecutar un binario anterior si la compilación falla.
swift build --package-path "$ROOT/Nuvex" --build-system native --disable-sandbox
"$ROOT/Nuvex/.build/debug/Nuvex" --verificar-interfaz
