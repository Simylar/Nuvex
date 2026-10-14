# Componentes de terceros

## openfortivpn

El motor VPN se distribuye con su código fuente en `vendor/openfortivpn/`. Consulta su archivo `LICENSE` (GNU GPL versión 3) y los avisos de autoría de sus archivos. El paquete compilado incluye una copia de esa licencia.

## OpenSSL 3

La compilación incorpora `libssl.3.dylib` y `libcrypto.3.dylib` de la instalación local de `openssl@3` de Homebrew. OpenSSL 3 se distribuye bajo Apache License 2.0. `Nuvex/build.sh` copia el archivo `LICENSE.txt` de esa instalación a `Nuvex.app/Contents/Resources/OpenSSL-LICENSE.txt`, para que la licencia coincida con las bibliotecas efectivamente incluidas.

## Certificado de CA

`Nuvex/Resources/prepa-ca-bundle.pem` contiene certificados de CA públicos, incluida la CA intermedia RapidSSL TLS RSA CA G1, para compatibilidad con la cadena TLS de un servidor concreto. No contiene claves privadas. Selecciónalo solo si corresponde al servidor que configuras.
