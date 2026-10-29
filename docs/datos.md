# Dónde guarda Nuvex tus datos

Nada de lo que configuras vive dentro de `Nuvex.app`. Por eso actualizar, reinstalar o volver a una versión anterior no borra conexiones, contraseñas ni ajustes.

| Dato | Ubicación | Notas |
| --- | --- | --- |
| Conexiones (servidor, usuario, opciones) | `~/.config/nuvex/profiles.json` | Sin contraseñas. Lo valida `nuvexconfig.py` y su huella forma parte del ayudante. |
| Contraseñas VPN | Llavero de inicio de sesión, servicio `nuvex.<id>` | Etiqueta visible `Nuvex: <nombre de la VPN>`. Nunca en archivos ni en argumentos de procesos. |
| Ajustes propios de la app | `~/Library/Application Support/Nuvex/ajustes.json` | Esquema 3: correo, política, exclusiones y recibo/revocación de capacidades internas. Carpeta 0700, archivo 0600. |
| Copias de seguridad | `~/Library/Application Support/Nuvex/Copias/` | Una antes de cada versión nueva; se conservan 10. Sin contraseñas. |
| Versiones anteriores de la app | `~/Library/Application Support/Nuvex/Versiones/` | Archivos ZIP guardados por `scripts/instalar.sh`; se conservan 3. |
| Preferencias de la interfaz | UserDefaults `local.gertcode.nuvex` | Avisos, intervalo, Touch ID, actualizaciones. |
| Ayudante y motor | `/Library/PrivilegedHelperTools/Nuvex` | Instalado con autorización de administrador. |
| Registro | `~/Library/Logs/Nuvex.log` | Nunca incluye contraseñas ni códigos. Se rota a una generación al alcanzar 2 MB. |
| Regla de Codex (opcional) | `~/.codex/rules/nuvex.rules` | Gestionada y revocable por Nuvex; autoriza solo el prefijo estable de su CLI. |
| Regla de Claude Code (opcional) | Entradas concretas de `~/.claude/settings.json` | Se mezclan sin borrar otras claves; permiten y excluyen del sandbox solo el CLI. |

## Reglas que no cambian entre versiones

1. El identificador de la app es siempre `local.gertcode.nuvex`. Cambiarlo dejaría huérfanas las preferencias, los avisos y los permisos del Llavero.
2. El `id` de cada conexión no cambia nunca: enlaza el perfil con su contraseña del Llavero.
3. `profiles.json` no recibe campos nuevos. El ayudante firma su contenido completo, así que cualquier campo nuevo obligaría a todos a reautorizarlo. Lo nuevo va a `ajustes.json`.
4. `ajustes.json` lleva `version`. Las claves que una versión no conoce se ignoran al leer y se conservan al escribir. Si los datos son de una versión más nueva, la app los abre en modo de solo lectura.
5. Si algún día `profiles.json` necesita cambiar, será con `version: 3`, una migración probada en `nuvexconfig.py`, copia previa automática y una versión marcada como «requiere autorizar el ayudante».
6. Los nombres de servicio del Llavero (`nuvex.<id>`) no se renombran.

Solo la ausencia de `ajustes.json` inicia valores de serie. Un archivo vacío,
corrupto o con una versión de esquema inválida bloquea cambios hasta repararlo;
no se sobrescribe como si fuera una instalación nueva.

## Volver atrás

- Configuración: Ajustes › General › Copias de seguridad › Restaurar. Se valida la copia completa antes de modificar datos y se guarda una copia del estado actual. Se recuperan conexiones y configuración del lector de códigos, conservando las autorizaciones, revocaciones y exclusiones actuales. Si la copia no contiene ajustes, se conserva el lector actual de las conexiones recuperadas.
- App: `Nuvex/scripts/revertir.sh` vuelve a la versión anterior guardada por el instalador.
- Contraseñas: para una copia completa, exporta tus conexiones cifradas.

La restauración escribe perfiles y después ajustes. Si falla el segundo paso,
intenta recuperar los perfiles anteriores; solo después de persistir ambos
archivos retira las contraseñas de conexiones eliminadas. Si también falla esa
recuperación, informa del estado indeterminado y remite a «Antes de restaurar».
La copia previa no incluye contraseñas ni permite recuperar una contraseña ya
eliminada; el diálogo advierte antes de retirar conexiones y sus contraseñas.
Un cierre forzado o corte de energía entre los dos archivos todavía puede
requerir recuperación manual: no existe una transacción duradera entre ellos.
