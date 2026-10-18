import CryptoKit
import Security
import Foundation

/// Lógica sin red ni interfaz para leer códigos de verificación de correos y
/// para el inicio de sesión OAuth con PKCE. Se prueba por separado.
enum ExtractorCodigo {
    /// Primero busca un número cerca de palabras como «código» o «token».
    static let patronCercano = #"(?i)(?:c[oó]digo|code|token|authcode|clave|passcode|otp|pin)\D{0,40}?(\d{4,8})\b"#
    /// Si no lo encuentra, acepta un único número de 6 dígitos en todo el texto.
    static let patronSeisDigitos = #"(?<!\d)(\d{6})(?!\d)"#

    /// Código encontrado en el texto, o nil si no hay uno inequívoco.
    static func extraer(de texto: String, patron personalizado: String = "") -> String? {
        if !personalizado.trimmingCharacters(in: .whitespaces).isEmpty {
            return primeraCoincidencia(personalizado, en: texto)
        }
        if let codigo = primeraCoincidencia(patronCercano, en: texto) { return codigo }
        let seis = coincidencias(patronSeisDigitos, en: texto)
        return Set(seis).count == 1 ? seis.first : nil
    }

    /// true si el patrón personalizado es una expresión regular válida.
    static func patronValido(_ patron: String) -> Bool {
        patron.trimmingCharacters(in: .whitespaces).isEmpty || (try? NSRegularExpression(pattern: patron)) != nil
    }

    /// «482913» → «48••13», para mostrarlo sin revelarlo.
    static func enmascarar(_ codigo: String) -> String {
        guard codigo.count > 4 else { return String(repeating: "•", count: codigo.count) }
        return String(codigo.prefix(2)) + String(repeating: "•", count: codigo.count - 4) + String(codigo.suffix(2))
    }

    private static func primeraCoincidencia(_ patron: String, en texto: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: patron),
              let resultado = regex.firstMatch(in: texto, range: NSRange(texto.startIndex..., in: texto)) else { return nil }
        let grupo = resultado.numberOfRanges > 1 ? 1 : 0
        guard let rango = Range(resultado.range(at: grupo), in: texto) else { return nil }
        let codigo = String(texto[rango]).trimmingCharacters(in: .whitespaces)
        return codigo.isEmpty ? nil : codigo
    }

    private static func coincidencias(_ patron: String, en texto: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: patron) else { return [] }
        return regex.matches(in: texto, range: NSRange(texto.startIndex..., in: texto)).compactMap {
            Range($0.range(at: 1), in: texto).map { String(texto[$0]) }
        }
    }

    // MARK: Correo

    /// Búsqueda de Gmail: remitente, correos recibidos desde el inicio del
    /// intento (con 30 s de margen) y, si se indica, palabras del asunto.
    static func consultaGmail(remitente: String, asunto: String, desde: Date) -> String {
        var partes = ["from:(\(remitente.trimmingCharacters(in: .whitespaces)))",
                      "after:\(Int(desde.timeIntervalSince1970) - 30)"]
        let asunto = asunto.trimmingCharacters(in: .whitespaces)
        if !asunto.isEmpty { partes.append("subject:(\(asunto))") }
        return partes.joined(separator: " ")
    }

    /// Texto legible de un correo HTML: sin etiquetas, estilos ni entidades.
    static func textoDesdeHTML(_ html: String) -> String {
        var texto = html
        for patron in [#"(?is)<(script|style)[^>]*>.*?</\1>"#, #"(?i)<br\s*/?>"#, #"(?i)</(p|div|tr|li|h\d)>"#] {
            texto = texto.replacingOccurrences(of: patron, with: "\n", options: .regularExpression)
        }
        texto = texto.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entidades = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                         "&oacute;": "ó", "&aacute;": "á", "&eacute;": "é", "&iacute;": "í", "&uacute;": "ú", "&ntilde;": "ñ"]
        for (entidad, valor) in entidades { texto = texto.replacingOccurrences(of: entidad, with: valor) }
        return texto.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
    }

    /// Base64 «url» de Gmail y de los tokens JWT, sin relleno.
    static func decodificarBase64URL(_ texto: String) -> Data? {
        var base = texto.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base.append("=") }
        return Data(base64Encoded: base)
    }

    static func codificarBase64URL(_ datos: Data) -> String {
        datos.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: OAuth

    /// Desafío PKCE S256 (RFC 7636) para un verificador.
    static func desafioPKCE(_ verificador: String) -> String {
        codificarBase64URL(Data(SHA256.hash(data: Data(verificador.utf8))))
    }

    /// Verificador PKCE aleatorio de 43 caracteres.
    static func verificadorPKCE() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return codificarBase64URL(Data(bytes))
    }

    /// Correo de la cuenta en el id_token que devuelve Google.
    static func correoDeIDToken(_ token: String) -> String? {
        let partes = token.split(separator: ".")
        guard partes.count >= 2, let datos = decodificarBase64URL(String(partes[1])),
              let reclamos = try? JSONSerialization.jsonObject(with: datos) as? [String: Any] else { return nil }
        return reclamos["email"] as? String
    }
}
