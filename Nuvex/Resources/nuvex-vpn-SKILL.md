---
name: nuvex-vpn
description: Conecta, desconecta y consulta las VPN Fortinet del usuario con Nuvex mediante el comando `nuvex`. Úsala cuando el usuario pida conectarse o desconectarse de una VPN, pregunte si está conectado, diga que salió de casa o que necesita entrar a la red de la oficina, el cliente o la escuela, o cuando una tarea falle por no tener acceso a un recurso interno. Frases como "conéctame a la VPN", "conecta la de la oficina", "desconecta la VPN", "¿estoy en la VPN?", "salí de casa".
---
<!-- nuvex-vpn: gestionado por Nuvex. Se actualiza desde Ajustes de Nuvex › Automatización. -->

# Nuvex: VPN del usuario

Nuvex es la app de la barra de menús que gestiona las VPN Fortinet de esta Mac. El comando `nuvex` habla con ella; si no está abierta, la abre. Las contraseñas nunca pasan por ti: Nuvex las toma del Llavero.

La Mac debe estar encendida, con una sesión de usuario iniciada y despierta. Durante la suspensión real macOS no ejecuta Nuvex, el comando ni la red; al despertar, vuelve a ejecutar `nuvex estado` antes de decidir si hace falta reintentar.

Si `nuvex` no está en el PATH, usa `~/.local/bin/nuvex` o `/Applications/Nuvex.app/Contents/Resources/bin/nuvex`.

`nuvex` necesita abrir Nuvex y hablar con ella por un socket local, algo que el sandbox de los asistentes bloquea. Ejecútalo siempre fuera del sandbox: en Codex, pide permisos elevados para el comando; en Claude Code, desactiva el sandbox para ese comando. Nunca abras el ejecutable de Nuvex directamente (`Nuvex.app/Contents/MacOS/…`): heredaría el aislamiento y no podría usar el Llavero ni el ayudante.

## Comandos

```sh
nuvex estado --json                 # Lista las VPN y su estado. Hazlo primero.
nuvex conectar "<vpn>" --json       # Conecta y espera el resultado (hasta 180 s).
nuvex desconectar "<vpn>" --json
nuvex desconectar --todas --json
printf '%s' "<código>" | nuvex codigo "<vpn>" --json
nuvex diagnostico                   # Qué falta para conectar sin la persona.
nuvex diagnostico --profundo        # Además prueba el Llavero; puede pedir autorización.
```

`<vpn>` es el nombre que muestra `nuvex estado`, una parte única de él (por ejemplo `oficina`) o su id. Con `--json`, cada línea es un evento o el resultado final; `salida` coincide con el código de salida y `motivo` es el código estable para decidir qué hacer. No tomes decisiones comparando literalmente `titulo` o `detalle`.

## Códigos de salida

| Código | Significado | Qué hacer |
| --- | --- | --- |
| 0 | Hecho | Informa del resultado (nombre, IP si la hay). |
| 1 | Error de conexión | Explica `titulo` y `detalle`. Reintenta una sola vez solo si `motivo` es `servidor_no_responde`. |
| 2 | Uso incorrecto o VPN no encontrada | Revisa el nombre con `nuvex estado`; si varias coinciden, pregunta cuál. |
| 3 | No permitido | El usuario restringió los asistentes en Ajustes de Nuvex › Automatización. Díselo; no intentes saltarlo. |
| 4 | Hace falta la persona en la Mac | Explica `detalle` (autorizar el ayudante, Touch ID, contraseña o Llavero). No reintentes. |
| 5 | Tiempo agotado | Consulta `nuvex estado`; puede seguir conectando o esperando un código. |
| 6 | Nuvex no responde | Pide al usuario que abra Nuvex. |
| 7 | El sandbox bloquea Nuvex (`motivo` `aislamiento`) | Repite el mismo comando fuera del sandbox. No es un fallo de la cuenta, la VPN ni la app. |

`nuvex desconectar "<vpn>" --json` también cancela un intento que siga conectando o esperando el código.

## Código de verificación

Algunas VPN piden un código enviado por correo, SMS o app.

1. Si durante `conectar` llega el evento `codigo_requerido` y su detalle dice que Nuvex lo está buscando en el correo, espera: Nuvex lo lee solo.
2. Si no, pide el código al usuario en el chat. Cuando lo dé, envíalo con:
   `printf '%s' "<código>" | nuvex codigo "<vpn>" --json`
   El `conectar` original termina en cuanto el código llega. Si ya terminó por tiempo, comprueba con `nuvex estado`.
3. Usa el código una sola vez. No lo guardes en archivos, notas ni memoria, y no lo repitas en tus respuestas.

## Reglas

- Antes de conectar, ejecuta `nuvex estado` para usar el nombre exacto y no conectar algo que ya lo está.
- Conecta o desconecta solo lo que el usuario pidió. No desconectes otras VPN para «hacer sitio» sin preguntar.
- Ante un error de usuario o contraseña, no reintentes: el servidor puede bloquear la cuenta. Dile que la revise en Ajustes de Nuvex.
- No leas ni muestres el Llavero, `~/.config/nuvex/profiles.json` ni el registro para obtener credenciales.
- Al terminar, resume en una frase: qué VPN quedó conectada o desconectada, o qué falta y quién debe hacerlo.
