import Foundation

/// Datos mínimos que Nuvex exige antes de entregar una actualización a
/// Sparkle. La firma EdDSA sigue siendo la autoridad sobre el contenido; estas
/// reglas evitan instalar por accidente un paquete o un canal inesperados.
struct CandidatoActualizacion: Equatable {
    let version: String
    let compilacion: String
    let canal: String?
    let direccion: URL?
    let tipoInstalacion: String
    let tamano: UInt64?
}

enum ErrorPreparacionActualizacion: LocalizedError, Equatable {
    case versionInvalida
    case versionAnterior
    case compilacionInvalida
    case compilacionNoSuperior
    case canalNoPermitido
    case direccionInsegura
    case tipoNoCompatible
    case espacioInsuficiente(necesario: Int64, disponible: Int64)

    var errorDescription: String? {
        switch self {
        case .versionInvalida:
            return "La actualización no declara una versión válida."
        case .versionAnterior:
            return "La actualización declara una versión anterior a la instalada."
        case .compilacionInvalida:
            return "La actualización no declara un número de compilación válido."
        case .compilacionNoSuperior:
            return "La actualización no es más nueva que la versión instalada."
        case .canalNoPermitido:
            return "La actualización pertenece a un canal que no está habilitado."
        case .direccionInsegura:
            return "La actualización no se descargaría mediante una conexión HTTPS válida."
        case .tipoNoCompatible:
            return "La actualización no contiene una aplicación compatible."
        case .espacioInsuficiente(let necesario, let disponible):
            let formato = ByteCountFormatter()
            formato.countStyle = .file
            return "No hay espacio suficiente para preparar la actualización. Se necesitan aproximadamente \(formato.string(fromByteCount: necesario)) y hay \(formato.string(fromByteCount: disponible)) disponibles."
        }
    }
}

/// Implementación estricta y pequeña de SemVer 2.0.0. Los metadatos de
/// compilación se validan, pero no intervienen en la precedencia.
struct VersionSemantica: Comparable, Equatable {
    private enum Identificador: Equatable {
        case numerico(String)
        case texto(String)
    }

    private let mayor: String
    private let menor: String
    private let parche: String
    private let preliminar: [Identificador]

    init?(_ valor: String) {
        let partesMetadatos = valor.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard partesMetadatos.count <= 2,
              partesMetadatos.count == 1 || Self.identificadoresValidos(partesMetadatos[1]) else {
            return nil
        }
        let partesPreliminares = partesMetadatos[0].split(
            separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard partesPreliminares.count <= 2 else { return nil }
        let nucleo = partesPreliminares[0].split(separator: ".", omittingEmptySubsequences: false)
        guard nucleo.count == 3,
              let mayor = Self.numeroNucleo(nucleo[0]),
              let menor = Self.numeroNucleo(nucleo[1]),
              let parche = Self.numeroNucleo(nucleo[2]) else { return nil }

        var preliminar: [Identificador] = []
        if partesPreliminares.count == 2 {
            let componentes = partesPreliminares[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !componentes.isEmpty else { return nil }
            for componente in componentes {
                guard Self.identificadorValido(componente) else { return nil }
                if Self.esNumerico(componente) {
                    guard componente.count == 1 || componente.first != "0" else { return nil }
                    preliminar.append(.numerico(String(componente)))
                } else {
                    preliminar.append(.texto(String(componente)))
                }
            }
        }
        self.mayor = mayor
        self.menor = menor
        self.parche = parche
        self.preliminar = preliminar
    }

    static func < (izquierda: VersionSemantica, derecha: VersionSemantica) -> Bool {
        for (a, b) in zip([izquierda.mayor, izquierda.menor, izquierda.parche],
                          [derecha.mayor, derecha.menor, derecha.parche]) where a != b {
            return comparaNumeros(a, b)
        }
        if izquierda.preliminar.isEmpty { return false }
        if derecha.preliminar.isEmpty { return true }
        for (a, b) in zip(izquierda.preliminar, derecha.preliminar) where a != b {
            switch (a, b) {
            case (.numerico(let x), .numerico(let y)): return comparaNumeros(x, y)
            case (.numerico, .texto): return true
            case (.texto, .numerico): return false
            case (.texto(let x), .texto(let y)): return x < y
            }
        }
        return izquierda.preliminar.count < derecha.preliminar.count
    }

    private static func numeroNucleo(_ valor: Substring) -> String? {
        guard esNumerico(valor),
              valor.count == 1 || valor.first != "0" else { return nil }
        return String(valor)
    }

    private static func identificadoresValidos(_ valor: Substring) -> Bool {
        let componentes = valor.split(separator: ".", omittingEmptySubsequences: false)
        return !componentes.isEmpty && componentes.allSatisfy(identificadorValido)
    }

    private static func identificadorValido(_ valor: Substring) -> Bool {
        !valor.isEmpty && valor.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122) || $0 == 45
        }
    }

    private static func esNumerico(_ valor: Substring) -> Bool {
        !valor.isEmpty && valor.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func comparaNumeros(_ izquierda: String, _ derecha: String) -> Bool {
        izquierda.count == derecha.count ? izquierda < derecha : izquierda.count < derecha.count
    }
}

enum PreparacionActualizacion {
    private static let reservaMinima: Int64 = 250 * 1_024 * 1_024
    private static let margen: Int64 = 50 * 1_024 * 1_024

    static func validar(_ candidato: CandidatoActualizacion, actual: InfoVersion,
                        permiteBeta: Bool, capacidadDisponible: Int64?) throws {
        guard let versionCandidata = VersionSemantica(candidato.version),
              let versionActual = VersionSemantica(actual.corta) else {
            throw ErrorPreparacionActualizacion.versionInvalida
        }
        guard versionCandidata >= versionActual else {
            throw ErrorPreparacionActualizacion.versionAnterior
        }
        guard let compilacion = Int(candidato.compilacion), compilacion > 0 else {
            throw ErrorPreparacionActualizacion.compilacionInvalida
        }
        guard compilacion > actual.compilacion else {
            throw ErrorPreparacionActualizacion.compilacionNoSuperior
        }
        switch candidato.canal {
        case nil, "": break
        case "beta" where permiteBeta: break
        default: throw ErrorPreparacionActualizacion.canalNoPermitido
        }
        guard candidato.direccion?.scheme?.lowercased() == "https",
              candidato.direccion?.host?.isEmpty == false else {
            throw ErrorPreparacionActualizacion.direccionInsegura
        }
        guard candidato.tipoInstalacion == "application" else {
            throw ErrorPreparacionActualizacion.tipoNoCompatible
        }
        if let capacidadDisponible {
            let necesario = espacioNecesario(tamano: candidato.tamano)
            guard capacidadDisponible >= necesario else {
                throw ErrorPreparacionActualizacion.espacioInsuficiente(
                    necesario: necesario, disponible: max(0, capacidadDisponible))
            }
        }
    }

    /// Descarga, extracción y reemplazo temporal pueden coexistir. Se reserva
    /// tres veces el archivo más un margen, con un mínimo prudente de 250 MB.
    static func espacioNecesario(tamano: UInt64?) -> Int64 {
        guard let tamano, tamano > 0, tamano <= UInt64((Int64.max - margen) / 3) else {
            return reservaMinima
        }
        return max(reservaMinima, Int64(tamano) * 3 + margen)
    }
}

enum EtapaPresentacionActualizacion {
    case sinDescargar
    case descargada
    case instalando
}

enum AccionPresentacionActualizacion: Equatable {
    case iniciarDescarga
    case instalarAhora
    case mostrarDisponible
    case mantenerProgramada
}

/// Decide cómo responder a Sparkle sin mezclar sus etapas con el estado de la
/// interfaz. Solo una acción iniciada expresamente por el usuario puede pedir
/// un reinicio inmediato.
enum PoliticaPresentacionActualizacion {
    static func accion(etapa: EtapaPresentacionActualizacion,
                       iniciadaPorUsuario: Bool,
                       instalarAhora: Bool) -> AccionPresentacionActualizacion {
        let autorizada = iniciadaPorUsuario && instalarAhora
        switch etapa {
        case .sinDescargar, .descargada:
            // `.descargada` todavía necesita que Sparkle extraiga y verifique
            // el paquete antes de ofrecer una instalación lista.
            return autorizada ? .iniciarDescarga : .mostrarDisponible
        case .instalando:
            return autorizada ? .instalarAhora : .mantenerProgramada
        }
    }
}

struct InstalacionActualizacionPendiente: Codable, Equatable {
    let versionOrigen: String
    let compilacionOrigen: Int
    let versionEsperada: String
    let compilacionEsperada: Int
    let iniciada: Date
}

enum ResultadoInstalacionActualizacion: Equatable {
    case verificada(InstalacionActualizacionPendiente)
    case incompleta(InstalacionActualizacionPendiente, instalada: InfoVersion)

    var mensaje: String {
        switch self {
        case .verificada(let registro):
            return "Se verificó la instalación de Nuvex \(registro.versionEsperada) (\(registro.compilacionEsperada))."
        case .incompleta(let registro, let instalada):
            return "No se pudo confirmar la actualización a Nuvex \(registro.versionEsperada) (\(registro.compilacionEsperada)). Actualmente usas Nuvex \(instalada.corta) (\(instalada.compilacion))."
        }
    }
}

/// Registro pequeño y sin secretos que permite al siguiente proceso confirmar
/// que realmente arrancó la compilación que Sparkle intentó instalar.
enum RegistroInstalacionActualizacion {
    static let clave = "instalacionActualizacionPendiente"

    @discardableResult
    static func comenzar(version: String, compilacion: String,
                         actual: InfoVersion = .actual,
                         defaults: UserDefaults = .standard,
                         ahora: Date = Date()) -> Bool {
        guard let compilacionEsperada = Int(compilacion),
              compilacionEsperada > actual.compilacion else { return false }
        let registro = InstalacionActualizacionPendiente(
            versionOrigen: actual.corta, compilacionOrigen: actual.compilacion,
            versionEsperada: version, compilacionEsperada: compilacionEsperada,
            iniciada: ahora)
        guard let datos = try? JSONEncoder().encode(registro) else { return false }
        defaults.set(datos, forKey: clave)
        return true
    }

    static func resolver(actual: InfoVersion = .actual,
                         defaults: UserDefaults = .standard) -> ResultadoInstalacionActualizacion? {
        guard let datos = defaults.data(forKey: clave),
              let registro = try? JSONDecoder().decode(InstalacionActualizacionPendiente.self, from: datos) else {
            defaults.removeObject(forKey: clave)
            return nil
        }
        if actual.compilacion == registro.compilacionEsperada
            && actual.corta == registro.versionEsperada {
            defaults.removeObject(forKey: clave)
            return .verificada(registro)
        }
        return .incompleta(registro, instalada: actual)
    }

    /// El fallo se conserva entre aperturas hasta que la pantalla de
    /// actualización haya tenido oportunidad de mostrárselo al usuario.
    static func confirmarLectura(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: clave)
    }

    static func cancelar(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: clave)
    }
}
