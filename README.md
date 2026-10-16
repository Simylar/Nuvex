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
- Estado y reconexión desde la barra de menús, avisos de desconexión y acceso opcional desde Terminal o `nuvex://connect/<id>`.

## Compilar e instalar

Necesitas **macOS 14 o posterior**, Swift 6, las Command Line Tools de Xcode, Homebrew, `autoconf`, `automake`, `pkgconf` y `openssl@3`. macOS debe proporcionar `/usr/sbin/pppd`.

```sh
brew install autoconf automake pkgconf openssl@3
git clone https://github.com/Simylar/Nuvex.git
cd Nuvex/Nuvex
./build.sh
```

El resultado es `Nuvex/Nuvex.app` dentro del repositorio. Puedes copiarlo a `/Applications` y abrirlo. El paquete incluye `openfortivpn` y las bibliotecas OpenSSL necesarias; Homebrew se necesita para compilar, no para ejecutar la app. La compilación se firma localmente en modo ad hoc y **no está notarizada** para distribución como binario público.

## Primer uso

1. Al abrir Nuvex sin conexiones aparece la ventana de bienvenida. También puedes abrirla con **Añadir conexión…** en el menú de Nuvex.
2. Pulsa **Añadir primera conexión**. Escribe el nombre, el servidor Fortinet y su puerto, el usuario y la contraseña VPN. Selecciona los certificados del sistema o la CA incluida si corresponde a tu servidor. Si necesitas una huella SHA-256 verificada, configúrala en Ajustes antes de conectar.
3. Pulsa **Guardar y continuar**. Nuvex guarda el perfil sin contraseña en `~/.config/nuvex/profiles.json`, guarda la contraseña en el Llavero y prepara el ayudante. macOS puede pedir autorización de administrador para instalarlo.
4. Pulsa **Conectar ahora**, o el círculo de la conexión en el menú de Nuvex. Si la VPN solicita un código por correo o app, Nuvex te lo pedirá en ese momento.

Para más servidores, abre **Ajustes de Nuvex…** (⌘,) y pulsa **+** al pie de la barra lateral. Cada conexión se guarda por separado con **Guardar** (⌘S). Puedes cambiar las opciones de rutas y DNS de cada perfil. Si varias VPN anuncian las mismas redes o modifican DNS a la vez, comprueba cuál debe administrar cada recurso. Los perfiles existentes de Nuvex se conservan al actualizar la app.

La confirmación local con Touch ID, cuando está disponible, se configura en **General** para Nuvex completo y se solicita una vez durante la preparación inicial. El diálogo de administrador pertenece a macOS: Nuvex no puede imponer Touch ID allí. Un ayudante vigente se reutiliza al conectar; los cambios de conexión o del motor pueden requerir una nueva autorización.

## Alcance y seguridad

La interfaz implementa el flujo de usuario, contraseña y código solicitado por el servidor mediante `openfortivpn`. Los portales que exijan SAML, certificados de cliente u otros métodos pueden requerir soporte adicional. La conexión y la convivencia de rutas o DNS deben validarse con cada servidor y red; las pruebas del repositorio no sustituyen esa verificación.

Nuvex no escribe contraseñas ni códigos en los perfiles o argumentos del proceso. El ayudante acepta solo los perfiles configurados y acciones previstas. No desactiva la verificación TLS. Los enlaces `nuvex://` piden confirmación antes de conectar. Consulta [INSTALAR.md](INSTALAR.md) para los detalles del ayudante, privacidad, diagnóstico y límites.

## Desarrollo

```sh
python3 -m unittest discover -s tests -v
bash tests/test_security_preferences.sh
bash tests/test_interfaz.sh
cd Nuvex && ./build.sh
```

El código de la app está en `Nuvex/Sources/Nuvex/`, separado en modelo, motor, Llavero, panel, Ajustes y bienvenida. Para generar capturas con datos ficticios, ejecuta `bash Nuvex/scripts/capturas.sh` desde la raíz; las imágenes quedan en `.build-cache/capturas/`. Los scripts de configuración y del ayudante están en la raíz; el motor `openfortivpn` está en `vendor/openfortivpn/`. El paquete generado `Nuvex/Nuvex.app` y los datos locales quedan fuera de Git.

Para comprobar una conexión con un servidor real y un recurso interno autorizado, sigue [la guía de validación en vivo](docs/validacion-en-vivo.md). Las pruebas automáticas comprueban la configuración y el código; no establecen túneles contra servidores de terceros.

## Licencias

El código propio de Nuvex se publica bajo [GPL-3.0](LICENSE). El motor conserva su licencia y avisos en `vendor/openfortivpn/`. Las bibliotecas OpenSSL 3 incluidas usan Apache-2.0; la compilación copia su licencia vigente al paquete. Consulta [los avisos de terceros](THIRD_PARTY_NOTICES.md).
