import Foundation

/// Comprobaciones de la lectura de códigos de correo y del PKCE de OAuth.
@main
struct CorreoChecks {
    static func main() {
        // Formatos habituales de códigos por correo.
        let casos: [(String, String?)] = [
            ("AuthCode: 123456", "123456"),
            // Correo real de FortiToken: el asunto y el cuerpo, con un cero inicial.
            ("AuthCode: 043051\nYour authentication token code is 043051.", "043051"),
            ("Your authentication token code is 043051.", "043051"),
            ("Tu código de verificación es 654321. Caduca en 5 minutos.", "654321"),
            ("Your FortiToken code is: 482913", "482913"),
            ("Su clave temporal: 4821", "4821"),
            ("Token valid for 10 minutes: 112233", "112233"),
            ("Acceso del 2026-10-17 a las 10:31. Use 135790 para continuar.", "135790"),
            ("Pedido 123456 y referencia 654321", nil),
            ("Hola, no hay ningún número aquí.", nil),
        ]
        for (texto, esperado) in casos {
            let obtenido = ExtractorCodigo.extraer(de: texto)
            precondition(obtenido == esperado, "«\(texto)» → \(obtenido ?? "nil"), se esperaba \(esperado ?? "nil")")
        }
        let html = "<html><style>p{color:red}</style><body><p>C&oacute;digo de acceso:</p><p><b>778899</b></p><p>Ref. 2026</p></body></html>"
        let texto = ExtractorCodigo.textoDesdeHTML(html)
        precondition(!texto.contains("<") && !texto.contains("color"))
        precondition(ExtractorCodigo.extraer(de: texto) == "778899")
        precondition(ExtractorCodigo.extraer(de: "PIN 9988, ref 112233", patron: #"PIN (\d+)"#) == "9988")
        precondition(ExtractorCodigo.patronValido(#"codigo (\d{6})"#))
        precondition(!ExtractorCodigo.patronValido("("))
        precondition(ExtractorCodigo.patronValido(""))
        precondition(ExtractorCodigo.enmascarar("482913") == "48••13")
        precondition(ExtractorCodigo.enmascarar("1234") == "••••")

        // La configuración de Fortinet que se propone por defecto encuentra ese correo.
        precondition(ConfigCorreo.fortinet.remitente == "DoNotReply@notification.fortinet.net")
        precondition(ExtractorCodigo.consultaGmail(remitente: ConfigCorreo.fortinet.remitente,
                                                   asunto: ConfigCorreo.fortinet.asunto, desde: Date(timeIntervalSince1970: 100))
                     == "from:(DoNotReply@notification.fortinet.net) after:70 subject:(AuthCode)")

        // Búsqueda de Gmail.
        let desde = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(ExtractorCodigo.consultaGmail(remitente: " noreply@empresa.com ", asunto: "", desde: desde)
                     == "from:(noreply@empresa.com) after:1799999970")
        precondition(ExtractorCodigo.consultaGmail(remitente: "a@b.c", asunto: "AuthCode", desde: desde)
                     .hasSuffix("subject:(AuthCode)"))

        // PKCE: vector de ejemplo del RFC 7636, apéndice B.
        precondition(ExtractorCodigo.desafioPKCE("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                     == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verificador = ExtractorCodigo.verificadorPKCE()
        precondition(verificador.count == 43 && verificador != ExtractorCodigo.verificadorPKCE())
        precondition(!verificador.contains("+") && !verificador.contains("/") && !verificador.contains("="))

        // Base64 url y correo del id_token.
        let carga = ExtractorCodigo.codificarBase64URL(Data(#"{"email":"samuel@gmail.com","sub":"1"}"#.utf8))
        precondition(ExtractorCodigo.correoDeIDToken("e30.\(carga).firma") == "samuel@gmail.com")
        precondition(ExtractorCodigo.correoDeIDToken("no-es-un-token") == nil)
        precondition(String(decoding: ExtractorCodigo.decodificarBase64URL("SG9sYQ")!, as: UTF8.self) == "Hola")

        // Errores de Gmail: cada uno con su explicación y su salida.
        func cuerpo(_ json: String) -> Data { Data(json.utf8) }
        precondition(ProblemaGmail.clasificar(estado: 403, cuerpo: cuerpo(#"{"error":{"code":403,"message":"Gmail API has not been used in project 123 before or it is disabled.","status":"PERMISSION_DENIED","details":[{"reason":"SERVICE_DISABLED"}]}}"#)) == .apiDesactivada)
        precondition(ProblemaGmail.clasificar(estado: 403, cuerpo: cuerpo(#"{"error":{"code":403,"errors":[{"reason":"accessNotConfigured"}]}}"#)) == .apiDesactivada)
        precondition(ProblemaGmail.clasificar(estado: 403, cuerpo: cuerpo(#"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#)) == .sinPermiso)
        precondition(ProblemaGmail.clasificar(estado: 429, cuerpo: cuerpo("{}")) == .limite)
        precondition(ProblemaGmail.clasificar(estado: 403, cuerpo: cuerpo(#"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#)) == .limite)
        precondition(ProblemaGmail.clasificar(estado: 500, cuerpo: cuerpo("no es json")) == .servidor(500))
        precondition(ProblemaGmail.clasificarToken("invalid_grant") == .sesionCaducada)
        precondition(ProblemaGmail.clasificarToken("invalid_client") == .clienteNoValido)
        precondition(ProblemaGmail.clasificar(URLError(.notConnectedToInternet)) == .sinRed)
        precondition(ProblemaGmail.apiDesactivada.definitivo && ProblemaGmail.sesionCaducada.definitivo)
        precondition(!ProblemaGmail.sinRed.definitivo && !ProblemaGmail.limite.definitivo)
        precondition(ProblemaGmail.servidor(0).detalle.hasPrefix("Google devolvió un error inesperado."))

        print("Correo: comprobaciones superadas")
    }
}
