# Arquitectura, permisos y operación de Nuvex

Este documento describe la implementación real de Nuvex 3.3.0. No sustituye
la guía de publicación ni promete ejecución durante la suspensión física de
macOS.

## Componentes y límites de confianza

| Componente | Responsabilidad | Privilegio y datos |
| --- | --- | --- |
| App `Nuvex` | Interfaz, estado, Gmail, Llavero y coordinación | Sesión del usuario; no es root |
| `nuvex` | CLI para Terminal, Codex y Claude Code | No recibe contraseñas; el OTP entra por stdin |
| Socket Unix | Protocolo JSON por líneas | Carpeta 0700, socket 0600, mismo UID y ejecutable oficial |
| `nuvexctl.sh` y configurador | Lista, conecta, detiene y aplica perfiles | Acciones acotadas; nunca guarda la contraseña |
| Ayudante de red | Ejecuta el motor y operaciones de red necesarias | Instalado como root; valida perfiles, hashes y acciones |
| `openfortivpn` | Túnel Fortinet SSL VPN | Recibe contraseña y OTP por tubería privada |
| Gmail API | Encuentra el OTP | OAuth `gmail.readonly`; cliente del propio usuario |

La interfaz no llama directamente a operaciones privilegiadas. El ayudante no
expone una API general y el socket de automatización no acepta binarios
arbitrarios del mismo usuario.

## Flujo de conexión y código

1. Nuvex valida que el perfil, la contraseña y el ayudante estén listos.
2. Lee la contraseña del Llavero; la confirmación inicial con Touch ID se
   comparte para Nuvex, no para otros procesos.
3. Inicia `nuvexctl connect` y entrega la contraseña por stdin.
4. El motor emite `NUVEX_OTP_REQUIRED` si necesita un segundo factor.
5. Se abre una ventana normal, redimensionable y limitada al `visibleFrame` de
   la pantalla activa. No flota sobre menús y su contenido puede desplazarse.
6. Compiten tres fuentes: entrada manual, `nuvex codigo` y Gmail. La primera
   respuesta válida cierra las demás.
7. El intento se confirma consultando de nuevo el estado del túnel. No se
   considera conectado solo porque el proceso haya terminado con código cero.

### Lector de Gmail

- La consulta combina remitente, asunto opcional y el inicio del intento con
  30 segundos de margen por el redondeo de Gmail.
- Se examinan hasta diez candidatos y se elige el más reciente por
  `internalDate`, no por el orden incidental de procesamiento.
- Se recorren árboles MIME `multipart/*`. Las partes `text/plain` se prueban
  primero y, si no contienen un código, se prueba HTML; si Gmail entrega el
  texto con `attachmentId`, se obtiene mediante `messages.attachments.get`. El
  cuerpo acumulado está limitado a 256 KiB.
- La extracción requiere un patrón explícito o un OTP inequívoco. No se
  registran contenido, dirección, asunto ni código.
- Un ID de mensaje usado se conserva en memoria durante la sesión para no
  reutilizarlo. El filtro temporal evita correos antiguos después de reiniciar.
- Un sondeo correcto espera 3, 5 y después 8 segundos. Red, cuota y errores 5xx
  aplican backoff exponencial truncado y jitter. `Retry-After` se respeta sin
  acortarlo; el límite total de la operación evita esperas ilimitadas.
- 401 invalida solo el token de acceso. La renovación OAuth está serializada
  para que dos conexiones no usen el refresh token simultáneamente. Cerrar la
  sesión o reemplazar el cliente cancela la renovación y descarta respuestas
  tardías antes de revocar el token.
- Errores permanentes (sesión revocada, cliente inválido, scope o API) detienen
  el sondeo y muestran una acción concreta; los transitorios siguen hasta el
  límite configurado.

## Automatización: Codex y Claude Code

La integración usa tres piezas deliberadamente pequeñas:

1. El CLI local `nuvex`, con salida humana o JSON, motivos y códigos de salida
   estables, timeouts y diagnóstico.
2. Una habilidad `nuvex-vpn/SKILL.md` instalada en `~/.codex/skills` y
   `~/.claude/skills`, que enseña descubrimiento, permisos y recuperación.
3. Reglas opcionales, explícitas y revocables que sacan únicamente
   `~/.local/bin/nuvex` del sandbox de Bash: un archivo propio de Codex y dos
   entradas acotadas en los ajustes de Claude Code.

No se añade MCP: las capacidades son acciones locales, acotadas y ya tienen un
contrato CLI seguro. Mantener además un servidor MCP duplicaría transporte,
autorización y ciclo de vida sin exponer una capacidad nueva. Los servidores
MCP locales también necesitarían configuración y una política de herramientas;
no resolverían la suspensión real ni la ausencia de una sesión iniciada.

**Configurar** instala o actualiza el comando y las habilidades detectadas,
crea únicamente las reglas acotadas de los agentes cuya habilidad quedó bajo
gestión de Nuvex, activa el inicio con la sesión y ejecuta el diagnóstico real.
No reemplaza ni autoriza una habilidad ajena. Después de una actualización,
solo sincroniza las habilidades que ya administraba y no concede permisos
nuevos. Cada petición lleva un identificador opaco de operación para
correlacionar el registro; clientes anteriores del protocolo 2 siguen siendo
compatibles.

Cuando el sandbox del agente impide abrir apps o acceder al socket, el CLI sale
con código 7. Desde Ajustes, la persona puede autorizar una regla persistente
para la ruta exacta del CLI. Codex la ejecuta fuera del sandbox por prefijo;
Claude Code combina `permissions.allow` con `sandbox.excludedCommands`. Nuvex
preserva las demás reglas, no habilita modos globales y permite revocar lo que
añadió.

## Modelo de permisos

| Autorización | Quién la controla | Persistencia | Cuándo reaparece |
| --- | --- | --- | --- |
| Contraseña VPN | Llavero de macOS | Entrada por perfil y usuario | ACL revocada, firma distinta o entrada nueva |
| Confirmación inicial | LocalAuthentication | Marca local de Nuvex | Si se reactiva la opción o cambia el estado migrado |
| Ayudante de red | macOS/admin + sudoers acotado | Mientras binario/configuración coincidan | Motor, perfil firmado o ayudante cambian |
| Avisos | TCC/Notificaciones de macOS | Decisión del sistema | Solo si se revoca; Nuvex la pide desde Ajustes |
| Gmail | Google OAuth | Refresh token en Llavero | Revocación, cliente borrado o app OAuth en prueba |
| Inicio de sesión | `SMAppService.mainApp` | Registro de macOS | Si el usuario lo desactiva o macOS exige aprobación |
| Asistentes | Política interna de Nuvex | `ajustes.json` | Solo al cambiarla; puede limitarse por conexión |
| Sandbox de agentes | Codex o Claude Code | Regla exacta y revocable para el CLI | Si se revoca, se mueve la ruta o una política administrada la prohíbe |

`Conectar sin preguntar` es el perfil global de confianza interno para
operaciones rutinarias, combinado con la lista de conexiones permitidas. No
sustituye TCC, el diálogo de administrador, Touch ID, Google OAuth ni las
aprobaciones del agente. La app registra categorías de avisos al iniciar, pero
solicita autorización únicamente al pulsar **Autorizar…** en Ajustes.

## Ciclo de vida de macOS

| Estado | Comportamiento real |
| --- | --- |
| App minimizada/no visible | Continúan socket, sondeo de estado y Gmail si hay una solicitud |
| Sesión bloqueada | Procesos y túnel pueden continuar; no se pueden aceptar diálogos interactivos |
| Pantalla apagada | Igual que sesión activa mientras el sistema no duerma |
| App cerrada | Un túnel ya creado puede continuar; al ejecutar el CLI, este abre Nuvex en segundo plano y espera hasta 15 s por el socket |
| Pérdida de red | Gmail aplica backoff; al recuperarse se adelantan reconciliación y lectura pendiente |
| Suspensión real | CPU y red locales no ejecutan trabajo; no se consulta Gmail ni se atienden agentes |
| Reactivación | Se reinicia el socket si falló, se consulta el túnel y se reanuda una lectura transitoria |
| Reinicio | El inicio automático puede abrir Nuvex al iniciar sesión; no se supone que un intento incompleto sobreviva |

Nuvex no mantiene la Mac despierta indefinidamente. Evitar reposo durante cada
espera OTP gastaría energía y no resolvería reinicios ni pérdida de red. Una
operación verdaderamente disponible mientras la Mac duerme requiere un
servicio remoto siempre activo que custodie autorización y, posiblemente,
credenciales. Eso añade infraestructura, costo, superficie de ataque, gestión
de secretos y controles de revocación; no forma parte de la arquitectura local.

Un LaunchAgent separado mediante `SMAppService.agent` permitiría que el motor
de automatización sobreviviera al cierre explícito de la app, pero hoy
duplicaría el dueño de perfiles, operaciones, socket, OAuth y Llavero. También
introduciría otra identidad de código capaz de provocar autorizaciones y no
aportaría ejecución durante reposo. `SMAppService.mainApp` más el arranque en
segundo plano desde el CLI cubre el caso observado con menor superficie; XPC es
adecuado para separar privilegios, no para prometer persistencia durante sueño.

## Recuperación y observabilidad

El registro `~/Library/Logs/Nuvex.log` rota a 2 MiB, conserva una generación y
tiene modo 0600. Los eventos nuevos usan pares `clave=valor` para Gmail, ciclo
de vida y control remoto. Incluyen operación, clase de fallo, intento y demora,
pero nunca OTP, contraseña, token OAuth, cuerpo, asunto o dirección de correo.

`nuvex diagnostico` revisa control, ayudante, política, Touch ID, firma,
Llavero y cada perfil sin conectar. `--profundo` prueba la lectura real del
Llavero y puede requerir presencia. Ajustes también comprueba el enlace del CLI
y las habilidades instaladas. El servidor del socket reinicia la escucha si
`accept` termina inesperadamente. Al despertar o recuperar la red también
detecta una ruta de socket perdida y la recrea, sin abrir dos escuchas.

## Pruebas y límites

Las pruebas automatizadas cubren extracción y fallback a HTML, árboles MIME
inline y con `attachmentId`, tamaño acumulado máximo, clasificación de errores,
backoff y `Retry-After`, protocolo compatible, socket privado, detección de una
ruta de socket perdida, clientes rechazados, concurrencia remota y geometría en
pantallas pequeñas/secundarias.

Requieren validación manual o infraestructura externa: OAuth y correo reales,
VPN Fortinet real, suspensión física, bloqueo de sesión, revocaciones TCC,
multimonitor, tamaño de texto, firma de distribución, notarización y ejecución
real desde versiones instaladas de Codex y Claude Code.
