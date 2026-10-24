import AppKit
import Darwin
import Foundation
import Security

enum ErrorGoogle: LocalizedError, Equatable {
    case sinCliente
    case sinSesion
    case caducada
    case cancelado
    case respuesta(String)

    var errorDescription: String? {
        switch self {
        case .sinCliente: return "Falta el cliente OAuth de Google."
        case .sinSesion: return "No hay ninguna cuenta de Google conectada."
        case .caducada: return "La sesión de Google caducó. Vuelve a iniciar sesión."
        case .cancelado: return "Se canceló el inicio de sesión."
        case .respuesta(let detalle): return detalle
        }
    }
}

/// Cuenta de Google con permiso de solo lectura de Gmail, para leer los
/// códigos de verificación. Usa el cliente OAuth «App de escritorio» del
/// propio usuario (docs/gmail.md). El token de renovación y el secreto del
/// cliente se guardan en el Llavero; el token de acceso solo vive en memoria.
@MainActor
final class CuentaGoogle: ObservableObject {
    static let shared = CuentaGoogle()
    static let permisos = "openid email https://www.googleapis.com/auth/gmail.readonly"

    enum Estado: Equatable {
        case sinCliente
        case desconectada
        case esperandoNavegador
        case conectada(String)
        case caducada(String)
    }

    @Published private(set) var estado: Estado = .sinCliente
    @Published private(set) var error: String?

    private struct Guardado: Codable {
        var clienteID: String
        var secreto: String
        var tokenRenovacion: String?
        var correo: String?
    }

    private var guardado: Guardado?
    private var acceso: (token: String, caduca: Date)?
    /// Comparte una sola renovación entre lectores concurrentes. Al ser un
    /// actor principal, una espera de red permite reentrada; sin esta tarea dos
    /// VPN podían renovar el mismo refresh token al mismo tiempo.
    private struct RenovacionEnCurso {
        let id: UUID
        let tarea: Task<(token: String, caduca: Date), Error>
    }
    private var renovacionEnCurso: RenovacionEnCurso?
    private var inicio: Task<Void, Never>?
    private var servidor: ServidorRedireccion?

    private init() {
        guardado = Self.leerLlavero()
        recalcular()
    }

    var clienteID: String? { guardado?.clienteID }
    var correo: String? {
        if case .conectada(let correo) = estado { return correo }
        return nil
    }

    private func recalcular(caducada: Bool = false) {
        guard let guardado else { estado = .sinCliente; return }
        guard guardado.tokenRenovacion != nil, let correo = guardado.correo else { estado = .desconectada; return }
        estado = caducada ? .caducada(correo) : .conectada(correo)
    }

    // MARK: Cliente OAuth

    func guardarCliente(id: String, secreto: String) -> Bool {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let secreto = secreto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(".apps.googleusercontent.com"), !secreto.isEmpty else {
            error = "El ID de cliente termina en .apps.googleusercontent.com y el secreto no puede estar vacío."
            return false
        }
        let nuevo = Guardado(clienteID: id, secreto: secreto)
        guard Self.escribirLlavero(nuevo) else {
            error = "No se pudo guardar el cliente en el Llavero."
            return false
        }
        invalidarRenovacion()
        guardado = nuevo
        error = nil
        recalcular()
        return true
    }

    func olvidarCliente() async {
        await cerrarSesion()
        Self.borrarLlavero()
        guardado = nil
        recalcular()
    }

    // MARK: Sesión

    func iniciarSesion() {
        guard let guardado else { error = ErrorGoogle.sinCliente.localizedDescription; return }
        cancelarInicio()
        error = nil
        estado = .esperandoNavegador
        inicio = Task { [weak self] in
            do {
                let servidor = try ServidorRedireccion()
                self?.servidor = servidor
                let verificador = ExtractorCodigo.verificadorPKCE()
                let estadoOAuth = ExtractorCodigo.verificadorPKCE()
                var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                url.queryItems = [
                    URLQueryItem(name: "client_id", value: guardado.clienteID),
                    URLQueryItem(name: "redirect_uri", value: servidor.direccion),
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "scope", value: Self.permisos),
                    URLQueryItem(name: "code_challenge", value: ExtractorCodigo.desafioPKCE(verificador)),
                    URLQueryItem(name: "code_challenge_method", value: "S256"),
                    URLQueryItem(name: "state", value: estadoOAuth),
                    URLQueryItem(name: "access_type", value: "offline"),
                    URLQueryItem(name: "prompt", value: "consent"),
                ]
                NSWorkspace.shared.open(url.url!)
                let respuesta = try await servidor.esperar()
                guard respuesta["state"] == estadoOAuth else { throw ErrorGoogle.respuesta("La respuesta de Google no corresponde a este inicio de sesión.") }
                if let fallo = respuesta["error"] {
                    throw fallo == "access_denied" ? ErrorGoogle.cancelado : ErrorGoogle.respuesta("Google respondió: \(fallo)")
                }
                guard let codigo = respuesta["code"] else { throw ErrorGoogle.respuesta("Google no devolvió el código de autorización.") }
                let tokens = try await Self.pedirToken([
                    "code": codigo, "client_id": guardado.clienteID, "client_secret": guardado.secreto,
                    "redirect_uri": servidor.direccion, "grant_type": "authorization_code", "code_verifier": verificador,
                ])
                guard let renovacion = tokens["refresh_token"] as? String else {
                    throw ErrorGoogle.respuesta("Google no entregó un token de renovación. Quita el acceso de Nuvex en tu cuenta de Google y vuelve a intentarlo.")
                }
                let correo = (tokens["id_token"] as? String).flatMap(ExtractorCodigo.correoDeIDToken) ?? "tu cuenta"
                self?.completarInicio(renovacion: renovacion, correo: correo, tokens: tokens)
            } catch {
                self?.fallarInicio(error)
            }
        }
    }

    func cancelarInicio() {
        inicio?.cancel()
        inicio = nil
        servidor?.cerrar()
        servidor = nil
        if estado == .esperandoNavegador { recalcular() }
    }

    private func completarInicio(renovacion: String, correo: String, tokens: [String: Any]) {
        guard var guardado else { return }
        guardado.tokenRenovacion = renovacion
        guardado.correo = correo
        guard Self.escribirLlavero(guardado) else {
            fallarInicio(ErrorGoogle.respuesta("No se pudo guardar la sesión en el Llavero."))
            return
        }
        self.guardado = guardado
        if let token = tokens["access_token"] as? String {
            acceso = (token, Date().addingTimeInterval(TimeInterval(tokens["expires_in"] as? Int ?? 3000)))
        }
        servidor = nil
        inicio = nil
        error = nil
        Log.escribir("cuenta de Google conectada para leer códigos")
        recalcular()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func fallarInicio(_ fallo: Error) {
        servidor?.cerrar()
        servidor = nil
        inicio = nil
        if fallo is CancellationError { recalcular(); return }
        error = fallo.localizedDescription
        Log.escribir("inicio de sesión de Google fallido: \(fallo.localizedDescription)")
        recalcular()
    }

    /// Revoca el acceso en Google y lo borra del Llavero. Conserva el cliente.
    func cerrarSesion() async {
        let token = guardado?.tokenRenovacion
        invalidarRenovacion()
        guardado?.tokenRenovacion = nil
        guardado?.correo = nil
        if let guardado, !Self.escribirLlavero(guardado) {
            error = "No se pudo actualizar la sesión guardada en el Llavero."
        }
        recalcular()
        if let token {
            var peticion = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            peticion.timeoutInterval = 15
            peticion.httpMethod = "POST"
            peticion.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            peticion.httpBody = Self.formulario(["token": token])
            _ = try? await URLSession.shared.data(for: peticion)
        }
    }

    func invalidarAcceso() { acceso = nil }

    /// Token de acceso vigente; lo renueva si caducó.
    func tokenAcceso() async throws -> String {
        if let acceso, acceso.caduca > Date().addingTimeInterval(60) { return acceso.token }
        if let renovacionEnCurso {
            let renovado: (token: String, caduca: Date)
            do { renovado = try await renovacionEnCurso.tarea.value }
            catch {
                guard self.renovacionEnCurso?.id == renovacionEnCurso.id else { throw ErrorGoogle.sinSesion }
                throw error
            }
            guard self.renovacionEnCurso?.id == renovacionEnCurso.id else { throw ErrorGoogle.sinSesion }
            acceso = renovado
            return renovado.token
        }
        guard let guardado else { throw ErrorGoogle.sinCliente }
        guard let renovacion = guardado.tokenRenovacion else { throw ErrorGoogle.sinSesion }
        let tarea: Task<(token: String, caduca: Date), Error> = Task {
            let tokens = try await Self.pedirToken([
                "client_id": guardado.clienteID, "client_secret": guardado.secreto,
                "refresh_token": renovacion, "grant_type": "refresh_token",
            ])
            guard let token = tokens["access_token"] as? String else {
                throw ErrorGoogle.respuesta("Google no devolvió un token de acceso.")
            }
            return (token: token, caduca: Date().addingTimeInterval(TimeInterval(tokens["expires_in"] as? Int ?? 3000)))
        }
        let idRenovacion = UUID()
        renovacionEnCurso = RenovacionEnCurso(id: idRenovacion, tarea: tarea)
        defer {
            if renovacionEnCurso?.id == idRenovacion { renovacionEnCurso = nil }
        }
        do {
            let renovado = try await tarea.value
            guard renovacionEnCurso?.id == idRenovacion else { throw ErrorGoogle.sinSesion }
            acceso = renovado
            if case .caducada = estado { recalcular() }
            return renovado.token
        } catch ErrorGoogle.respuesta(let detalle) where detalle.contains("invalid_grant") {
            Log.escribir("la sesión de Google caducó")
            recalcular(caducada: true)
            throw ErrorGoogle.caducada
        }
    }

    /// Impide que una respuesta tardía de OAuth restaure un token de acceso
    /// después de cerrar sesión o reemplazar el cliente configurado.
    private func invalidarRenovacion() {
        renovacionEnCurso?.tarea.cancel()
        renovacionEnCurso = nil
        acceso = nil
    }

    // MARK: Red

    private static func formulario(_ campos: [String: String]) -> Data {
        var permitidos = CharacterSet.alphanumerics
        permitidos.insert(charactersIn: "-._~")
        return Data(campos.map { clave, valor in
            "\(clave)=\(valor.addingPercentEncoding(withAllowedCharacters: permitidos) ?? "")"
        }.joined(separator: "&").utf8)
    }

    private static func pedirToken(_ campos: [String: String]) async throws -> [String: Any] {
        var peticion = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 15)
        peticion.httpMethod = "POST"
        peticion.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        peticion.httpBody = formulario(campos)
        let (datos, respuesta) = try await URLSession.shared.data(for: peticion)
        let json = (try? JSONSerialization.jsonObject(with: datos) as? [String: Any]) ?? [:]
        guard (respuesta as? HTTPURLResponse)?.statusCode == 200 else {
            let fallo = json["error"] as? String ?? "error desconocido"
            let detalle = json["error_description"] as? String ?? ""
            throw ErrorGoogle.respuesta("Google rechazó la petición (\(fallo)). \(detalle)")
        }
        return json
    }

    // MARK: Llavero

    private static let servicio = "nuvex.google"
    private static let cuenta = "cuenta"

    private static func leerLlavero() -> Guardado? {
        let consulta: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: servicio, kSecAttrAccount as String: cuenta,
                                       kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var resultado: CFTypeRef?
        guard SecItemCopyMatching(consulta as CFDictionary, &resultado) == errSecSuccess,
              let datos = resultado as? Data else { return nil }
        return try? JSONDecoder().decode(Guardado.self, from: datos)
    }

    private static func escribirLlavero(_ guardado: Guardado) -> Bool {
        guard let datos = try? JSONEncoder().encode(guardado) else { return false }
        let consulta: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: servicio, kSecAttrAccount as String: cuenta]
        let actualizado = SecItemUpdate(consulta as CFDictionary, [kSecValueData as String: datos] as CFDictionary)
        if actualizado == errSecItemNotFound {
            var nuevo = consulta
            nuevo[kSecValueData as String] = datos
            nuevo[kSecAttrLabel as String] = "Nuvex: cuenta de Google para códigos"
            return SecItemAdd(nuevo as CFDictionary, nil) == errSecSuccess
        }
        return actualizado == errSecSuccess
    }

    private static func borrarLlavero() {
        let consulta: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: servicio, kSecAttrAccount as String: cuenta]
        SecItemDelete(consulta as CFDictionary)
    }
}

// MARK: - Redirección local

/// Servidor HTTP de un solo uso en 127.0.0.1 que recibe la respuesta de
/// Google tras iniciar sesión (OAuth para apps de escritorio). Espera hasta
/// cinco minutos y atiende una única petición.
final class ServidorRedireccion: @unchecked Sendable {
    let direccion: String
    private let fd: Int32
    private let cerrojo = NSLock()
    private var cerrado = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ErrorGoogle.respuesta("No se pudo abrir el puerto local para Google.") }
        var direccion = sockaddr_in()
        direccion.sin_family = sa_family_t(AF_INET)
        direccion.sin_addr.s_addr = inet_addr("127.0.0.1")
        direccion.sin_port = 0
        direccion.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var tamano = socklen_t(MemoryLayout<sockaddr_in>.size)
        let enlazado = withUnsafeMutablePointer(to: &direccion) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { puntero -> Bool in
                bind(fd, puntero, tamano) == 0 && listen(fd, 1) == 0 && getsockname(fd, puntero, &tamano) == 0
            }
        }
        guard enlazado else { close(fd); throw ErrorGoogle.respuesta("No se pudo abrir el puerto local para Google.") }
        self.fd = fd
        self.direccion = "http://127.0.0.1:\(UInt16(bigEndian: direccion.sin_port))"
    }

    func cerrar() {
        cerrojo.lock(); defer { cerrojo.unlock() }
        guard !cerrado else { return }
        cerrado = true
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    /// Parámetros de la petición de vuelta (code, state o error).
    func esperar() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuacion in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    continuacion.resume(with: Result { try atender() })
                }
            }
        } onCancel: {
            cerrar()
        }
    }

    private func atender() throws -> [String: String] {
        defer { cerrar() }
        var sondeo = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let limite = Date().addingTimeInterval(300)
        while true {
            let restante = Int32(max(0, limite.timeIntervalSinceNow) * 1000)
            guard restante > 0 else { throw ErrorGoogle.respuesta("Se agotó el tiempo para iniciar sesión en Google.") }
            let listo = poll(&sondeo, 1, min(restante, 1000))
            if listo < 0 && errno == EINTR { continue }
            if listo < 0 || cerradoAhora { throw CancellationError() }
            if listo == 0 { continue }
            let cliente = accept(fd, nil, nil)
            guard cliente >= 0 else { throw CancellationError() }
            defer { close(cliente) }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let leidos = read(cliente, &buffer, buffer.count)
            let peticion = String(decoding: buffer.prefix(max(0, leidos)), as: UTF8.self)
            // Primera línea: «GET /?code=…&state=… HTTP/1.1». Otras rutas (favicon) se ignoran.
            let partes = peticion.split(separator: " ", maxSplits: 2)
            guard partes.count >= 2, partes[0] == "GET", let componentes = URLComponents(string: String(partes[1])),
                  componentes.path == "/" else {
                responder(cliente, estado: "404 Not Found", cuerpo: "")
                continue
            }
            var parametros: [String: String] = [:]
            componentes.queryItems?.forEach { parametros[$0.name] = $0.value ?? "" }
            let exito = parametros["code"] != nil
            responder(cliente, estado: "200 OK", cuerpo: """
                <!doctype html><html lang="es"><meta charset="utf-8"><title>Nuvex</title>
                <body style="font: 15px -apple-system, sans-serif; text-align: center; padding: 64px; color: #333">
                <h2>\(exito ? "Cuenta conectada a Nuvex" : "No se conectó la cuenta")</h2>
                <p>\(exito ? "Ya puedes cerrar esta pestaña y volver a Nuvex." : "Vuelve a Nuvex para intentarlo de nuevo.")</p>
                </body></html>
                """)
            return parametros
        }
    }

    private var cerradoAhora: Bool { cerrojo.lock(); defer { cerrojo.unlock() }; return cerrado }

    private func responder(_ cliente: Int32, estado: String, cuerpo: String) {
        let datos = Array(cuerpo.utf8)
        let cabecera = "HTTP/1.1 \(estado)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(datos.count)\r\nConnection: close\r\n\r\n"
        let respuesta = Array(cabecera.utf8) + datos
        _ = respuesta.withUnsafeBytes { write(cliente, $0.baseAddress, respuesta.count) }
    }
}
