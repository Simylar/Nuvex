# Posible cliente OAuth de Nuvex — propuesta separada

Esta propuesta no está implementada. El refinamiento conserva la integración
actual: cliente de escritorio aportado por la persona, navegador externo,
PKCE, retorno local, Gmail API y credenciales en el Llavero. No se creó un
proyecto de Google, un cliente OAuth ni un servicio externo.

## Beneficio esperado

Un cliente de escritorio propiedad del proyecto Nuvex permitiría ofrecer
**Conectar con Google** sin pedir que cada persona cree un proyecto en Google
Cloud o importe su archivo JSON. La selección de lectura por conexión y el
consentimiento de Google seguirían siendo explícitos. Tener un cliente propio
no concede acceso a una cuenta ni elimina por sí solo los avisos de verificación.

## Trabajo previo a una decisión

1. Definir quién administra el proyecto, sus cuotas, la marca, el dominio, la
   política de privacidad y el soporte. Revisar los requisitos vigentes de Google.
2. Registrar un cliente de tipo **App de escritorio**, conservar PKCE y el
   retorno local compatibles con el flujo nativo. Un cliente distribuido en una
   app de escritorio no puede tratar su secreto incluido como confidencial.
3. Revisar la verificación exigida por `gmail.readonly`, un permiso restringido.
   Las excepciones y obligaciones dependen del uso y la distribución. Un cliente
   común no evita el consentimiento ni las restricciones de administradores de
   Google Workspace.
4. Diseñar una adopción opcional que conserve los clientes personales y sus
   sesiones. Cambiar de cliente puede requerir iniciar sesión y consentir de nuevo;
   no debe migrarse ni invalidarse una cuenta silenciosamente.
5. Probar revocación, cuenta sin permiso, cuota agotada, restricciones de dominio,
   cancelación y recuperación del Llavero. Mantener siempre la entrada manual del
   código como alternativa.

## Límites de la propuesta

No se necesita proponer un servidor que lea o custodie el correo para evaluar
un cliente nativo común. Introducir un servidor ampliaría el alcance y los
requisitos de privacidad. Google exige una evaluación de seguridad en ciertos
casos de acceso a datos restringidos desde o a través de servidores de terceros;
no se presupone que el modelo exclusivamente local requiera lo mismo.

La conveniencia y viabilidad de distribuir el cliente deben decidirse después
de verificar esos requisitos. Esta nota no promete aprobación, coste ni plazo.

## Fuentes oficiales consultadas

- [OAuth para aplicaciones nativas](https://developers.google.com/identity/protocols/oauth2/native-app).
- [Políticas de OAuth](https://developers.google.com/identity/protocols/oauth2/policies).
- [Verificación de permisos restringidos](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification).
- [Problemas de autenticación de Gmail](https://developers.google.com/workspace/gmail/api/troubleshoot-authentication-authorization).
