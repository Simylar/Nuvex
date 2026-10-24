# Nuvex 3.3.0 — Resumen técnico de release

Este documento acompaña las notas orientadas al usuario de `CHANGELOG.md`. El
commit, build, hashes y canal definitivos se obtienen del
`release-manifest.txt` y `SHA256SUMS` generados por
`Nuvex/scripts/publicar.sh --simular`; no se escriben a mano aquí para evitar
que un commit documental deje esos datos obsoletos.

## Alcance desde 3.2.1

- Sistema visual nativo unificado, temas claro y oscuro, ventana OTP adaptable
  e icono de aplicación validado en todas las escalas.
- Gmail con recorrido MIME, adjuntos, HTML, selección temporal, deduplicación,
  reintentos acotados, `Retry-After` y cancelación segura de OAuth.
- CLI y socket con protocolo 2 compatible, identidad mediante audit token,
  recuperación de escucha y resolución del hogar real del usuario.
- Onboarding de un clic para Codex y Claude Code, reglas persistentes acotadas,
  revocación y sincronización conservadora de skills gestionadas.
- Reconciliación al recuperar red o despertar, cancelación consistente de
  conexiones y conservación del motor previamente autorizado.

## Evidencia real disponible

- Actualización controlada desde Nuvex 3.2.1 conservando perfiles,
  preferencias y accesos existentes al Llavero.
- Dos conexiones consecutivas reales de «Prepa en Línea», incluida la lectura
  automática de dos OTP de Gmail y la desconexión final del túnel.
- Codex Desktop descubrió la skill en una sesión nueva y ejecutó el CLI con la
  regla persistente acotada, sin una aprobación redundante.
- El CLI instalado, el socket privado y el ayudante vigente respondieron al
  diagnóstico; el motor instalado coincidió byte por byte con el empaquetado.

Estas comprobaciones corresponden al entorno personal utilizado durante la
estabilización. No sustituyen una matriz de equipos externos.

## Cobertura automatizada

Las pruebas cubren núcleo, correo, geometría, permisos de agentes, socket,
ciclo de app, preferencias de seguridad, exportación, rollback, SemVer,
contrato del appcast, firma EdDSA, deltas y actualización E2E con interrupción
o alteración. El pipeline vuelve a ejecutarlas antes de generar artefactos.

## Validaciones que siguen siendo físicas o externas

- Claude Code real requiere una instalación iniciada y funcional; la máquina
  de certificación tenía su sesión pendiente y una dependencia externa de Node
  dañada, por lo que solo se validaron sus reglas y archivos de configuración.
- Bloqueo de sesión, pantalla apagada, suspensión física/reactivación, reinicio
  de macOS y pérdida/recuperación de Internet deben registrarse manualmente.
- Una instalación limpia en otra Mac, accesibilidad con VoiceOver, texto
  ampliado y una configuración multimonitor requieren hardware o intervención.
- La distribución pública requiere Developer ID, Hardened Runtime, timestamp y
  notarización. La identidad autofirmada actual solo cubre el canal privado.

## Compatibilidad y rollback

Los artefactos oficiales actuales requieren Apple Silicon (`arm64`) y macOS 14
o posterior; no se certifica una instalación Intel. No cambian el bundle ID,
el protocolo 2, el formato de perfiles ni el modelo de datos del Llavero. El
ZIP completo siempre acompaña a cualquier delta. El instalador conserva una
copia recuperable y valida firma, versión, apertura y socket antes de confirmar
el reemplazo.
