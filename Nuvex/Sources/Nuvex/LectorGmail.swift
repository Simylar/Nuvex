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

    private struct FalloPeticion: Error {
        let problema: ProblemaGmail
        let retryAfter: TimeInterval?
    }

    private struct Busqueda {
        let hallazgos: [Hallazgo]
        /// Mensajes que se leyeron correctamente, tuvieran código o no. Se
        /// evita descargarlos de nuevo en cada sondeo de la misma operación.
        let inspeccionados: Set<String>
    }

    enum Resultado: Equatable, Sendable {
        case codigo(CodigoRecibido)
        /// Se agotó la espera sin que llegara el correo.
        case sinCorreo
        /// No se pudo consultar Gmail. Si no es definitivo, es el último
        /// problema que hubo antes de agotarse la espera.
        case problema(ProblemaGmail)
    }

    /// Espera el correo con el código hasta el límite de la configuración.
    /// `alCambiar` informa de problemas pasajeros (nil cuando se resuelven);
    /// los definitivos terminan la espera al momento.
    static func esperar(_ config: ConfigCorreo, desde: Date,
                        alCambiar: @escaping @MainActor (ProblemaGmail?) -> Void = { _ in }) async -> Resultado {
        let limite = Date().addingTimeInterval(TimeInterval(max(config.espera, 15)))
        let comienzo = Date()
        let operacion = String(UUID().uuidString.prefix(8)).lowercased()
        var ultimo: ProblemaGmail?
        var fallosConsecutivos = 0
        var inspeccionados: Set<String> = []
        while Date() < limite, !Task.isCancelled {
            var pausa = SoporteGmail.pausaSinCorreo(segundosTranscurridos: Date().timeIntervalSince(comienzo))
            do {
                let token = try await CuentaGoogle.shared.tokenAcceso()
                let excluir = await MainActor.run { usados }
                let busqueda = try await buscar(config, desde: desde,
                                                excluir: excluir.union(inspeccionados), token: token)
                inspeccionados.formUnion(busqueda.inspeccionados)
                fallosConsecutivos = 0
                if ultimo != nil {
                    ultimo = nil
                    await alCambiar(nil)
                    Log.escribir("gmail op=\(operacion) estado=recuperado")
                }
                for hallazgo in busqueda.hallazgos {
                    // La selección y la reserva son una sola operación en el
                    // actor principal: dos VPN simultáneas no pueden consumir
                    // el mismo correo aunque lo hayan leído a la vez.
                    let reservado = await MainActor.run { usados.insert(hallazgo.id).inserted }
                    guard reservado else {
                        inspeccionados.insert(hallazgo.id)
                        continue
                    }
                    Log.escribir("gmail op=\(operacion) estado=codigo_encontrado segundos=\(Int(Date().timeIntervalSince(comienzo)))")
                    return .codigo(CodigoRecibido(codigo: hallazgo.codigo, remitente: hallazgo.remitente))
                }
            } catch {
                if Task.isCancelled { return .sinCorreo }
                let problema = problema(de: error)
                fallosConsecutivos += 1
                let retryAfter = (error as? FalloPeticion)?.retryAfter
                pausa = SoporteGmail.pausaTrasError(
                    fallosConsecutivos: fallosConsecutivos,
                    problema: problema,
                    retryAfter: retryAfter,
                    jitter: Double.random(in: 0...1)
                )
                // Registra los cambios de clase y algunos hitos, no cada
                // sondeo fallido. Nunca incluye token, asunto ni correo.
                if problema != ultimo || [1, 2, 4, 8].contains(fallosConsecutivos) {
                    Log.escribir("gmail op=\(operacion) estado=fallo tipo=\(problema.codigoDiagnostico) intento=\(fallosConsecutivos) reintento_s=\(Int(pausa.rounded(.up)))")
                }
                if problema.definitivo { return .problema(problema) }
                if problema != ultimo {
                    ultimo = problema
                    await alCambiar(problema)
                }
            }
            let restante = limite.timeIntervalSinceNow
            guard restante > 0 else { break }
            do {
                try await Task.sleep(for: .seconds(min(pausa, restante)))
            } catch {
                return .sinCorreo
            }
        }
        Log.escribir("gmail op=\(operacion) estado=agotado segundos=\(Int(Date().timeIntervalSince(comienzo)))")
        return ultimo.map(Resultado.problema) ?? .sinCorreo
    }

    /// Traduce cualquier error de la cuenta o de la API a un problema explicable.
    static func problema(de error: Error) -> ProblemaGmail {
        if let fallo = error as? FalloPeticion { return fallo.problema }
        if let problema = ProblemaGmail.clasificar(error) { return problema }
        switch error {
        case ErrorGoogle.caducada: return .sesionCaducada
        case ErrorGoogle.sinSesion, ErrorGoogle.sinCliente: return .sinCuenta
        case ErrorGoogle.respuesta(let detalle):
            // «Google rechazó la petición (invalid_client). …»
            if let inicio = detalle.firstIndex(of: "("), let fin = detalle.firstIndex(of: ")"), inicio < fin {
                return ProblemaGmail.clasificarToken(String(detalle[detalle.index(after: inicio)..<fin]))
            }
            return .servidor(0)
        default:
            return .servidor(0)
        }
    }

    /// El correo más reciente que cumple la configuración (últimos 7 días),
    /// para comprobarla desde Ajustes.
    static func probar(_ config: ConfigCorreo) async throws -> Hallazgo? {
        let token = try await CuentaGoogle.shared.tokenAcceso()
        var consulta = "from:(\(config.remitente.trimmingCharacters(in: .whitespaces))) newer_than:7d"
        let asunto = config.asunto.trimmingCharacters(in: .whitespaces)
        if !asunto.isEmpty { consulta += " subject:(\(asunto))" }
        var hallazgos: [Hallazgo] = []
        for id in try await listar(consulta, token: token) {
            if let hallazgo = try await leer(id, patron: config.patron, token: token) { hallazgos.append(hallazgo) }
        }
        return hallazgos.max { $0.fecha < $1.fecha }
    }

    private static func buscar(_ config: ConfigCorreo, desde: Date, excluir: Set<String>,
                               token: String) async throws -> Busqueda {
        let consulta = ExtractorCodigo.consultaGmail(remitente: config.remitente, asunto: config.asunto, desde: desde)
        var hallazgos: [Hallazgo] = []
        var inspeccionados: Set<String> = []
        for id in try await listar(consulta, token: token) where !excluir.contains(id) {
            let hallazgo = try await leer(id, patron: config.patron, token: token)
            guard let hallazgo else {
                inspeccionados.insert(id)
                continue
            }
            // Gmail redondea after: a segundos; se descarta lo anterior al intento.
            if hallazgo.fecha >= desde.addingTimeInterval(-30) { hallazgos.append(hallazgo) }
            else { inspeccionados.insert(id) }
        }
        return Busqueda(hallazgos: hallazgos.sorted { $0.fecha > $1.fecha }, inspeccionados: inspeccionados)
    }

    // MARK: API de Gmail

    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me/messages"

    private static func listar(_ consulta: String, token: String) async throws -> [String] {
        var url = URLComponents(string: base)!
        url.queryItems = [URLQueryItem(name: "q", value: consulta), URLQueryItem(name: "maxResults", value: "10")]
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
        var codigo = ExtractorCodigo.extraer(de: asunto, patron: patron)
        if codigo == nil {
            for formato in [ParteTextoGmail.Formato.plano, .html] {
                let texto = try await cuerpo(carga, formato: formato, mensajeID: id, token: token)
                if let encontrado = SoporteGmail.extraerCodigo(asunto: asunto, cuerpo: texto, patron: patron) {
                    codigo = encontrado
                    break
                }
            }
        }
        guard let codigo else { return nil }
        let milisegundos = Double(json["internalDate"] as? String ?? "") ?? 0
        return Hallazgo(id: id, codigo: codigo, remitente: direccion(cabeceras["from"] ?? ""), asunto: asunto,
                        fecha: Date(timeIntervalSince1970: milisegundos / 1000))
    }

    /// Texto del formato solicitado; si Gmail dejó una parte fuera del
    /// `payload`, se recupera con attachments.get. El llamador prueba HTML solo
    /// cuando ni el asunto ni el texto plano contienen un código válido.
    private static func cuerpo(_ carga: [String: Any], formato: ParteTextoGmail.Formato,
                               mensajeID: String, token: String) async throws -> String {
        let candidatas = SoporteGmail.partesTexto(en: carga).filter { $0.formato == formato }
        var codificadas: [String] = []
        for parte in candidatas {
            if let datos = parte.datos, !datos.isEmpty {
                codificadas.append(datos)
            } else if let adjuntoID = parte.adjuntoID, !adjuntoID.isEmpty,
                      let datos = try await leerAdjunto(adjuntoID, mensajeID: mensajeID, token: token) {
                codificadas.append(datos)
            }
        }
        return SoporteGmail.texto(datosBase64URL: codificadas, formato: formato)
    }

    private static func leerAdjunto(_ adjuntoID: String, mensajeID: String, token: String) async throws -> String? {
        guard let mensaje = mensajeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let adjunto = adjuntoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(base)/\(mensaje)/attachments/\(adjunto)") else { return nil }
        let json = try await pedir(url, token: token)
        guard (json["size"] as? Int ?? 0) <= SoporteGmail.maximoBytesTexto else { return nil }
        return json["data"] as? String
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
                // Token de acceso caducado: la próxima consulta lo renueva. Si
                // la sesión entera caducó, la renovación lo dirá.
                await MainActor.run { CuentaGoogle.shared.invalidarAcceso() }
                throw FalloPeticion(problema: .servidor(401), retryAfter: nil)
            }
            let problema = ProblemaGmail.clasificar(estado: codigo, cuerpo: datos)
            let retryAfter = SoporteGmail.retryAfter(
                (respuesta as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            )
            throw FalloPeticion(problema: problema, retryAfter: retryAfter)
        }
        return (try JSONSerialization.jsonObject(with: datos) as? [String: Any]) ?? [:]
    }
}
