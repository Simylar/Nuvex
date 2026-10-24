import Foundation

/// Por qué no se pudo leer el código del correo, explicado para la persona y
/// con lo que puede hacer para resolverlo.
enum ProblemaGmail: LocalizedError, Equatable, Sendable {
    /// Google invalidó la sesión (`invalid_grant`): hay que volver a iniciarla.
    case sesionCaducada
    /// No hay cuenta conectada o falta el cliente OAuth.
    case sinCuenta
    /// El cliente OAuth no es válido (`invalid_client`, `unauthorized_client`).
    case clienteNoValido
    /// La sesión no tiene el permiso de lectura de Gmail.
    case sinPermiso
    /// La Gmail API no está activada en el proyecto de Google Cloud.
    case apiDesactivada
    /// Demasiadas consultas seguidas.
    case limite
    /// No hay conexión con Google.
    case sinRed
    /// Google respondió con un error inesperado.
    case servidor(Int)

    enum Accion: Equatable, Sendable {
        /// Volver a iniciar sesión en Ajustes › Cuenta de Google.
        case cuentaGoogle
        /// Abrir la Gmail API en la consola de Google Cloud.
        case activarAPI
        /// Volver a buscar el correo.
        case reintentar
    }

    var titulo: String {
        switch self {
        case .sesionCaducada: return "La sesión de Google caducó"
        case .sinCuenta: return "No hay ninguna cuenta de Google conectada"
        case .clienteNoValido: return "Google rechazó el cliente OAuth"
        case .sinPermiso: return "Falta el permiso para leer Gmail"
        case .apiDesactivada: return "La Gmail API está desactivada"
        case .limite: return "Google pidió esperar un momento"
        case .sinRed: return "Sin conexión con Gmail"
        case .servidor: return "Gmail no respondió bien"
        }
    }

    /// Identificador estable y sin datos personales para el registro.
    var codigoDiagnostico: String {
        switch self {
        case .sesionCaducada: return "sesion_caducada"
        case .sinCuenta: return "sin_cuenta"
        case .clienteNoValido: return "cliente_no_valido"
        case .sinPermiso: return "sin_permiso"
        case .apiDesactivada: return "api_desactivada"
        case .limite: return "limite"
        case .sinRed: return "sin_red"
        case .servidor(let codigo): return "servidor_\(codigo)"
        }
    }

    var detalle: String {
        switch self {
        case .sesionCaducada:
            return "Vuelve a iniciar sesión en Ajustes › Cuenta de Google. Si pasa cada 7 días, publica la app de tu proyecto de Google Cloud (docs/gmail.md)."
        case .sinCuenta:
            return "Conecta tu cuenta en Ajustes › Cuenta de Google para que Nuvex lea el código."
        case .clienteNoValido:
            return "Revisa el ID y el secreto del cliente en Ajustes › Cuenta de Google; quizá se borró o cambió en Google Cloud."
        case .sinPermiso:
            return "Al iniciar sesión no se concedió la lectura de Gmail. Desconecta la cuenta y vuelve a conectarla marcando ese permiso."
        case .apiDesactivada:
            return "Actívala en la consola de Google Cloud, en el mismo proyecto del cliente OAuth, y vuelve a intentarlo en un minuto."
        case .limite:
            return "Nuvex volverá a intentarlo en unos segundos."
        case .sinRed:
            return "Revisa tu conexión a Internet. Nuvex sigue intentándolo mientras espera el código."
        case .servidor(let codigo):
            let respuesta = codigo > 0 ? "Google respondió con el código \(codigo)." : "Google devolvió un error inesperado."
            return respuesta + " Nuvex sigue intentándolo mientras espera el código."
        }
    }

    var errorDescription: String? { "\(titulo). \(detalle)" }

    var accion: Accion {
        switch self {
        case .sesionCaducada, .sinCuenta, .clienteNoValido, .sinPermiso: return .cuentaGoogle
        case .apiDesactivada: return .activarAPI
        case .limite, .sinRed, .servidor: return .reintentar
        }
    }

    /// Si es definitivo no tiene sentido seguir consultando: no se resolverá
    /// solo mientras se espera el código.
    var definitivo: Bool { accion != .reintentar }

    static let consolaGmailAPI = URL(string: "https://console.cloud.google.com/apis/library/gmail.googleapis.com")!

    /// Clasifica una respuesta de error de la Gmail API.
    static func clasificar(estado: Int, cuerpo: Data) -> ProblemaGmail {
        let json = (try? JSONSerialization.jsonObject(with: cuerpo) as? [String: Any]) ?? [:]
        let error = json["error"] as? [String: Any] ?? [:]
        var razones = Set<String>()
        for lista in [error["errors"], error["details"]] {
            for elemento in lista as? [[String: Any]] ?? [] {
                if let razon = elemento["reason"] as? String { razones.insert(razon) }
            }
        }
        if let estadoTexto = error["status"] as? String { razones.insert(estadoTexto) }
        let mensaje = (error["message"] as? String ?? "").lowercased()

        if razones.contains("accessNotConfigured") || razones.contains("SERVICE_DISABLED")
            || mensaje.contains("has not been used in project") || mensaje.contains("it is disabled") {
            return .apiDesactivada
        }
        if razones.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") || razones.contains("insufficientPermissions")
            || mensaje.contains("insufficient authentication scopes") {
            return .sinPermiso
        }
        if estado == 429 || razones.contains("rateLimitExceeded") || razones.contains("userRateLimitExceeded")
            || razones.contains("RESOURCE_EXHAUSTED") {
            return .limite
        }
        if estado == 401 { return .sesionCaducada }
        if estado == 403 { return .sinPermiso }
        return .servidor(estado)
    }

    /// Clasifica un error del servidor de tokens de Google (`/token`).
    static func clasificarToken(_ codigoError: String) -> ProblemaGmail {
        switch codigoError {
        case "invalid_grant": return .sesionCaducada
        case "invalid_client", "unauthorized_client", "deleted_client": return .clienteNoValido
        default: return .servidor(400)
        }
    }

    /// Clasifica un error de red de URLSession.
    static func clasificar(_ error: Error) -> ProblemaGmail? {
        if let problema = error as? ProblemaGmail { return problema }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nil }
        return .sinRed
    }
}
