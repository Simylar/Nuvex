# Cambios

Este archivo sigue el formato de [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y Nuvex usa [versionado semántico](https://semver.org/lang/es/). Cada sección `## [X.Y.Z]` se muestra en la app como «Novedades» y se publica como notas de la versión.

## [3.1.1] - 2026-10-18

### Mejoras
- **Cancelar una conexión en curso**: mientras una VPN conecta, su fila muestra el tiempo transcurrido y un botón «Cancelar». Las demás VPN no se tocan.
- **Errores de Gmail que se entienden**: si no se puede leer el código del correo, el panel dice por qué (sesión caducada, permiso que falta, Gmail API desactivada o sin conexión), cómo resolverlo y ofrece «Volver a buscar».
- **Qué se guardó y qué quedó pendiente**: al guardar una conexión, Nuvex indica por separado las conexiones, las contraseñas del Llavero y el ayudante de red, con «Autorizar el ayudante ahora» si hace falta.
- **Diagnóstico visible de automatización**: Ajustes puede comprobar permisos, ayudante, Llavero, conexiones, comando y habilidades sin intentar conectar una VPN.
- **Automatización más robusta**: valida el comando y la versión del protocolo, y evita operaciones simultáneas sobre una misma conexión.

### Correcciones
- «Buscar actualizaciones» ya no abre una segunda ventana: todo ocurre en Ajustes › Actualización de software.
- Las consultas al motor tienen tiempo límite y ya no pueden quedarse esperando para siempre; un intento de conexión que no termina se detiene a los 5½ minutos.
- Al quitar una habilidad, Nuvex ya no elimina otros archivos que estén en su carpeta.

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
