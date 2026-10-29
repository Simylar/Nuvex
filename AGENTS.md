# Nuvex: desarrollo y experiencia de usuario

## Antes de cambiar el proyecto

- Lee `README.md`, `STYLE_GUIDE.md`, `docs/arquitectura-y-operacion.md` y la documentación del flujo afectado.
- Revisa el estado de Git y el código relacionado. Conserva los cambios ajenos.
- Para cambios complejos, define un plan breve. Antes de modificar cada flujo, identifica la tarea de la persona, los requisitos indispensables, los fallos posibles y cómo conservar su contexto.
- Mantén Swift/SwiftUI y las convenciones existentes. No añadas dependencias, contratos, permisos o cambios de esquema sin necesidad.

## Arquitectura

- `Nuvex/Sources/Nuvex/`: app SwiftUI, ventanas AppKit y coordinación mediante `VPNModel`.
- `NuvexControl` y `nuvex-cli`: contrato de automatización. Conserva la compatibilidad del protocolo.
- `nuvexctl.sh`, `nuvexconfig.py` y el ayudante: configuración y operaciones privilegiadas acotadas.
- Las contraseñas y la cuenta de Google viven en el Llavero; los perfiles no contienen secretos. Nunca incluyas contraseñas, códigos, tokens, datos personales o enlaces de acceso en mensajes, capturas o documentación.

## Principios de producto

- Organiza las pantallas para añadir una conexión, conectarse y recuperarse de un problema. El primer uso entra directamente al formulario, sin tutorial obligatorio.
- Pide servidor, usuario y contraseña. En altas desde la interfaz, el nombre vacío puede derivarse del servidor válido. No cambies nombres existentes ni normalices importaciones para ocultar errores.
- Usa certificados del sistema por defecto. Las opciones de certificado, huella, grupo de acceso, rutas y DNS siguen accesibles en «Opciones del servidor»; despliega las opciones ya personalizadas. Nunca desactives TLS ni adivines la confianza de un servidor.
- La acción inicial **Conectar** guarda, prepara y conecta con una sola acción de la persona. macOS controla los diálogos de autorización necesarios. Espera el resultado concreto, sin segundo clic ni encadenar otra autorización después de un fallo. Reutiliza la contraseña guardada al corregir otros datos.
- Distingue datos guardados, contraseña guardada, preparación del ayudante y túnel confirmado. La existencia de un perfil y el código cero de un proceso no bastan para declarar éxito.
- Consume el resultado de la solicitud concreta de guardado. Conserva los datos ante errores y limpia una contraseña introducida cuando se confirme su guardado; no infieras resultados mediante mensajes globales o temporizadores de la vista.
- Reutiliza autorizaciones válidas. Gmail, asistentes, avisos, inicio de sesión y reconexión opcional requieren las decisiones correspondientes. Conserva las exclusiones y políticas existentes de automatización.
- La recuperación automática está desactivada por defecto. Tras activarla, solo recupera caídas observadas durante la sesión, con red y ayudante vigentes y sin nuevos diálogos de Llavero o administrador. Un intento por conexión iniciada manualmente, cancelable y sin bucles; el servidor puede pedir un código. No conectes perfiles al arrancar por el mero hecho de existir.
- Una recuperación pendiente cuenta como operación cancelable también para Terminal. Cancelarla elimina la caída pendiente: los cambios de red posteriores no deben reactivarla. Cancelar un túnel recién iniciado debe confirmar su detención e invalidar consultas anteriores igual que Desconectar.
- Explica primero el problema y ofrece la acción que lo resuelve. Los detalles de diagnóstico se consultan aparte. No declares una conexión activa si su estado no se pudo comprobar.
- Bloquea operaciones duplicadas y escrituras si no se pudo leer la configuración. Mantén confirmación para eliminar conexiones, olvidar cuentas, exportar secretos o ampliar permisos. Las acciones rutinarias reversibles no necesitan confirmaciones añadidas.

## Interfaz nativa

- `Diseno.swift` es la fuente de tokens. Usa `Form`, `Section`, `DisclosureGroup`, `NavigationSplitView`, estilos de botón y barras de acciones existentes.
- Una acción principal por pantalla; texto explícito para conectar, desconectar, cancelar o reintentar.
- Ofrece atajos, foco predecible y etiquetas VoiceOver con el nombre de la conexión. No dupliques un botón visible mediante otro control accesible de solo icono.
- Respeta apariencia clara/oscura, contraste, reducción de movimiento y transparencia. No añadas vidrio decorativo sobre contenido.
- Al reabrir, recupera primero el código o borrador pendiente y después la conexión con error, en curso o activa. No envíes siempre a General ni abras ventanas duplicadas.
- Los borradores de primer uso viven solo durante la sesión. Reiniciar la app no recupera contraseñas sin guardar.

## Verificación y entrega

- Revisa el diff completo y evita archivos temporales o cambios ajenos.
- Ejecuta las pruebas pertinentes; agrega regresiones cuando cambie el comportamiento. Comandos en `README.md`.
- `bash Nuvex/scripts/capturas.sh` genera muestras de depuración; sus servicios de cuenta y permisos usan datos ficticios. Las capturas no validan interacciones, VoiceOver, diálogos de macOS ni conexiones VPN reales.
- `bash tests/test_interaccion.sh` comprueba eventos locales en una ventana de muestra, solo después de compilar correctamente. No es un recorrido humano ni valida VoiceOver.
- Inspecciona las pantallas modificadas en ambas apariencias y tamaños mínimos. Distingue pruebas automáticas, inspección de renderizados y validación manual en `docs/experiencia-de-usuario.md`.
- Compilar no autoriza instalar, publicar, distribuir ni cambiar una VPN real. Sigue el alcance autorizado por el usuario.
