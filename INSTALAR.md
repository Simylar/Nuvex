# Nuvex

Nuvex es una app de barra de menús para conexiones Fortinet SSL VPN compatibles con `openfortivpn`. Una instalación nueva empieza sin perfiles y permite configurar hasta 64 conexiones desde la propia app. Incluye el motor `openfortivpn` y sus bibliotecas TLS. Para usarla no se necesita FortiClientVPN ni OpenConnect. macOS aporta `pppd`, que Nuvex utiliza para crear el túnel.

## Estado de esta entrega

La app, el motor incluido, la configuración, el Llavero, la detección de solicitudes de código y la supervisión se pueden comprobar sin credenciales. La conexión real con cada servidor debe validarse con su cuenta. Los portales que requieran SAML u otros mecanismos fuera del flujo usuario/contraseña de la app pueden necesitar soporte adicional.

Nuvex permite iniciar varias VPN a la vez. Cada conexión tiene sus propias opciones de rutas y DNS en **Opciones de red avanzadas**. Las rutas de una VPN pueden incluir la salida general a Internet. Si dos VPN anuncian las mismas redes o administran DNS al mismo tiempo, el tráfico y la resolución pueden entrar en conflicto. Ajusta estas opciones antes de conectarlas; comprueba el acceso a los recursos internos de cada VPN simultánea.

## Compilar

En `Nuvex/`, ejecuta `./build.sh`. Se requiere Swift, las Command Line Tools, `automake`, `autoconf`, `pkgconf` y OpenSSL 3 de Homebrew **solo para compilar**. La app resultante es `Nuvex/Nuvex.app` y lleva el motor y sus bibliotecas dentro. El código fuente y la licencia GPL de `openfortivpn` están en `vendor/openfortivpn/`. La licencia Apache-2.0 de las bibliotecas OpenSSL incluidas se copia desde esa instalación al paquete compilado.

`build.sh` no instala nada en `/Applications` ni modifica la configuración VPN de macOS.

Los logos editables están en `Nuvex/Resources/` como SVG. Al compilar se genera el `.icns` de macOS a partir del símbolo vectorial; la interfaz usa el SVG para el panel y el icono de la barra.

## Primer uso

1. Copia `Nuvex/Nuvex.app` a `/Applications` y ábrela.
2. En la ventana de bienvenida, pulsa **Añadir primera conexión**. Si la cerraste, usa **Añadir conexión…** en el menú de Nuvex. Indica nombre, servidor, usuario, contraseña y método de confianza TLS. Para otra VPN, abre **Ajustes de Nuvex…** y pulsa **+** al pie de la barra lateral. Cada pantalla comprueba si existe una contraseña para ese usuario sin leerla. Nuvex almacena la contraseña en el Llavero de macOS, nunca en `profiles.json`.
3. Pulsa **Guardar y continuar** (o **Guardar** en Ajustes). Nuvex instala o actualiza automáticamente el ayudante cuando cambian las conexiones o sus componentes. macOS solicitará autorización de administrador cuando haga falta. Nuvex verificará los archivos preparados e instalará el ayudante en `/Library/PrivilegedHelperTools/Nuvex`. Esto es necesario para crear la interfaz PPP y las rutas. El ayudante solo acepta los perfiles configurados y acciones predefinidas. Si la autorización falla, puedes reintentar desde **Ajustes › Ayudante de red**.
4. Conecta la VPN que necesites. Si el ayudante necesita actualizarse, **Conectar** lo hará antes de continuar. Una actualización limitada al ayudante puede hacerse con otra VPN activa si la configuración y el motor instalado no cambiaron; macOS solicitará autorización. Si el servidor solicita un código por correo, app u otro medio, Nuvex lo pide en ese momento y no lo guarda.

Al añadir o eliminar perfiles, o cambiar servidor, usuario o confianza TLS, **Guardar** actualiza el ayudante. Nuvex impide cambiar las conexiones mientras hay un túnel activo; desconéctalo primero. Si solo cambias una contraseña y el ayudante ya está actualizado, Nuvex la guarda en el Llavero sin solicitar autorización de administrador. En **General → Seguridad**, la confirmación local se aplica a Nuvex completo: solicita Touch ID una vez durante la preparación inicial cuando está disponible y, de otro modo, la contraseña del equipo. Las preferencias anteriores por conexión se migran a esta opción general; una instalación que ya cuenta con el ayudante se considera preparada. Las conexiones siguientes se inician con un clic. La contraseña VPN debe estar guardada. La instalación del ayudante usa la autorización de administrador de macOS: el sistema decide si ofrece Touch ID y Nuvex no puede imponerlo. Una vez instalado el ayudante vigente, las conexiones posteriores lo reutilizan sin volver a solicitar autorización de administrador. Si cambian sus archivos o la configuración de las conexiones, macOS solicitará autorización para actualizarlo.

Al abrir Ajustes, Nuvex quita de la edición los espacios al inicio o al final del usuario. Si un perfil antiguo tenía esos espacios, **Guardar** copia primero su contraseña al usuario corregido, verifica la nueva entrada y después actualiza el perfil y el ayudante. Conserva la entrada antigua si la actualización del perfil falla. La migración puede pedir Touch ID y requiere que no haya VPN activas. El configurador rechaza nuevos usuarios con espacios al inicio o al final.

## Configuración

- `~/.config/nuvex/profiles.json`: lista de conexiones, servidores, usuarios, confianza TLS, realm, opciones de rutas/DNS y habilitación. No contiene contraseñas ni códigos. Se crea con permisos `0600`; la versión anterior de dos perfiles se migra al guardar.
- **Ajustes** de Nuvex: los campos de cada conexión, avisos de desconexión y preparación del ayudante.
- **Llavero de macOS**: un servicio `nuvex.<id>` por conexión, asociado al usuario VPN correspondiente.
- Las opciones **Certificados del sistema**, **Paquete de CA para Prepa incluido** y **Huella SHA-256** controlan la verificación TLS. El paquete incluye certificados públicos y la CA intermedia RapidSSL TLS RSA CA G1; selecciónalo solo si corresponde a la cadena de tu servidor. Para otras VPN puedes usar los certificados del sistema o una huella verificada. Nunca se desactiva la verificación TLS. Si el servidor cambia de certificado o emisor, revisa el método de confianza.
- En **Opciones de red avanzadas** puedes indicar un realm y decidir si la VPN configura rutas y DNS. Los valores iniciales mantienen ambas opciones activas.

No se incluyen servidores, usuarios ni contraseñas preconfigurados. Los perfiles que ya existen en `profiles.json` se conservan; Nuvex no importa archivos privados de FortiClientVPN.

## Barra de menús y avisos

El icono indica si hay conexión, desconexión o un corte detectado. Nuvex consulta el estado cada cinco segundos. Cuando una VPN que estaba conectada se cae, muestra un aviso con acción **Reconectar**. La notificación permanece en el Centro de notificaciones hasta descartarla; para que el banner no desaparezca automáticamente, selecciona **Alertas** en Ajustes del Sistema → Notificaciones → Nuvex.

El enlace `nuvex://connect/<id>` permite a Codex u otra automatización local solicitar cualquiera de las conexiones guardadas. Nuvex pide confirmación al usuario y, si el servidor lo solicita, el código de verificación. La app debe estar instalada para registrar el esquema `nuvex://`.

También puedes consultar `./nuvexctl.sh list` o iniciar `./nuvexctl.sh connect <id>` desde Terminal, dentro de la carpeta del proyecto. Si el servidor solicita un código, se pregunta en Terminal. Ambos usan la misma configuración y muestran el mismo estado que la app.

## Actualizar sin perder datos

Las conexiones, contraseñas y ajustes viven fuera de la app ([docs/datos.md](docs/datos.md)), así que actualizar no los toca.

- **Desde la app**: Ajustes › Actualización de software muestra la versión disponible y sus novedades. Las VPN activas siguen conectadas durante la instalación.
- **Desde el código**: `Nuvex/scripts/instalar.sh` compila, pasa las pruebas, guarda la versión anterior como ZIP en `~/Library/Application Support/Nuvex/Versiones` y reemplaza la app. Conserva además la app anterior durante el reemplazo hasta verificar firma, versión, arranque y respuesta del control local; si algo falla, la restaura y vuelve a abrir automáticamente. Solo cierra la copia de `/Applications`, no otras compilaciones que estén abiertas. También archiva los respaldos `.app` antiguos. Después de comprobar la instalación, retira la copia compilada del repositorio. `Nuvex/scripts/revertir.sh` usa el mismo reemplazo recuperable para volver atrás y rechaza hacerlo durante una conexión en curso; `--forzar` permite continuar de forma explícita.
- Antes de cada versión nueva, Nuvex copia la configuración en `~/Library/Application Support/Nuvex/Copias`. Se restaura desde Ajustes › General › Copias de seguridad.
- Si una versión cambia el motor, Nuvex pide autorizar el ayudante en ese momento. Si cambió la firma de la app, pide probar el acceso al Llavero: elige «Permitir siempre».
- Antes de descargar desde la app, Nuvex exige una versión y compilación superiores, un canal permitido, un paquete de aplicación mediante HTTPS y espacio suficiente. Sparkle verifica después la firma EdDSA del archivo. Tras reiniciar, Nuvex confirma que está ejecutando la compilación esperada y muestra el resultado en Actualización de software.

## Privacidad y límites

Las contraseñas y códigos viajan al ayudante por entrada estándar; no se colocan en argumentos del proceso ni en la configuración. El registro de diagnóstico del motor reside en `/var/run/nuvex/UID/perfil/openfortivpn.log` con permisos de `root`.

Los fallos de consulta de la app se registran en `~/Library/Logs/Nuvex.log` con permisos `0600`, sin copiar la salida de los perfiles ni escribir una línea por cada consulta exitosa.

La app se firma localmente en modo ad hoc. No está notarizada para distribución pública. El ayudante usa una regla limitada en `/etc/sudoers.d/` para evitar pedir la contraseña de administrador en cada conexión. La instalación solicita autorización explícita de macOS y verifica los archivos preparados antes de copiarlos.
