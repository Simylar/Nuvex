import Darwin
import Foundation

/// Configura únicamente la excepción necesaria para ejecutar el CLI oficial
/// de Nuvex fuera del sandbox de Bash. No cambia el modo global de permisos ni
/// concede acceso a otros comandos.
enum AutorizacionAgentes {
    static let comandoPlantilla = "~/.local/bin/nuvex"

    enum Estado: Equatable {
        case noDisponible
        case ausente
        case parcial
        case instalada
        case ajena
    }

    static let marcaCodex = "# nuvex-vpn: gestionado por Nuvex."

    static func estadoCodex(raiz: URL, comando: String,
                            archivos: FileManager = .default) -> Estado {
        guard archivos.fileExists(atPath: raiz.path) else { return .noDisponible }
        let archivo = archivoCodex(raiz)
        guard archivos.fileExists(atPath: archivo.path) else { return .ausente }
        guard !esEnlace(archivo),
              let texto = try? String(contentsOf: archivo, encoding: .utf8),
              esCodexGestionado(texto) else { return .ajena }
        return texto == reglaCodex(comando: comando) ? .instalada : .parcial
    }

    static func instalarCodex(raiz: URL, comando: String,
                              archivos: FileManager = .default) throws {
        let carpeta = raiz.appendingPathComponent("rules", isDirectory: true)
        let archivo = archivoCodex(raiz)
        guard !esEnlace(raiz), !esEnlace(carpeta) else { throw CocoaError(.fileWriteNoPermission) }
        if archivos.fileExists(atPath: archivo.path) {
            guard !esEnlace(archivo),
                  let texto = try? String(contentsOf: archivo, encoding: .utf8),
                  esCodexGestionado(texto) else { throw CocoaError(.fileWriteFileExists) }
        }
        try archivos.createDirectory(at: carpeta, withIntermediateDirectories: true)
        try escribirPrivado(Data(reglaCodex(comando: comando).utf8), en: archivo, archivos: archivos)
    }

    static func quitarCodex(raiz: URL, archivos: FileManager = .default) throws {
        let archivo = archivoCodex(raiz)
        guard archivos.fileExists(atPath: archivo.path), !esEnlace(archivo),
              let texto = try? String(contentsOf: archivo, encoding: .utf8),
              esCodexGestionado(texto) else { return }
        try archivos.removeItem(at: archivo)
    }

    static func estadoClaude(raiz: URL, comando: String,
                             archivos: FileManager = .default) -> Estado {
        guard archivos.fileExists(atPath: raiz.path) else { return .noDisponible }
        let archivo = archivoClaude(raiz)
        guard archivos.fileExists(atPath: archivo.path) else { return .ausente }
        guard !esEnlace(archivo), let ajustes = try? leerAjustesClaude(archivo),
              let reglas = reglasClaude(ajustes) else { return .ajena }
        let permiso = reglas.permitidas.contains(reglaPermisoClaude(comando))
        let exclusion = reglas.excluidas.contains(reglaSandboxClaude(comando))
        if permiso && exclusion { return .instalada }
        return permiso || exclusion ? .parcial : .ausente
    }

    static func instalarClaude(raiz: URL, comando: String,
                               archivos: FileManager = .default) throws {
        let archivo = archivoClaude(raiz)
        guard !esEnlace(raiz), !esEnlace(archivo) else { throw CocoaError(.fileWriteNoPermission) }
        try archivos.createDirectory(at: raiz, withIntermediateDirectories: true)
        var ajustes = try leerAjustesClaude(archivo)
        guard var reglas = reglasClaude(ajustes) else { throw CocoaError(.fileReadCorruptFile) }
        agregar(reglaPermisoClaude(comando), a: &reglas.permitidas)
        agregar(reglaSandboxClaude(comando), a: &reglas.excluidas)
        ajustes["permissions"] = combinando(ajustes["permissions"], clave: "allow", valores: reglas.permitidas)
        ajustes["sandbox"] = combinando(ajustes["sandbox"], clave: "excludedCommands", valores: reglas.excluidas)
        try guardarAjustesClaude(ajustes, en: archivo, archivos: archivos)
    }

    static func quitarClaude(raiz: URL, comando: String,
                             archivos: FileManager = .default) throws {
        let archivo = archivoClaude(raiz)
        guard archivos.fileExists(atPath: archivo.path) else { return }
        guard !esEnlace(archivo) else { throw CocoaError(.fileWriteNoPermission) }
        var ajustes = try leerAjustesClaude(archivo)
        guard var reglas = reglasClaude(ajustes) else { throw CocoaError(.fileReadCorruptFile) }
        reglas.permitidas.removeAll { $0 == reglaPermisoClaude(comando) }
        reglas.excluidas.removeAll { $0 == reglaSandboxClaude(comando) }
        ajustes = quitandoOCombinando(ajustes, seccion: "permissions", clave: "allow", valores: reglas.permitidas)
        ajustes = quitandoOCombinando(ajustes, seccion: "sandbox", clave: "excludedCommands", valores: reglas.excluidas)
        try guardarAjustesClaude(ajustes, en: archivo, archivos: archivos)
    }

    static func reglaCodex(comando: String) -> String {
        let ruta = literalJSON(comando)
        return """
        \(marcaCodex)
        # Revocable desde Ajustes de Nuvex > Automatización.
        prefix_rule(
            pattern = [\(ruta)],
            decision = "allow",
            justification = "Permite solo el CLI oficial de Nuvex fuera del sandbox; la app aplica su propia política por VPN.",
            match = [\(literalJSON(comando + " estado --json")), \(literalJSON(comando + " conectar oficina --json"))],
            not_match = ["nuvex estado --json", "/Applications/Nuvex.app/Contents/MacOS/Nuvex"],
        )

        """
    }

    static func reglaPermisoClaude(_ comando: String) -> String { "Bash(\(comando) *)" }
    static func reglaSandboxClaude(_ comando: String) -> String { "\(comando) *" }

    /// Las shells de los agentes pueden redefinir HOME. La habilidad instalada
    /// usa la misma ruta absoluta y acotada que sus reglas persistentes.
    static func personalizarHabilidad(_ plantilla: String, comando: String) -> String {
        plantilla.replacingOccurrences(of: comandoPlantilla, with: comando)
    }

    private static func archivoCodex(_ raiz: URL) -> URL {
        raiz.appendingPathComponent("rules/nuvex.rules")
    }

    private static func archivoClaude(_ raiz: URL) -> URL {
        raiz.appendingPathComponent("settings.json")
    }

    private static func leerAjustesClaude(_ archivo: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: archivo.path) else { return [:] }
        let objeto = try JSONSerialization.jsonObject(with: Data(contentsOf: archivo))
        guard let ajustes = objeto as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return ajustes
    }

    private static func reglasClaude(_ ajustes: [String: Any])
        -> (permitidas: [String], excluidas: [String])? {
        let permisos = ajustes["permissions"] as? [String: Any] ?? [:]
        let sandbox = ajustes["sandbox"] as? [String: Any] ?? [:]
        guard ajustes["permissions"] == nil || ajustes["permissions"] is [String: Any],
              ajustes["sandbox"] == nil || ajustes["sandbox"] is [String: Any],
              permisos["allow"] == nil || permisos["allow"] is [String],
              sandbox["excludedCommands"] == nil || sandbox["excludedCommands"] is [String] else { return nil }
        return (permisos["allow"] as? [String] ?? [], sandbox["excludedCommands"] as? [String] ?? [])
    }

    private static func combinando(_ existente: Any?, clave: String, valores: [String]) -> [String: Any] {
        var seccion = existente as? [String: Any] ?? [:]
        seccion[clave] = valores
        return seccion
    }

    private static func quitandoOCombinando(_ ajustes: [String: Any], seccion: String,
                                             clave: String, valores: [String]) -> [String: Any] {
        var resultado = ajustes
        var contenido = resultado[seccion] as? [String: Any] ?? [:]
        if valores.isEmpty { contenido.removeValue(forKey: clave) }
        else { contenido[clave] = valores }
        if contenido.isEmpty { resultado.removeValue(forKey: seccion) }
        else { resultado[seccion] = contenido }
        return resultado
    }

    private static func guardarAjustesClaude(_ ajustes: [String: Any], en archivo: URL,
                                              archivos: FileManager) throws {
        let datos = try JSONSerialization.data(withJSONObject: ajustes, options: [.prettyPrinted, .sortedKeys])
        try escribirPrivado(datos + Data("\n".utf8), en: archivo, archivos: archivos)
    }

    private static func escribirPrivado(_ datos: Data, en archivo: URL,
                                         archivos: FileManager) throws {
        let permisosAnteriores = (try? archivos.attributesOfItem(atPath: archivo.path)[.posixPermissions]) as? NSNumber
        try datos.write(to: archivo, options: .atomic)
        let permisos = permisosAnteriores?.intValue ?? 0o600
        try archivos.setAttributes([.posixPermissions: permisos], ofItemAtPath: archivo.path)
    }

    private static func agregar(_ valor: String, a valores: inout [String]) {
        if !valores.contains(valor) { valores.append(valor) }
    }

    private static func esCodexGestionado(_ texto: String) -> Bool {
        texto.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) == marcaCodex
    }

    private static func literalJSON(_ texto: String) -> String {
        let datos = try? JSONSerialization.data(withJSONObject: [texto], options: .withoutEscapingSlashes)
        let arreglo = datos.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arreglo.dropFirst().dropLast())
    }

    private static func esEnlace(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
