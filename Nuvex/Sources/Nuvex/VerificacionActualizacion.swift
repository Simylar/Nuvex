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

/// Traduce los errores técnicos de Sparkle y Foundation a indicaciones que el
/// usuario puede entender y resolver. Los códigos corresponden a la API
/// pública `SUSparkleError`; se mantienen aquí para que esta política sea
/// comprobable sin enlazar el framework en las pruebas del núcleo.
enum PresentacionErrorActualizacion {
    private static let dominioSparkle = "SUSparkleErrorDomain"
    private static let erroresConfiguracion: Set<Int> = [1, 2, 3, 4, 5, 6, 7, 5_000]
    private static let erroresAppcast: Set<Int> = [1_000, 1_002, 1_004]
    private static let errorSinActualizacion = 1_001
    private static let errorDesdeImagenDeDisco = 1_003
    private static let errorAplicacionTranslocada = 1_005
    private static let erroresNotas: Set<Int> = [1_006, 1_007]
    private static let errorTemporal = 2_000
    private static let errorDescarga = 2_001
    private static let errorExtraccion = 3_000
    private static let errorFirmaInsuficiente = 2
    private static let erroresVerificacion: Set<Int> = [3_001, 3_002, 4_006, 4_009]
    private static let errorCancelado = 4_007
    private static let errorSinPermiso = 4_012
    private static let erroresInstalacion = 4_000...4_012

    static func mensaje(_ error: any Error) -> String {
        if let preparacion = error as? ErrorPreparacionActualizacion,
           let descripcion = preparacion.errorDescription {
            return descripcion
        }
        let nsError = error as NSError
        let cadena = cadenaDeErrores(nsError)
        if cadena.contains(where: { $0.domain == NSURLErrorDomain }) {
            return "No hay conexión con el servidor de actualizaciones. Comprueba tu conexión a Internet y vuelve a intentarlo."
        }
        let rechazoDeSeguridad = cadena.contains {
            $0.domain == dominioSparkle && erroresVerificacion.contains($0.code)
        } || cadena.dropFirst().contains {
            $0.domain == dominioSparkle && $0.code == errorFirmaInsuficiente
        }
        if rechazoDeSeguridad {
            return "La actualización no superó la verificación de seguridad y no se instaló. Inténtalo de nuevo más tarde."
        }
        guard nsError.domain == dominioSparkle else {
            return "No se pudo completar la actualización. Inténtalo de nuevo; si el problema continúa, instala la versión publicada de Nuvex."
        }

        switch nsError.code {
        case let codigo where erroresConfiguracion.contains(codigo):
            return "La configuración de actualizaciones no es válida. Instala nuevamente la versión publicada de Nuvex."
        case let codigo where erroresAppcast.contains(codigo):
            return "El servidor publicó información de actualización no válida. Inténtalo de nuevo más tarde."
        case errorSinActualizacion:
            return "No se encontró una actualización compatible. Vuelve a buscar más tarde."
        case errorDesdeImagenDeDisco:
            return "Nuvex no puede actualizarse desde una imagen de disco. Mueve la aplicación a la carpeta Aplicaciones y vuelve a intentarlo."
        case errorAplicacionTranslocada:
            return "Nuvex no puede actualizarse desde la carpeta donde se descargó. Mueve la aplicación a la carpeta Aplicaciones, ábrela desde ahí y vuelve a intentarlo."
        case let codigo where erroresNotas.contains(codigo):
            return "No se pudieron cargar los detalles de la versión. Puedes volver a intentarlo o consultar la versión publicada."
        case errorTemporal:
            return "macOS no pudo preparar el espacio temporal para la actualización. Comprueba el espacio disponible y vuelve a intentarlo."
        case errorDescarga:
            return "No se pudo descargar la actualización. Comprueba tu conexión a Internet y vuelve a intentarlo."
        case errorExtraccion:
            return "No se pudo preparar el archivo descargado. Vuelve a descargar la actualización."
        case errorCancelado:
            return "La instalación fue cancelada. Nuvex no realizó ningún cambio."
        case errorSinPermiso:
            return "macOS no permitió reemplazar Nuvex. Comprueba que la aplicación esté en la carpeta Aplicaciones y que tengas permiso para modificarla."
        case erroresInstalacion:
            return "macOS no pudo instalar o volver a abrir Nuvex. Cierra otras copias de la aplicación y vuelve a intentarlo."
        default:
            return "No se pudo completar la actualización. Inténtalo de nuevo; si el problema continúa, instala la versión publicada de Nuvex."
        }
    }

    private static func cadenaDeErrores(_ error: NSError) -> [NSError] {
        var resultado: [NSError] = []
        var actual: NSError? = error
        while let elemento = actual, resultado.count < 8 {
            resultado.append(elemento)
            guard let causa = elemento.userInfo[NSUnderlyingErrorKey] as? NSError,
                  causa !== elemento else { break }
            actual = causa
        }
        return resultado
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
            return "Nuvex \(registro.versionEsperada) (compilación \(registro.compilacionEsperada)) se instaló y abrió correctamente."
        case .incompleta(let registro, let instalada):
            return "La actualización a Nuvex \(registro.versionEsperada) (compilación \(registro.compilacionEsperada)) no se completó. Nuvex volvió a abrirse con la versión \(instalada.corta) (compilación \(instalada.compilacion)). Tus conexiones, contraseñas y ajustes se conservaron; busca la actualización de nuevo."
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
