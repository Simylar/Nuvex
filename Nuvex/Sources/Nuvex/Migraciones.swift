import Foundation

/// Versión de la app tal como la escribe build.sh en el Info.plist.
struct InfoVersion: Equatable {
    let corta: String
    let compilacion: Int
    let canal: String
    let commit: String

    static let actual = InfoVersion(bundle: .main)

    init(corta: String, compilacion: Int, canal: String = "publicada", commit: String = "") {
        self.corta = corta
        self.compilacion = compilacion
        self.canal = canal
        self.commit = commit
    }

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        corta = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        compilacion = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
        canal = info["NuvexCanal"] as? String ?? "desarrollo"
        commit = info["NuvexCommit"] as? String ?? ""
    }

    /// "3.1.0" en publicaciones; "3.1.0 · desarrollo 1a2b3c4" en compilaciones locales.
    var descripcion: String {
        canal == "publicada" || commit.isEmpty ? corta : "\(corta) · \(canal) \(commit)"
    }
}

/// Copia de seguridad de la configuración sin secretos.
struct CopiaSeguridad: Identifiable, Equatable {
    let url: URL
    let fecha: Date
    let etiqueta: String
    let conexiones: Int
    var id: String { url.lastPathComponent }
}

/// Copias automáticas antes de cada versión nueva y pasos de migración.
/// Nunca guarda contraseñas: esas viven en el Llavero y se respaldan con la
/// exportación cifrada.
enum Migraciones {
    static let claveCompilacion = "ultimaCompilacionEjecutada"
    static let claveVersion = "ultimaVersionEjecutada"
    static let copiasConservadas = 10

    struct Resultado {
        /// Primer arranque de esta versión (no de la app).
        let versionNueva: Bool
        let anterior: String?
        let copia: URL?
    }

    static func carpetaCopias(_ base: URL) -> URL { base.appendingPathComponent("Copias", isDirectory: true) }

    /// Se llama al arrancar, antes de leer la configuración.
    @discardableResult
    static func ejecutar(defaults: UserDefaults = .standard,
                         version: InfoVersion = .actual,
                         base: URL = Preferencias.directorio,
                         perfiles: URL = URL(fileURLWithPath: Paths.perfiles),
                         ahora: Date = Date()) -> Resultado {
        let compilacionAnterior = defaults.object(forKey: claveCompilacion) as? Int
        var versionAnterior = defaults.string(forKey: claveVersion)
        // Nuvex 3.0 no registraba su versión: si ya hay conexiones, se viene de ella.
        if versionAnterior == nil, FileManager.default.fileExists(atPath: perfiles.path) {
            versionAnterior = "3.0"
        }
        guard compilacionAnterior != version.compilacion || versionAnterior != version.corta else {
            return Resultado(versionNueva: false, anterior: versionAnterior, copia: nil)
        }
        var copia: URL?
        do {
            copia = try crearCopia(etiqueta: "v\(versionAnterior ?? "anterior")", base: base,
                                   perfiles: perfiles, ahora: ahora)
            rotar(base: base)
        } catch {
            Log.escribir("no se pudo copiar la configuración antes de actualizar: \(error.localizedDescription)")
        }
        defaults.set(version.compilacion, forKey: claveCompilacion)
        defaults.set(version.corta, forKey: claveVersion)
        if let versionAnterior {
            Log.escribir("Nuvex \(versionAnterior) → \(version.descripcion)")
        }
        // Una instalación nueva no tiene versión anterior: no es una actualización.
        return Resultado(versionNueva: versionAnterior != nil, anterior: versionAnterior, copia: copia)
    }

    /// Copia profiles.json y ajustes.json. Devuelve nil si no hay nada que copiar.
    static func crearCopia(etiqueta: String, base: URL, perfiles: URL, ahora: Date = Date()) throws -> URL? {
        let archivos = FileManager.default
        let ajustes = base.appendingPathComponent("ajustes.json")
        let origen = [perfiles, ajustes].filter { archivos.fileExists(atPath: $0.path) }
        guard !origen.isEmpty else { return nil }
        let formato = DateFormatter()
        formato.locale = Locale(identifier: "en_US_POSIX")
        formato.dateFormat = "yyyy-MM-dd_HHmmss"
        let limpia = etiqueta.filter { $0.isLetter || $0.isNumber || ".-_".contains($0) }
        var destino = carpetaCopias(base).appendingPathComponent("\(formato.string(from: ahora))-\(limpia)", isDirectory: true)
        var n = 2
        while archivos.fileExists(atPath: destino.path) {
            destino = carpetaCopias(base).appendingPathComponent("\(formato.string(from: ahora))-\(limpia)-\(n)", isDirectory: true)
            n += 1
        }
        try archivos.createDirectory(at: destino, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        try archivos.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        try archivos.setAttributes([.posixPermissions: 0o700], ofItemAtPath: carpetaCopias(base).path)
        for archivo in origen {
            let copia = destino.appendingPathComponent(archivo.lastPathComponent)
            try archivos.copyItem(at: archivo, to: copia)
            try archivos.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copia.path)
        }
        return destino
    }

    /// Conserva las copias más recientes.
    static func rotar(base: URL, conservar: Int = copiasConservadas) {
        for copia in copias(base: base).dropFirst(conservar) {
            try? FileManager.default.removeItem(at: copia.url)
        }
    }

    /// Copias de la más reciente a la más antigua.
    static func copias(base: URL = Preferencias.directorio) -> [CopiaSeguridad] {
        let carpeta = carpetaCopias(base)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: carpeta, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> CopiaSeguridad? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let nombre = url.lastPathComponent
            let partes = nombre.split(separator: "-", maxSplits: 3)
            let fecha = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let etiqueta = partes.count == 4 ? String(partes[3]) : nombre
            return CopiaSeguridad(url: url, fecha: fecha, etiqueta: etiqueta,
                                  conexiones: perfiles(en: url)?.count ?? 0)
        }
        .sorted { ($0.fecha, $0.id) > ($1.fecha, $1.id) }
    }

    /// Conexiones guardadas en una copia, o nil si no tiene profiles.json legible.
    static func perfiles(en copia: URL) -> [VPNProfile]? {
        struct Archivo: Decodable { let version: Int; let profiles: [VPNProfile] }
        guard let datos = try? Data(contentsOf: copia.appendingPathComponent("profiles.json")),
              let archivo = try? JSONDecoder().decode(Archivo.self, from: datos),
              archivo.version == 2 else { return nil }
        return archivo.profiles
    }
}

/// Lectura del CHANGELOG (formato Keep a Changelog).
enum NotasCambios {
    /// Contenido de la sección `## [versión]`, sin el encabezado.
    static func seccion(de version: String, en contenido: String) -> String? {
        var dentro = false
        var lineas: [String] = []
        for linea in contenido.components(separatedBy: "\n") {
            if linea.hasPrefix("## [") {
                if dentro { break }
                dentro = linea.hasPrefix("## [\(version)]")
                continue
            }
            if dentro { lineas.append(linea) }
        }
        let resultado = lineas.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return resultado.isEmpty ? nil : resultado
    }
}
