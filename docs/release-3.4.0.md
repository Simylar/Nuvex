# Nuvex 3.4.0 — Candidato de publicación

Las novedades para quien usa la app están en `CHANGELOG.md`. Este documento
registra el alcance y los pendientes del candidato; no acredita su publicación.
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

## Pendientes antes de la salida estable

- Actualización controlada desde 3.3.0, verificando perfiles, preferencias,
  acceso al Llavero y el mismo requisito de firma.
- Gmail real: opción inicialmente desactivada, persistencia de la elección,
  consentimiento de modificación, traslado del mensaje correcto solo tras
  confirmar el túnel y recuperación desde la papelera. Cancelar o fallar una
  conexión debe conservar el mensaje.
- Caída real de red: un intento de recuperación, cancelación efectiva,
  conservación del aviso y ausencia de diálogos inesperados en segundo plano.
- Interacción con los diálogos del Llavero y revisión de accesibilidad con
  VoiceOver. Las capturas y pruebas automáticas no acreditan esos resultados.

Usa `docs/plan-validacion-produccion.md` y `docs/validacion-en-vivo.md` como
procedimiento, adaptando la versión de origen a 3.3.0. Registra los resultados
del candidato exacto sin incluir correos, OTP, tokens ni destinos privados.

## Compatibilidad y distribución

Se mantienen `local.gertcode.nuvex`, el protocolo 2, los perfiles y las entradas
del Llavero. No se cambia la identidad «Nuvex Release» ni la clave pública de
Sparkle. No hay cambio del motor incluido en el alcance del código; la
simulación comprueba si puede reutilizar el publicado según la política de
OpenSSL. El canal existente es autofirmado y no notarizado; la distribución
general con Developer ID requiere una migración de firma independiente.
