import Foundation

/// Resultado de esta solicitud, independiente de errores de otras ventanas.
struct ResultadoGuardado: Sendable {
    let id: UUID
    let resumen: ResumenGuardado
    let idsConfirmados: Set<String>

    var completo: Bool { resumen.conexiones == .hecho && !resumen.hayProblemas && !resumen.enCurso }
    func confirmaImportacion(_ ids: Set<String>) -> Bool {
        resumen.conexiones == .hecho && !ids.isEmpty && ids.isSubset(of: idsConfirmados)
    }
    var avisos: [String] {
        resumen.pasos.compactMap {
            switch $0.paso {
            case .fallo(let mensaje), .pendiente(let mensaje): return mensaje
            default: return nil
            }
        }
    }
}

enum AjustesDelGuardado: Sendable {
    case conservar
    case importarCorreo([String: ConfigCorreo])
    case restaurarCorreo([String: ConfigCorreo]?)

    var esRestauracion: Bool {
        if case .restaurarCorreo = self { return true }
        return false
    }

    /// Solo cambia la configuración del lector. Las decisiones de seguridad
    /// actuales, incluidas las exclusiones, nunca se recuperan de una copia.
    @MainActor
    func aplicar(en preferencias: Preferencias, ids: Set<String>) throws -> ResumenGuardado.Paso {
        if case .conservar = self { return .noAplica }
        if case .importarCorreo(let correo) = self, correo.isEmpty { return .noAplica }
        guard preferencias.modificar({ actuales in
            switch self {
            case .conservar: break
            case .importarCorreo(let correo):
                for (id, config) in correo where ids.contains(id) { actuales.correo[id] = config }
            case .restaurarCorreo(let correo):
                actuales.correo = (correo ?? actuales.correo).filter { ids.contains($0.key) }
            }
        }) else {
            throw ErrorVPN(mensaje: "No se pudieron guardar los ajustes de lectura de códigos. Revisa el acceso al archivo de ajustes y vuelve a intentarlo.")
        }
        return .hecho
    }
}

struct PreparacionRestauracion {
    let perfiles: [VPNProfile]
    let ajustes: AjustesDelGuardado

    static func leer(en carpeta: URL) throws -> PreparacionRestauracion {
        struct Archivo: Decodable { let version: Int; let profiles: [VPNProfile] }
        let archivo = try JSONDecoder().decode(Archivo.self,
            from: Data(contentsOf: carpeta.appendingPathComponent("profiles.json")))
        guard archivo.version == 2 else {
            throw ErrorVPN(mensaje: "La copia usa una versión de conexiones no compatible.")
        }
        let perfiles = archivo.profiles.map(\.normalizado)
        try Validacion.validarColeccion(perfiles)
        let datos: Data?
        do { datos = try Data(contentsOf: carpeta.appendingPathComponent("ajustes.json")) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { datos = nil }
        var correo: [String: ConfigCorreo]?
        if let datos {
            let lectura = try ArchivoAjustes.leer(datos)
            guard !lectura.esMasNuevo else {
                throw ErrorVPN(mensaje: "Los ajustes de la copia requieren una versión más nueva de Nuvex.")
            }
            correo = lectura.ajustes.correo
        }
        return PreparacionRestauracion(perfiles: perfiles, ajustes: .restaurarCorreo(correo))
    }
}

/// Compensa el cambio de perfiles si no se pudo persistir el segundo archivo.
/// El Llavero solo se limpia después de completar ambos pasos.
enum PersistenciaRestauracion {
    struct RecuperacionFallida: LocalizedError {
        let errorDescription: String?
    }

    static func aplicar(perfiles: @Sendable () throws -> Void,
                        ajustes: @Sendable () async throws -> Void,
                        revertir: @Sendable () throws -> Void) async throws {
        try perfiles()
        do { try await ajustes() }
        catch {
            do { try revertir() }
            catch {
                throw RecuperacionFallida(errorDescription: "La restauración se interrumpió y no se pudieron recuperar los perfiles anteriores. Revisa la copia «Antes de restaurar» antes de conectar o volver a guardar.")
            }
            throw error
        }
    }
}
