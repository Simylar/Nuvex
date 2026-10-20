#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_COMPILADA="$ROOT/Nuvex/Nuvex.app"
SPARKLE_CHECKOUT="$ROOT/Nuvex/.build/checkouts/Sparkle"
SPARKLE_FRAMEWORKS="$APP_COMPILADA/Contents/Frameworks"
SPARKLE_CLI="$SPARKLE_CHECKOUT/sparkle-cli"
GENERAR="$ROOT/Nuvex/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

if [ ! -d "$APP_COMPILADA" ] || [ ! -x "$GENERAR" ] || [ ! -d "$SPARKLE_CLI" ]; then
  echo 'Falta la app compilada o Sparkle; ejecuta primero ./build.sh.' >&2
  exit 1
fi

if [ -z "${SDKROOT:-}" ]; then
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
fi
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build-cache/clang}"
export SDKROOT CLANG_MODULE_CACHE_PATH
mkdir -p "$CLANG_MODULE_CACHE_PATH"

directorio_usuario_real="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
if [ ! -d "$directorio_usuario_real" ] || [ "$directorio_usuario_real" = '/' ]; then
  echo 'No se pudo determinar un directorio de usuario seguro para la prueba.' >&2
  exit 1
fi

temporal="$(mktemp -d /private/tmp/nuvex-actualizacion-e2e.XXXXXX)"
servidor_pid=''
actualizador_pid=''
identificador='mx.edu.iebo.nuvex.prueba.actualizacion-e2e'
cache_usuario_prueba="$directorio_usuario_real/Library/Caches/$identificador"
cache_generate_appcast="$directorio_usuario_real/Library/Caches/Sparkle_generate_appcast"
rutas_cache_generada="$temporal/rutas-cache-generate-appcast"
cache_generate_existia='no'
if [ -d "$cache_generate_appcast" ]; then
  cache_generate_existia='si'
fi

limpiar_estado_usuario() {
  local ruta
  local nombre

  defaults delete "$identificador" >/dev/null 2>&1 || true
  rm -rf -- "$cache_usuario_prueba"
  if [ -f "$rutas_cache_generada" ]; then
    while IFS= read -r ruta; do
      nombre="${ruta##*/}"
      if [[ "$ruta" = "$cache_generate_appcast/"* ]] \
        && [[ "$nombre" =~ ^[0-9a-f]{64}$ ]]; then
        rm -rf -- "$ruta"
      fi
    done < "$rutas_cache_generada"
  fi
  if [ "$cache_generate_existia" = 'no' ]; then
    rmdir "$cache_generate_appcast" 2>/dev/null || true
  fi
}

limpiar() {
  if [ -n "$actualizador_pid" ] && kill -0 "$actualizador_pid" 2>/dev/null; then
    kill "$actualizador_pid" 2>/dev/null || true
    wait "$actualizador_pid" 2>/dev/null || true
  fi
  if [ -n "$servidor_pid" ] && kill -0 "$servidor_pid" 2>/dev/null; then
    kill "$servidor_pid" 2>/dev/null || true
    wait "$servidor_pid" 2>/dev/null || true
  fi
  limpiar_estado_usuario
  rm -rf "$temporal"
}
trap limpiar EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

limpiar_estado_usuario

comprobador="$temporal/firma-actualizacion-checks"
swiftc -parse-as-library -sdk "$SDKROOT" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$ROOT/Nuvex/Tests/FirmaActualizacionChecks.swift" -o "$comprobador"

privada="$temporal/clave-privada"
publica="$temporal/clave-publica"
"$comprobador" crear-clave "$privada" "$publica"

cli="$temporal/sparkle-cli"
clang -fobjc-arc \
  '-DSPU_OBJC_DIRECT=__attribute__((objc_direct))' \
  '-DSPU_OBJC_DIRECT_MEMBERS=__attribute__((objc_direct_members))' \
  -framework Cocoa \
  -F "$SPARKLE_FRAMEWORKS" -framework Sparkle \
  -I "$SPARKLE_CLI" \
  "$SPARKLE_CLI/main.m" \
  "$SPARKLE_CLI/SPUCommandLineDriver.m" \
  "$SPARKLE_CLI/SPUCommandLineUserDriver.m" \
  -Wl,-rpath,"$SPARKLE_FRAMEWORKS" \
  -o "$cli"

actualizaciones="$temporal/actualizaciones"
instalacion="$temporal/instalacion"
usuario_temporal="$temporal/usuario"
mkdir -p "$actualizaciones" "$instalacion" "$usuario_temporal/Library/Caches"

clave_publica="$(tr -d '\n' < "$publica")"

crear_version() {
  local version="$1"
  local compilacion="$2"
  local directorio_version="$temporal/version-$compilacion"
  local app="$directorio_version/Nuvex.app"
  local info="$app/Contents/Info.plist"

  mkdir "$directorio_version"
  ditto "$APP_COMPILADA" "$app"
  plutil -replace CFBundleIdentifier -string "$identificador" "$info"
  plutil -replace CFBundleShortVersionString -string "$version" "$info"
  plutil -replace CFBundleVersion -string "$compilacion" "$info"
  plutil -replace SUFeedURL -string 'https://example.invalid/nuvex/appcast.xml' "$info"
  plutil -replace SUPublicEDKey -string "$clave_publica" "$info"
  printf 'versión=%s\ncompilación=%s\n' "$version" "$compilacion" \
    > "$app/Contents/Resources/PruebaActualizacionE2E.txt"
  codesign --force --deep --sign - "$app" >/dev/null
  codesign --verify --deep --strict "$app"
  ditto -c -k --sequesterRsrc --keepParent "$app" \
    "$actualizaciones/Nuvex-$version.zip"
  printf 'Notas de la versión %s\n' "$version" > "$actualizaciones/Nuvex-$version.md"
}

crear_version 9.9.0 900
crear_version 9.9.1 901
ditto "$temporal/version-900/Nuvex.app" "$instalacion/Nuvex.app"

python3 - "$cache_generate_appcast" "$rutas_cache_generada" \
  "$actualizaciones/Nuvex-9.9.0.zip" "$actualizaciones/Nuvex-9.9.1.zip" <<'PY'
import hashlib
import pathlib
import sys

cache, registro, *archivos = sys.argv[1:]
rutas = []
for archivo in archivos:
    digest = hashlib.sha256(pathlib.Path(archivo).read_bytes()).hexdigest()
    rutas.append(str(pathlib.Path(cache) / digest))
pathlib.Path(registro).write_text("\n".join(rutas) + "\n", encoding="utf-8")
PY

puerto_archivo="$temporal/puerto"
registro_servidor="$temporal/servidor-http.log"
registro_peticiones="$temporal/peticiones-http.log"
marcador_interrupcion="$temporal/interrumpir-descargas"
python3 - "$actualizaciones" "$puerto_archivo" "$marcador_interrupcion" \
  "$registro_peticiones" \
  >"$registro_servidor" 2>&1 <<'PY' &
import functools
import http.server
import pathlib
import socket
import sys
import urllib.parse

directorio, puerto_archivo, marcador_interrupcion, registro_peticiones = sys.argv[1:]


class Manejador(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        ruta = urllib.parse.urlsplit(self.path).path
        with pathlib.Path(registro_peticiones).open("a", encoding="utf-8") as registro:
            registro.write(ruta + "\n")
        if pathlib.Path(marcador_interrupcion).exists() and ruta.endswith((".zip", ".delta")):
            archivo = pathlib.Path(self.translate_path(ruta))
            if archivo.is_file():
                contenido = archivo.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(contenido)))
                self.end_headers()
                self.wfile.write(contenido[: max(1, len(contenido) // 4)])
                self.wfile.flush()
                try:
                    self.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                self.connection.close()
                return
        super().do_GET()


manejador = functools.partial(Manejador, directory=directorio)
servidor = http.server.ThreadingHTTPServer(("127.0.0.1", 0), manejador)
pathlib.Path(puerto_archivo).write_text(str(servidor.server_port), encoding="utf-8")
servidor.serve_forever()
PY
servidor_pid=$!

for _ in $(seq 1 100); do
  [ -s "$puerto_archivo" ] && break
  if ! kill -0 "$servidor_pid" 2>/dev/null; then
    echo 'El servidor local de actualizaciones terminó antes de iniciar.' >&2
    sed -n '1,120p' "$registro_servidor" >&2
    exit 1
  fi
  sleep 0.05
done
if [ ! -s "$puerto_archivo" ]; then
  echo 'El servidor local de actualizaciones no informó su puerto.' >&2
  exit 1
fi

puerto="$(tr -d '[:space:]' < "$puerto_archivo")"
url_base="http://127.0.0.1:$puerto"
url_publicacion="https://127.0.0.1:$puerto"
CFFIXED_USER_HOME="$usuario_temporal" "$GENERAR" --ed-key-file "$privada" \
  --download-url-prefix "$url_publicacion/" \
  --embed-release-notes --maximum-versions 2 --maximum-deltas 1 \
  "$actualizaciones" >/dev/null

python3 "$ROOT/Nuvex/scripts/verificar_appcast.py" \
  "$actualizaciones/appcast.xml" 9.9.1 901 \
  --url-esperada "$url_publicacion/Nuvex-9.9.1.zip" \
  --archivo "$actualizaciones/Nuvex-9.9.1.zip" \
  --directorio-archivos "$actualizaciones"

# Producción conserva HTTPS. Solo la copia consumida por esta prueba usa el
# servidor loopback para no depender de red, certificados ni servicios externos.
appcast_local="$actualizaciones/appcast-local.xml"
python3 - "$actualizaciones/appcast.xml" "$appcast_local" \
  "$url_publicacion/" "$url_base/" <<'PY'
import pathlib
import sys

origen, destino, url_publicacion, url_local = sys.argv[1:]
contenido = pathlib.Path(origen).read_text(encoding="utf-8")
if url_publicacion not in contenido:
    raise SystemExit("El appcast no contiene la URL de publicación esperada")
pathlib.Path(destino).write_text(
    contenido.replace(url_publicacion, url_local),
    encoding="utf-8",
)
PY

ejecutar_actualizacion() {
  local app="$1"
  local usuario="$2"
  local registro="$3"

  mkdir -p "$usuario/Library/Caches"
  env CFFIXED_USER_HOME="$usuario" \
    "$cli" \
    --check-immediately \
    --feed-url "$url_base/appcast-local.xml" \
    --user-agent-name 'Nuvex-Prueba-E2E' \
    --verbose \
    "$app" >"$registro" 2>&1 &
  actualizador_pid=$!

  for _ in $(seq 1 240); do
    if ! kill -0 "$actualizador_pid" 2>/dev/null; then
      break
    fi
    sleep 0.25
  done

  if kill -0 "$actualizador_pid" 2>/dev/null; then
    kill "$actualizador_pid" 2>/dev/null || true
    wait "$actualizador_pid" 2>/dev/null || true
    actualizador_pid=''
    estado_actualizacion=124
    return
  fi

  if wait "$actualizador_pid"; then
    estado_actualizacion=0
  else
    estado_actualizacion=$?
  fi
  actualizador_pid=''
}

verificar_version_instalada() {
  local app="$1"
  local version_esperada="$2"
  local compilacion_esperada="$3"
  local info="$app/Contents/Info.plist"
  local version
  local compilacion

  version="$(plutil -extract CFBundleShortVersionString raw -o - "$info")"
  compilacion="$(plutil -extract CFBundleVersion raw -o - "$info")"
  if [ "$version" != "$version_esperada" ] || [ "$compilacion" != "$compilacion_esperada" ]; then
    return 1
  fi
  grep -Fx "versión=$version_esperada" \
    "$app/Contents/Resources/PruebaActualizacionE2E.txt" >/dev/null
  grep -Fx "compilación=$compilacion_esperada" \
    "$app/Contents/Resources/PruebaActualizacionE2E.txt" >/dev/null
  codesign --verify --deep --strict "$app"
}

registro_exito="$temporal/sparkle-cli-exito.log"
ejecutar_actualizacion "$instalacion/Nuvex.app" "$usuario_temporal" "$registro_exito"
if [ "$estado_actualizacion" -ne 0 ]; then
  echo "Sparkle terminó el caso válido con código $estado_actualizacion." >&2
  sed -n '1,240p' "$registro_exito" >&2
  exit 1
fi
if ! verificar_version_instalada "$instalacion/Nuvex.app" 9.9.1 901; then
  echo 'Sparkle no dejó instalada íntegramente la versión esperada.' >&2
  sed -n '1,240p' "$registro_exito" >&2
  exit 1
fi
if ! grep -E '/[^/]+\.delta$' "$registro_peticiones" >/dev/null; then
  echo 'El caso válido no descargó la actualización delta.' >&2
  sed -n '1,240p' "$registro_servidor" >&2
  exit 1
fi
if grep -Fx '/Nuvex-9.9.1.zip' "$registro_peticiones" >/dev/null; then
  echo 'El caso válido recurrió al ZIP completo en lugar de aplicar el delta.' >&2
  sed -n '1,240p' "$registro_servidor" >&2
  exit 1
fi

instalacion_interrumpida="$temporal/instalacion-interrumpida"
mkdir "$instalacion_interrumpida"
ditto "$temporal/version-900/Nuvex.app" "$instalacion_interrumpida/Nuvex.app"
rm -f "$registro_peticiones"
touch "$marcador_interrupcion"
registro_interrumpido="$temporal/sparkle-cli-interrumpido.log"
ejecutar_actualizacion \
  "$instalacion_interrumpida/Nuvex.app" \
  "$temporal/usuario-interrumpido" \
  "$registro_interrumpido"
rm -f "$marcador_interrupcion"
if [ "$estado_actualizacion" -eq 0 ]; then
  echo 'Sparkle aceptó una descarga interrumpida.' >&2
  sed -n '1,240p' "$registro_interrumpido" >&2
  exit 1
fi
if ! grep -F 'error 2001 (SUSparkleErrorDomain)' "$registro_interrumpido" >/dev/null; then
  echo 'Sparkle falló por una causa distinta a la descarga interrumpida esperada.' >&2
  sed -n '1,240p' "$registro_interrumpido" >&2
  exit 1
fi
if ! grep -F 'Downloading Update...' "$registro_interrumpido" >/dev/null \
  || ! grep -E '/[^/]+\.delta$' "$registro_peticiones" >/dev/null \
  || ! grep -Fx '/Nuvex-9.9.1.zip' "$registro_peticiones" >/dev/null; then
  echo 'La interrupción no ocurrió durante la descarga de los paquetes esperados.' >&2
  sed -n '1,240p' "$registro_interrumpido" >&2
  exit 1
fi
if ! verificar_version_instalada "$instalacion_interrumpida/Nuvex.app" 9.9.0 900; then
  echo 'Una descarga interrumpida modificó la versión instalada.' >&2
  sed -n '1,240p' "$registro_interrumpido" >&2
  exit 1
fi

python3 - "$actualizaciones" <<'PY'
import pathlib
import sys

directorio = pathlib.Path(sys.argv[1])
archivos = [directorio / "Nuvex-9.9.1.zip", *directorio.glob("*.delta")]
if len(archivos) < 2:
    raise SystemExit("No se encontraron el ZIP nuevo y su delta para alterar")
for archivo in archivos:
    contenido = bytearray(archivo.read_bytes())
    if not contenido:
        raise SystemExit(f"No se puede alterar el archivo vacío {archivo.name}")
    posicion = len(contenido) // 2
    contenido[posicion] ^= 0x01
    archivo.write_bytes(contenido)
PY

instalacion_alterada="$temporal/instalacion-alterada"
mkdir "$instalacion_alterada"
ditto "$temporal/version-900/Nuvex.app" "$instalacion_alterada/Nuvex.app"
rm -f "$registro_peticiones"
registro_alterado="$temporal/sparkle-cli-alterado.log"
ejecutar_actualizacion \
  "$instalacion_alterada/Nuvex.app" \
  "$temporal/usuario-alterado" \
  "$registro_alterado"
if [ "$estado_actualizacion" -eq 0 ]; then
  echo 'Sparkle aceptó paquetes cuya firma ya no correspondía.' >&2
  sed -n '1,240p' "$registro_alterado" >&2
  exit 1
fi
if ! grep -F 'error 4005 (SUSparkleErrorDomain)' "$registro_alterado" >/dev/null; then
  echo 'Sparkle falló por una causa distinta a la firma inválida esperada.' >&2
  sed -n '1,240p' "$registro_alterado" >&2
  exit 1
fi
if ! grep -F 'Extracting Update...' "$registro_alterado" >/dev/null \
  || ! grep -E '/[^/]+\.delta$' "$registro_peticiones" >/dev/null \
  || ! grep -Fx '/Nuvex-9.9.1.zip' "$registro_peticiones" >/dev/null; then
  echo 'El rechazo no ocurrió durante la validación de los paquetes alterados.' >&2
  sed -n '1,240p' "$registro_alterado" >&2
  exit 1
fi
if ! verificar_version_instalada "$instalacion_alterada/Nuvex.app" 9.9.0 900; then
  echo 'Un paquete con firma inválida modificó la versión instalada.' >&2
  sed -n '1,240p' "$registro_alterado" >&2
  exit 1
fi

if [ "${NUVEX_E2E_MOSTRAR_REGISTROS:-0}" = '1' ]; then
  echo '--- descarga interrumpida ---'
  sed -n '1,240p' "$registro_interrumpido"
  echo '--- firma inválida ---'
  sed -n '1,240p' "$registro_alterado"
fi

echo 'Actualización E2E: instalación válida y fallos de red o firma conservan la versión anterior'
