import Foundation

// MARK: - Datos

/// Cómo obtener por correo el código de verificación de una conexión.
struct ConfigCorreo: Codable, Equatable {
    var remitente: String
    var asunto: String = ""
    /// Segundos que se espera el correo antes de pedir el código a mano.
    var espera: Int = 120
    /// Expresión regular con un grupo que captura el código. Vacía: la de serie.
    var patron: String = ""

    init(remitente: String, asunto: String = "", espera: Int = 120, patron: String = "") {
        self.remitente = remitente
        self.asunto = asunto
        self.espera = espera
        self.patron = patron
    }

    /// Los campos que falten (de versiones anteriores) toman su valor de serie.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remitente = try c.decodeIfPresent(String.self, forKey: .remitente) ?? ""
        asunto = try c.decodeIfPresent(String.self, forKey: .asunto) ?? ""
        espera = try c.decodeIfPresent(Int.self, forKey: .espera) ?? 120
        patron = try c.decodeIfPresent(String.self, forKey: .patron) ?? ""
    }
}

/// Qué pueden hacer la Terminal y los asistentes (Claude Code, Codex).
enum PoliticaAsistentes: String, Codable, CaseIterable {
    case noPermitir
    case preguntar
    case permitir
}

/// Ajustes propios de la app. Viven fuera de profiles.json porque el
/// ayudante firma ese archivo: cambiarlo obligaría a reinstalarlo.
struct AjustesApp: Equatable {
    static let versionActual = 1

    var correo: [String: ConfigCorreo] = [:]
    var politicaAsistentes: PoliticaAsistentes = .permitir
    /// Conexiones que los asistentes no pueden conectar aunque la política lo permita.
    var bloqueadasParaAsistentes: Set<String> = []
    var avisarAccionesAsistentes = true
}

extension AjustesApp: Codable {
    private enum Claves: String, CodingKey {
        case version, correo, politicaAsistentes, bloqueadasParaAsistentes, avisarAccionesAsistentes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Claves.self)
        correo = try c.decodeIfPresent([String: ConfigCorreo].self, forKey: .correo) ?? [:]
        politicaAsistentes = (try? c.decodeIfPresent(PoliticaAsistentes.self, forKey: .politicaAsistentes)) ?? .permitir
        bloqueadasParaAsistentes = try c.decodeIfPresent(Set<String>.self, forKey: .bloqueadasParaAsistentes) ?? []
        avisarAccionesAsistentes = try c.decodeIfPresent(Bool.self, forKey: .avisarAccionesAsistentes) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Claves.self)
        try c.encode(AjustesApp.versionActual, forKey: .version)
        try c.encode(correo, forKey: .correo)
        try c.encode(politicaAsistentes, forKey: .politicaAsistentes)
        try c.encode(bloqueadasParaAsistentes.sorted(), forKey: .bloqueadasParaAsistentes)
        try c.encode(avisarAccionesAsistentes, forKey: .avisarAccionesAsistentes)
    }
}

// MARK: - Lectura y escritura sin perder datos

/// Lee y escribe ajustes.json conservando las claves que esta versión no
/// conoce, para que volver a una versión anterior no borre datos nuevos.
enum ArchivoAjustes {
    struct Lectura {
        var ajustes: AjustesApp
        /// Contenido original completo, incluidas las claves desconocidas.
        var crudo: [String: Any]
        var versionArchivo: Int
        var esMasNuevo: Bool { versionArchivo > AjustesApp.versionActual }
    }

    /// Pasos de migración: el de la clave N lleva un archivo de la versión N-1
    /// a la N. Deben ser idempotentes.
    static let migraciones: [Int: @Sendable ([String: Any]) -> [String: Any]] = [:]

    static func leer(_ datos: Data?) throws -> Lectura {
        guard let datos, !datos.isEmpty else {
            return Lectura(ajustes: AjustesApp(), crudo: [:], versionArchivo: AjustesApp.versionActual)
        }
        guard var crudo = try JSONSerialization.jsonObject(with: datos) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let version = crudo["version"] as? Int ?? 1
        if version < AjustesApp.versionActual {
            for paso in (version + 1)...AjustesApp.versionActual {
                if let migrar = migraciones[paso] { crudo = migrar(crudo) }
            }
        }
        let conocido = try JSONSerialization.data(withJSONObject: crudo)
        let ajustes = try JSONDecoder().decode(AjustesApp.self, from: conocido)
        return Lectura(ajustes: ajustes, crudo: crudo, versionArchivo: version)
    }

    static func escribir(_ ajustes: AjustesApp, sobre crudo: [String: Any]) throws -> Data {
        let conocido = try JSONEncoder().encode(ajustes)
        guard let nuevo = try JSONSerialization.jsonObject(with: conocido) as? [String: Any] else {
            throw CocoaError(.fileWriteUnknown)
        }
        let combinado = crudo.merging(nuevo) { _, actual in actual }
        return try JSONSerialization.data(withJSONObject: combinado, options: [.prettyPrinted, .sortedKeys])
    }

    /// Escritura atómica con permisos privados (carpeta 0700, archivo 0600).
    static func guardarAtomico(_ datos: Data, en url: URL) throws {
        let carpeta = url.deletingLastPathComponent()
        let archivos = FileManager.default
        try archivos.createDirectory(at: carpeta, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        try archivos.setAttributes([.posixPermissions: 0o700], ofItemAtPath: carpeta.path)
        let temporal = carpeta.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard archivos.createFile(atPath: temporal.path, contents: datos,
                                  attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if archivos.fileExists(atPath: url.path) {
                _ = try archivos.replaceItemAt(url, withItemAt: temporal)
            } else {
                try archivos.moveItem(at: temporal, to: url)
            }
        } catch {
            try? archivos.removeItem(at: temporal)
            throw error
        }
        try archivos.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Almacén

@MainActor
final class Preferencias: ObservableObject {
    static let shared = Preferencias()

    nonisolated static let directorio = URL(fileURLWithPath: Paths.userHome + "/Library/Application Support/Nuvex",
                                            isDirectory: true)
    nonisolated static var archivo: URL { directorio.appendingPathComponent("ajustes.json") }

    @Published private(set) var ajustes = AjustesApp()
    /// Mensaje cuando los ajustes los guardó una versión más nueva: no se escriben.
    @Published private(set) var soloLectura: String?
    private var crudo: [String: Any] = [:]
    private let url: URL

    init(url: URL = Preferencias.archivo) {
        self.url = url
        cargar()
    }

    func cargar() {
        do {
            let lectura = try ArchivoAjustes.leer(try? Data(contentsOf: url))
            ajustes = lectura.ajustes
            crudo = lectura.crudo
            soloLectura = lectura.esMasNuevo
                ? "Estos ajustes los guardó una versión más nueva de Nuvex. Actualiza Nuvex para cambiarlos."
                : nil
        } catch {
            Log.escribir("ajustes.json no se pudo leer: \(error.localizedDescription)")
            soloLectura = "No se pudieron leer los ajustes de Nuvex. Se usan los valores de serie hasta que se repare el archivo."
        }
    }

    /// Aplica un cambio y lo guarda. Devuelve false si no se pudo guardar.
    @discardableResult
    func modificar(_ cambio: (inout AjustesApp) -> Void) -> Bool {
        guard soloLectura == nil else { return false }
        var nuevos = ajustes
        cambio(&nuevos)
        guard nuevos != ajustes else { return true }
        do {
            try ArchivoAjustes.guardarAtomico(try ArchivoAjustes.escribir(nuevos, sobre: crudo), en: url)
            ajustes = nuevos
            return true
        } catch {
            Log.escribir("no se guardaron los ajustes: \(error.localizedDescription)")
            return false
        }
    }

    /// Borra lo asociado a una conexión eliminada.
    func olvidarConexion(_ id: String) {
        modificar {
            $0.correo.removeValue(forKey: id)
            $0.bloqueadasParaAsistentes.remove(id)
        }
    }
}
