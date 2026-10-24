import Foundation

/// Parte de texto de un mensaje de Gmail. Gmail puede incluir el contenido en
/// `data` o dejarlo en un recurso separado identificado por `attachmentId`.
struct ParteTextoGmail: Equatable {
    enum Formato: Equatable {
        case plano
        case html
    }

    let formato: Formato
    let datos: String?
    let adjuntoID: String?
    let tamano: Int
}

/// Estado local de una espera de OTP. Gmail puede listar un mensaje nuevo
/// antes de que todas sus partes MIME estén disponibles. En ese caso se vuelve
/// a leer un número pequeño y acotado de veces; los mensajes definitivamente
/// descartados y los ya usados se excluyen desde el primer momento.
struct RegistroInspeccionGmail {
    static let maximoLecturasSinCodigo = 3

    private var lecturasSinCodigo: [String: Int] = [:]
    private var descartados: Set<String> = []

    mutating func registrarSinCodigo(_ ids: Set<String>) {
        for id in ids { lecturasSinCodigo[id, default: 0] += 1 }
    }

    mutating func descartar(_ ids: Set<String>) {
        descartados.formUnion(ids)
    }

    func excluidos(usados: Set<String>) -> Set<String> {
        usados
            .union(descartados)
            .union(lecturasSinCodigo.compactMap { id, lecturas in
                lecturas >= Self.maximoLecturasSinCodigo ? id : nil
            })
    }

    func lecturas(de id: String) -> Int { lecturasSinCodigo[id, default: 0] }
}

/// Lógica pura del lector de Gmail, separada de la red para poder probar los
/// árboles MIME y la política de reintentos sin una cuenta real.
enum SoporteGmail {
    /// Un correo OTP legítimo es pequeño. El límite evita descargar o procesar
    /// adjuntos inesperados como si fueran el cuerpo del mensaje.
    static let maximoBytesTexto = 256 * 1_024

    static func partesTexto(en carga: [String: Any]) -> [ParteTextoGmail] {
        var resultado: [ParteTextoGmail] = []

        func recorrer(_ parte: [String: Any]) {
            let tipo = (parte["mimeType"] as? String ?? "").lowercased()
            if tipo == "text/plain" || tipo == "text/html" {
                let cuerpo = parte["body"] as? [String: Any] ?? [:]
                let tamano = cuerpo["size"] as? Int ?? 0
                if tamano <= maximoBytesTexto {
                    resultado.append(ParteTextoGmail(
                        formato: tipo == "text/plain" ? .plano : .html,
                        datos: cuerpo["data"] as? String,
                        adjuntoID: cuerpo["attachmentId"] as? String,
                        tamano: tamano
                    ))
                }
            }
            (parte["parts"] as? [[String: Any]])?.forEach(recorrer)
        }

        recorrer(carga)
        return resultado
    }

    static func texto(datosBase64URL: [String], formato: ParteTextoGmail.Formato) -> String {
        var fragmentos: [String] = []
        var bytesAcumulados = 0
        for codificado in datosBase64URL {
            guard codificado.utf8.count <= maximoBytesTexto * 2,
                  let datos = ExtractorCodigo.decodificarBase64URL(codificado),
                  datos.count <= maximoBytesTexto else { continue }
            guard bytesAcumulados + datos.count <= maximoBytesTexto else { break }
            bytesAcumulados += datos.count
            fragmentos.append(String(decoding: datos, as: UTF8.self))
        }
        let texto = fragmentos.joined(separator: "\n")
        return formato == .html ? ExtractorCodigo.textoDesdeHTML(texto) : texto
    }

    /// Conserva la prioridad del texto plano, pero permite probar la variante
    /// HTML cuando el cuerpo plano existe y no contiene ningún código.
    static func extraerCodigo(asunto: String, cuerpo: String, patron: String) -> String? {
        ExtractorCodigo.extraer(de: asunto + "\n" + cuerpo, patron: patron)
    }

    /// Sondeo normal cuando Gmail respondió correctamente pero el mensaje aún
    /// no llega. Empieza ágil y reduce consultas conforme pasa el tiempo.
    static func pausaSinCorreo(segundosTranscurridos: TimeInterval) -> TimeInterval {
        segundosTranscurridos < 30 ? 3 : segundosTranscurridos < 90 ? 5 : 8
    }

    /// Backoff exponencial truncado con jitter para fallos transitorios. Un
    /// `Retry-After` válido siempre se respeta; el llamador lo acota al tiempo
    /// que todavía queda en la operación.
    static func pausaTrasError(fallosConsecutivos: Int, problema: ProblemaGmail,
                               retryAfter: TimeInterval? = nil, jitter: TimeInterval) -> TimeInterval {
        if let retryAfter, retryAfter > 0 {
            // El límite total de la operación se aplica al dormir. Acortar aquí
            // la indicación del servidor provocaría una petición prematura.
            return max(1, retryAfter)
        }
        let exponente = min(max(fallosConsecutivos - 1, 0), 5)
        let base = min(30, pow(2, Double(exponente)))
        let minimo: TimeInterval = problema == .limite ? 5 : 1
        return min(30, max(minimo, base) + min(max(jitter, 0), 1))
    }

    /// `Retry-After` admite segundos o una fecha HTTP. La fecha se interpreta
    /// en GMT y las respuestas vencidas piden un reintento inmediato acotado.
    static func retryAfter(_ valor: String?, ahora: Date = Date()) -> TimeInterval? {
        guard let valor = valor?.trimmingCharacters(in: .whitespacesAndNewlines), !valor.isEmpty else { return nil }
        if let segundos = TimeInterval(valor) { return max(0, segundos) }
        let formato = DateFormatter()
        formato.locale = Locale(identifier: "en_US_POSIX")
        formato.timeZone = TimeZone(secondsFromGMT: 0)
        formato.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formato.date(from: valor).map { max(0, $0.timeIntervalSince(ahora)) }
    }
}
