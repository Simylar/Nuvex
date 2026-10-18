# Publicar versiones de Nuvex

Nuvex se actualiza con [Sparkle](https://sparkle-project.org). Cada versión se publica en GitHub Releases y la app la descubre mediante `appcast.xml`, servido desde GitHub Pages. Sparkle verifica la firma EdDSA de cada actualización antes de instalarla.

## Configuración única

En la Mac desde la que publicas:

```sh
Nuvex/scripts/configurar-publicacion.sh
```

El script crea dos claves en tu llavero de inicio de sesión:

- **Identidad «Nuvex Release»**: certificado autofirmado de firma de código, válido 10 años. Firmar siempre con la misma identidad hace que el Llavero no vuelva a pedir permiso a Nuvex tras cada actualización.
- **Clave EdDSA de Sparkle**: firma cada actualización. Su parte pública se guarda en `Nuvex/Resources/sparkle_ed_public_key` y viaja con el código.

Deja una copia de cada una en el Escritorio. Guárdalas en tu gestor de contraseñas y bórralas del Escritorio. **Si se pierden**, las apps ya instaladas no aceptarán versiones firmadas con claves nuevas y habrá que reinstalar Nuvex a mano.

Para publicar desde otra Mac, importa ambas copias:

```sh
security import Nuvex-Release-certificado.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
Nuvex/.build/artifacts/sparkle/Sparkle/bin/generate_keys -f Nuvex-EdDSA-clave-privada.txt
```

## Publicación automática con GitHub Actions

`.github/workflows/publicar.yml` publica cada versión cuando se sube una etiqueta `vX.Y.Z`. Usa tres secretos del repositorio, que guarda `configurar-publicacion.sh`:

- `NUVEX_CERTIFICADO_P12` y `NUVEX_CERTIFICADO_FRASE`: el certificado «Nuvex Release» y su frase, que se importan en un llavero temporal que se borra al terminar.
- `SPARKLE_ED_PRIVATE_KEY`: la clave que firma el appcast y cada actualización. Llega a `generate_appcast` por la entrada estándar.

El flujo pasa las pruebas, compila, firma, crea el GitHub Release y actualiza `appcast.xml` en la rama `gh-pages`. Una etiqueta cuyo mensaje contenga «beta» se publica en el canal beta.

## Publicar una versión

1. Sube la versión en `Nuvex/VERSION` (formato X.Y.Z).
2. En `CHANGELOG.md`, escribe la sección `## [X.Y.Z] - AAAA-MM-DD` con las novedades en lenguaje para quien usa la app. Es lo que verá en «Actualización de software» y en «Novedades».
3. Haz commit en `main`.
4. Comprueba que todo funciona sin subir nada:

   ```sh
   Nuvex/scripts/publicar.sh --simular
   ```

5. Publica:

   ```sh
   Nuvex/scripts/publicar.sh
   ```

   El script repite las comprobaciones y sube la etiqueta; GitHub Actions hace el resto. Sigue el progreso con `gh run watch`. Con `--beta`, la versión solo llega a quienes activan «Recibir versiones beta». Con `--local`, se compila y publica desde tu Mac sin GitHub Actions.

El script exige el árbol limpio, una versión mayor que la última etiqueta, las notas en el CHANGELOG y todas las pruebas en verde. También se niega a publicar si el motor `openfortivpn` cambió sin cambios en `vendor/openfortivpn`, porque un motor distinto obliga a todos a reautorizar el ayudante.

## Qué ve quien tiene Nuvex instalado

- Nuvex busca una vez al día. Si hay versión nueva, aparece un aviso en el panel y en el Centro de notificaciones, sin ventanas inesperadas.
- «Actualización de software» muestra la versión, su tamaño, las novedades y el botón «Actualizar ahora», con el progreso de descarga e instalación.
- Las VPN activas siguen conectadas durante la actualización. Si hay una conexión o un código en curso, el reinicio espera a que termine.
- Al abrirse, la versión nueva muestra sus novedades.

## Sin Developer ID

Nuvex no está notarizada. La primera instalación en cada Mac se aprueba una vez en Ajustes del Sistema › Privacidad y seguridad › «Abrir igualmente». Las actualizaciones posteriores las instala Sparkle tras verificar su firma y no vuelven a pedirlo. Con una cuenta del Apple Developer Program, basta cambiar la identidad en `publicar.sh` y añadir `notarytool submit --wait` y `stapler staple`.
