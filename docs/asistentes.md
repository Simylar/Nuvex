# Conectar la VPN desde la Terminal, Claude Code o Codex

Nuvex incluye el comando `nuvex`, pensado para que puedas pedirle a Claude Code o a Codex «conéctame a la VPN de la oficina» cuando no estás frente a la Mac.

## Activarlo

En **Ajustes de Nuvex › Automatización**:

1. Elige el permiso en **Terminal y asistentes**:
   - **Conectar sin preguntar**: los asistentes conectan aunque no estés en la Mac.
   - **Pedir confirmación en la Mac**: aparece un diálogo que hay que aceptar.
   - **No permitir**: solo pueden consultar el estado.
2. En **Conexiones disponibles para asistentes**, desactiva las que no quieras que usen.
3. Pulsa **Instalar** en **Comando nuvex**. Se crea `~/.local/bin/nuvex`.
4. Pulsa **Instalar** en **Claude Code** y **Codex**. Así aprenden cuándo y cómo usar `nuvex`.

## Comandos

```sh
nuvex estado
nuvex conectar oficina
nuvex desconectar oficina
nuvex desconectar --todas
printf '%s' 123456 | nuvex codigo oficina
nuvex diagnostico
```

`oficina` puede ser el nombre completo, una parte única del nombre o el id de la conexión. Con `--json`, cada evento y el resultado salen como una línea JSON. Si Nuvex no está abierta, `nuvex` la abre.

| Código de salida | Significado |
| --- | --- |
| 0 | Hecho |
| 1 | Error de conexión |
| 2 | Uso incorrecto o conexión no encontrada |
| 3 | No permitido en Ajustes › Automatización |
| 4 | Hace falta la persona en la Mac |
| 5 | Tiempo agotado |
| 6 | Nuvex no responde |

## Antes de salir de casa

Ejecuta `nuvex diagnostico`. Para conectar a distancia hace falta:

- La Mac encendida, con tu sesión iniciada y sin dormir.
- El ayudante de red al día. Si una actualización lo cambió, Nuvex lo avisa para autorizarlo con la contraseña de administrador.
- La confirmación inicial con Touch ID ya hecha: conecta una vez desde el menú.
- Acceso al Llavero permitido. Tras cambiar la firma de la app, pulsa **Probar** en el menú y elige «Permitir siempre».
- Si la VPN pide un código, que Nuvex lo lea del correo o que se lo des al asistente en el chat.

## Seguridad

- El socket de control está en `~/Library/Application Support/Nuvex/control.sock`, con permisos 0600, y solo atiende a procesos de tu usuario.
- `nuvex` nunca recibe ni muestra contraseñas. Los códigos de verificación llegan por la entrada estándar, así no quedan en el historial ni en la lista de procesos.
- Cada conexión o desconexión hecha por un asistente queda en el registro y, si lo eliges, en un aviso que dice quién la pidió.
