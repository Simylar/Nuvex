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
temporal="$(mktemp -d)"
trap 'rm -rf "$temporal"' EXIT
swiftc -sdk "$SDKROOT" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$ROOT/Nuvex/Sources/Nuvex/Modelos.swift" \
  "$ROOT/Nuvex/Sources/Nuvex/BorradorBienvenida.swift" \
  "$ROOT/Nuvex/Sources/Nuvex/Preferencias.swift" \
  "$ROOT/Nuvex/Sources/Nuvex/Soporte.swift" \
  "$ROOT/Nuvex/Sources/Nuvex/GuardadoConfiguracion.swift" \
  "$ROOT/Nuvex/Sources/Nuvex/EstadoCapacidades.swift" \
  "$ROOT/Nuvex/Sources/Nuvex/AccesoLlavero.swift" \
  "$ROOT/Nuvex/Sources/Nuvex/ProblemaGmail.swift" \
  "$ROOT/Nuvex/Tests/ConfiguracionChecks.swift" -o "$temporal/configuracion-checks"
"$temporal/configuracion-checks"
