import Foundation

/// Convierte notas HTML a texto sin cargar recursos, ejecutar contenido ni
/// depender de WebKit. Está limitado deliberadamente a la presentación de
/// notas de versión y no pretende ser un navegador ni un sanitizador HTML.
enum TextoHTMLSeguro {
    static func convertir(_ html: String) -> String {
        var texto = html.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        texto = reemplazar(#"<!--.*?(?:-->|$)"#, en: texto, con: "")
        for etiqueta in ["script", "style", "head", "svg", "iframe", "object", "noscript"] {
            texto = reemplazar(
                #"<\s*"# + etiqueta + #"\b[^>]*>.*?(?:<\s*/\s*"# + etiqueta + #"\s*>|$)"#,
                en: texto, con: "")
        }
        texto = reemplazar(#"<\s*br\b[^>]*>"#, en: texto, con: "\n")
        texto = reemplazar(#"<\s*li\b[^>]*>"#, en: texto, con: "\n• ")
        texto = reemplazar(
            #"<\s*/\s*(?:p|div|li|h[1-6]|tr|blockquote|section|article|ul|ol)\s*>"#,
            en: texto, con: "\n")
        texto = reemplazar(#"<[^>]*>"#, en: texto, con: "")
        texto = decodificarEntidades(texto)

        var lineas: [String] = []
        var ultimaVacia = true
        for lineaOriginal in texto.split(separator: "\n", omittingEmptySubsequences: false) {
            let linea = reemplazar(#"[\t ]+"#, en: String(lineaOriginal), con: " ")
                .trimmingCharacters(in: .whitespaces)
            if linea.isEmpty {
                if !ultimaVacia { lineas.append("") }
                ultimaVacia = true
            } else {
                lineas.append(linea)
                ultimaVacia = false
            }
        }
        while lineas.last?.isEmpty == true { lineas.removeLast() }
        return lineas.joined(separator: "\n")
    }

    private static func reemplazar(_ patron: String, en texto: String, con reemplazo: String) -> String {
        guard let expresion = try? NSRegularExpression(
            pattern: patron, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return texto }
        return expresion.stringByReplacingMatches(
            in: texto, range: NSRange(texto.startIndex..., in: texto), withTemplate: reemplazo)
    }

    private static func decodificarEntidades(_ texto: String) -> String {
        let conocidas: [Substring: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": " ", "ensp": " ", "emsp": " ", "ndash": "–", "mdash": "—",
            "hellip": "…", "bull": "•"
        ]
        var resultado = ""
        var posicion = texto.startIndex
        while posicion < texto.endIndex,
              let ampersand = texto[posicion...].firstIndex(of: "&") {
            resultado.append(contentsOf: texto[posicion..<ampersand])
            let limite = texto.index(ampersand, offsetBy: 16, limitedBy: texto.endIndex) ?? texto.endIndex
            guard let puntoYComa = texto[ampersand..<limite].firstIndex(of: ";") else {
                resultado.append("&")
                posicion = texto.index(after: ampersand)
                continue
            }
            let inicio = texto.index(after: ampersand)
            let entidad = texto[inicio..<puntoYComa]
            if let conocida = conocidas[entidad] {
                resultado.append(conocida)
                posicion = texto.index(after: puntoYComa)
            } else if let escalar = escalarNumerico(entidad) {
                resultado.unicodeScalars.append(escalar)
                posicion = texto.index(after: puntoYComa)
            } else {
                resultado.append("&")
                posicion = inicio
            }
        }
        resultado.append(contentsOf: texto[posicion...])
        return resultado
    }

    private static func escalarNumerico(_ entidad: Substring) -> UnicodeScalar? {
        let valor: UInt32?
        if entidad.hasPrefix("#x") || entidad.hasPrefix("#X") {
            valor = UInt32(entidad.dropFirst(2), radix: 16)
        } else if entidad.hasPrefix("#") {
            valor = UInt32(entidad.dropFirst(), radix: 10)
        } else {
            return nil
        }
        guard let valor, valor != 0, !(0xD800...0xDFFF).contains(valor) else { return nil }
        return UnicodeScalar(valor)
    }
}
