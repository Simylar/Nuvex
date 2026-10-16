# Validación en vivo de una VPN Fortinet

Esta prueba requiere acceso autorizado a un servidor Fortinet SSL VPN compatible con `openfortivpn` y a un recurso interno de ese entorno. Cada servidor puede exigir un método de autenticación, certificado o configuración de red distinto. No guardes servidores privados, usuarios, contraseñas, códigos ni destinos internos en Git.

1. Configura la VPN desde Nuvex, incluida su confianza TLS, usuario y opciones de rutas y DNS. Guarda la configuración.
2. Desconecta las demás VPN de Nuvex para poder atribuir la ruta al perfil que vas a probar. Conecta ese perfil y completa cualquier código que solicite el servidor.
3. Desde la raíz del repositorio, ejecuta:

   ```sh
   python3 tests/live_vpn_check.py ID_DEL_PERFIL --status-only
   python3 tests/live_vpn_check.py ID_DEL_PERFIL --host HOST_INTERNO --port PUERTO_TCP
   ```

   `HOST_INTERNO` debe ser un host o IP de un servicio interno que tengas permiso de consultar, sin esquema `https://`, ruta ni credenciales. El comprobador no imprime el destino ni lee la contraseña o el código VPN. Respeta `XDG_CONFIG_HOME` si está definido; en otro caso utiliza `~/.config` del usuario real de macOS.

4. Confirma en la aplicación o con el responsable de la red que el servicio respondió como se esperaba. Si el recurso usa HTTP o una API, una conexión TCP solo demuestra que el puerto respondió; comprueba también la operación propia de ese servicio con una herramienta autorizada.

`--status-only` confirma únicamente que el ayudante de Nuvex informa un túnel activo. Sale con código **2** para señalar que falta comprobar un recurso. La prueba con `--host` y `--port` sale con **0** solo si el perfil está activo, ninguna otra VPN de Nuvex lo está, el destino resuelve, macOS elige una interfaz `pppN` para su ruta y el puerto TCP acepta la conexión. Sale con **1** si no puede completar esa verificación. No demuestra por sí sola que el tráfico provenga del perfil elegido si hay otras VPN fuera de Nuvex usando interfaces PPP; desconéctalas para esta prueba.

Repite el procedimiento con cada servidor distinto que quieras declarar compatible. Para comprobar dos VPN simultáneas, vuelve a conectar ambas y revisa por separado los recursos, rutas y DNS esperados de cada una; el comprobador automatizado exige una sola VPN de Nuvex y no cubre la convivencia.

El modo túnel SSL VPN fue retirado de FortiOS 7.6.3 y versiones posteriores según [las notas de Fortinet](https://docs.fortinet.com/document/fortigate/7.6.3/fortios-release-notes/173430/ssl-vpn-tunnel-mode-replaced-with-ipsec-vpn). Para esos equipos, esta prueba y Nuvex no ofrecen ese modo de conexión.
