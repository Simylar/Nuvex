import Foundation

/// Evita que el temporizador de un intento anterior afecte a una reconexión
/// posterior del mismo perfil.
enum VigenciaIntentoConexion {
    static func corresponde(_ intento: Date, al inicioActual: Date?) -> Bool {
        inicioActual == intento
    }
}

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

enum EstadoMotor {
    /// Solo una respuesta válida del motor puede confirmar que se detuvieron
    /// todos los túneles solicitados. Una consulta fallida nunca cuenta como éxito.
    static func confirmaDesconexion(_ ids: Set<String>, codigo: Int32, salida: String) -> Bool {
        guard !ids.isEmpty, codigo == 0, let datos = salida.data(using: .utf8),
              let lista = try? JSONDecoder().decode([VPNStatus].self, from: datos) else { return false }
        return ids.allSatisfy { id in lista.first(where: { $0.id == id })?.connected == false }
    }
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

    var etiquetaLlavero: String { "Nuvex: \(name)" }

    /// Solo para altas desde la interfaz. Los perfiles importados conservan su
    /// validación estricta y un nombre escrito nunca se reemplaza.
    var conNombreSugerido: VPNProfile {
        var copia = normalizado
        guard Validacion.vacio(name), Validacion.servidorValido(copia.server) else { return copia }
        let direccion = copia.server.hasPrefix("https://") ? copia.server : "https://" + copia.server
        if let host = URLComponents(string: direccion)?.host {
            copia.name = String(host.unicodeScalars.prefix(60))
        }
        return copia
    }
}

/// Un intento automático por conexión iniciada por la persona. Una reconexión
/// exitosa no repone el presupuesto: evita bucles y bloqueos de la cuenta.
struct RecuperacionConexion {
    private var intentadas: Set<String> = []

    mutating func permitirNuevoIntento(_ id: String) { intentadas.remove(id) }

    func puedeIntentar(_ id: String) -> Bool { !intentadas.contains(id) }

    mutating func reservar(_ id: String, activada: Bool, disponible: Bool) -> Bool {
        guard activada, disponible else { return false }
        return intentadas.insert(id).inserted
    }
}

/// Seleccionar una tarea al reabrir nunca inicia ni cambia una VPN.
enum ReaperturaNuvex {
    static func conexion(perfiles: [VPNProfile], estados: [String: EstadoUI], enCurso: Set<String>) -> String? {
        let visibles = perfiles.filter(\.enabled)
        return visibles.first(where: { if case .error = estados[$0.id] { return true }; return false })?.id
            ?? visibles.first(where: { enCurso.contains($0.id) })?.id
            ?? visibles.first(where: { estados[$0.id] == .conectada })?.id
            ?? visibles.first?.id
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
    enum Codigo: String, Equatable {
        case cancelada
        case certificado
        case tunelRechazado
        case autenticacion
        case servidorNoEncontrado
        case servidorNoResponde
        case ayudante
        case tunelActivo
        case agotado
        case desconocido
    }

    enum Accion: Equatable {
        case reintentar(String)
        case ajustes(String)
        case ninguna
    }
    let titulo: String
    let detalle: String
    let accion: Accion
    let codigo: Codigo

    init(titulo: String, detalle: String, accion: Accion, codigo: Codigo = .desconocido) {
        self.titulo = titulo
        self.detalle = detalle
        self.accion = accion
        self.codigo = codigo
    }

    /// La persona canceló el intento; no es un error que mostrar.
    static let canceladaPorPersona = Fallo(titulo: "Conexión cancelada", detalle: "Cancelaste el intento de conexión.",
                                           accion: .reintentar("Conectar"), codigo: .cancelada)

    /// Clasifica la salida del motor (openfortivpn y nuvexctl). La salida
    /// original queda en el registro para diagnóstico.
    static func interpretar(_ salida: String, codigoCancelado: Bool = false) -> Fallo {
        if codigoCancelado {
            return Fallo(titulo: "Conexión cancelada",
                         detalle: "No se introdujo el código de verificación.",
                         accion: .reintentar("Conectar"), codigo: .cancelada)
        }
        func tiene(_ texto: String) -> Bool { salida.localizedCaseInsensitiveContains(texto) }
        if tiene("NUVEX_TLS_VERIFY_FAILED") || tiene("Gateway certificate validation failed") {
            return Fallo(titulo: "Certificado no verificado",
                         detalle: "El certificado del servidor no coincide con la confianza TLS de esta conexión. Revísala o actualiza el ayudante.",
                         accion: .ajustes("Revisar…"), codigo: .certificado)
        }
        if tiene("tunnel mode is allowed") {
            return Fallo(titulo: "El servidor rechazó el túnel",
                         detalle: "El portal no inició el túnel SSL VPN. Revisa el realm y confirma con el administrador que tu usuario tenga permiso para el modo túnel.",
                         accion: .ajustes("Revisar…"), codigo: .tunelRechazado)
        }
        if tiene("Could not authenticate to gateway") || tiene("Authentication failed") {
            return Fallo(titulo: "Autenticación rechazada",
                         detalle: "Revisa el usuario, la contraseña y el código si se solicitó. Si son correctos, consulta si el servidor exige un certificado de cliente u otro método de acceso.",
                         accion: .ajustes("Cambiar…"), codigo: .autenticacion)
        }
        if tiene("getaddrinfo") {
            return Fallo(titulo: "No se encuentra el servidor",
                         detalle: "No se pudo resolver la dirección del servidor. Revisa cómo está escrita o tu conexión a Internet.",
                         accion: .ajustes("Revisar…"), codigo: .servidorNoEncontrado)
        }
        if tiene("timed out") || tiene("Connection refused") || tiene("Network is unreachable")
            || tiene("no establecio el tunel") {
            return Fallo(titulo: "El servidor no responde",
                         detalle: "No hubo respuesta del servidor. Puede estar caído o bloqueado por la red actual.",
                         accion: .reintentar("Reintentar"), codigo: .servidorNoResponde)
        }
        if tiene("instala o actualiza el ayudante") {
            return Fallo(titulo: "El ayudante necesita actualizarse",
                         detalle: "La configuración cambió desde que se instaló el ayudante de red. Nuvex pedirá autorización a macOS para actualizarlo.",
                         accion: .reintentar("Preparar"), codigo: .ayudante)
        }
        if tiene("la VPN ya esta activa") {
            return Fallo(titulo: "Ya hay un túnel activo",
                         detalle: "Esta VPN ya tiene un túnel en marcha. Desconéctala antes de volver a conectar.",
                         accion: .ninguna, codigo: .tunelActivo)
        }
        return Fallo(titulo: "No se pudo conectar",
                     detalle: "Comprueba tu conexión a Internet y vuelve a intentarlo. Si el problema continúa, abre el registro para consultar el diagnóstico.",
                     accion: .reintentar("Reintentar"), codigo: .desconocido)
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

/// Qué se guardó y qué quedó pendiente al guardar conexiones. Guardar tiene
/// pasos independientes que pueden fallar por separado.
struct ResumenGuardado: Equatable, Sendable {
    enum Paso: Equatable, Sendable {
        case hecho
        case enCurso
        /// Se hará más adelante; el texto dice cuándo.
        case pendiente(String)
        case fallo(String)
        case noAplica
    }

    var conexiones: Paso
    var contrasenas: Paso = .noAplica
    var ayudante: Paso = .noAplica
    var ajustes: Paso = .noAplica

    var pasos: [(titulo: String, paso: Paso)] {
        [("Conexiones", conexiones), ("Lectura de códigos", ajustes), ("Contraseñas en el Llavero", contrasenas), ("Ayudante de red", ayudante)]
            .filter { $0.paso != .noAplica }
    }

    var hayProblemas: Bool {
        pasos.contains { if case .fallo = $0.paso { return true }; if case .pendiente = $0.paso { return true }; return false }
    }

    var enCurso: Bool { pasos.contains { $0.paso == .enCurso } }

    /// Una línea para la barra de guardado.
    var resumen: String {
        if case .fallo = conexiones { return "No se guardaron los cambios" }
        if case .pendiente = conexiones { return "Revisa el estado de las conexiones antes de continuar" }
        if case .fallo = ajustes { return "Conexiones guardadas; falta guardar la lectura de códigos" }
        if case .fallo = contrasenas { return "Conexión guardada, pero falta una contraseña en el Llavero" }
        if case .fallo = ayudante { return "Conexión guardada; falta preparar el ayudante de red" }
        if case .pendiente = ayudante { return "Conexión guardada; el ayudante se preparará al volver a conectar" }
        if enCurso { return "Cambios guardados. Aplicando…" }
        return ayudante == .hecho ? "Cambios guardados y aplicados." : "Cambios guardados."
    }
}

// MARK: - Validación compartida por Ajustes y la bienvenida

enum Validacion {
    static func validarColeccion(_ perfiles: [VPNProfile]) throws {
        guard perfiles.count <= 64, Set(perfiles.map(\.id)).count == perfiles.count else {
            throw ErrorVPN(mensaje: "La configuración debe tener hasta 64 conexiones con identificadores únicos.")
        }
        for perfil in perfiles {
            guard perfil.id.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil else {
                throw ErrorVPN(mensaje: "La configuración contiene un identificador de conexión inválido.")
            }
            if let motivo = motivo(perfil) { throw ErrorVPN(mensaje: motivo) }
        }
    }
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
            return "Escribe la dirección del servidor, por ejemplo vpn.empresa.com. Añade :puerto solo si te lo indicaron."
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
