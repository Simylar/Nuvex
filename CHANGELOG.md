# Cambios

Este archivo sigue el formato de [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y Nuvex usa [versionado semántico](https://semver.org/lang/es/). Cada sección `## [X.Y.Z]` se muestra en la app como «Novedades» y se publica como notas de la versión.

## [3.1.0] - Sin publicar

### Añadido
- Actualizaciones desde la app con Sparkle: búsqueda diaria, aviso discreto en el panel y canal beta opcional.
- Copia automática de la configuración antes de cada actualización y restauración desde Ajustes.
- Comprobación tras actualizar: acceso al Llavero, estado del ayudante y novedades de la versión.
- `scripts/instalar.sh` y `scripts/revertir.sh` para instalar desde el código sin perder datos.
- Comando `nuvex` y habilidad para Claude Code y Codex: conectan, desconectan y consultan tus VPN, con permisos en Ajustes › Automatización.
- Aviso de desconexión con Reconectar, que se queda en pantalla con el estilo «Alertas».
- Ventana del código de verificación que no bloquea la app.
- Lectura del código de verificación desde Gmail (solo lectura), configurable por conexión.

### Cambiado
- La versión sale de `Nuvex/VERSION` y el número de compilación del historial de Git.
- La app se firma con una identidad estable cuando existe, para que el Llavero no vuelva a pedir permiso tras cada actualización.
- El motor compilado se reutiliza mientras su código no cambie, así actualizar no obliga a reinstalar el ayudante.

## [3.0.0] - 2026-10-16

### Añadido
- Interfaz renovada al estilo de macOS: panel compacto, Ajustes por conexión, bienvenida y mensajes de error con acción.
