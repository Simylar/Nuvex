# Leer el código de verificación desde Gmail

Algunas VPN envían un código por correo cada vez que te conectas. Nuvex puede leerlo de tu Gmail y usarlo sin que lo copies, también cuando le pides a Claude Code o a Codex que conecten estando fuera de casa.

Nuvex solo pide permiso de **lectura** (`gmail.readonly`): no puede enviar, mover, marcar ni borrar correos. Solo busca correos del remitente que indiques en cada conexión, recibidos después de empezar a conectar, y nunca guarda el código ni el contenido del correo.

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
5. Copia el **ID de cliente** (termina en `.apps.googleusercontent.com`) y el **Secreto de cliente**.

## 2. Conecta la cuenta en Nuvex

1. Abre **Ajustes de Nuvex › Cuenta de Google**, pega el ID y el secreto y pulsa **Guardar**.
2. Pulsa **Iniciar sesión con Google**. Se abre el navegador.
3. Google mostrará «Google no verificó esta app». Es normal con un cliente propio: pulsa **Configuración avanzada › Ir a Nuvex** y acepta el permiso de lectura de Gmail.
4. Al volver, Nuvex muestra tu dirección y «Conectada · solo lectura de Gmail».

El secreto y el token de la sesión se guardan en el Llavero de macOS.

## 3. Activa la lectura en cada conexión

En **Ajustes de Nuvex › (tu conexión) › Código de verificación**:

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
2. Nuvex consulta Gmail cada pocos segundos durante el tiempo configurado (2 minutos por defecto).
3. Al encontrar el código, lo escribe y conecta. Puedes pulsar **Revisar** para detenerlo.
4. Si no llega a tiempo, puedes escribirlo a mano o un asistente puede enviarlo con `nuvex codigo`.

## Quitar el acceso

- **Cerrar sesión** en Ajustes › Cuenta de Google revoca el acceso en Google y lo borra del Llavero.
- También puedes retirarlo desde [tu cuenta de Google › Seguridad › Apps de terceros](https://myaccount.google.com/connections).
