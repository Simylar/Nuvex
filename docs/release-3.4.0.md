# Nuvex 3.4.0 — Resumen técnico de release

Las novedades para quien usa la app están en `CHANGELOG.md`. Este documento
registra el alcance, la validación y las limitaciones; no acredita por sí solo su publicación.
El commit, build, hashes y canal definitivos se obtienen de
`release-manifest.txt` y `SHA256SUMS` generados por la simulación del commit
exacto, sin copiarlos a mano aquí.

## Alcance desde 3.3.0

- Papelera opcional para el mensaje cuyo código completó una conexión. La
  elección persiste y está desactivada por defecto. `gmail.modify` requiere
  consentimiento explícito; no se usa borrado definitivo ni hay reintentos de
  traslado en segundo plano.
- Primer uso directo y conexión con guardado, preparación y arranque en una
  acción, conservando el avance y distinguiendo los resultados de cada paso.
- Permisos centrados en acciones pendientes, reutilización de autorizaciones y
  recuperación automática opcional con un intento por conexión manual.
- Correcciones de renovación OAuth compartida, contadores y avisos de caídas,
  reconciliación del Llavero y persistencia del editor de Gmail.

## Verificación automatizada disponible

La revisión previa pasó 42 pruebas de Python y las 15 suites Swift/shell,
incluidas las regresiones de los flujos corregidos. Se compilaron depuración y
un paquete ad hoc, se probaron actualizaciones en copias temporales y se
revisaron renderizados claros y oscuros con datos ficticios. El detalle está en
`docs/experiencia-de-usuario.md`, en la revisión del 30 de octubre de 2026.

La simulación de publicación vuelve a compilar y ejecutar las pruebas sobre el
commit congelado, verifica la identidad de firma del canal y los metadatos del
paquete, y genera y valida ZIP, deltas, appcast, notas, manifiesto y hashes sin
subir una etiqueta ni un release.

## Validación local de la actualización

La prueba preliminar del candidato 3.4.0 (163), `07c46d5`, actualizó la instalación
local 3.3.0 conservando el túnel activo. La firma instalada anterior y la nueva
tienen el mismo requisito designado. Pasaron la lectura real de Gmail y una
conexión posterior con OTP obtenido automáticamente, sin traslado del mensaje.
No se provocó un corte de red; la caída observada durante la sesión no acredita
el comportamiento de recuperación automática, que permaneció desactivada.

Durante la apertura se observó una petición del Llavero clásico y una espera de
`SecItemCopyMatching` en el actor principal. La corrección posterior carga la
cuenta en segundo plano, muestra su comprobación y bloquea las mutaciones hasta
terminar. Las regresiones cubren éxito, denegación y cancelación del consumidor,
con un lector bloqueado de muestra. La intervención del Llavero en macOS 27.2
sigue siendo una limitación: no se certifica Gmail desatendido bajo esa condición.
El candidato corregido 3.4.0 (164), `1ef10d7`, se instaló conservando el túnel.
Su ZIP y delta desde 3.3.0 superaron firmas y checksums; el delta aplicado en una
copia aislada coincidió con el paquete completo. El control y la navegación
respondieron mientras el Llavero esperaba autorización, y la lectura real de
Gmail pasó después de que la persona resolviera el diálogo.

## Papelera y recuperación con una VPN real

Con consentimiento de la persona se autorizó modificación en Google y se activó
temporalmente la recuperación. Se interrumpió solo el túnel de prueba mediante
el ayudante existente. Nuvex inició un intento sin una orden de reconexión, pero
la búsqueda de correo agotó sus 120 segundos. Tras «Volver a buscar» se utilizó
el código del mensaje nuevo; el servidor rechazó la autenticación. El mensaje
se conservó en Recibidos y no se realizó un reintento sin revisar el acceso y
obtener la autorización de la persona. No se determinó la causa del rechazo.

El intento manual posterior autorizado conectó con un código nuevo de Gmail.
Nuvex movió automáticamente ese mensaje a la papelera tras confirmar el túnel.
Se recuperó únicamente ese mensaje mediante «Mover a Recibidos» en Gmail y se
comprobó su presencia en la bandeja; el mensaje del intento fallido se conservó.
La recuperación automática volvió a quedar desactivada y la VPN quedó conectada.

Esto acredita el traslado recuperable en una conexión satisfactoria y la
conservación del correo ante un rechazo. La prueba de recuperación acredita el
inicio de un intento y la recuperación manual posterior; **no** una reconexión
completa desatendida cuando el correo tarda más que el tiempo configurado.

## Comprobaciones físicas o externas pendientes

- Pérdida y recuperación de Internet: la prueba interrumpió el túnel, no la red
  general de la Mac. Quedan también suspensión, bloqueo y reinicio físicos.
- Gmail desatendido cuando el Llavero clásico exige autorización en macOS 27.2.
- VoiceOver, otros equipos, texto ampliado y configuración multimonitor. Las
  capturas y pruebas automáticas no acreditan estos resultados.
- Recurso interno del servidor VPN: se confirmó el túnel, sin certificar aquí
  una aplicación o servicio privado concreto.

Usa `docs/plan-validacion-produccion.md` y `docs/validacion-en-vivo.md` como
procedimiento, adaptando la versión de origen a 3.3.0. No registres correos,
OTP, tokens ni destinos privados. El cierre documental posterior no modifica
el código validado en `1ef10d7`; los metadatos del artefacto final se vuelven a
comprobar en la simulación de su commit exacto.

## Compatibilidad y distribución

Se mantienen `local.gertcode.nuvex`, el protocolo 2, los perfiles y las entradas
del Llavero. No se cambia la identidad «Nuvex Release» ni la clave pública de
Sparkle. No hay cambio del motor incluido en el alcance del código; la
simulación comprueba si puede reutilizar el publicado según la política de
OpenSSL. El canal existente es autofirmado y no notarizado; la distribución
general con Developer ID requiere una migración de firma independiente.
