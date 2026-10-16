import Foundation

// MARK: - Modelo de datos

struct VPNStatus: Decodable, Identifiable {
    let id: String
    let name: String
    let connected: Bool
    let pid: Int
    // El motor no conoce estos datos; la app los completa leyendo el sistema
    // (ver DetallesTunel) mientras la VPN esta conectada.
    var ip: String
    var iface: String
    var networks: [String]
    let enabled: Bool
    let configured: Bool
    let helperReady: Bool
    var inicio: Date? = nil
}

struct VPNProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var server: String
    var username: String
    var trust: String
    var realm: String
    var manageRoutes: Bool
    var manageDNS: Bool
    var enabled: Bool

    static func nuevo() -> VPNProfile {
        VPNProfile(id: "vpn-" + UUID().uuidString.lowercased(), name: "", server: "", username: "",
                   trust: "system", realm: "", manageRoutes: true, manageDNS: true, enabled: true)
    }

    var normalizado: VPNProfile {
        var copia = self
        copia.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        copia.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        return copia
    }
}

enum PasswordStatus: Equatable {
    case saved
    case missing
    case error(Int32)
}

/// Fallo de conexión explicado para personas: un título corto para la fila
/// del panel, un detalle completo y la acción que lo resuelve.
struct Fallo: Equatable {
    enum Accion: Equatable {
        case reintentar(String)
        case ajustes(String)
        case ninguna
    }
    let titulo: String
    let detalle: String
    let accion: Accion

    /// Clasifica la salida del motor (openfortivpn y nuvexctl). La salida
    /// original queda en el registro para diagnóstico.
    static func interpretar(_ salida: String, codigoCancelado: Bool = false) -> Fallo {
        if codigoCancelado {
            return Fallo(titulo: "Conexión cancelada",
                         detalle: "No se introdujo el código de verificación.",
                         accion: .reintentar("Conectar"))
        }
        func tiene(_ texto: String) -> Bool { salida.localizedCaseInsensitiveContains(texto) }
        if tiene("NUVEX_TLS_VERIFY_FAILED") || tiene("Gateway certificate validation failed") {
            return Fallo(titulo: "Certificado no verificado",
                         detalle: "El certificado del servidor no coincide con la confianza TLS de esta conexión. Revísala o actualiza el ayudante.",
                         accion: .ajustes("Revisar…"))
        }
        if tiene("tunnel mode is allowed") {
            return Fallo(titulo: "El servidor rechazó el túnel",
                         detalle: "El portal no inició el túnel SSL VPN. Revisa el realm y confirma con el administrador que tu usuario tenga permiso para el modo túnel.",
                         accion: .ajustes("Revisar…"))
        }
        if tiene("Could not authenticate to gateway") || tiene("Authentication failed") {
            return Fallo(titulo: "Autenticación rechazada",
                         detalle: "Revisa el usuario, la contraseña y el código si se solicitó. Si son correctos, consulta si el servidor exige un certificado de cliente u otro método de acceso.",
                         accion: .ajustes("Cambiar…"))
        }
        if tiene("getaddrinfo") {
            return Fallo(titulo: "No se encuentra el servidor",
                         detalle: "No se pudo resolver la dirección del servidor. Revisa cómo está escrita o tu conexión a Internet.",
                         accion: .ajustes("Revisar…"))
        }
        if tiene("timed out") || tiene("Connection refused") || tiene("Network is unreachable")
            || tiene("no establecio el tunel") {
            return Fallo(titulo: "El servidor no responde",
                         detalle: "No hubo respuesta del servidor. Puede estar caído o bloqueado por la red actual.",
                         accion: .reintentar("Reintentar"))
        }
        if tiene("instala o actualiza el ayudante") {
            return Fallo(titulo: "El ayudante necesita actualizarse",
                         detalle: "La configuración cambió desde que se instaló el ayudante de red. Nuvex pedirá autorización a macOS para actualizarlo.",
                         accion: .reintentar("Preparar"))
        }
        if tiene("la VPN ya esta activa") {
            return Fallo(titulo: "Ya hay un túnel activo",
                         detalle: "Esta VPN ya tiene un túnel en marcha. Desconéctala antes de volver a conectar.",
                         accion: .ninguna)
        }
        let ultima = salida.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty && !$0.hasPrefix("NUVEX_") })
            .map { $0.hasPrefix("nuvex: ") ? String($0.dropFirst(7)) : $0 }
        return Fallo(titulo: "No se pudo conectar",
                     detalle: ultima ?? "El motor terminó sin dar detalles. Consulta el registro.",
                     accion: .reintentar("Reintentar"))
    }
}

/// Result exige que el tipo de fallo conforme a Error, y String no lo hace.
struct ErrorVPN: LocalizedError {
    let mensaje: String
    var fallo: Fallo? = nil
    var errorDescription: String? { mensaje }

    var falloParaFila: Fallo {
        fallo ?? Fallo(titulo: "No se pudo conectar", detalle: mensaje, accion: .reintentar("Reintentar"))
    }
}

/// Estado en el que puede encontrarse una VPN desde el punto de vista de la
/// interfaz. `conectando` no viene del motor: lo mantiene la app mientras el
/// proceso de conexion esta en marcha, porque puede tardar (sobre todo cuando
/// hay que esperar al codigo del correo).
enum EstadoUI: Equatable {
    case desconectada
    case conectando
    case conectada
    case error(Fallo)
}

// MARK: - Validación compartida por Ajustes y la bienvenida

enum Validacion {
    // Misma regla que nuvexconfig.py para que el aviso aparezca antes de guardar.
    static func servidorValido(_ servidor: String) -> Bool {
        let patron = #"^(?:https://)?(?:[A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9a-fA-F:]+\])(?::([0-9]{1,5}))?/?$"#
        guard let regex = try? NSRegularExpression(pattern: patron),
              let match = regex.firstMatch(in: servidor, range: NSRange(servidor.startIndex..., in: servidor))
        else { return false }
        if let rango = Range(match.range(at: 1), in: servidor), let puerto = Int(servidor[rango]) {
            return (1...65535).contains(puerto)
        }
        return true
    }

    static func huellaValida(_ trust: String) -> Bool {
        if trust == "system" || trust == "bundle" { return true }
        guard trust.hasPrefix("sha256:") else { return false }
        let huella = trust.dropFirst(7)
        return huella.count == 64 && huella.allSatisfy { "0123456789abcdefABCDEF".contains($0) }
    }

    private static func contieneControles(_ texto: String) -> Bool {
        texto.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    static func vacio(_ texto: String) -> Bool {
        texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Primer motivo por el que la conexión no se puede guardar, o nil.
    static func motivo(_ perfil: VPNProfile) -> String? {
        let normalizado = perfil.normalizado
        if vacio(perfil.name) { return "Falta el nombre de la conexión." }
        if perfil.name.unicodeScalars.count > 60 { return "El nombre admite hasta 60 caracteres." }
        if contieneControles(perfil.name) { return "El nombre contiene caracteres no permitidos." }
        if perfil.enabled && vacio(normalizado.server) { return "Falta el servidor." }
        if normalizado.server.unicodeScalars.count > 255 { return "El servidor admite hasta 255 caracteres." }
        if !vacio(normalizado.server) && !servidorValido(normalizado.server) {
            return "El servidor debe tener la forma host:puerto, por ejemplo vpn.empresa.com:443."
        }
        if perfil.enabled && vacio(normalizado.username) { return "Falta el usuario." }
        if normalizado.username.unicodeScalars.count > 128 { return "El usuario admite hasta 128 caracteres." }
        if contieneControles(normalizado.username) { return "El usuario contiene caracteres no permitidos." }
        if perfil.realm.unicodeScalars.count > 128 { return "El realm admite hasta 128 caracteres." }
        if contieneControles(perfil.realm) { return "El realm contiene caracteres no permitidos." }
        if !huellaValida(perfil.trust) {
            return perfil.trust.hasPrefix("sha256:")
                ? "La huella SHA-256 debe tener 64 caracteres hexadecimales."
                : "Selecciona un método válido de confianza TLS."
        }
        return nil
    }
}

enum Formato {
    /// "ahora", "12 min", "1 h 12 min", "2 d 3 h".
    static func duracion(desde inicio: Date, hasta fin: Date = Date()) -> String {
        let minutos = max(0, Int(fin.timeIntervalSince(inicio) / 60))
        if minutos < 1 { return "ahora" }
        if minutos < 60 { return "\(minutos) min" }
        let horas = minutos / 60
        if horas < 24 { return minutos % 60 == 0 ? "\(horas) h" : "\(horas) h \(minutos % 60) min" }
        return horas % 24 == 0 ? "\(horas / 24) d" : "\(horas / 24) d \(horas % 24) h"
    }
}
