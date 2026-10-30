# Arquitectura, permisos y operación de Nuvex

Este documento describe la implementación del árbol de trabajo de Nuvex. No sustituye
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
| Gmail API | Encuentra el OTP y puede mover el correo usado a la papelera | OAuth `gmail.readonly` por defecto, `gmail.modify` opcional; cliente del propio usuario |

La interfaz no llama directamente a operaciones privilegiadas. El ayudante no
expone una API general y el socket de automatización no acepta binarios
arbitrarios del mismo usuario.

## Flujo de conexión y código

1. Nuvex valida que el perfil, la contraseña y el ayudante estén listos.
2. Lee la contraseña del Llavero; la confirmación inicial con Touch ID se
   comparte para Nuvex, no para otros procesos.
3. Inicia `nuvexctl connect` y entrega la contraseña por stdin.
4. El motor emite `NUVEX_OTP_REQUIRED` si necesita un segundo factor.
5. Se abre un panel flotante, por debajo de menús y alertas, redimensionable y
   limitado al `visibleFrame` de la pantalla activa. Su contenido puede desplazarse;
   **Código…** en la fila trae al frente la misma ventana sin crear otra solicitud.
6. Compiten tres fuentes: entrada manual, `nuvex codigo` y Gmail. La primera
   respuesta válida cierra las demás.
7. El intento se confirma consultando de nuevo el estado del túnel. No se
   considera conectado solo porque el proceso haya terminado con código cero.

Las tres fuentes usan `ExtractorCodigo.normalizar`: retira separadores de una
agrupación numérica y conserva los guiones de códigos alfanuméricos, incluidos
los extraídos por un patrón personalizado. Los controles internos se rechazan
en vez de transformarse silenciosamente en otro código.

### Lector de Gmail

- `enviarCorreoPapelera` vive en `ajustes.json`, desactivado de serie y sin
  ampliar el alcance de sesiones existentes. `CuentaGoogle` guarda los scopes
  concedidos en el Llavero; su ausencia en datos antiguos equivale a solo lectura.
  La solicitud de modificación requiere una decisión explícita desde Ajustes.
- `EntregaCodigo` conserva el origen solo cuando se envía el código encontrado.
  `UsoCorreoGmail` pertenece a un intento. Tras la entrega y el éxito del proceso,
  habilita una consulta nueva del túnel, identificada por la revisión de esa
  entrega. Cancelar, fallar o agotar la confirmación invalida el uso. Las consultas
  anteriores a esos requisitos, de otro intento o de una entrega reemplazada no
  autorizan mover el correo aunque sus respuestas lleguen después.
- Un estado desconectado o un perfil ausente en una consulta vigente cancela el
  uso pendiente. El propio uso impone un plazo de 30 segundos con reloj continuo
  después del éxito del proceso, aunque el estado público ya estuviera conectado.
- Después de confirmar, `CuentaGoogle` vuelve a comprobar la opción y la sesión
  antes de `POST messages/{id}/trash`. Cambiar de cuenta o sesión invalida la
  referencia. No hay borrado definitivo, cola persistente ni reintentos de
  traslado. Un fallo se muestra en Cuenta de Google sin cambiar el estado VPN.
- La preparación diferencia lector no configurado de cuenta ausente, Llavero
  inaccesible, sesión caducada, inicio OAuth pendiente y remitente vacío. La
  ventana muestra el problema desde la primera solicitud, ofrece la acción
  correspondiente y permite seguir escribiendo el código manualmente.
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
- Todos los consumidores de una renovación comparten también la traducción de
  errores. Retirar una tarea ya terminada no invalida la sesión: la vigencia se
  comprueba por su identidad, y una respuesta antigua no vuelve a guardar tokens
  ni cambia el estado de otro inicio OAuth.
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
| Confirmación inicial | Nuvex + LocalAuthentication | Marca local de Nuvex | Tras revocarla; reactivar el interruptor conserva una confirmación ya completada |
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

### Autorización conjunta en General

`SeccionPermisosNuvex` reúne el alcance y las acciones. La autorización conjunta
reutiliza la confirmación inicial y `IntegracionAsistentes.configurar()`, guarda
la política `permitir` y un recibo explícito de capacidades en `ajustes.json`
(esquema 3). Las exclusiones por conexión permanecen. No activa inicio de sesión,
solicita avisos, instala el ayudante ni inicia OAuth automáticamente: se muestran
sus estados y las acciones existentes. La marca global no otorga permisos del
sistema. Las capacidades futuras requieren un identificador nuevo y una nueva
decisión; el arranque no instala ni autoriza integraciones nuevas.

`EstadoCapacidades` calcula las acciones pendientes de perfiles habilitados,
contraseñas, confirmación inicial, ayudante y funciones opcionales configuradas.
General muestra tres acciones y permite desplegar el resto con los detalles y
la autorización conjunta. El acceso interactivo desde una acción se limita a
esa contraseña; el control detallado conserva la comprobación de todas. Un
estado desconocido o una sesión guardada no acredita autorización externa.
Tras una consulta vigente de todas las entradas, General retira el aviso de
cambio de firma si cada contraseña está disponible o se confirmó su ausencia.
Una consulta parcial, desconocida o con intervención pendiente no lo retira.

Revocar guarda primero `noPermitir`, elimina el recibo, invalida una confirmación
inicial en curso y retira las reglas gestionadas de todos los agentes. Informa
de limpiezas parciales. Conserva contraseñas, túneles y permisos externos. Un
cambio individual posterior se respeta y puede volver parcial el estado global.
Una revocación de una regla en el agente no implica que su política general
rechace el comando: el bloqueo efectivo de Nuvex reside en su política interna.

`AutorizacionCapacidades` conserva la operación en la aplicación aunque se
cierre o cambie la vista de General. Evita solicitudes duplicadas y comprueba
una generación después de la espera: una confirmación tardía no prepara reglas
ni restaura una autorización revocada. Las vistas observan ese mismo estado y
actualizan sus comprobaciones al terminar. Los resultados de consultas antiguas
del Llavero se descartan cuando cambian los perfiles o comienza otra consulta.
Un fallo al leer `ajustes.json` bloquea su modificación; solo un archivo ausente
inicia valores de serie. No interpretar errores de acceso como ajustes vacíos.
Un archivo de cero bytes también es un error. La versión del esquema debe ser
un entero positivo antes de recorrer migraciones; un valor negativo o no
numérico se rechaza sin reemplazar el archivo.

`ConfirmacionInicial` comparte una sola tarea de autenticación entre operaciones
concurrentes; su generación impide que una respuesta tardía restaure una marca
revocada. El acceso al Llavero sigue siendo independiente y por entrada.
`AccesoLlavero` comprueba sin interacción: disponible ahora, ausente, requiere
interacción, cancelado o fallo. Un error de autenticación no permite distinguir
con certeza una ACL denegada de un Llavero bloqueado. La prueba interactiva
recorre todas las contraseñas guardadas. Se retiró la lectura alternativa de
secretos mediante `/usr/bin/security`: cambiar de ejecutable podía producir un
segundo diálogo y otra decisión de confianza. Entradas antiguas autorizadas solo
a esa herramienta pueden necesitar permitir expresamente a la app firmada.

`ChequeoActualizacion` compara certificado y requisito designado (incluido el
identificador). Un cambio solo es un indicio; no prueba que macOS haya revocado
el acceso. El CLI comprueba la contraseña de la VPN solicitada en lugar de
bloquearlas todas por la marca de cambio de firma. La identidad desconocida no
se presenta como estable.

`CuentaGoogle` lee el Llavero sin diálogos al arrancar y diferencia una entrada
ausente de una bloqueada/corrupta. La recuperación explícita conserva el cliente
existente; no exige otro consentimiento OAuth por un error local. El estado
«sesión guardada» no demuestra que el scope o el servicio sigan disponibles.
Un HTTP 403 sin motivo explícito ya no se clasifica como falta de scope.
Cerrar u olvidar la cuenta solo cambia el estado después de persistirlo en el
Llavero. Si falla la escritura o el borrado, conserva el estado anterior y
explica el fallo, evitando que una sesión aparentemente cerrada reaparezca al
reiniciar. Si se cierra localmente pero Google no confirma la revocación remota,
lo indica y remite al panel de la cuenta; no oculta el fallo de red.
Cerrar sesión retira el token de renovación, el correo y los scopes de esa
sesión. El cliente se conserva; olvidar la cuenta retira también el cliente.
Los intentos de inicio OAuth tienen identidad propia y se cancelan al cambiar
de cliente. Sus respuestas y errores tardíos no pueden reemplazar ni cancelar
un inicio posterior. Lo mismo se aplica a errores de renovación: un
`invalid_grant` de una operación invalidada no caduca la cuenta actual. Las
pruebas simulan esas respuestas sin usar Google ni abrir el navegador.
Una revocación remota pendiente tampoco puede borrar el cliente o publicar
avisos de la sesión anterior si ya comenzó un nuevo inicio OAuth. La revocación
admite un sustituto en pruebas para reproducir esa reentrada sin tocar Google.

## Recuperación de una conexión

**General › Recuperación** guarda `reconectarAutomaticamente` en preferencias de
macOS, desactivado por defecto. No modifica las autorizaciones de asistentes.
Dos consultas válidas consecutivas sin un túnel antes activo confirman su caída.
Cuando haya red, `RecuperacionConexion` reserva como máximo un intento por perfil
hasta la siguiente conexión manual. El intento se reserva al ejecutarse, después de validar la espera; una caída
de red durante la espera no lo consume. La reserva sobrevive a una recuperación
exitosa durante la sesión: otra caída no inicia un bucle. Cerrar la app termina
el seguimiento; abrirla no conecta perfiles por sí solo.

Antes de programar y ejecutar el intento se comprueban estado, perfil habilitado,
ayudante vigente y operaciones incompatibles. La preparación exige una contraseña
guardada y ninguna confirmación inicial pendiente. La espera de tres segundos es
cancelable. La lectura del Llavero usa `LAContext.interactionNotAllowed`: una ACL
revocada o un Llavero bloqueado producen una acción manual, sin diálogo automático.
No se instala el ayudante en segundo plano. El servidor todavía puede pedir un
código, con la misma ventana y lector opcional existentes.

Un fallo queda en la fila con reintento explícito. Los avisos de recuperación
respetan la preferencia de avisar de desconexiones. Cancelar el código o el intento
vuelve a un estado neutral; agotar la espera conserva un fallo recuperable.
La desconexión voluntaria se confirma con `list`, impide duplicados y nunca activa
recuperación. Una revisión de estado descarta consultas iniciadas antes de esa
confirmación. Las respuestas de conexión también deben pertenecer al intento
actual para no reemplazar un intento posterior.
Iniciar una conexión manual o descartar una caída limpia su contador anterior;
los sondeos durante un intento no acumulan nuevas faltas. Si la espera automática
se interrumpe por red, consulta, guardado o preferencia, se conserva la caída y se
envía como máximo un aviso, respetando la preferencia de notificaciones. Las
consultas válidas posteriores pueden reprogramar la espera cuando desaparezca
el impedimento, sin consumir el intento antes de ejecutarlo.

La espera de recuperación forma parte de `conexionEnCurso`, de modo que una
desconexión solicitada por Terminal también la cancela. Cancelar retira la caída
pendiente; un cambio de red posterior no la reprograma. Cancelar un túnel cuyo
proceso ya terminó comparte `aplicarDesconexionConfirmada` con Desconectar y
bloquea órdenes de detención duplicadas durante la comprobación.

## Guardado, importación y restauración

`VPNModel.guardarPerfiles` devuelve un `ResultadoGuardado` propio de cada
operación, con los ID confirmados y pasos separados de perfiles, contraseñas,
lector y ayudante. El alta inicial, Ajustes e importación esperan su propio resultado; no infieren éxito del
estado global ni de ID que ya existían. Una carga fallida de perfiles bloquea
su modificación. Los formularios conservan los datos ante errores y solo limpian
la contraseña introducida cuando su escritura se confirma. Un rechazo conserva la vista previa y
muestra el error; un guardado parcial enumera lo pendiente.

El primer uso consume ese resultado y, solo si es completo y la contraseña está
guardada o disponible, pasa a `conectarTrasGuardar`. Puede iniciar antes del
siguiente sondeo usando la confirmación del ayudante de ese guardado; el éxito
del túnel sigue dependiendo de `list`. Si falla la escritura en el Llavero, la
preparación del ayudante queda pendiente y no abre otro diálogo. Cancelar una
autorización nunca encadena un segundo intento automático.

`PreparacionRestauracion` valida todos los archivos antes de crear la copia
previa o escribir perfiles. `AjustesDelGuardado.restaurarCorreo` recupera solo
el lector y conserva las decisiones de seguridad actuales. No revive políticas,
recibos ni exclusiones de una copia antigua. `PersistenciaRestauracion`
compensa el cambio de perfiles si fallan los ajustes; la limpieza del Llavero
espera a que ambos se hayan persistido. Si falla también la compensación, se
recarga el estado efectivo y se solicita revisar la copia previa. No hay un
diario duradero que garantice atomicidad ante un corte de energía entre archivos.

## Ciclo de vida de macOS

El servidor Unix usa `DispatchSourceRead` y escucha no bloqueante. Cancelar la
fuente cierra el descriptor cuando termina su manejador; evita cerrar desde el
hilo principal un descriptor que otro hilo tiene bloqueado en `accept`. Los
clientes aceptados conservan lectura bloqueante. Las pruebas cubren clientes
que demoran su escritura y veinte cierres con reinicio inmediato del servicio.

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
