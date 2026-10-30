<p align="center">
  <img src="Nuvex/Resources/nuvex_logo.svg" alt="Logo de Nuvex" width="320">
</p>

# Nuvex

Nuvex es una app de barra de menús para macOS con la que puedes configurar y conectar servidores **Fortinet SSL VPN** compatibles con `openfortivpn`. Cada persona añade sus propias VPN desde la app. Una instalación nueva no incluye servidores, usuarios ni contraseñas.

## Qué ofrece

- Hasta 64 conexiones, cada una con servidor, usuario, confianza TLS, realm y opciones de rutas y DNS.
- Varias VPN simultáneas, con avisos cuando sus rutas o DNS pueden entrar en conflicto.
- Contraseñas en el Llavero de macOS y códigos de verificación solicitados solo cuando el servidor los pide.
- Instalación del ayudante de red desde la app, con autorización de macOS cuando haga falta.
- Estado y reconexión desde la barra de menús, con un aviso de desconexión que ofrece **Reconectar**.
- Lectura opcional del código de verificación desde Gmail. Puede enviar el correo usado a la papelera con una opción y autorización adicionales ([guía](docs/gmail.md)).
- Comando `nuvex` y habilidad para Claude Code y Codex: conectan tus VPN cuando se lo pides, incluso fuera de casa ([guía](docs/asistentes.md)).
- Exportación e importación de conexiones en un archivo cifrado con una frase.
- Actualizaciones desde la app con sus novedades, sin perder conexiones, contraseñas ni ajustes ([dónde vive cada dato](docs/datos.md)).

La arquitectura, el modelo de permisos, la recuperación y los límites durante el reposo están documentados en [Arquitectura y operación](docs/arquitectura-y-operacion.md).

## Compilar e instalar

Los artefactos oficiales actuales requieren una Mac con **Apple Silicon (arm64)** y **macOS 14 o posterior**. Para compilar necesitas Swift 6, las Command Line Tools de Xcode, Homebrew, `autoconf`, `automake`, `pkgconf` y `openssl@3`. macOS debe proporcionar `/usr/sbin/pppd`.

```sh
brew install autoconf automake pkgconf openssl@3
git clone https://github.com/Simylar/Nuvex.git
cd Nuvex/Nuvex
./build.sh
```

El resultado es `Nuvex/Nuvex.app` dentro del repositorio. Para instalarlo o actualizarlo en `/Applications` sin perder datos, usa:

```sh
Nuvex/scripts/instalar.sh
```

El script compila, pasa las pruebas, guarda la versión anterior en un ZIP, reemplaza únicamente la copia de `/Applications` sin cortar las VPN activas y la vuelve a abrir. Si falla después de cerrarla, recupera y abre la versión anterior. También archiva los respaldos antiguos que eran paquetes `.app` y retira la copia compilada del repositorio para evitar duplicados en la búsqueda de aplicaciones. `Nuvex/scripts/revertir.sh` vuelve a la versión anterior y protege las conexiones en curso; `--forzar` omite esa protección de forma explícita. El paquete incluye `openfortivpn` y las bibliotecas OpenSSL necesarias; Homebrew se necesita para compilar, no para ejecutar la app. La compilación **no está notarizada**. Con `Nuvex/scripts/configurar-publicacion.sh` se crea una identidad de firma estable para conservar el requisito designado entre versiones; el Llavero todavía puede requerir autorización. La publicación y sus límites se explican en [docs/publicar.md](docs/publicar.md).

## Primer uso

1. Al abrir Nuvex sin conexiones aparece directamente **Añadir conexión**. Escribe el servidor, el usuario y la contraseña que te dio tu organización. El nombre es opcional: si lo dejas vacío, Nuvex usa la dirección del servidor. No hace falta escribir el puerto 443.
2. Usa **Opciones del servidor** solo si tu organización te dio un certificado, una huella verificada o un grupo de acceso (realm). Las rutas y el DNS tienen valores predeterminados y se pueden ajustar allí. Los certificados del sistema se verifican automáticamente; Nuvex no adivina ni omite la confianza TLS.
3. Pulsa **Conectar**. Nuvex guarda el perfil y la contraseña en el Llavero, prepara el ayudante y empieza a conectar. macOS pide autorización solo cuando corresponde. Si falla guardar la contraseña, no encadena la autorización del ayudante.
4. La misma ventana muestra el progreso, permite cancelar y ofrece **Introducir código** cuando hace falta. Solo anuncia **Conectada** al confirmar el túnel. Si cancelas un permiso o falla un paso, conserva el avance y ofrece una acción concreta; no repite el intento automáticamente. Al editar una conexión ya guardada, puedes conservar su contraseña del Llavero.

Si ya tienes un archivo de Nuvex, **Importar…** permite recuperar sus conexiones sin volver a escribirlas. Gmail y los asistentes se pueden configurar más adelante.

En el uso diario, abre Nuvex en la barra de menús y pulsa **Conectar**, **Desconectar** o **Cancelar**. **Código…** trae al frente una verificación pendiente. Los atajos **⌘1–⌘9** realizan la acción correspondiente a cada fila. **Añadir conexión…** (**⌘N**) vuelve a abrir el formulario. En **Ajustes de Nuvex…** (**⌘,**) puedes editar cada conexión y guardar con **⌘S**; **+** sigue disponible en la barra lateral. Las opciones de servidor personalizadas se muestran desplegadas para que puedas revisarlas.

En **General › Recuperación** puedes activar **Reconectar si se pierde la conexión**. Está desactivado por defecto. Tras una caída confirmada y cuando haya red, Nuvex programa un solo intento con los permisos existentes, que puedes cancelar. No instala el ayudante ni abre diálogos del Llavero en segundo plano. Si falta un permiso o falla el intento, ofrece reconexión manual. El servidor puede volver a pedir un código. La recuperación no se repite hasta que vuelvas a iniciar una conexión manualmente y no conecta perfiles al arrancar la app.

El formulario inicial conserva los datos sin guardar al cerrar y reabrir la ventana durante la misma sesión. Cerrar la ventana no equivale a cancelar una operación; usa **Cancelar** para detener el intento. Reabrir Nuvex recupera primero una verificación o preparación pendiente; después muestra la conexión con error, en curso o activa, antes de recurrir a General. Los errores de guardado conservan la contraseña introducida para reintentar. Al terminar la app, los datos aún no guardados se pierden; las conexiones ya guardadas se recuperan normalmente. La ventana de Ajustes conserva sus borradores de perfil y descarta contraseñas introducidas al cerrarse.

Los éxitos rutinarios de los asistentes no muestran avisos por defecto; puedes activarlos en Automatización. Si ya habías elegido recibirlos, se conserva esa preferencia.

La revisión de flujos, decisiones y verificaciones está en [Experiencia de usuario](docs/experiencia-de-usuario.md). La posibilidad de un cliente OAuth común se analiza por separado en [Cliente OAuth de Nuvex](docs/gmail-cliente-nuvex.md); no está implementada.

La confirmación local con Touch ID, cuando está disponible, se configura en **General** para Nuvex completo y se solicita una vez durante la preparación inicial. El diálogo de administrador pertenece a macOS: Nuvex no puede imponer Touch ID allí. Un ayudante vigente se reutiliza al conectar; los cambios de conexión o del motor pueden requerir una nueva autorización.

En **General › Permisos y capacidades**, **Autorizar todas las capacidades de
Nuvex…** permite las operaciones rutinarias de Terminal y asistentes sin
preguntar cada vez, completa la confirmación inicial y configura las
integraciones detectadas. Conserva las conexiones excluidas en Automatización.
La decisión se guarda fuera de la app; las capacidades nuevas requieren otra
decisión explícita. **Revocar…** bloquea la automatización, retira sus reglas
gestionadas y restablece la confirmación inicial. No desconecta VPN activas ni
borra contraseñas.

El mismo apartado muestra el estado y las acciones para el ayudante, Gmail y
cada contraseña. Los permisos del Llavero, administrador, avisos, inicio de
sesión y Google los concede su sistema correspondiente. Una comprobación sin
diálogos distingue una entrada ausente de un acceso que requiere intervención;
no garantiza acceso permanente. Si no se pudo leer la cuenta de Google al
arrancar, **Recuperar acceso…** vuelve a leerla sin crear otro cliente OAuth.

General muestra primero hasta tres acciones pendientes de las funciones que
utilizas, con un botón para resolver cada una. Al desplegar **Todas las
capacidades y autorización conjunta**, aparecen las demás acciones, los estados
detallados y los controles para autorizar o revocar. No configurar Gmail o
desactivar la automatización no se presenta como un permiso faltante.

Restaurar una copia recupera las conexiones y su lectura de códigos, conservando
tus autorizaciones y exclusiones actuales. Las importaciones distinguen un
cambio rechazado de una operación completa o con pendientes de Llavero, lectura
de códigos o ayudante; no muestran éxito por la mera existencia de una conexión.

## Alcance y seguridad

La interfaz implementa el flujo de usuario, contraseña y código solicitado por el servidor mediante `openfortivpn`. Los portales que exijan SAML, certificados de cliente u otros métodos pueden requerir soporte adicional. La conexión y la convivencia de rutas o DNS deben validarse con cada servidor y red; las pruebas del repositorio no sustituyen esa verificación.

Nuvex no escribe contraseñas ni códigos en los perfiles o argumentos del proceso. El ayudante acepta solo los perfiles configurados y acciones previstas. No desactiva la verificación TLS. Los enlaces `nuvex://` piden confirmación antes de conectar. Consulta [INSTALAR.md](INSTALAR.md) para los detalles del ayudante, privacidad, diagnóstico y límites.

## Desarrollo

```sh
python3 -m unittest discover -s tests -v
for prueba in tests/test_*.sh; do bash "$prueba"; done
cd Nuvex && ./build.sh
```

La prueba `tests/test_actualizacion_e2e.sh` levanta un servidor local y actualiza únicamente una copia temporal firmada con una clave efímera. No modifica `/Applications`, el Llavero ni conexiones VPN reales.

El lenguaje visual (tokens, Liquid Glass, componentes y reglas para pantallas nuevas) está documentado en [STYLE_GUIDE.md](STYLE_GUIDE.md) e implementado en `Nuvex/Sources/Nuvex/Diseno.swift`. El código de la app está en `Nuvex/Sources/Nuvex/`; el protocolo del comando `nuvex` en `Nuvex/Sources/NuvexControl/` y el comando en `Nuvex/Sources/nuvex-cli/`. Para generar capturas con datos ficticios, ejecuta `bash Nuvex/scripts/capturas.sh` desde la raíz; las imágenes quedan en `.build-cache/capturas/`. Los scripts de configuración y del ayudante están en la raíz; el motor `openfortivpn` está en `vendor/openfortivpn/`. El paquete generado `Nuvex/Nuvex.app` y los datos locales quedan fuera de Git.

Para comprobar una conexión con un servidor real y un recurso interno autorizado, sigue [la guía de validación en vivo](docs/validacion-en-vivo.md). Antes de publicar un sucesor de 3.2.1, ejecuta también el [plan de validación de producción](docs/plan-validacion-produccion.md). Las pruebas automáticas comprueban la configuración y el código; no establecen túneles contra servidores de terceros.

## Licencias

El código propio de Nuvex se publica bajo [GPL-3.0](LICENSE). El motor conserva su licencia y avisos en `vendor/openfortivpn/`. Las bibliotecas OpenSSL 3 incluidas usan Apache-2.0; la compilación copia su licencia vigente al paquete. Consulta [los avisos de terceros](THIRD_PARTY_NOTICES.md).
