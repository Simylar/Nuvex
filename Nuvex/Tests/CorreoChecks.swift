import Foundation

/// Comprobaciones de la lectura de códigos de correo y del PKCE de OAuth.
@main
struct CorreoChecks {
    static func main() {
        // Formatos habituales de códigos por correo.
        let casos: [(String, String?)] = [
            ("AuthCode: 123456", "123456"),
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

        print("Correo: comprobaciones superadas")
    }
}
