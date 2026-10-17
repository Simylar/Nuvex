import Foundation

/// Lee de Gmail el código de verificación que envía el servidor VPN. Solo
/// lectura: no marca, mueve ni borra correos. Nunca registra el código ni el
/// contenido del correo.
enum LectorGmail {
    struct Hallazgo: Equatable {
        let id: String
        let codigo: String
        let remitente: String
        let asunto: String
        let fecha: Date
    }

    /// Correos ya usados en esta sesión: un código no se usa dos veces.
    @MainActor private static var usados: Set<String> = []

    /// Espera el correo con el código hasta el límite de la configuración.
    static func esperar(_ config: ConfigCorreo, desde: Date) async -> CodigoRecibido? {
        let limite = Date().addingTimeInterval(TimeInterval(max(config.espera, 15)))
        let comienzo = Date()
        while Date() < limite, !Task.isCancelled {
            do {
                let token = try await CuentaGoogle.shared.tokenAcceso()
                let excluir = await MainActor.run { usados }
                if let hallazgo = try await buscar(config, desde: desde, excluir: excluir, token: token) {
                    await MainActor.run { _ = usados.insert(hallazgo.id) }
                    Log.escribir("código encontrado en el correo tras \(Int(Date().timeIntervalSince(comienzo))) s")
                    return CodigoRecibido(codigo: hallazgo.codigo, remitente: hallazgo.remitente)
                }
            } catch ErrorGoogle.caducada, ErrorGoogle.sinSesion, ErrorGoogle.sinCliente {
                return nil
            } catch {
                if Task.isCancelled { return nil }
                Log.escribir("no se pudo consultar Gmail: \(error.localizedDescription)")
            }
            let pausa: Duration = Date().timeIntervalSince(comienzo) < 30 ? .seconds(3) : .seconds(5)
            try? await Task.sleep(for: pausa)
        }
        return nil
    }

    /// El correo más reciente que cumple la configuración (últimos 7 días),
    /// para comprobarla desde Ajustes.
    static func probar(_ config: ConfigCorreo) async throws -> Hallazgo? {
        let token = try await CuentaGoogle.shared.tokenAcceso()
        var consulta = "from:(\(config.remitente.trimmingCharacters(in: .whitespaces))) newer_than:7d"
        let asunto = config.asunto.trimmingCharacters(in: .whitespaces)
        if !asunto.isEmpty { consulta += " subject:(\(asunto))" }
        for id in try await listar(consulta, token: token) {
            if let hallazgo = try await leer(id, patron: config.patron, token: token) { return hallazgo }
        }
        return nil
    }

    static func buscar(_ config: ConfigCorreo, desde: Date, excluir: Set<String>, token: String) async throws -> Hallazgo? {
        let consulta = ExtractorCodigo.consultaGmail(remitente: config.remitente, asunto: config.asunto, desde: desde)
        for id in try await listar(consulta, token: token) where !excluir.contains(id) {
            guard let hallazgo = try await leer(id, patron: config.patron, token: token) else { continue }
            // Gmail redondea after: a segundos; se descarta lo anterior al intento.
            if hallazgo.fecha >= desde.addingTimeInterval(-30) { return hallazgo }
        }
        return nil
    }

    // MARK: API de Gmail

    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me/messages"

    private static func listar(_ consulta: String, token: String) async throws -> [String] {
        var url = URLComponents(string: base)!
        url.queryItems = [URLQueryItem(name: "q", value: consulta), URLQueryItem(name: "maxResults", value: "5")]
        let json = try await pedir(url.url!, token: token)
        return (json["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    private static func leer(_ id: String, patron: String, token: String) async throws -> Hallazgo? {
        let json = try await pedir(URL(string: "\(base)/\(id)?format=full")!, token: token)
        guard let carga = json["payload"] as? [String: Any] else { return nil }
        let cabeceras = Dictionary((carga["headers"] as? [[String: String]] ?? []).compactMap { cabecera -> (String, String)? in
            guard let nombre = cabecera["name"]?.lowercased(), let valor = cabecera["value"] else { return nil }
            return (nombre, valor)
        }, uniquingKeysWith: { primero, _ in primero })
        let asunto = cabeceras["subject"] ?? ""
        let texto = asunto + "\n" + cuerpo(carga)
        guard let codigo = ExtractorCodigo.extraer(de: texto, patron: patron) else { return nil }
        let milisegundos = Double(json["internalDate"] as? String ?? "") ?? 0
        return Hallazgo(id: id, codigo: codigo, remitente: direccion(cabeceras["from"] ?? ""), asunto: asunto,
                        fecha: Date(timeIntervalSince1970: milisegundos / 1000))
    }

    /// Texto plano del correo; si solo hay HTML, convertido a texto.
    private static func cuerpo(_ parte: [String: Any]) -> String {
        var plano: [String] = []
        var html: [String] = []
        func recorrer(_ parte: [String: Any]) {
            let tipo = (parte["mimeType"] as? String ?? "").lowercased()
            if let datos = (parte["body"] as? [String: Any])?["data"] as? String,
               let decodificado = ExtractorCodigo.decodificarBase64URL(datos) {
                let texto = String(decoding: decodificado, as: UTF8.self)
                if tipo == "text/plain" { plano.append(texto) } else if tipo == "text/html" { html.append(texto) }
            }
            (parte["parts"] as? [[String: Any]])?.forEach(recorrer)
        }
        recorrer(parte)
        return plano.isEmpty ? html.map(ExtractorCodigo.textoDesdeHTML).joined(separator: "\n") : plano.joined(separator: "\n")
    }

    /// «Fortinet <noreply@empresa.com>» → «noreply@empresa.com».
    private static func direccion(_ remitente: String) -> String {
        if let inicio = remitente.firstIndex(of: "<"), let fin = remitente.firstIndex(of: ">"), inicio < fin {
            return String(remitente[remitente.index(after: inicio)..<fin])
        }
        return remitente.trimmingCharacters(in: .whitespaces)
    }

    private static func pedir(_ url: URL, token: String) async throws -> [String: Any] {
        var peticion = URLRequest(url: url, timeoutInterval: 15)
        peticion.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (datos, respuesta) = try await URLSession.shared.data(for: peticion)
        let codigo = (respuesta as? HTTPURLResponse)?.statusCode ?? 0
        guard codigo == 200 else {
            if codigo == 401 {
                // Token de acceso caducado: la próxima consulta lo renueva.
                await MainActor.run { CuentaGoogle.shared.invalidarAcceso() }
                throw ErrorGoogle.respuesta("Gmail rechazó el token de acceso.")
            }
            if codigo == 403 {
                throw ErrorGoogle.respuesta("Google no permitió leer Gmail (403). Comprueba que la Gmail API esté activada en tu proyecto.")
            }
            throw ErrorGoogle.respuesta("Gmail respondió con el código \(codigo).")
        }
        return (try JSONSerialization.jsonObject(with: datos) as? [String: Any]) ?? [:]
    }
}
