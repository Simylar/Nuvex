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
        precondition(ExtractorCodigo.codigoValido("A9-42"))
        precondition(!ExtractorCodigo.codigoValido(""))
        precondition(!ExtractorCodigo.codigoValido(String(repeating: "1", count: 65)))
        precondition(!ExtractorCodigo.codigoValido("123\n456"))
        precondition(ExtractorCodigo.extraer(de: String(repeating: "A", count: 65),
                                             patron: #"(A+)"#) == nil)
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

        // Gmail puede entregar una parte de texto inline o mediante
        // attachmentId, incluso sin que sea un archivo adjunto visible.
        let mime: [String: Any] = [
            "mimeType": "multipart/alternative",
            "parts": [
                ["mimeType": "text/plain", "body": ["attachmentId": "texto-1", "size": 42]],
                ["mimeType": "text/html", "body": ["data": ExtractorCodigo.codificarBase64URL(Data("<b>123456</b>".utf8)), "size": 13]],
                ["mimeType": "image/png", "body": ["attachmentId": "imagen", "size": 2_000]],
            ],
        ]
        let partes = SoporteGmail.partesTexto(en: mime)
        precondition(partes.count == 2)
        precondition(partes[0] == ParteTextoGmail(formato: .plano, datos: nil, adjuntoID: "texto-1", tamano: 42))
        precondition(SoporteGmail.texto(datosBase64URL: [
            ExtractorCodigo.codificarBase64URL(Data("AuthCode: 246810".utf8)),
        ], formato: .plano) == "AuthCode: 246810")
        precondition(SoporteGmail.extraerCodigo(asunto: "AuthCode", cuerpo: "Este cuerpo no incluye cifras",
                                                patron: "") == nil)
        precondition(SoporteGmail.extraerCodigo(asunto: "AuthCode", cuerpo: "<b>975310</b>",
                                                patron: "") == "975310",
                     "si la parte plana no tiene código se debe poder probar la variante HTML")
        let fragmentoGrande = ExtractorCodigo.codificarBase64URL(
            Data(String(repeating: "a", count: SoporteGmail.maximoBytesTexto / 2 + 1).utf8))
        let textoAcotado = SoporteGmail.texto(datosBase64URL: [fragmentoGrande, fragmentoGrande], formato: .plano)
        precondition(textoAcotado.utf8.count <= SoporteGmail.maximoBytesTexto,
                     "el límite se aplica al cuerpo completo, no a cada fragmento por separado")
        let demasiadoGrande: [String: Any] = [
            "mimeType": "text/plain",
            "body": ["attachmentId": "enorme", "size": SoporteGmail.maximoBytesTexto + 1],
        ]
        precondition(SoporteGmail.partesTexto(en: demasiadoGrande).isEmpty)

        // Un mensaje nuevo sin código se relee de forma acotada: Gmail puede
        // haber listado su ID antes de terminar de propagar las partes MIME.
        var inspeccion = RegistroInspeccionGmail()
        precondition(!inspeccion.excluidos(usados: []).contains("nuevo"))
        inspeccion.registrarSinCodigo(["nuevo"])
        inspeccion.registrarSinCodigo(["nuevo"])
        precondition(!inspeccion.excluidos(usados: []).contains("nuevo"))
        inspeccion.registrarSinCodigo(["nuevo"])
        precondition(inspeccion.excluidos(usados: []).contains("nuevo"),
                     "un mensaje sin código no debe releerse indefinidamente")
        inspeccion.descartar(["antiguo"])
        precondition(inspeccion.excluidos(usados: []).contains("antiguo"))
        precondition(inspeccion.excluidos(usados: ["usado"]).contains("usado"))

        // Sondeo normal y backoff truncado, con jitter y Retry-After.
        precondition(SoporteGmail.pausaSinCorreo(segundosTranscurridos: 0) == 3)
        precondition(SoporteGmail.pausaSinCorreo(segundosTranscurridos: 45) == 5)
        precondition(SoporteGmail.pausaSinCorreo(segundosTranscurridos: 120) == 8)
        precondition(SoporteGmail.pausaTrasError(fallosConsecutivos: 1, problema: .sinRed, jitter: 0) == 1)
        precondition(SoporteGmail.pausaTrasError(fallosConsecutivos: 4, problema: .sinRed, jitter: 0.5) == 8.5)
        precondition(SoporteGmail.pausaTrasError(fallosConsecutivos: 1, problema: .limite, jitter: 0) == 5)
        precondition(SoporteGmail.pausaTrasError(fallosConsecutivos: 8, problema: .limite, jitter: 1) == 30)
        precondition(SoporteGmail.pausaTrasError(fallosConsecutivos: 1, problema: .sinRed,
                                                retryAfter: 17, jitter: 0) == 17)
        precondition(SoporteGmail.pausaTrasError(fallosConsecutivos: 1, problema: .limite,
                                                retryAfter: 120, jitter: 0) == 120,
                     "Retry-After no se acorta; el límite global se aplica al dormir")
        precondition(SoporteGmail.retryAfter("12") == 12)
        let fechaHTTP = Date(timeIntervalSince1970: 1_800_000_030)
        precondition(SoporteGmail.retryAfter("Fri, 15 Jan 2027 08:00:30 GMT",
                                             ahora: Date(timeIntervalSince1970: 1_800_000_000)) == fechaHTTP.timeIntervalSince1970 - 1_800_000_000)

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
        precondition(ProblemaGmail.sinRed.codigoDiagnostico == "sin_red")
        precondition(ProblemaGmail.apiDesactivada.definitivo && ProblemaGmail.sesionCaducada.definitivo)
        precondition(!ProblemaGmail.sinRed.definitivo && !ProblemaGmail.limite.definitivo)
        precondition(ProblemaGmail.servidor(0).detalle.hasPrefix("Google devolvió un error inesperado."))

        print("Correo: comprobaciones superadas")
    }
}
