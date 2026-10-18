# Dónde guarda Nuvex tus datos

Nada de lo que configuras vive dentro de `Nuvex.app`. Por eso actualizar, reinstalar o volver a una versión anterior no borra conexiones, contraseñas ni ajustes.

| Dato | Ubicación | Notas |
| --- | --- | --- |
| Conexiones (servidor, usuario, opciones) | `~/.config/nuvex/profiles.json` | Sin contraseñas. Lo valida `nuvexconfig.py` y su huella forma parte del ayudante. |
| Contraseñas VPN | Llavero de inicio de sesión, servicio `nuvex.<id>` | Nunca en archivos ni en argumentos de procesos. |
| Ajustes propios de la app | `~/Library/Application Support/Nuvex/ajustes.json` | Código por correo, permisos de asistentes. Carpeta 0700, archivo 0600. |
| Copias de seguridad | `~/Library/Application Support/Nuvex/Copias/` | Una antes de cada versión nueva; se conservan 10. Sin contraseñas. |
| Versiones anteriores de la app | `~/Library/Application Support/Nuvex/Versiones/` | Las guarda `scripts/instalar.sh`; se conservan 3. |
| Preferencias de la interfaz | UserDefaults `local.gertcode.nuvex` | Avisos, intervalo, Touch ID, actualizaciones. |
| Ayudante y motor | `/Library/PrivilegedHelperTools/Nuvex` | Instalado con autorización de administrador. |
| Registro | `~/Library/Logs/Nuvex.log` | Nunca incluye contraseñas ni códigos. |

## Reglas que no cambian entre versiones

1. El identificador de la app es siempre `local.gertcode.nuvex`. Cambiarlo dejaría huérfanas las preferencias, los avisos y los permisos del Llavero.
2. El `id` de cada conexión no cambia nunca: enlaza el perfil con su contraseña del Llavero.
3. `profiles.json` no recibe campos nuevos. El ayudante firma su contenido completo, así que cualquier campo nuevo obligaría a todos a reautorizarlo. Lo nuevo va a `ajustes.json`.
4. `ajustes.json` lleva `version`. Las claves que una versión no conoce se ignoran al leer y se conservan al escribir. Si los datos son de una versión más nueva, la app los abre en modo de solo lectura.
5. Si algún día `profiles.json` necesita cambiar, será con `version: 3`, una migración probada en `nuvexconfig.py`, copia previa automática y una versión marcada como «requiere autorizar el ayudante».
6. Los nombres de servicio del Llavero (`nuvex.<id>`) no se renombran.

## Volver atrás

- Configuración: Ajustes › General › Copias de seguridad › Restaurar. Antes de restaurar se guarda una copia del estado actual.
- App: `Nuvex/scripts/revertir.sh` vuelve a la versión anterior guardada por el instalador.
- Contraseñas: para una copia completa, exporta tus conexiones cifradas.
