---
name: nuvex-vpn
description: Conecta, desconecta y consulta las VPN Fortinet del usuario con Nuvex mediante el comando `nuvex`. Úsala cuando el usuario pida conectarse o desconectarse de una VPN, pregunte si está conectado, diga que salió de casa o que necesita entrar a la red de la oficina, el cliente o la escuela, o cuando una tarea falle por no tener acceso a un recurso interno. Frases como "conéctame a la VPN", "conecta la de la oficina", "desconecta la VPN", "¿estoy en la VPN?", "salí de casa".
---
<!-- nuvex-vpn: gestionado por Nuvex. Se actualiza desde Ajustes de Nuvex › Automatización. -->

# Nuvex: VPN del usuario

Nuvex es la app de la barra de menús que gestiona las VPN Fortinet de esta Mac. El comando `nuvex` habla con ella; si no está abierta, la abre. Las contraseñas nunca pasan por ti: Nuvex las toma del Llavero.

Si `nuvex` no está en el PATH, usa `~/.local/bin/nuvex` o `/Applications/Nuvex.app/Contents/Resources/bin/nuvex`.

## Comandos

```sh
nuvex estado --json                 # Lista las VPN y su estado. Hazlo primero.
nuvex conectar "<vpn>" --json       # Conecta y espera el resultado (hasta 180 s).
nuvex desconectar "<vpn>" --json
nuvex desconectar --todas --json
printf '%s' "<código>" | nuvex codigo "<vpn>" --json
nuvex diagnostico                   # Qué falta para conectar sin la persona.
```

`<vpn>` es el nombre que muestra `nuvex estado`, una parte única de él (por ejemplo `oficina`) o su id. Con `--json`, cada línea es un evento o el resultado final; el campo `salida` del resultado coincide con el código de salida.

## Códigos de salida

| Código | Significado | Qué hacer |
| --- | --- | --- |
| 0 | Hecho | Informa del resultado (nombre, IP si la hay). |
| 1 | Error de conexión | Explica `titulo` y `detalle`. Reintenta una sola vez solo si el título es «El servidor no responde». |
| 2 | Uso incorrecto o VPN no encontrada | Revisa el nombre con `nuvex estado`; si varias coinciden, pregunta cuál. |
| 3 | No permitido | El usuario restringió los asistentes en Ajustes de Nuvex › Automatización. Díselo; no intentes saltarlo. |
| 4 | Hace falta la persona en la Mac | Explica `detalle` (autorizar el ayudante, Touch ID, contraseña o Llavero). No reintentes. |
| 5 | Tiempo agotado | Consulta `nuvex estado`; puede seguir conectando o esperando un código. |
| 6 | Nuvex no responde | Pide al usuario que abra Nuvex. |

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
