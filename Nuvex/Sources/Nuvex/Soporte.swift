import AppKit
import ServiceManagement
import Darwin

/// Registro a fichero. Una app de barra de menus no tiene consola donde mirar,
/// asi que sin esto cualquier fallo es invisible.
enum Log {
    static let ruta = Paths.userHome + "/Library/Logs/Nuvex.log"
    static func escribir(_ mensaje: String) {
        let linea = "\(Date().formatted(date: .omitted, time: .standard)) \(mensaje)\n"
        guard let datos = linea.data(using: .utf8) else { return }
        guard prepararArchivo(), let fh = FileHandle(forWritingAtPath: ruta) else { return }
        fh.seekToEndOfFile(); fh.write(datos); try? fh.close()
    }

    @discardableResult
    private static func prepararArchivo() -> Bool {
        let files = FileManager.default
        if !files.fileExists(atPath: ruta) {
            guard files.createFile(atPath: ruta, contents: nil,
                                   attributes: [.posixPermissions: 0o600]) else { return false }
        }
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ruta)
        return true
    }

    /// Abre el registro con la app predeterminada para .log (Consola).
    @MainActor static func mostrar() {
        guard prepararArchivo() else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: ruta))
    }
}

// Ruta al motor. Se resuelve junto al bundle de la app o, si no, en la
// carpeta de scripts, para poder ejecutar la app desde cualquier sitio.
enum Paths {
    // Un lanzador puede heredar HOME/XDG_CONFIG_HOME de otra app. Los perfiles
    // deben resolverse siempre desde el hogar real del usuario de macOS.
    static let userHome: String = {
        guard let record = getpwuid(getuid()),
              let home = String(validatingCString: record.pointee.pw_dir) else {
            return NSHomeDirectory()
        }
        return home
    }()
    static let environment: [String: String] = {
        var values = ProcessInfo.processInfo.environment
        values["HOME"] = userHome
        values["XDG_CONFIG_HOME"] = userHome + "/.config"
        return values
    }()
    static let nuvexctl: String = {
        Bundle.main.resourceURL?.appendingPathComponent("nuvexctl.sh").path ?? ""
    }()
    static let perfiles = userHome + "/.config/nuvex/profiles.json"
    static let logo: NSImage? = {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("nuvex_mark.svg").path else { return nil }
        return NSImage(contentsOfFile: path)
    }()
}

/// Abrir al iniciar sesión mediante el registro de ítems de inicio de macOS.
@MainActor
enum InicioDeSesion {
    static var activo: Bool { SMAppService.mainApp.status == .enabled }
    static var requiereAprobacion: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func cambiar(_ activar: Bool) throws {
        if activar { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    static func abrirAjustesDelSistema() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
