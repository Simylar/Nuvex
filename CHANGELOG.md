# Cambios

Este archivo sigue el formato de [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y Nuvex usa [versionado semántico](https://semver.org/lang/es/). Cada sección `## [X.Y.Z]` se muestra en la app como «Novedades» y se publica como notas de la versión.

## [3.3.0] - 2026-10-24

### Nuevo diseño y experiencia
- Nuvex estrena un sistema visual unificado inspirado en macOS y Liquid Glass, con materiales, color, tipografía, espaciado, sombras y estados interactivos coherentes.
- El panel, la bienvenida, Ajustes, actualización de software, exportación y los diálogos se adaptan mejor a los modos claro y oscuro.
- La ventana del código de verificación permanece dentro del área visible, permite desplazamiento y conserva sus acciones accesibles en pantallas pequeñas y configuraciones con varios monitores.
- La navegación, los mensajes de estado y los componentes reutilizables ofrecen una experiencia más clara sin cambiar las conexiones existentes.

### Nuevas capacidades
- Nuvex recupera automáticamente el control local y reconcilia el estado de las VPN después de reactivar la Mac o recuperar la conexión de red.
- La lectura de Gmail admite árboles MIME completos, contenido mediante `attachmentId` y fallback de texto plano a HTML, con límites de tamaño y selección temporal más estrictos.
- El diagnóstico muestra el estado del comando, las habilidades y las autorizaciones de Codex y Claude Code sin iniciar una VPN.

### Mejoras de automatización
- Codex y Claude Code pueden recibir una autorización persistente, acotada y revocable para `~/.local/bin/nuvex`, sin desactivar globalmente sus sandboxes.
- El comando abre Nuvex en segundo plano cuando hace falta; la app continúa atendiendo con el menú oculto o la sesión bloqueada mientras la sesión de usuario siga iniciada.
- Las habilidades explican recuperación, códigos de salida y límites reales de macOS, y se actualizan sin reemplazar archivos ajenos.

### Correcciones de errores
- El socket de control se recrea si su escucha se interrumpe o desaparece su ruta, evitando que el CLI quede bloqueado hasta reiniciar la app.
- Gmail respeta `Retry-After`, limita el cuerpo acumulado y no descarta un código válido presente solo en la parte HTML.
- Cerrar la sesión de Google o reemplazar el cliente ya no permite que una renovación OAuth tardía restaure el acceso anterior.
- Las solicitudes simultáneas, desconexiones y reactivaciones conservan un estado consistente sin duplicar operaciones.

### Seguridad y estabilidad
- Las reglas de agentes se escriben con permisos privados, son idempotentes, preservan configuraciones ajenas y se eliminan al revocar el acceso o quitar el CLI gestionado.
- El servidor mantiene la validación del usuario, del binario oficial, del protocolo y de la política configurada para cada VPN.
- Los diagnósticos y registros evitan guardar contraseñas, tokens OAuth, códigos, cuerpos de correo y otros secretos.

### Compatibilidad y limitaciones conocidas
- Perfiles, preferencias, credenciales del Llavero, cuenta Gmail, políticas de automatización y protocolo del CLI conservan sus formatos actuales; la actualización no requiere migración destructiva.
- macOS no ejecuta Nuvex, Gmail ni los agentes durante una suspensión real. Al despertar se reanudan únicamente las operaciones que continúen vigentes; antes de iniciar sesión tampoco están disponibles la automatización por usuario ni su Llavero.
- En Claude Code, enviar manualmente un código mediante una tubería puede requerir una aprobación puntual; Nuvex no amplía la autorización a comandos ajenos como `printf`.
- Antes de publicar deben validarse en hardware real la actualización firmada desde 3.2.1, la continuidad del Llavero, Gmail, una VPN Fortinet, bloqueo de sesión, suspensión y reactivación.

## [3.2.1] - 2026-10-20

### Correcciones
- Codex y Claude Code ya no se quedan esperando cuando su sandbox impide abrir Nuvex: el comando `nuvex` lo detecta al momento y les indica repetir la orden fuera del sandbox, sin abrir la app de forma insegura. Pulsa **Actualizar** en las habilidades de **Ajustes › Automatización** para que los asistentes reciban estas instrucciones.

## [3.2.0] - 2026-10-20

### Mejoras
- Automatización usa estados, eventos y motivos estables en JSON, limita el tiempo de respuesta y permite un diagnóstico profundo opcional del Llavero.
- Las instalaciones nuevas piden confirmación antes de aceptar acciones remotas; las preferencias existentes se conservan.
- El diagnóstico ejecuta el comando instalado de extremo a extremo y diferencia configuración local de credenciales o servidores realmente probados.
- Las actualizaciones y su publicación validan SemVer sin regresiones, compilación, canal, tipo de paquete, HTTPS, firma EdDSA y espacio disponible; el siguiente arranque exige la versión exacta y conserva cualquier diagnóstico pendiente hasta mostrarlo.
- La prueba de actualización completa reproduce en copias temporales la descarga firmada, el parche delta, la extracción y el reemplazo; además comprueba que una interrupción o una firma inválida conserve intacta la versión anterior, sin modificar la app instalada ni depender de servicios externos.
- La pantalla de actualización distingue entre una instalación programada y una que espera a que termine una conexión, un guardado o la preparación del ayudante.
- La versión instalada y la compilación candidata se identifican claramente; después de reiniciar se confirma el resultado y, si la instalación no se completó, se informa que la versión anterior y los datos se conservaron.
- Los fallos ocurridos fuera de la pantalla de actualización dejan un aviso discreto en el panel y un indicador en Ajustes hasta que se revisan.
- Los fallos de red, firma, configuración, espacio o permisos muestran una explicación segura y una acción útil, sin exponer detalles técnicos internos.

### Correcciones
- `nuvex conectar` ya no informa un fallo durante el intervalo entre el arranque del túnel y su confirmación en el estado.
- `nuvex desconectar` puede cancelar una conexión que aún está arrancando o esperando un código.
- Una cancelación solo se informa como completada tras confirmar el estado del túnel; una confirmación en la Mac ya vencida no ejecuta la orden.
- Un diagnóstico con pendientes devuelve un código de salida distinto de cero y el registro se rota para no crecer indefinidamente.
- La instalación y la restauración desde código conservan la app anterior hasta verificar firma, versión, arranque y control local; si fallan, la recuperan y vuelven a abrir, sin cerrar otras copias de Nuvex ni continuar con una conexión en curso cuyo estado no se pudo comprobar.
- Cancelar una búsqueda temprana ya no permite que una respuesta tardía reactive la actualización, y las notas HTML se convierten localmente sin cargar recursos externos.
- Una actualización descargada se extrae y verifica antes de ofrecer instalarla al cerrar; el diagnóstico anterior no se borra por un fallo de búsqueda ajeno.
- La publicación se cancela si no puede recuperar el appcast anterior y comprueba que cada ZIP conserve su versión y canal, evitando perder historial o mover versiones entre estable y beta.

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
