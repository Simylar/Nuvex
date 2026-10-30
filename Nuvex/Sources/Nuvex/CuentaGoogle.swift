import AppKit
import Darwin
import Foundation
import Security
import LocalAuthentication

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

/// Cuenta de Google con lectura de Gmail y modificación opcional, para leer los
/// códigos de verificación. Usa el cliente OAuth «App de escritorio» del
/// propio usuario (docs/gmail.md). El token de renovación y el secreto del
/// cliente se guardan en el Llavero; el token de acceso solo vive en memoria.
@MainActor
final class CuentaGoogle: ObservableObject {
    static let shared: CuentaGoogle = {
        if ModoDemostracion.activo {
            return CuentaGoogle(lectorLlavero: { _ in (nil, errSecItemNotFound) },
                                escritorLlavero: { _ in false }, borradorLlavero: { false })
        }
        return CuentaGoogle()
    }()
    static let permisoLeer = "https://www.googleapis.com/auth/gmail.readonly"
    static let permisos = "openid email \(permisoLeer)"
    static let permisoModificar = "https://www.googleapis.com/auth/gmail.modify"

    static func permisosOAuth(modificar: Bool) -> String {
        modificar ? "openid email \(permisoModificar)" : permisos
    }

    static func permisosConcedidos(_ respuesta: String?, solicitados: String) throws -> Set<String> {
        let concedidos = Set((respuesta ?? solicitados).split(separator: " ").map(String.init))
        guard concedidos.contains(permisoLeer) || concedidos.contains(permisoModificar) else {
            throw ErrorGoogle.respuesta("Google no concedió acceso para leer Gmail. Vuelve a iniciar sesión y permite la lectura de códigos. La sesión anterior se conserva si estaba guardada.")
        }
        return concedidos
    }

    enum Estado: Equatable {
        case sinCliente
        case llaveroNoDisponible(Int32)
        case desconectada
        case esperandoNavegador
        case conectada(String)
        case caducada(String)
    }

    @Published private(set) var estado: Estado = .sinCliente
    @Published private(set) var error: String?
    @Published private(set) var avisoPapelera: String?
    @Published private(set) var comprobandoLlavero = false
    @Published private var permisoPapeleraRechazado = false
    private(set) var idSesion = UUID()

    private struct Guardado: Codable, Equatable {
        var clienteID: String
        var secreto: String
        var tokenRenovacion: String?
        var correo: String?
        /// Ausente en cuentas antiguas: se conserva el alcance de solo lectura.
        var permisos: Set<String>?
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
    private var idInicio: UUID?
    private var servidor: ServidorRedireccion?
    private let lectorLlavero: (@MainActor (Bool) -> (datos: Data?, estado: OSStatus))?
    private let lectorSegundoPlano: @Sendable (Bool) -> (datos: Data?, estado: OSStatus)
    private let escritorLlavero: @MainActor (Data) -> Bool
    private let borradorLlavero: @MainActor () -> Bool
    private let pedirTokens: @MainActor ([String: String]) async throws -> [String: Any]
    private let abrirNavegador: @MainActor (URL) -> Bool
    private let revocarToken: @MainActor (String) async -> String?

    init(lectorLlavero: (@MainActor (Bool) -> (datos: Data?, estado: OSStatus))? = nil,
         lectorSegundoPlano: @escaping @Sendable (Bool) -> (datos: Data?, estado: OSStatus) = { CuentaGoogle.leerLlavero(interactivo: $0) },
         escritorLlavero: @escaping @MainActor (Data) -> Bool = CuentaGoogle.escribirDatosLlavero,
         borradorLlavero: @escaping @MainActor () -> Bool = CuentaGoogle.borrarLlavero,
         pedirTokens: @escaping @MainActor ([String: String]) async throws -> [String: Any] = CuentaGoogle.pedirToken,
         abrirNavegador: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
         revocarToken: @escaping @MainActor (String) async -> String? = CuentaGoogle.revocarEnGoogle) {
        self.lectorLlavero = lectorLlavero
        self.lectorSegundoPlano = lectorSegundoPlano
        self.escritorLlavero = escritorLlavero
        self.borradorLlavero = borradorLlavero
        self.pedirTokens = pedirTokens
        self.abrirNavegador = abrirNavegador
        self.revocarToken = revocarToken
        recuperarDelLlavero(interactivo: false)
    }

    /// Solicita una lectura sin interacción al arrancar. El Llavero clásico
    /// puede exigir autorización en algunas versiones de macOS: la espera
    /// queda fuera del actor principal y nunca equivale a «sin configurar».
    func recuperarDelLlavero(interactivo: Bool = true) {
        guard !comprobandoLlavero else { return }
        cancelarInicio()
        invalidarRenovacion()
        if let lectorLlavero {
            aplicarLecturaLlavero(lectorLlavero(interactivo))
            return
        }
        let sesion = idSesion
        let lector = lectorSegundoPlano
        comprobandoLlavero = true
        Task { [weak self] in
            let lectura = await Task.detached(priority: .userInitiated) { lector(interactivo) }.value
            guard let self, self.idSesion == sesion else { return }
            self.comprobandoLlavero = false
            self.aplicarLecturaLlavero(lectura)
        }
    }

    private func aplicarLecturaLlavero(_ lectura: (datos: Data?, estado: OSStatus)) {
        guard lectura.estado == errSecSuccess || lectura.estado == errSecItemNotFound else {
            estado = .llaveroNoDisponible(lectura.estado)
            return
        }
        if lectura.estado == errSecSuccess {
            guard let datos = lectura.datos,
                  let cuenta = try? JSONDecoder().decode(Guardado.self, from: datos) else {
                estado = .llaveroNoDisponible(errSecDecode)
                return
            }
            guardado = cuenta
        } else { guardado = nil }
        error = nil
        recalcular()
    }

    var clienteID: String? { guardado?.clienteID }
    var puedeModificarCorreo: Bool {
        !comprobandoLlavero && correo != nil && !permisoPapeleraRechazado
            && guardado?.permisos?.contains(Self.permisoModificar) == true
    }
    var correo: String? {
        guard !comprobandoLlavero else { return nil }
        if case .conectada(let correo) = estado { return correo }
        return nil
    }

    var mensajePapeleraPendiente: String {
        if comprobandoLlavero { return "Comprobando la cuenta guardada en el Llavero…" }
        switch estado {
        case .sinCliente:
            return "Prepara la cuenta de Google para autorizar el traslado. Mientras tanto, Nuvex conservará los correos."
        case .llaveroNoDisponible:
            return "Recupera el acceso al Llavero para comprobar la cuenta. Mientras tanto, Nuvex conservará los correos."
        case .desconectada:
            return "Inicia sesión con Google para autorizar el traslado. Mientras tanto, Nuvex conservará los correos."
        case .esperandoNavegador:
            return "Completa el inicio de sesión en el navegador. Mientras tanto, Nuvex conservará los correos."
        case .caducada:
            return "La sesión de Google caducó. Vuelve a iniciar sesión; mientras tanto, Nuvex conservará los correos."
        case .conectada:
            return "Falta autorizar el traslado en Google. Mientras tanto, Nuvex conservará los correos."
        }
    }

    var problemaParaLeerCorreo: ProblemaGmail? {
        if comprobandoLlavero { return .llaveroNoDisponible }
        switch estado {
        case .sinCliente, .desconectada: return .sinCuenta
        case .llaveroNoDisponible: return .llaveroNoDisponible
        case .esperandoNavegador: return .inicioPendiente
        case .caducada: return .sesionCaducada
        case .conectada: return nil
        }
    }

    private func recalcular(caducada: Bool = false) {
        guard let guardado else { estado = .sinCliente; return }
        guard guardado.tokenRenovacion != nil, let correo = guardado.correo else { estado = .desconectada; return }
        estado = caducada ? .caducada(correo) : .conectada(correo)
    }

    // MARK: Cliente OAuth

    func guardarCliente(id: String, secreto: String) -> Bool {
        guard !comprobandoLlavero else { return false }
        if case .llaveroNoDisponible = estado {
            error = "Recupera primero el acceso al Llavero para conservar la cuenta guardada."
            return false
        }
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let secreto = secreto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(".apps.googleusercontent.com"), !secreto.isEmpty else {
            error = "El ID de cliente termina en .apps.googleusercontent.com y el secreto no puede estar vacío."
            return false
        }
        let nuevo = Guardado(clienteID: id, secreto: secreto)
        guard escribirLlavero(nuevo) else {
            error = "No se pudo guardar el cliente en el Llavero."
            return false
        }
        cancelarInicio()
        invalidarRenovacion()
        guardado = nuevo
        error = nil
        recalcular()
        return true
    }

    func olvidarCliente() async {
        var esperado = guardado
        esperado?.tokenRenovacion = nil
        esperado?.correo = nil
        esperado?.permisos = nil
        guard await cerrarSesion() else { return }
        guard guardado == esperado, idInicio == nil else {
            error = "La cuenta cambió mientras se cerraba la sesión. Revisa la cuenta actual antes de olvidarla."
            return
        }
        guard borradorLlavero() else {
            error = "No se pudo borrar el cliente del Llavero. La sesión se cerró, pero el cliente se conserva."
            return
        }
        guardado = nil
        recalcular()
    }

    // MARK: Sesión

    func iniciarSesion(modificarCorreo: Bool = false) {
        guard !comprobandoLlavero else { return }
        guard let guardado else { error = ErrorGoogle.sinCliente.localizedDescription; return }
        cancelarInicio()
        let id = UUID()
        idInicio = id
        let pedirTokens = self.pedirTokens
        let abrirNavegador = self.abrirNavegador
        let permisosSolicitados = Self.permisosOAuth(modificar: modificarCorreo)
        error = nil
        estado = .esperandoNavegador
        inicio = Task { [weak self] in
            guard self?.idInicio == id, !Task.isCancelled else { return }
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
                    URLQueryItem(name: "scope", value: permisosSolicitados),
                    URLQueryItem(name: "code_challenge", value: ExtractorCodigo.desafioPKCE(verificador)),
                    URLQueryItem(name: "code_challenge_method", value: "S256"),
                    URLQueryItem(name: "state", value: estadoOAuth),
                    URLQueryItem(name: "access_type", value: "offline"),
                    URLQueryItem(name: "prompt", value: "consent"),
                ]
                guard abrirNavegador(url.url!) else {
                    throw ErrorGoogle.respuesta("No se pudo abrir el navegador para iniciar sesión. Revisa el navegador predeterminado y vuelve a intentarlo.")
                }
                let respuesta = try await servidor.esperar()
                try Task.checkCancellation()
                guard self?.idInicio == id else { return }
                guard respuesta["state"] == estadoOAuth else { throw ErrorGoogle.respuesta("La respuesta de Google no corresponde a este inicio de sesión.") }
                if let fallo = respuesta["error"] {
                    throw fallo == "access_denied" ? ErrorGoogle.cancelado : ErrorGoogle.respuesta("Google respondió: \(fallo)")
                }
                guard let codigo = respuesta["code"] else { throw ErrorGoogle.respuesta("Google no devolvió el código de autorización.") }
                let tokens = try await pedirTokens([
                    "code": codigo, "client_id": guardado.clienteID, "client_secret": guardado.secreto,
                    "redirect_uri": servidor.direccion, "grant_type": "authorization_code", "code_verifier": verificador,
                ])
                try Task.checkCancellation()
                guard self?.idInicio == id else { return }
                guard let renovacion = tokens["refresh_token"] as? String else {
                    throw ErrorGoogle.respuesta("Google no entregó un token de renovación. Quita el acceso de Nuvex en tu cuenta de Google y vuelve a intentarlo.")
                }
                let correo = (tokens["id_token"] as? String).flatMap(ExtractorCodigo.correoDeIDToken) ?? "tu cuenta"
                self?.completarInicio(renovacion: renovacion, correo: correo, tokens: tokens,
                                     permisosSolicitados: permisosSolicitados)
            } catch {
                guard self?.idInicio == id else { return }
                self?.fallarInicio(error)
            }
        }
    }

    func cancelarInicio() {
        idInicio = nil
        inicio?.cancel()
        inicio = nil
        servidor?.cerrar()
        servidor = nil
        if estado == .esperandoNavegador { recalcular() }
    }

    private func completarInicio(renovacion: String, correo: String, tokens: [String: Any],
                                permisosSolicitados: String) {
        guard var guardado else { return }
        guardado.tokenRenovacion = renovacion
        guardado.correo = correo
        // OAuth permite omitir scope si coincide con lo solicitado. Si Google
        // devuelve una concesión parcial, se respeta exclusivamente esa lista.
        do {
            guardado.permisos = try Self.permisosConcedidos(tokens["scope"] as? String, solicitados: permisosSolicitados)
        } catch {
            fallarInicio(error)
            return
        }
        guard escribirLlavero(guardado) else {
            fallarInicio(ErrorGoogle.respuesta("No se pudo guardar la sesión en el Llavero."))
            return
        }
        invalidarRenovacion()
        self.guardado = guardado
        if let token = tokens["access_token"] as? String {
            acceso = (token, Date().addingTimeInterval(TimeInterval(tokens["expires_in"] as? Int ?? 3000)))
        }
        servidor = nil
        inicio = nil
        idInicio = nil
        error = nil
        Log.escribir("cuenta de Google conectada para leer códigos")
        recalcular()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func fallarInicio(_ fallo: Error) {
        servidor?.cerrar()
        servidor = nil
        inicio = nil
        idInicio = nil
        if fallo is CancellationError { recalcular(); return }
        error = fallo.localizedDescription
        Log.escribir("inicio de sesión de Google fallido: \(fallo.localizedDescription)")
        recalcular()
    }

    /// Revoca el acceso en Google y lo borra del Llavero. Conserva el cliente.
    @discardableResult
    func cerrarSesion() async -> Bool {
        guard !comprobandoLlavero else { return false }
        cancelarInicio()
        guard var nuevo = guardado else {
            if case .llaveroNoDisponible = estado {
                error = "Recupera el acceso al Llavero antes de cerrar o borrar la cuenta guardada."
                return false
            }
            return true
        }
        let token = nuevo.tokenRenovacion
        invalidarRenovacion()
        nuevo.tokenRenovacion = nil
        nuevo.correo = nil
        nuevo.permisos = nil
        guard escribirLlavero(nuevo) else {
            error = "No se pudo cerrar la sesión guardada en el Llavero. Se conserva la cuenta; recupera el acceso y reintenta."
            return false
        }
        guardado = nuevo
        error = nil
        recalcular()
        if let token {
            let aviso = await revocarToken(token)
            if guardado == nuevo, idInicio == nil { error = aviso }
        }
        return true
    }

    private static func revocarEnGoogle(_ token: String) async -> String? {
        var peticion = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        peticion.timeoutInterval = 15
        peticion.httpMethod = "POST"
        peticion.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        peticion.httpBody = Self.formulario(["token": token])
        do {
            let (_, respuesta) = try await URLSession.shared.data(for: peticion)
            return (respuesta as? HTTPURLResponse)?.statusCode == 200 ? nil
                : "Sesión cerrada en este equipo. Google no confirmó la revocación; revisa el acceso desde tu cuenta de Google."
        } catch {
            return "Sesión cerrada en este equipo. No se pudo confirmar la revocación en Google; revisa el acceso desde tu cuenta."
        }
    }

    func invalidarAcceso() { acceso = nil }

    /// Token de acceso vigente; lo renueva si caducó.
    func tokenAcceso() async throws -> String {
        while comprobandoLlavero { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        if case .llaveroNoDisponible = estado { throw ProblemaGmail.llaveroNoDisponible }
        if let acceso, acceso.caduca > Date().addingTimeInterval(60) { return acceso.token }
        let sesion = idSesion
        let actual: RenovacionEnCurso
        if let renovacionEnCurso {
            actual = renovacionEnCurso
        } else {
            guard let guardado else { throw ErrorGoogle.sinCliente }
            guard let renovacion = guardado.tokenRenovacion else { throw ErrorGoogle.sinSesion }
            let pedirTokens = self.pedirTokens
            let tarea: Task<(token: String, caduca: Date), Error> = Task {
                let tokens = try await pedirTokens([
                    "client_id": guardado.clienteID, "client_secret": guardado.secreto,
                    "refresh_token": renovacion, "grant_type": "refresh_token",
                ])
                guard let token = tokens["access_token"] as? String else {
                    throw ErrorGoogle.respuesta("Google no devolvió un token de acceso.")
                }
                return (token: token, caduca: Date().addingTimeInterval(TimeInterval(tokens["expires_in"] as? Int ?? 3000)))
            }
            actual = RenovacionEnCurso(id: UUID(), tarea: tarea)
            renovacionEnCurso = actual
        }
        defer {
            if renovacionEnCurso?.id == actual.id { renovacionEnCurso = nil }
        }
        do {
            let renovado = try await actual.tarea.value
            // La retirada normal de la tarea no equivale a cerrar sesión:
            // varios consumidores pueden reanudarse después de ese defer.
            guard idSesion == sesion else { throw ErrorGoogle.sinSesion }
            if renovacionEnCurso?.id == actual.id {
                acceso = renovado
                if case .caducada = estado { recalcular() }
            }
            return renovado.token
        } catch {
            guard idSesion == sesion else { throw ErrorGoogle.sinSesion }
            if case ErrorGoogle.respuesta(let detalle) = error, detalle.contains("invalid_grant") {
                if renovacionEnCurso?.id == actual.id, idInicio == nil {
                    Log.escribir("la sesión de Google caducó")
                    recalcular(caducada: true)
                }
                throw ErrorGoogle.caducada
            }
            throw error
        }
    }

    /// Impide que una respuesta tardía de OAuth restaure un token de acceso
    /// después de cerrar sesión o reemplazar el cliente configurado.
    private func invalidarRenovacion() {
        renovacionEnCurso?.tarea.cancel()
        renovacionEnCurso = nil
        acceso = nil
        idSesion = UUID()
        avisoPapelera = nil
        permisoPapeleraRechazado = false
    }

    /// Operación secundaria: nunca cambia el resultado de la conexión VPN ni
    /// abre OAuth. La referencia impide usar un ID en otra cuenta o sesión.
    func moverCorreoUsado(_ mensaje: MensajeCodigoGmail,
                         preferencias: Preferencias? = nil,
                         mover: (String, String) async throws -> Void = PapeleraGmail.mover) async {
        let preferencias = preferencias ?? .shared
        guard mensaje.sesion == idSesion, preferencias.soloLectura == nil,
              preferencias.ajustes.enviarCorreoPapelera, puedeModificarCorreo else { return }
        do {
            let token = try await tokenAcceso()
            guard mensaje.sesion == idSesion, preferencias.soloLectura == nil,
                  preferencias.ajustes.enviarCorreoPapelera, puedeModificarCorreo else { return }
            try await mover(mensaje.id, token)
            guard mensaje.sesion == idSesion else { return }
            Log.escribir("gmail estado=correo_en_papelera")
        } catch {
            guard mensaje.sesion == idSesion else { return }
            if let problema = error as? ProblemaGmail, problema == .sesionCaducada { invalidarAcceso() }
            if let problema = error as? ProblemaGmail, problema == .sinPermiso {
                permisoPapeleraRechazado = true
                avisoPapelera = "Falta permiso para mover el correo utilizado. Autoriza la papelera en Cuenta de Google."
            } else {
                avisoPapelera = "Gmail no confirmó el traslado de un correo utilizado. Revisa el mensaje en Gmail y muévelo a la papelera si sigue allí."
            }
            Log.escribir("gmail estado=papelera_sin_confirmar")
        }
    }

    func descartarAvisoPapelera() { avisoPapelera = nil }

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

    nonisolated private static let servicio = "nuvex.google"
    nonisolated private static let cuenta = "cuenta"

    nonisolated private static func leerLlavero(interactivo: Bool) -> (datos: Data?, estado: OSStatus) {
        let contexto = LAContext()
        contexto.interactionNotAllowed = !interactivo
        let consulta: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: servicio, kSecAttrAccount as String: cuenta,
                                       kSecUseAuthenticationContext as String: contexto,
                                       kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var resultado: CFTypeRef?
        let estado = SecItemCopyMatching(consulta as CFDictionary, &resultado)
        return (resultado as? Data, estado)
    }

    private func escribirLlavero(_ guardado: Guardado) -> Bool {
        guard let datos = try? JSONEncoder().encode(guardado) else { return false }
        return escritorLlavero(datos)
    }

    private static func escribirDatosLlavero(_ datos: Data) -> Bool {
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

    private static func borrarLlavero() -> Bool {
        let consulta: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: servicio, kSecAttrAccount as String: cuenta]
        let resultado = SecItemDelete(consulta as CFDictionary)
        return resultado == errSecSuccess || resultado == errSecItemNotFound
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
