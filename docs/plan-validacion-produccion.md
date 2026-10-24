# Plan de validación de producción

Este plan valida un candidato sucesor de Nuvex 3.2.1 sin confundir pruebas
automatizadas con resultados de servicios, hardware o cuentas reales. Registra
para cada caso: fecha, versión, compilación, versión de macOS, resultado,
duración y referencia al diagnóstico. No copies contraseñas, tokens, OTP ni
correos completos al reporte.

## Preparación controlada

1. Conserva el ZIP publicado de Nuvex 3.2.1 y un respaldo cifrado de las
   conexiones.
2. Comprueba que no haya una conexión o un código en curso.
3. Anota la firma de 3.2.1 con `codesign -d -r- /Applications/Nuvex.app`.
4. Instala el candidato mediante el flujo normal de actualización, no copiando
   ejecutables sueltos.
5. Confirma que `CFBundleIdentifier` siga siendo `local.gertcode.nuvex`, que el
   requisito designado conserve el mismo certificado y que perfiles, ajustes y
   entradas del Llavero permanezcan disponibles.

## Gmail real

| ID | Escenario | Procedimiento | Resultado esperado |
| --- | --- | --- | --- |
| G-01 | Entrega inmediata | Inicia una conexión y provoca un OTP por correo. | Se usa una vez, sin intervención y sin datos sensibles en el log. |
| G-02 | Entrega retrasada | Retrasa el envío entre 30 y 90 s. | El sondeo cambia de 3 a 5 s, continúa dentro del límite y conecta. |
| G-03 | MIME HTML | Envía un correo cuya parte plana no tenga OTP y cuyo HTML sí. | Nuvex prueba HTML y obtiene el OTP. |
| G-04 | `attachmentId` | Usa un mensaje cuya parte de texto sea externa en la API. | Se consulta `messages.attachments.get` y se obtiene el OTP. |
| G-05 | Duplicado | Entrega dos veces el mismo mensaje o inicia dos VPN simultáneas. | Un ID no se consume dos veces; cada conexión espera su mensaje válido. |
| G-06 | Mensajes inválidos | Envía asunto coincidente sin OTP y después uno válido. | El inválido no se descarga en cada sondeo y el válido posterior se usa. |
| G-07 | Sin red | Desactiva Wi-Fi durante la espera y reactívalo antes del límite. | Se informa fallo transitorio, no hay bucle agresivo y la lectura se recupera. |
| G-08 | Cuota/servidor | Con un proxy de prueba devuelve 429/5xx y `Retry-After`. | No hay petición antes del intervalo indicado y el límite global se respeta. |
| G-09 | Sesión revocada | Revoca Nuvex desde la cuenta de Google. | La renovación termina como permanente y guía a iniciar sesión otra vez. |
| G-10 | Cierre concurrente | Cierra la sesión mientras se renueva OAuth. | No reaparece un access token ni continúa una lectura con la sesión cerrada. |

## Codex, Claude Code y socket

1. Instala versiones funcionales de ambos agentes y reinícialos después de
   pulsar **Preparar** en Ajustes › Automatización.
2. Comprueba que `~/.local/bin/nuvex` apunte al binario de la app instalada y
   que cada agente descubra `nuvex-vpn` desde su directorio de skills.
3. Pulsa **Autorizar** en **Acceso persistente de agentes**, reinicia cada
   agente y ejecuta `~/.local/bin/nuvex estado --json`, `diagnostico` y una
   conexión autorizada. No debe aparecer otra aprobación. Revoca la regla,
   reinicia el agente y confirma que vuelve a solicitarla o devuelve código 7.
   Para un OTP manual, confirma por separado que Claude Code solicita una sola
   aprobación para la tubería y que no se creó una regla global para `printf`.
4. Verifica los códigos 3, 4, 5, 6 y 7 con política denegada, confirmación
   pendiente, timeout, app cerrada y sandbox respectivamente.
5. Crea temporalmente una skill `nuvex-vpn` no gestionada para un agente y deja
   la del otro ausente. **Preparar** debe conservar la ajena y preparar la otra.
6. En una copia de prueba, provoca la terminación de `accept`: el CLI debe
   responder después del reinicio automático y solo debe existir una escucha.
   En otra ejecución elimina la ruta del socket y simula una recuperación de
   red o un despertar; en ese punto debe recrearse y volver a responder.

Inspecciona `~/.codex/rules/nuvex.rules` y las entradas exactas de Claude Code.
No uses `danger-full-access`, `bypassPermissions` ni
`--dangerously-skip-permissions`. La prueba debe demostrar que solo el CLI de
Nuvex sale del sandbox y que las reglas ajenas permanecen intactas.

## Ciclo de vida y conectividad

| ID | Estado | Procedimiento | Resultado esperado |
| --- | --- | --- | --- |
| L-01 | App oculta | Cierra paneles sin terminar Nuvex y consulta desde el CLI. | Socket, estado y conexión siguen disponibles. |
| L-02 | Sesión bloqueada | Bloquea 2 min con una VPN activa. | El túnel continúa; no aparece una petición interactiva imposible de aceptar. |
| L-03 | Reposo físico | Inicia una espera Gmail, suspende 1 min y reactiva. | No se promete trabajo dormido; al despertar se reconcilian socket, túnel y lectura vigente. |
| L-04 | Pérdida de Internet | Retira red con VPN activa y restáurala. | El estado converge sin duplicar procesos ni operaciones. |
| L-05 | Reinicio | Activa “Abrir al iniciar sesión”, reinicia e inicia sesión. | Nuvex arranca una vez, el socket responde y no se reanuda un OTP vencido. |
| L-06 | App cerrada | Termina Nuvex conservando un túnel permitido y vuelve a abrirla. | El estado real se redescubre; no se crea un segundo túnel. |

Durante L-02 y L-03 revisa procesos, descriptores del socket y consumo de CPU
antes y después. No debe quedar una tarea de Gmail, una ventana OTP ni una
reserva remota después de cancelar o agotar el intento.

## Permisos, firma y actualización

1. En una cuenta de macOS de prueba realiza una instalación limpia y registra
   cada diálogo: Gatekeeper, ayudante, notificaciones, Gmail, Touch ID y
   Llavero. Repite conexión y diagnóstico; no deben reaparecer sin revocación o
   cambio del componente protegido.
2. Actualiza una copia firmada de 3.2.1 al candidato. La identidad de firma y el
   identificador deben permanecer iguales. El diagnóstico normal no debe leer
   secretos; `--profundo` debe hacerlo solo con la intervención que macOS exija.
3. Revoca por separado notificaciones, Gmail, inicio automático y acceso a una
   entrada del Llavero. Cada caso debe mostrar una acción concreta sin ampliar
   privilegios ni borrar configuraciones.
4. Verifica el ZIP final con `codesign --verify --deep --strict`, `spctl` y las
   herramientas de Sparkle. Para distribución general fuera de la Mac App
   Store, prueba además Developer ID, hardened runtime y notarización.

## Interfaz y accesibilidad

Ejecuta la ventana OTP en modo claro y oscuro, con teclado solamente, VoiceOver,
texto ampliado y monitores principal/secundario a distintas escalas. Coloca el
cursor y la barra de menús cerca de cada borde. La ventana debe permanecer en
`visibleFrame`, permitir scroll, mantener visibles Cancelar y Conectar y no
flotar sobre menús u otras aplicaciones.

## Criterio de salida

Son bloqueantes: pérdida o reutilización incorrecta de OTP, restauración de un
token tras cerrar sesión, socket inaccesible sin recuperación, regresión de
perfiles o Llavero, firma distinta de 3.2.1, actualización no verificable,
operaciones remotas que ignoren la política y cualquier fuga de secretos.

Una limitación documentada de suspensión real no es un defecto: es aceptable si
el sistema no promete ejecución dormido y converge correctamente al despertar.
