---
name: nuvex-vpn
description: Conecta, desconecta y consulta las VPN Fortinet del usuario con Nuvex mediante el comando `nuvex`. Úsala cuando el usuario pida conectarse o desconectarse de una VPN, pregunte si está conectado, diga que salió de casa o que necesita entrar a la red de la oficina, el cliente o la escuela, o cuando una tarea falle por no tener acceso a un recurso interno. Frases como "conéctame a la VPN", "conecta la de la oficina", "desconecta la VPN", "¿estoy en la VPN?", "salí de casa".
---
<!-- nuvex-vpn: gestionado por Nuvex. Se actualiza desde Ajustes de Nuvex › Automatización. -->

# Nuvex: VPN del usuario

Nuvex es la app de la barra de menús que gestiona las VPN Fortinet de esta Mac. El comando `nuvex` habla con ella; si el proceso no está abierto, lo inicia en segundo plano. Las contraseñas nunca pasan por ti: Nuvex las toma del Llavero.

No hace falta que el menú o una ventana estén visibles. Nuvex sigue atendiendo en segundo plano y con la sesión bloqueada mientras esa sesión de usuario permanezca iniciada. Si **Abrir al iniciar sesión** está activo, macOS vuelve a iniciar Nuvex después de reiniciar e iniciar sesión. Antes de iniciar sesión no están disponibles el Llavero ni esta automatización por usuario.

Durante una suspensión real macOS pausa CPU y red: ningún proceso local, LaunchAgent ni servicio XPC puede conectar la VPN o consultar Gmail. Al despertar, Nuvex reconcilia el túnel, restaura el socket y reanuda una lectura de correo todavía vigente. Ejecuta de nuevo `nuvex estado` antes de decidir si hace falta reintentar.

Usa siempre `~/.local/bin/nuvex`; si no existe, pide al usuario pulsar **Configurar** en Ajustes de Nuvex › Automatización. Esa única acción prepara el CLI y las skills, crea las reglas acotadas para los agentes detectados y comprueba el resultado.

El CLI necesita llegar a un socket Unix privado fuera del sandbox de Bash. **Configurar** concede una autorización persistente y revocable que abarca únicamente `~/.local/bin/nuvex`: no desactiva globalmente el sandbox y Nuvex sigue limitando cada VPN según su propia política. Si falta la regla, pide usar esa acción; solo si no está disponible solicita una aprobación específica para ese ejecutable. No uses modos globales como `danger-full-access`, `bypassPermissions` o `--dangerously-skip-permissions`. Nunca abras el ejecutable gráfico (`Nuvex.app/Contents/MacOS/Nuvex`) directamente.

## Comandos

```sh
~/.local/bin/nuvex estado --json                 # Lista las VPN y su estado. Hazlo primero.
~/.local/bin/nuvex conectar "<vpn>" --json       # Conecta y espera el resultado (hasta 180 s).
~/.local/bin/nuvex desconectar "<vpn>" --json
~/.local/bin/nuvex desconectar --todas --json
printf '%s' "<código>" | ~/.local/bin/nuvex codigo "<vpn>" --json
~/.local/bin/nuvex diagnostico                   # Qué falta para conectar sin la persona.
~/.local/bin/nuvex diagnostico --profundo        # Además prueba el Llavero; puede pedir autorización.
```

`<vpn>` es el nombre que muestra `~/.local/bin/nuvex estado`, una parte única de él (por ejemplo `oficina`) o su id. Con `--json`, cada línea es un evento o el resultado final; `salida` coincide con el código de salida y `motivo` es el código estable para decidir qué hacer. No tomes decisiones comparando literalmente `titulo` o `detalle`.

## Códigos de salida

| Código | Significado | Qué hacer |
| --- | --- | --- |
| 0 | Hecho | Informa del resultado (nombre, IP si la hay). |
| 1 | Error de conexión | Explica `titulo` y `detalle`. Reintenta una sola vez solo si `motivo` es `servidor_no_responde`. |
| 2 | Uso incorrecto o VPN no encontrada | Revisa el nombre con `~/.local/bin/nuvex estado`; si varias coinciden, pregunta cuál. |
| 3 | No permitido | El usuario restringió los asistentes en Ajustes de Nuvex › Automatización. Díselo; no intentes saltarlo. |
| 4 | Hace falta la persona en la Mac | Explica `detalle` (autorizar el ayudante, Touch ID, contraseña o Llavero). No reintentes. |
| 5 | Tiempo agotado | Consulta `~/.local/bin/nuvex estado`; puede seguir conectando o esperando un código. |
| 6 | Nuvex no responde | Pide al usuario que abra Nuvex. |
| 7 | El sandbox bloquea Nuvex (`motivo` `aislamiento`) | Pide pulsar **Configurar** en Automatización o aprobar solo `~/.local/bin/nuvex`. No desactives el sandbox completo. |

`nuvex desconectar "<vpn>" --json` también cancela un intento que siga conectando o esperando el código.

## Código de verificación

Algunas VPN piden un código enviado por correo, SMS o app.

1. Si durante `conectar` llega el evento `codigo_requerido` y su detalle dice que Nuvex lo está buscando en el correo, espera: Nuvex lo lee solo.
2. Si no, pide el código al usuario en el chat. Cuando lo dé, envíalo con:
   `printf '%s' "<código>" | ~/.local/bin/nuvex codigo "<vpn>" --json`
   El `conectar` original termina en cuanto el código llega. Si ya terminó por tiempo, comprueba con `~/.local/bin/nuvex estado`.
   En Claude Code, la tubería combina dos comandos y puede exigir una aprobación puntual fuera del sandbox aunque Nuvex esté autorizado. No autorices `printf` globalmente ni guardes una regla más amplia para evitarla.
3. Usa el código una sola vez. No lo guardes en archivos, notas ni memoria, y no lo repitas en tus respuestas.

## Reglas

- Antes de conectar, ejecuta `~/.local/bin/nuvex estado` para usar el nombre exacto y no conectar algo que ya lo está.
- Conecta o desconecta solo lo que el usuario pidió. No desconectes otras VPN para «hacer sitio» sin preguntar.
- Ante un error de usuario o contraseña, no reintentes: el servidor puede bloquear la cuenta. Dile que la revise en Ajustes de Nuvex.
- No leas ni muestres el Llavero, `~/.config/nuvex/profiles.json` ni el registro para obtener credenciales.
- Al terminar, resume en una frase: qué VPN quedó conectada o desconectada, o qué falta y quién debe hacerlo.
