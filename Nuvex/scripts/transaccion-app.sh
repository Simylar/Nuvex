#!/usr/bin/env bash
# Reemplazo recuperable de un paquete .app. Se carga con `source`; el llamador
# debe verificar que la aplicación nueva arranca antes de confirmar.

NUVEX_TRANSACCION_ACTIVA=false
NUVEX_TRANSACCION_DESTINO=""
NUVEX_TRANSACCION_TEMPORAL=""
NUVEX_TRANSACCION_ANTERIOR=""

nuvex_preparar_reemplazo() {
  [ "$#" -eq 2 ] || { echo "nuvex: preparar reemplazo necesita origen y destino" >&2; return 2; }
  local origen="$1" destino="$2" padre nombre
  [ -d "$origen" ] && [ -f "$origen/Contents/Info.plist" ] && [ ! -L "$origen" ] \
    || { echo "nuvex: la aplicación de origen no es válida: $origen" >&2; return 1; }
  case "$destino" in
    /*.app) ;;
    *) echo "nuvex: el destino debe ser una ruta absoluta terminada en .app" >&2; return 1 ;;
  esac
  [ ! -L "$destino" ] || { echo "nuvex: el destino no puede ser un enlace simbólico" >&2; return 1; }
  [ ! -e "$destino" ] || [ -d "$destino" ] \
    || { echo "nuvex: el destino existe y no es una aplicación: $destino" >&2; return 1; }
  padre="$(dirname "$destino")"
  [ -d "$padre" ] && [ "$padre" != / ] \
    || { echo "nuvex: la carpeta de destino no es válida: $padre" >&2; return 1; }
  nombre="$(basename "$destino" .app)"

  NUVEX_TRANSACCION_DESTINO="$destino"
  NUVEX_TRANSACCION_TEMPORAL="$padre/.${nombre}.nueva.app"
  NUVEX_TRANSACCION_ANTERIOR="$padre/.${nombre}.anterior.app"
  if [ -e "$NUVEX_TRANSACCION_ANTERIOR" ] || [ -L "$NUVEX_TRANSACCION_ANTERIOR" ]; then
    if [ ! -e "$destino" ] && [ ! -L "$destino" ] \
      && [ -d "$NUVEX_TRANSACCION_ANTERIOR" ] && [ ! -L "$NUVEX_TRANSACCION_ANTERIOR" ]; then
      mv "$NUVEX_TRANSACCION_ANTERIOR" "$destino" || {
        echo "nuvex: no se pudo recuperar la actualización interrumpida" >&2
        return 1
      }
      echo "Se recuperó una versión anterior tras una actualización interrumpida." >&2
    else
      echo "nuvex: existe una actualización sin cerrar en $NUVEX_TRANSACCION_ANTERIOR" >&2
      return 1
    fi
  fi

  rm -rf "$NUVEX_TRANSACCION_TEMPORAL"
  ditto "$origen" "$NUVEX_TRANSACCION_TEMPORAL" || return 1
  codesign --verify --deep --strict "$NUVEX_TRANSACCION_TEMPORAL" || {
    rm -rf "$NUVEX_TRANSACCION_TEMPORAL"
    return 1
  }
  # Desde este punto cualquier señal debe activar la recuperación del llamador.
  NUVEX_TRANSACCION_ACTIVA=true
  if [ -d "$destino" ]; then
    mv "$destino" "$NUVEX_TRANSACCION_ANTERIOR" || {
      NUVEX_TRANSACCION_ACTIVA=false
      rm -rf "$NUVEX_TRANSACCION_TEMPORAL"
      return 1
    }
  fi
  if ! mv "$NUVEX_TRANSACCION_TEMPORAL" "$destino"; then
    if [ -d "$NUVEX_TRANSACCION_ANTERIOR" ]; then
      mv "$NUVEX_TRANSACCION_ANTERIOR" "$destino" || return 1
    fi
    NUVEX_TRANSACCION_ACTIVA=false
    rm -rf "$NUVEX_TRANSACCION_TEMPORAL"
    return 1
  fi
}

nuvex_revertir_reemplazo() {
  $NUVEX_TRANSACCION_ACTIVA || return 0
  local fallida
  fallida="$(dirname "$NUVEX_TRANSACCION_DESTINO")/.$(basename "$NUVEX_TRANSACCION_DESTINO" .app).fallida.app"
  rm -rf "$fallida"
  if [ -d "$NUVEX_TRANSACCION_DESTINO" ]; then
    mv "$NUVEX_TRANSACCION_DESTINO" "$fallida" || return 1
  fi
  if [ -d "$NUVEX_TRANSACCION_ANTERIOR" ]; then
    if ! mv "$NUVEX_TRANSACCION_ANTERIOR" "$NUVEX_TRANSACCION_DESTINO"; then
      [ ! -d "$fallida" ] || mv "$fallida" "$NUVEX_TRANSACCION_DESTINO" || true
      return 1
    fi
  fi
  rm -rf "$fallida" "$NUVEX_TRANSACCION_TEMPORAL"
  NUVEX_TRANSACCION_ACTIVA=false
}

nuvex_confirmar_reemplazo() {
  $NUVEX_TRANSACCION_ACTIVA || return 1
  rm -rf "$NUVEX_TRANSACCION_ANTERIOR" "$NUVEX_TRANSACCION_TEMPORAL" || return 1
  [ ! -e "$NUVEX_TRANSACCION_ANTERIOR" ] && [ ! -L "$NUVEX_TRANSACCION_ANTERIOR" ] || return 1
  [ ! -e "$NUVEX_TRANSACCION_TEMPORAL" ] && [ ! -L "$NUVEX_TRANSACCION_TEMPORAL" ] || return 1
  NUVEX_TRANSACCION_ACTIVA=false
}
