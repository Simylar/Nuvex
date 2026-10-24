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
swiftc -sdk "$SDKROOT" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$ROOT/Nuvex/Sources/Nuvex/AutorizacionAgentes.swift" \
  "$ROOT/Nuvex/Tests/AutorizacionAgentesChecks.swift" \
  -o "$tmp/agentes-checks"
if [ -x /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex ]; then
  export NUVEX_CODEX_BIN=/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
fi
if [ -x /Users/samuel/.local/bin/claude ]; then
  export NUVEX_CLAUDE_BIN=/Users/samuel/.local/bin/claude
fi
"$tmp/agentes-checks"
