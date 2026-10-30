# Leer el código de verificación desde Gmail

Algunas VPN envían un código por correo cada vez que te conectas. Nuvex puede leerlo de tu Gmail y usarlo sin que lo copies, también cuando le pides a Claude Code o a Codex que conecten estando fuera de casa.

Por defecto Nuvex pide permiso de **lectura** (`gmail.readonly`). Solo busca correos del remitente que indiques en cada conexión, recibidos después de empezar a conectar, y nunca guarda el código ni el contenido del correo. Opcionalmente puede enviar a la papelera el mensaje cuyo código completó una conexión, con un permiso adicional explicado más abajo.

Como Nuvex no es una app de Google verificada, usas tu propio cliente OAuth. Se crea una sola vez y es gratis.

## 1. Crea el cliente OAuth (una vez)

1. Entra en [Google Cloud Console](https://console.cloud.google.com/) con tu cuenta de Google y crea un proyecto, por ejemplo «Nuvex».
2. En **APIs y servicios › Biblioteca**, busca **Gmail API** y pulsa **Habilitar**.
3. En **APIs y servicios › Pantalla de consentimiento de OAuth** (o **Google Auth Platform**):
   - Tipo de usuario: **Externo**.
   - Nombre de la app: «Nuvex». Correo de asistencia: el tuyo.
   - En **Público** o **Usuarios de prueba**, añade tu dirección de Gmail.
   - Pulsa **Publicar app** para pasarla a **En producción**. Si la dejas en modo de prueba, Google cierra la sesión cada 7 días y Nuvex te pedirá volver a entrar.
4. En **APIs y servicios › Credenciales**, pulsa **Crear credenciales › ID de cliente de OAuth**:
   - Tipo de aplicación: **App de escritorio**.
   - Nombre: «Nuvex en mi Mac».
5. Descarga el archivo JSON del cliente de escritorio. No lo compartas: contiene su secreto.

## 2. Conecta la cuenta en Nuvex

1. Abre **Ajustes de Nuvex › Cuenta de Google**, pulsa **Importar archivo de Google…** y selecciona el JSON descargado. Si ya tienes los datos separados, usa **Introducir los datos manualmente**. Nuvex admite únicamente clientes de escritorio; importar no inicia sesión ni concede acceso a Gmail.
2. Pulsa **Iniciar sesión con Google**. Se abre el navegador.
3. Google mostrará «Google no verificó esta app». Es normal con un cliente propio: pulsa **Configuración avanzada › Ir a Nuvex** y acepta el permiso de lectura de Gmail.
4. Al volver, Nuvex muestra tu dirección y «Sesión guardada». La disponibilidad real de Google y el permiso se comprueban al leer un código.

El secreto y el token de la sesión se guardan en el Llavero de macOS. Cambiar una configuración con sesión guardada requiere confirmación y después volver a iniciar sesión. Los datos técnicos de la cuenta configurada están en **Opciones de la cuenta**. La lectura es opcional: puedes seguir conectándote y escribir el código sin configurar Google.

## 3. Activa la lectura en cada conexión

En **Ajustes de Nuvex › (tu conexión) › Código de verificación**:

La conexión debe estar guardada. Un borrador nuevo no escribe ajustes del lector
hasta guardarse. Si Nuvex no pudo leer los ajustes o estos requieren una versión
posterior, los controles quedan bloqueados y se explica el motivo. Los fallos de
escritura se muestran en la sección y no se anuncian como un guardado correcto.

1. Elige **Leer de Gmail**. Los campos se rellenan con el formato de FortiToken por correo, que es el habitual:
   - Remitente: `DoNotReply@notification.fortinet.net`
   - Asunto contiene: `AuthCode`

   Esos correos llegan con el asunto «AuthCode: 043051» y el texto «Your authentication token code is 043051.».
2. Si tu servidor envía el código desde otra dirección, cambia el **Remitente**. Es obligatorio.
3. **Asunto contiene** es opcional: sirve para ignorar otros correos del mismo remitente.
4. Pulsa **Probar con el último correo**. Nuvex muestra el código enmascarado, por ejemplo `48••13`, si encuentra uno de los últimos 7 días.

Si el código no aparece, abre **Patrón avanzado** y escribe una expresión regular con un grupo que capture el código, por ejemplo `Código: (\d{6})`.

## Cómo funciona al conectar

1. Cuando el servidor pide el código, aparece la ventana del código con «Buscando en tu@gmail.com…».
2. Nuvex consulta Gmail cada pocos segundos durante el tiempo configurado (2 minutos por defecto). Si hay un fallo de red, cuota o servidor, usa reintentos exponenciales con jitter y respeta `Retry-After`; nunca reintenta sin límite.
3. Al encontrar el código, lo escribe y conecta. Puedes pulsar **Revisar** para detenerlo.
4. Si no llega a tiempo, puedes escribirlo a mano o un asistente puede enviarlo con `nuvex codigo`.

Nuvex revisa el árbol MIME completo, incluidas partes de texto que Gmail entrega mediante `attachmentId`. Prueba primero el texto plano y también HTML si el primero no contiene un código. Elige el candidato más reciente por la fecha interna de Gmail y no reutiliza el mismo mensaje durante la sesión. El cuerpo acumulado tiene un límite de 256 KiB. Tras perder red o reactivar la Mac, una búsqueda pendiente se reanuda automáticamente si el intento de conexión sigue vigente.

El equipo debe estar despierto para consultar Gmail. Durante una suspensión real macOS detiene CPU y red; Nuvex reconcilia el estado al reactivarse, pero no puede recibir el correo mientras está dormido.

## Enviar el correo usado a la papelera · Opcional

En **Ajustes de Nuvex › Cuenta de Google › Correos con códigos**, activa
**Enviar el correo a la papelera después de usar el código**. Está desactivado
por defecto, también al actualizar. La elección se guarda inmediatamente y se
conserva al reiniciar; se aplica a todas las conexiones que lean códigos de Gmail.
No cambia la configuración del ayudante.

Nuvex explica el alcance antes de activar la opción. Si la sesión solo tiene
lectura, abre de nuevo el inicio de sesión para solicitar `gmail.modify`, el
permiso mínimo que admite `messages.trash`. Google también permite modificar
y enviar correo con ese permiso; no ofrece uno limitado a la papelera de los
códigos. Nuvex usa únicamente lectura y traslado del mensaje concreto, nunca
envío ni borrado definitivo. Google Workspace o la configuración/verificación
del cliente OAuth pueden impedir concederlo; revisa **Acceso a datos** del
proyecto si Google rechaza el permiso.

Si aún no preparaste el cliente, la opción queda guardada para el siguiente
inicio de sesión. Si cancelas o Google no concede modificación, queda pendiente
de autorización y los correos se conservan. La lectura con una sesión válida
puede seguir funcionando. **Autorizar la papelera…** permite solicitar el acceso
de nuevo desde la cuenta conectada. Las sesiones antiguas conservan su acceso de
lectura: no se amplían permisos al arrancar ni al conectar una VPN.

El traslado requiere las tres condiciones: código de ese correo entregado por
stdin, proceso de conexión satisfactorio y túnel confirmado por una consulta
del mismo intento iniciada después de cumplir los dos primeros requisitos.
Una respuesta tardía de una consulta anterior no autoriza el traslado.
La confirmación del correo caduca a los 30 segundos del resultado satisfactorio
del proceso. Si la consulta vigente muestra el túnel desconectado o el perfil
ausente, se conserva el correo y una conexión posterior no reactiva ese traslado.
Se conserva el mensaje si cancelas, falla el intento,
no puede confirmarse el túnel, se usa otro código manual o responde Terminal.
**Revisar** detiene el envío; si después envías el mismo código encontrado,
mantiene su origen. **Probar con el último correo** nunca mueve mensajes.
Solo se conserva en memoria el ID del mensaje y la identidad de la sesión,
sin persistirlos ni escribirlos en el registro.

Se realiza un traslado por intento, sin reintentos ni autorizaciones en segundo
plano. Si Gmail no lo confirma, el aviso queda en **Cuenta de Google** y la VPN
no se desconecta. Un fallo de red puede dejar el resultado indeterminado:
comprueba Gmail antes de mover el mensaje manualmente. Cerrar la app antes del
traslado puede dejar el correo en su carpeta; no hay cola persistente.

Desactivar la opción detiene traslados todavía no enviados; una petición ya
enviada puede completarse. No restaura mensajes ni revoca el permiso de Google.
Para volver a solo lectura, cierra sesión y vuelve a entrar con la opción
desactivada, o retira el acceso desde Google. Los mensajes pueden recuperarse
desde la papelera mientras Gmail los conserve allí, conforme a sus políticas.

Referencias: [messages.trash](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/trash),
[alcance de gmail.modify](https://developers.google.com/workspace/gmail/api/auth/scopes) y
[OAuth para escritorio](https://developers.google.com/identity/protocols/oauth2/native-app).
Las apps instaladas solicitan de nuevo el conjunto de permisos; no se usa
autorización incremental ni se solicita `https://mail.google.com/`.

## Quitar el acceso

- **Cerrar sesión** en Ajustes › Cuenta de Google revoca el acceso en Google y lo borra del Llavero.
- Al cerrar sesión se retiran también los permisos guardados de esa sesión; se conserva el cliente para volver a iniciar sesión.
- También puedes retirarlo desde [tu cuenta de Google › Seguridad › Apps de terceros](https://myaccount.google.com/connections).
