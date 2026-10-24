# Conectar la VPN desde la Terminal, Claude Code o Codex

Nuvex incluye el comando `nuvex`, pensado para que puedas pedirle a Claude Code o a Codex «conéctame a la VPN de la oficina» cuando no estás frente a la Mac.

## Activarlo

En **Ajustes de Nuvex › Automatización**:

1. Elige el permiso en **Terminal y asistentes**:
   - **Conectar sin preguntar**: los asistentes conectan aunque no estés en la Mac.
   - **Pedir confirmación en la Mac**: aparece un diálogo que hay que aceptar.
   - **No permitir**: solo pueden consultar el estado.
   Una instalación nueva empieza en **Pedir confirmación en la Mac**. Elegir
   **Conectar sin preguntar** es una decisión explícita para uso desatendido.
2. En **Conexiones disponibles para asistentes**, desactiva las que no quieras que usen.
3. Pulsa **Preparar**. Nuvex instala o actualiza `~/.local/bin/nuvex` y las habilidades de Claude Code y Codex que detecte. No reemplaza archivos que no haya creado ni cambia la política elegida. Si una herramienta ya tiene una habilidad `nuvex-vpn` ajena, la conserva y continúa preparando la otra.
4. En **Acceso persistente de agentes**, pulsa **Autorizar** para cada agente que quieras usar. Nuvex crea una regla limitada al CLI; no desactiva el sandbox completo. Reinicia el agente para que cargue la regla. Puedes revocarla desde la misma pantalla.
5. Revisa el diagnóstico automático. También puedes instalar o quitar cada componente por separado y pulsar **Comprobar preparación** sin iniciar una VPN.

## Comandos

```sh
~/.local/bin/nuvex estado
~/.local/bin/nuvex conectar oficina
~/.local/bin/nuvex desconectar oficina
~/.local/bin/nuvex desconectar --todas
printf '%s' 123456 | ~/.local/bin/nuvex codigo oficina
~/.local/bin/nuvex diagnostico
~/.local/bin/nuvex diagnostico --profundo
```

`oficina` puede ser el nombre completo, una parte única del nombre o el id de la conexión. Si una conexión está arrancando o esperando un código, `desconectar` cancela ese intento. Con `--json`, cada evento y el resultado salen como una línea JSON. Los campos `estado`, `evento` y `motivo` son códigos estables; cada petición incorpora un id opaco de operación para diagnóstico y los textos son para mostrarlos a la persona. Si Nuvex no está abierta, `nuvex` la abre.

El diagnóstico normal no conecta ninguna VPN ni lee el valor de las contraseñas: distingue entre configuración local y comprobaciones reales. `--profundo` intenta leer cada contraseña guardada sin mostrarla ni conservarla y puede pedir autorización de macOS.

| Código de salida | Significado |
| --- | --- |
| 0 | Hecho |
| 1 | Error de conexión |
| 2 | Uso incorrecto o conexión no encontrada |
| 3 | No permitido en Ajustes › Automatización |
| 4 | Hace falta la persona en la Mac o el diagnóstico tiene pendientes |
| 5 | Tiempo agotado |
| 6 | Nuvex no responde |
| 7 | El sandbox del asistente impide abrir Nuvex o hablar con ella |

### Sandbox de Codex y Claude Code

Codex y Claude Code pueden ejecutar Bash dentro de un sandbox de macOS que no deja abrir apps ni conectar con el socket Unix de Nuvex. Desde ahí, `open` puede responder `kLSNoExecutableErr` aunque la app esté instalada. `nuvex` lo detecta y sale con el código 7 y el motivo `aislamiento`; no es un fallo de la cuenta ni del servidor VPN.

La autorización persistente resuelve ese límite sin ampliar todos los comandos:

- Codex recibe un archivo propio `rules/nuvex.rules` en cada raíz de configuración detectada —`~/.codex` para el CLI y el hogar aislado de Codex Desktop cuando exista— cuyo prefijo exacto es la ruta absoluta `/Users/<usuario>/.local/bin/nuvex`.
- Claude Code conserva el resto de `~/.claude/settings.json` y añade solo un permiso `Bash` y una exclusión de sandbox para esa misma ruta absoluta.
- La skill instalada usa también la ruta absoluta. Así no depende de `HOME`, que Codex o Claude Code pueden redirigir a un contenedor propio; la interfaz sigue mostrando `~/.local/bin/nuvex` como abreviatura legible para Terminal.
- La app no activa `danger-full-access`, `bypassPermissions` ni `--dangerously-skip-permissions`. El servidor sigue aceptando únicamente el binario incluido en la misma app y vuelve a aplicar la política interna por conexión.

Las operaciones rutinarias del CLI quedan cubiertas. La entrega manual de un
OTP usa una tubería con `printf`; Claude Code exige que cada subcomando de una
tubería esté excluido para sacarla completa del sandbox. Esa operación
excepcional puede requerir una aprobación puntual: Nuvex no autoriza `printf`
globalmente porque ampliaría la confianza a un comando ajeno.

Tras actualizar Nuvex, pulsa **Preparar** para actualizar ambas habilidades. Las reglas continúan siendo válidas porque apuntan al enlace estable; **Comprobar preparación** informa si falta alguna.

## Antes de salir de casa

Ejecuta `nuvex diagnostico`. Para conectar a distancia hace falta:

- La Mac encendida y con tu sesión iniciada. El menú puede estar cerrado y la sesión puede estar bloqueada; el equipo no puede estar en suspensión real.
- El ayudante de red al día. Si una actualización lo cambió, Nuvex lo avisa para autorizarlo con la contraseña de administrador.
- La confirmación inicial con Touch ID ya hecha: conecta una vez desde el menú.
- Acceso al Llavero permitido. Tras cambiar la firma de la app, pulsa **Probar** en el menú y elige «Permitir siempre».
- Si la VPN pide un código, que Nuvex lo lea del correo o que se lo des al asistente en el chat.

Con la pantalla apagada o la sesión bloqueada, la app de barra de menús y el ayudante pueden continuar, pero no se pueden aceptar diálogos. Si el proceso de Nuvex fue cerrado, el CLI lo vuelve a abrir en segundo plano; **Abrir al iniciar sesión** usa `SMAppService.mainApp` para recuperarlo después de reiniciar e iniciar sesión. Durante la suspensión real no se ejecutan Nuvex, Gmail, el CLI ni los agentes. Al despertar se reconcilian socket, VPN y lecturas pendientes. Para operar mientras la Mac duerme sería necesario un servicio remoto siempre activo; Nuvex no simula esa capacidad ni evita el reposo indefinidamente.

## Seguridad

- El socket de control está en `~/Library/Application Support/Nuvex/control.sock`, con permisos 0600. Además de comprobar que el proceso pertenece a tu usuario, Nuvex solo acepta órdenes del comando incluido en esa misma copia de la app, valida la versión del protocolo y limita el tiempo de espera del cliente. Si la escucha termina inesperadamente, Nuvex la reinicia; al despertar o recuperar la red también recrea una ruta perdida.
- `nuvex` nunca recibe ni muestra contraseñas. Los códigos de verificación llegan por la entrada estándar, así no quedan en el historial ni en la lista de procesos.
- Cada conexión o desconexión hecha por un asistente queda en el registro y, si lo eliges, en un aviso que dice quién la pidió.
- Si llegan dos órdenes para la misma conexión, Nuvex conserva la primera y rechaza la segunda para que no se crucen.
