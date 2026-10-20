# Cambios

Este archivo sigue el formato de [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y Nuvex usa [versionado semántico](https://semver.org/lang/es/). Cada sección `## [X.Y.Z]` se muestra en la app como «Novedades» y se publica como notas de la versión.

## [Sin publicar]

### Mejoras
- Automatización usa estados, eventos y motivos estables en JSON, limita el tiempo de respuesta y permite un diagnóstico profundo opcional del Llavero.
- Las instalaciones nuevas piden confirmación antes de aceptar acciones remotas; las preferencias existentes se conservan.
- El diagnóstico ejecuta el comando instalado de extremo a extremo y diferencia configuración local de credenciales o servidores realmente probados.

### Correcciones
- `nuvex conectar` ya no informa un fallo durante el intervalo entre el arranque del túnel y su confirmación en el estado.
- `nuvex desconectar` puede cancelar una conexión que aún está arrancando o esperando un código.
- Una cancelación solo se informa como completada tras confirmar el estado del túnel; una confirmación en la Mac ya vencida no ejecuta la orden.
- Un diagnóstico con pendientes devuelve un código de salida distinto de cero y el registro se rota para no crecer indefinidamente.

## [3.1.2] - 2026-10-18

### Mejoras
- **Conectar desde toda la fila**: cuando una VPN está desconectada, ya no hace falta acertar en el candado; pulsar cualquier parte de la fila inicia la conexión. Las conexiones activas conservan sus detalles desplegables.
- **Automatización más fácil de comprobar**: Ajustes revisa permisos, ayudante, Llavero, conexiones, comando y habilidades sin intentar conectar una VPN.
- **Control remoto más robusto**: valida el comando y la versión del protocolo, e impide que dos órdenes modifiquen la misma conexión al mismo tiempo.
- **Ajustes siempre navegables**: la barra lateral se mantiene visible porque contiene la navegación principal de la ventana.
- **Versiones anteriores sin duplicados**: el instalador guarda los respaldos como ZIP para que macOS no los muestre como copias adicionales de Nuvex.

### Correcciones
- Al quitar una habilidad, Nuvex conserva cualquier otro archivo que exista en su carpeta y no sigue enlaces simbólicos.
- La herramienta de control puede reutilizar el motor y las bibliotecas de la app instalada cuando no hay una compilación local.
- La publicación conserva las URL correctas de versiones anteriores al generar actualizaciones delta.

## [3.1.1] - 2026-10-18

### Mejoras
- **Cancelar una conexión en curso**: mientras una VPN conecta, su fila muestra el tiempo transcurrido y un botón «Cancelar». Las demás VPN no se tocan.
- **Errores de Gmail que se entienden**: si no se puede leer el código del correo, el panel dice por qué (sesión caducada, permiso que falta, Gmail API desactivada o sin conexión), cómo resolverlo y ofrece «Volver a buscar».
- **Qué se guardó y qué quedó pendiente**: al guardar una conexión, Nuvex indica por separado las conexiones, las contraseñas del Llavero y el ayudante de red, con «Autorizar el ayudante ahora» si hace falta.

### Correcciones
- «Buscar actualizaciones» ya no abre una segunda ventana: todo ocurre en Ajustes › Actualización de software.
- Las consultas al motor tienen tiempo límite y ya no pueden quedarse esperando para siempre; un intento de conexión que no termina se detiene a los 5½ minutos.

## [3.1.0] - 2026-10-17

### Novedades
- **Actualización de software**: Nuvex busca versiones nuevas cada día, te muestra qué cambió y se actualiza con un clic. Tus conexiones, contraseñas y ajustes se conservan, y las VPN siguen conectadas mientras se instala.
- **Conecta con Claude Code o Codex**: pídeles «conéctame a la VPN de la oficina» y lo harán, incluso si no estás frente a la Mac. Tú decides qué pueden hacer en Ajustes › Automatización.
- **Código por correo automático**: conecta tu cuenta de Gmail (solo lectura) y Nuvex usará el código de FortiToken en cuanto llegue.
- **Aviso de desconexión con Reconectar**: si una VPN se cae, el aviso se queda en pantalla con el estilo «Alertas» y la reconecta sin abrir la app.
- **Exportar e importar conexiones** en un archivo cifrado con una frase, para llevarlas a otra Mac. Las contraseñas son opcionales y piden Touch ID.

### Mejoras
- Icono de la barra más claro: verde al estar conectada y con un trazo animado mientras conecta.
- La ventana del código de verificación ya no bloquea Nuvex y muestra de qué VPN es.
- Copias automáticas de la configuración antes de cada actualización, con restauración desde Ajustes › General.
- Comprobación tras actualizar: si macOS necesita volver a autorizar algo, Nuvex lo pide en ese momento.

## [3.0.0] - 2026-10-16

### Añadido
- Interfaz renovada al estilo de macOS: panel compacto, Ajustes por conexión, bienvenida y mensajes de error con acción.
