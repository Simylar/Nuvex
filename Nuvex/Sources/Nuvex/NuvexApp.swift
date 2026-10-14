import SwiftUI
import AppKit
import UserNotifications
import Security
import LocalAuthentication
import Darwin

/// Registro a fichero. Una app de barra de menus no tiene consola donde mirar,
/// asi que sin esto cualquier fallo es invisible.
enum Log {
    static let ruta = Paths.userHome + "/Library/Logs/Nuvex.log"
    static func escribir(_ mensaje: String) {
        let linea = "\(Date().formatted(date: .omitted, time: .standard)) \(mensaje)\n"
        guard let datos = linea.data(using: .utf8) else { return }
        let files = FileManager.default
        if !files.fileExists(atPath: ruta) {
            guard files.createFile(atPath: ruta, contents: nil,
                                   attributes: [.posixPermissions: 0o600]) else { return }
        }
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ruta)
        guard let fh = FileHandle(forWritingAtPath: ruta) else { return }
        fh.seekToEndOfFile(); fh.write(datos); try? fh.close()
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
    static let logo: NSImage? = {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("nuvex_mark.svg").path else { return nil }
        return NSImage(contentsOfFile: path)
    }()
    static let menuLogo: NSImage? = {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("nuvex_mark.svg").path,
              let image = NSImage(contentsOfFile: path) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

// MARK: - Modelo de datos

struct VPNStatus: Decodable, Identifiable {
    let id: String
    let name: String
    let connected: Bool
    let pid: Int
    let ip: String
    let iface: String
    let networks: [String]
    let enabled: Bool
    let configured: Bool
    let helperReady: Bool
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
}

enum PasswordStatus: Equatable {
    case saved
    case missing
    case error(Int32)
}

/// Los avisos de macOS quedan en el Centro de notificaciones. La presentación
/// como banner persistente depende de la preferencia del usuario en macOS.
final class VPNNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = VPNNotifications()
    var reconnect: ((String) -> Void)?

    func start() {
        let action = UNNotificationAction(identifier: "RECONNECT", title: "Reconectar", options: [.foreground])
        let category = UNNotificationCategory(identifier: "VPN_DISCONNECTED", actions: [action], intentIdentifiers: [])
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([category])
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func disconnected(id: String, name: String) {
        let content = UNMutableNotificationContent()
        content.title = "VPN desconectada"
        content.body = "\(name) perdió la conexión. Pulsa Reconectar para intentarlo de nuevo."
        content.categoryIdentifier = "VPN_DISCONNECTED"
        content.userInfo = ["profile": id]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "drop-\(id)", content: content, trigger: nil))
    }

    func clear(id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["drop-\(id)"])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "RECONNECT" || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let id = response.notification.request.content.userInfo["profile"] as? String {
            reconnect?(id)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

/// Result exige que el tipo de fallo conforme a Error, y String no lo hace.
struct ErrorVPN: LocalizedError {
    let mensaje: String
    var errorDescription: String? { mensaje }
}

/// Estado en el que puede encontrarse una VPN desde el punto de vista de la
/// interfaz. `conectando` no viene del motor: lo mantiene la app mientras el
/// proceso de conexion esta en marcha, porque puede tardar (sobre todo cuando
/// hay que esperar al codigo del correo).
enum EstadoUI: Equatable {
    case desconectada
    case conectando
    case conectada
    case error(String)
}

@MainActor
final class VPNModel: ObservableObject {
    @Published var vpns: [VPNStatus] = []
    @Published var profiles: [VPNProfile] = []
    @Published var passwordStatuses: [String: PasswordStatus] = [:]
    @Published var estados: [String: EstadoUI] = [:]
    @Published var ultimoError: String?
    @Published var errorConsulta: String?
    @Published var desconexiones: Set<String> = []
    @Published var mensajeAyudante: String?
    @Published var instalandoAyudante = false
    @Published var guardandoConfiguracion = false
    @Published var mensajeConfiguracion: String?
    @Published var settingsTargetID: String?

    private var timer: Timer?
    private var refrescando = false
    private var desconexionSolicitada: Set<String> = []
    private var faltas: [String: Int] = [:]
    private var conexionPendiente: String?

    init() {
        SecurityPreferences.migrate()
        VPNNotifications.shared.reconnect = { [weak self] id in
            Task { @MainActor in self?.conectar(id: id) }
        }
        VPNNotifications.shared.start()
        arrancar()
        cargarConfiguracion()
    }

    /// Idempotente: se llama al crear el modelo y tambien al abrir el panel.
    /// Debe arrancar al lanzar la app, no al abrir el menu, porque el icono de
    /// la barra ya refleja el estado antes de que el usuario haga clic.
    func arrancar() {
        guard timer == nil else { refrescar(); return }
        refrescar()
        let configured = UserDefaults.standard.object(forKey: "intervaloRevision") as? Int ?? 5
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(2, min(60, configured))), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refrescar() }
        }
    }

    func actualizarIntervalo() {
        timer?.invalidate()
        timer = nil
        arrancar()
    }

    var hayAlgunaConectada: Bool { vpns.contains { $0.connected } }
    var conectadas: Int { vpns.filter { $0.connected }.count }
    var avisoConvivencia: String? {
        let activeIds = Set(vpns.filter { $0.connected }.map(\.id))
        guard activeIds.count > 1 else { return nil }
        let activeProfiles = profiles.filter { activeIds.contains($0.id) }
        var shared: [String] = []
        if activeProfiles.filter(\.manageRoutes).count > 1 { shared.append("rutas") }
        if activeProfiles.filter(\.manageDNS).count > 1 { shared.append("DNS") }
        guard !shared.isEmpty else { return nil }
        return "Varias VPN administran \(shared.joined(separator: " y ")). Si sus redes o dominios se superponen, ajusta las opciones de cada conexión."
    }

    func estado(_ vpn: VPNStatus) -> EstadoUI {
        if let e = estados[vpn.id], e == .conectando { return .conectando }
        if vpn.connected { return .conectada }
        if let e = estados[vpn.id], case .error = e { return e }
        return .desconectada
    }

    // MARK: Consulta de estado

    func refrescar() {
        guard !refrescando else { return }
        refrescando = true
        Task.detached(priority: .utility) {
            let resultado: Resultado
            do {
                resultado = try Self.ejecutar(args: ["list"])
            } catch {
                Log.escribir("fallo al ejecutar el motor: \(error)")
                await MainActor.run {
                    self.refrescando = false
                    self.errorConsulta = "No se pudo consultar la VPN: \(error.localizedDescription)"
                }
                return
            }
            guard let datos = resultado.salida.data(using: .utf8),
                  let lista = try? JSONDecoder().decode([VPNStatus].self, from: datos)
            else {
                Log.escribir("salida no interpretable: código=\(resultado.codigo), bytes de salida=\(resultado.salida.utf8.count), bytes de error=\(resultado.error.utf8.count)")
                await MainActor.run {
                    self.refrescando = false
                    self.errorConsulta = resultado.error.isEmpty
                        ? "el motor devolvio una salida vacia (codigo \(resultado.codigo))"
                        : resultado.error.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return
            }
            await MainActor.run {
                self.refrescando = false
                self.errorConsulta = nil
                self.procesarTransiciones(lista)
                self.vpns = lista
                if let id = self.conexionPendiente,
                   let vpn = lista.first(where: { $0.id == id }) {
                    self.conexionPendiente = nil
                    self.confirmarConexionExterna(vpn)
                }
                // Si el motor ya la reporta conectada, se acabo el "conectando".
                for v in lista where v.connected {
                    if self.estados[v.id] == .conectando { self.estados[v.id] = .conectada }
                }
            }
        }
    }

    private func procesarTransiciones(_ lista: [VPNStatus]) {
        let anteriores = Dictionary(uniqueKeysWithValues: vpns.map { ($0.id, $0) })
        for vpn in lista {
            if vpn.connected {
                faltas.removeValue(forKey: vpn.id)
                desconexiones.remove(vpn.id)
                VPNNotifications.shared.clear(id: vpn.id)
                continue
            }
            if desconexionSolicitada.remove(vpn.id) != nil {
                faltas.removeValue(forKey: vpn.id)
                continue
            }
            if anteriores[vpn.id]?.connected == true || faltas[vpn.id] != nil {
                faltas[vpn.id, default: 0] += 1
                if faltas[vpn.id] == 2 {
                    desconexiones.insert(vpn.id)
                    if UserDefaults.standard.object(forKey: "avisarDesconexion") as? Bool ?? true {
                        VPNNotifications.shared.disconnected(id: vpn.id, name: vpn.name)
                    }
                }
            }
        }
    }

    // MARK: Acciones

    func conectar(_ vpn: VPNStatus) {
        guard vpn.enabled, vpn.configured else {
            ultimoError = "Completa la configuración de esta VPN antes de conectar."
            return
        }
        guard estado(vpn) != .conectando else { return }
        if !vpn.helperReady {
            instalarAyudante(conectarDespues: vpn)
            return
        }
        iniciarConexion(vpn)
    }

    private func iniciarConexion(_ vpn: VPNStatus) {
        guard estado(vpn) != .conectando else { return }
        estados[vpn.id] = .conectando
        ultimoError = nil
        Task.detached(priority: .userInitiated) {
            let resultado = await Self.conectarProceso(id: vpn.id, name: vpn.name)
            await MainActor.run {
                switch resultado {
                case .success:
                    self.estados[vpn.id] = .conectada
                case .failure(let e):
                    self.estados[vpn.id] = .error(e.mensaje)
                    self.ultimoError = e.mensaje
                }
                self.refrescar()
            }
        }
    }

    func conectar(id: String) {
        guard let vpn = vpns.first(where: { $0.id == id }) else { return }
        conectar(vpn)
    }

    func solicitarDesdeEnlace(_ url: URL) {
        guard url.scheme == "nuvex", url.host == "connect" else { return }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard id.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil else { return }
        if let vpn = vpns.first(where: { $0.id == id }) { confirmarConexionExterna(vpn) }
        else { conexionPendiente = id; refrescar() }
    }

    private func confirmarConexionExterna(_ vpn: VPNStatus) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Conectar a \(vpn.name)"
        alert.informativeText = "Una solicitud externa pidió iniciar esta VPN con Nuvex."
        alert.addButton(withTitle: "Conectar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn { conectar(vpn) }
    }

    func instalarAyudante(desdeGuardado: Bool = false, conectarDespues vpn: VPNStatus? = nil,
                         errorPrevio: String? = nil) {
        guard !instalandoAyudante else { return }
        instalandoAyudante = true
        mensajeAyudante = nil
        ultimoError = errorPrevio
        Task.detached(priority: .utility) {
            do {
                let result = try Self.ejecutar(args: ["install-helper"])
                await MainActor.run {
                    self.instalandoAyudante = false
                    self.mensajeAyudante = result.codigo == 0 ? result.salida : nil
                    let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    let installError = detail.isEmpty ?
                        "No se pudo instalar el ayudante (código \(result.codigo))." : detail
                    self.ultimoError = result.codigo == 0 ? errorPrevio :
                        [errorPrevio, installError].compactMap { $0 }.joined(separator: " ")
                    if desdeGuardado {
                        self.mensajeConfiguracion = result.codigo == 0 ? nil :
                            "La configuración se guardó; la actualización del ayudante quedó pendiente."
                    }
                    self.refrescar()
                    if result.codigo == 0, let vpn {
                        self.iniciarConexion(vpn)
                    }
                }
            } catch {
                await MainActor.run {
                    self.instalandoAyudante = false
                    self.ultimoError = [errorPrevio, error.localizedDescription]
                        .compactMap { $0 }.joined(separator: " ")
                    if desdeGuardado {
                        self.mensajeConfiguracion = "La configuración se guardó; la actualización del ayudante quedó pendiente."
                    }
                }
            }
        }
    }

    func desconectar(_ vpn: VPNStatus) {
        desconexionSolicitada.insert(vpn.id)
        Task.detached(priority: .userInitiated) {
            let resultado = try? Self.ejecutar(args: ["stop", vpn.id])
            await MainActor.run {
                if resultado?.codigo == 0 {
                    self.estados[vpn.id] = .desconectada
                } else {
                    self.desconexionSolicitada.remove(vpn.id)
                    let detail = resultado?.error.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.ultimoError = detail.isEmpty ? "No se pudo desconectar \(vpn.name)." : detail
                }
                self.refrescar()
            }
        }
    }

    func cargarConfiguracion() {
        Task.detached(priority: .utility) {
            guard let result = try? Self.ejecutar(args: ["config", "list"]), result.codigo == 0,
                  let data = result.salida.data(using: .utf8),
                  let profiles = try? JSONDecoder().decode([VPNProfile].self, from: data) else {
                await MainActor.run { self.ultimoError = "No se pudo leer la configuración." }
                return
            }
            let statuses = Dictionary(uniqueKeysWithValues: profiles.map {
                ($0.id, Self.passwordStatus(id: $0.id, username: $0.username))
            })
            await MainActor.run {
                self.profiles = profiles
                self.passwordStatuses = statuses
            }
        }
    }

    func guardarPerfiles(_ profiles: [VPNProfile], passwords: [String: String]) {
        let profiles = profiles.map { profile in
            var normalized = profile
            normalized.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized
        }
        let migrations = profiles.compactMap { profile -> (old: VPNProfile, new: VPNProfile)? in
            guard let previous = self.profiles.first(where: { $0.id == profile.id }),
                  previous.username != profile.username,
                  previous.username.trimmingCharacters(in: .whitespacesAndNewlines) == profile.username,
                  passwords[profile.id, default: ""].isEmpty else { return nil }
            return (previous, profile)
        }
        for profile in profiles {
            if let previous = self.profiles.first(where: { $0.id == profile.id }),
               previous.username != profile.username,
               passwords[profile.id, default: ""].isEmpty,
               !migrations.contains(where: { $0.new.id == profile.id }) {
                ultimoError = "Al cambiar el usuario de \(profile.name), introduce su contraseña para el nuevo usuario."
                return
            }
        }
        if profiles != self.profiles, let active = vpns.first(where: { $0.connected }) {
            ultimoError = "Desconecta \(active.name) antes de cambiar las conexiones. Puedes actualizar las contraseñas sin desconectarte."
            return
        }
        guard let data = try? JSONEncoder().encode(profiles),
              let json = String(data: data, encoding: .utf8) else { return }
        let previousProfiles = self.profiles
        let shouldInstall = profiles != previousProfiles || vpns.isEmpty || vpns.contains { !$0.helperReady }
        let canInstallNow = !hayAlgunaConectada
        guardandoConfiguracion = true
        mensajeConfiguracion = nil
        ultimoError = nil
        Task.detached(priority: .userInitiated) {
            var stagedMigrations: [VPNProfile] = []
            var configurationSaved = false
            do {
                for migration in migrations {
                    guard Self.passwordStatus(id: migration.old.id, username: migration.new.username) == .missing else {
                        throw ErrorVPN(mensaje: "Ya existe una contraseña para el usuario corregido de \(migration.new.name). Escribe la contraseña en Configuración para elegir cuál conservar.")
                    }
                    let password = try await Self.leerDelLlavero(id: migration.old.id,
                        name: migration.old.name,
                        reason: "Migrar la contraseña guardada de \(migration.old.name) al usuario corregido")
                    try Self.guardarEnLlavero(password, profile: migration.new)
                    stagedMigrations.append(migration.new)
                    guard Self.passwordStatus(id: migration.new.id, username: migration.new.username) == .saved else {
                        throw ErrorVPN(mensaje: "No se pudo verificar la contraseña migrada de \(migration.new.name).")
                    }
                }
                let result = try Self.ejecutar(args: ["config", "set-all", json])
                guard result.codigo == 0 else {
                    let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw ErrorVPN(mensaje: detail.isEmpty ? "El configurador terminó con código \(result.codigo)." : detail)
                }
                configurationSaved = true
                var keychainErrors: [String] = []
                var savedPasswordIDs = Set(migrations.map { $0.new.id })
                for profile in profiles {
                    if let password = passwords[profile.id], !password.isEmpty {
                        do {
                            try Self.guardarEnLlavero(password, profile: profile)
                            savedPasswordIDs.insert(profile.id)
                        }
                        catch { keychainErrors.append("No se guardó la contraseña de \(profile.name).") }
                    }
                }
                if keychainErrors.isEmpty {
                    for migration in migrations {
                        do { try Self.eliminarDelLlavero(profile: migration.old) }
                        catch { keychainErrors.append("No se pudo retirar la entrada antigua del Llavero de \(migration.new.name).") }
                    }
                    for previous in previousProfiles where !profiles.contains(where: {
                        $0.id == previous.id && $0.username == previous.username
                    }) && !migrations.contains(where: { $0.old.id == previous.id }) {
                        do { try Self.eliminarDelLlavero(profile: previous) }
                        catch { keychainErrors.append(error.localizedDescription) }
                    }
                }
                let statuses = Dictionary(uniqueKeysWithValues: profiles.map {
                    ($0.id, Self.passwordStatus(id: $0.id, username: $0.username))
                })
                for profile in profiles where savedPasswordIDs.contains(profile.id) {
                    if statuses[profile.id] != .saved {
                        keychainErrors.append("No se pudo confirmar la contraseña de \(profile.name) en el Llavero.")
                    }
                }
                await MainActor.run {
                    self.guardandoConfiguracion = false
                    let keychainError = keychainErrors.isEmpty ? nil :
                        "Se guardaron los perfiles, pero hubo errores en el Llavero: \(keychainErrors.joined(separator: " "))"
                    self.ultimoError = keychainError
                    self.mensajeConfiguracion = keychainErrors.isEmpty ?
                        (shouldInstall ? (canInstallNow ? "Configuración guardada. Aplicando cambios…" :
                            "Configuración guardada. Nuvex preparará el ayudante al volver a conectar.") :
                            "Configuración guardada.") : nil
                    self.mensajeAyudante = nil
                    self.profiles = profiles
                    self.passwordStatuses = statuses
                    for id in savedPasswordIDs { self.estados.removeValue(forKey: id) }
                    self.refrescar()
                    if shouldInstall && canInstallNow {
                        self.instalarAyudante(desdeGuardado: true, errorPrevio: keychainError)
                    }
                }
            } catch {
                var rollbackFailed = false
                if !configurationSaved {
                    for profile in stagedMigrations.reversed() {
                        do { try Self.eliminarDelLlavero(profile: profile) }
                        catch { rollbackFailed = true }
                    }
                }
                let failure = error.localizedDescription + (rollbackFailed ?
                    " También quedó una entrada nueva en el Llavero; revisa la contraseña de esta conexión antes de reintentar." : "")
                await MainActor.run {
                    self.guardandoConfiguracion = false
                    self.mensajeConfiguracion = nil
                    self.ultimoError = "No se completó la configuración: \(failure)"
                }
            }
        }
    }

    nonisolated static func guardarEnLlavero(_ password: String, profile: VPNProfile) throws {
        let service = "nuvex.\(profile.id)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: profile.username]
        let data = Data(password.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw ErrorVPN(mensaje: "El Llavero devolvió \(added)") }
        } else if update != errSecSuccess {
            throw ErrorVPN(mensaje: "El Llavero devolvió \(update)")
        }
    }

    nonisolated static func eliminarDelLlavero(profile: VPNProfile) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "nuvex.\(profile.id)",
                                    kSecAttrAccount as String: profile.username]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ErrorVPN(mensaje: "No se pudo retirar del Llavero la contraseña anterior de \(profile.name).")
        }
    }

    nonisolated static func passwordStatus(id: String, username: String) -> PasswordStatus {
        guard !username.isEmpty else { return .missing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "nuvex.\(id)", "-a", username]
        process.environment = Paths.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .error(-1)
        }
        switch process.terminationStatus {
        case 0: return .saved
        case 44: return .missing
        case let code: return .error(code)
        }
    }

    nonisolated static func leerDelLlavero(id: String, name: String,
                                            reason: String? = nil) async throws -> String {
        let userResult = try ejecutar(args: ["config", "get", id, "username"])
        guard userResult.codigo == 0 else { throw ErrorVPN(mensaje: "Falta el usuario de \(id)") }
        // El comando añade un salto de línea; los espacios del usuario forman
        // parte de la clave exacta con la que se guardó su contraseña.
        var username = userResult.salida
        if username.hasSuffix("\n") { username.removeLast() }
        guard !username.isEmpty else { throw ErrorVPN(mensaje: "Falta el usuario de \(id)") }
        if case .missing = passwordStatus(id: id, username: username) {
            throw ErrorVPN(mensaje: "No hay contraseña guardada para \(name). Agrégala en Configuración.")
        }
        let context = LAContext()
        if SecurityPreferences.needsInitialConfirmation() {
            var policyError: NSError?
            let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                             error: &policyError)
                ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
            guard context.canEvaluatePolicy(policy, error: &policyError) else {
                throw ErrorVPN(mensaje: "macOS no puede confirmar tu identidad para \(name). Revisa Touch ID o la contraseña del equipo en Ajustes del Sistema.")
            }
            do {
                try await context.evaluatePolicy(policy,
                    localizedReason: reason ?? "Usar la contraseña guardada para conectar a \(name)")
                SecurityPreferences.markInitialUseAuthorized()
            } catch {
                throw ErrorVPN(mensaje: "Se canceló o falló la confirmación de macOS para \(name).")
            }
        }
        let service = "nuvex.\(id)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: username,
                                    kSecReturnData as String: true,
                                    kSecUseAuthenticationContext as String: context,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let password = String(data: data, encoding: .utf8), !password.isEmpty {
            return password
        }
        if status == errSecUserCanceled || status == errSecAuthFailed {
            throw ErrorVPN(mensaje: "No se autorizó el acceso al Llavero para \(name). Vuelve a conectar y permite el acceso de Nuvex.")
        }
        if let password = leerConHerramientaDeMacOS(id: id, username: username) {
            return password
        }
        if case .missing = passwordStatus(id: id, username: username) {
            throw ErrorVPN(mensaje: "No hay contraseña guardada para \(name). Agrégala en Configuración.")
        }
        throw ErrorVPN(mensaje: "La contraseña de \(name) está en el Llavero, pero no se pudo usar (código \(status)). Revisa sus permisos en Acceso a Llaveros o vuelve a guardarla en Configuración.")
    }

    nonisolated static func leerConHerramientaDeMacOS(id: String, username: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "nuvex.\(id)", "-a", username, "-w"]
        process.environment = Paths.environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              var password = String(data: data, encoding: .utf8) else { return nil }
        if password.hasSuffix("\n") { password.removeLast() }
        return password.isEmpty ? nil : password
    }

    // MARK: Ejecucion del motor

    struct Resultado { let salida: String; let error: String; let codigo: Int32 }

    nonisolated static func ejecutar(args: [String]) throws -> Resultado {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Paths.nuvexctl)
        p.arguments = args
        p.environment = Paths.environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Resultado(salida: String(data: o, encoding: .utf8) ?? "",
                         error: String(data: e, encoding: .utf8) ?? "",
                         codigo: p.terminationStatus)
    }

    /// Conecta vigilando la salida del ayudante. Cuando el servidor pide el
    /// código por correo, lo solicita y lo entrega por entrada estándar.
    nonisolated static func conectarProceso(id: String, name: String) async -> Result<Void, ErrorVPN> {
        let password: String
        do { password = try await leerDelLlavero(id: id, name: name) }
        catch { return .failure(ErrorVPN(mensaje: error.localizedDescription)) }
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Paths.nuvexctl)
            p.arguments = ["connect", id, "--password-stdin"]
            p.environment = Paths.environment

            let entrada = Pipe(), salida = Pipe(), errores = Pipe()
            p.standardInput = entrada
            p.standardOutput = salida
            p.standardError = errores

            let acumulado = Acumulador()

            errores.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                // EOF también dispara el manejador. Dejarlo registrado provoca
                // un bucle de lecturas vacías e impide cerrar el intento.
                guard !d.isEmpty else {
                    fh.readabilityHandler = nil
                    return
                }
                let texto = String(data: d, encoding: .utf8) ?? ""
                let necesitaCodigo = acumulado.anadir(texto)
                guard necesitaCodigo else { return }
                Task { @MainActor in
                    if let codigo = pedirCodigoAlUsuario() {
                        entrada.fileHandleForWriting.write(Data((codigo + "\n").utf8))
                        // Cerrar es imprescindible, no cortesia: al otro lado
                        // hay un lector alimentando al motor VPN, y sin EOF se
                        // queda bloqueado para siempre esperando mas entrada.
                        try? entrada.fileHandleForWriting.close()
                    } else { try? entrada.fileHandleForWriting.close() }
                }
            }

            do {
                try p.run()
                entrada.fileHandleForWriting.write(Data((password + "\n").utf8))
            } catch {
                cont.resume(returning: .failure(ErrorVPN(mensaje: "no se pudo ejecutar nuvexctl.sh: \(error.localizedDescription)")))
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                p.waitUntilExit()
                errores.fileHandleForReading.readabilityHandler = nil
                try? entrada.fileHandleForWriting.close()
                if p.terminationStatus == 0 {
                    cont.resume(returning: .success(()))
                } else {
                    let output = acumulado.texto
                    let msg = output.contains("NUVEX_TLS_VERIFY_FAILED") ||
                        output.contains("Gateway certificate validation failed")
                        ? "No se pudo verificar el certificado del servidor. Actualiza el ayudante o revisa la confianza TLS de esta conexión."
                        : output
                        .split(separator: "\n")
                        .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                        .map(String.init) ?? "fallo al conectar"
                    cont.resume(returning: .failure(ErrorVPN(mensaje: msg)))
                }
            }
        }
    }
}

/// Acumula la salida de error del proceso y detecta el prompt del codigo.
/// Es una clase con cerrojo porque el manejador de lectura se ejecuta en una
/// cola distinta de la principal.
final class Acumulador: @unchecked Sendable {
    private let cerrojo = NSLock()
    private var buffer = ""
    private var yaPedido = false

    var texto: String {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return buffer
    }

    /// Devuelve true la primera vez que aparece el prompt del codigo.
    func anadir(_ s: String) -> Bool {
        cerrojo.lock(); defer { cerrojo.unlock() }
        buffer += s
        guard !yaPedido else { return false }
        // el motor señala que necesita el código para el codigo del correo.
        if buffer.contains("NUVEX_OTP_REQUIRED") {
            yaPedido = true
            return true
        }
        return false
    }
}

@MainActor
func pedirCodigoAlUsuario() -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let alerta = NSAlert()
    alerta.messageText = "Código de verificación"
    alerta.informativeText = "Escribe el código que solicitó esta VPN (correo, app u otro medio). Nuvex no lo guarda."
    alerta.addButton(withTitle: "Conectar")
    alerta.addButton(withTitle: "Cancelar")

    let campo = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    campo.placeholderString = "Código"
    alerta.accessoryView = campo
    alerta.window.initialFirstResponder = campo

    let respuesta = alerta.runModal()
    guard respuesta == .alertFirstButtonReturn else { return nil }
    let valor = campo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    campo.stringValue = ""
    return valor.isEmpty ? nil : valor
}

// MARK: - Interfaz

struct FilaVPN: View {
    let vpn: VPNStatus
    let estado: EstadoUI
    let passwordStatus: PasswordStatus?
    let alConectar: () -> Void
    let alDesconectar: () -> Void
    let alConfigurar: () -> Void

    private var simbolo: String {
        switch estado {
        case .conectada: return "checkmark.shield.fill"
        case .conectando: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.shield.fill"
        case .desconectada: return "shield.slash"
        }
    }

    private var color: Color {
        switch estado {
        case .conectada: return .green
        case .conectando: return .orange
        case .error: return .red
        case .desconectada: return .secondary
        }
    }

    private var descripcion: String {
        switch estado {
        case .conectada:
            return vpn.ip.isEmpty ? "Conectada" : "Conectada · \(vpn.ip)"
        case .conectando: return "Conectando…"
        case .desconectada: return "Desconectada"
        case .error(let message): return message
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: simbolo)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(vpn.name).font(.system(size: 16, weight: .semibold))
                    Text(descripcion)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if case .conectando = estado {
                    ProgressView().controlSize(.small)
                } else if case .conectada = estado {
                    Button("Desconectar", action: alDesconectar)
                        .controlSize(.small)
                } else if passwordStatus == .missing {
                    Button("Configurar", action: alConfigurar)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button(vpn.helperReady ? "Conectar" : "Preparar y conectar", action: alConectar)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!vpn.enabled || !vpn.configured)
                }
            }
            if vpn.connected {
                HStack(spacing: 12) {
                    if !vpn.iface.isEmpty {
                        Label(vpn.iface, systemImage: "cable.connector")
                    }
                    if !vpn.networks.isEmpty {
                        Label("\(vpn.networks.count) rutas", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            } else if !vpn.configured {
                Label("Falta configurar usuario o servidor", systemImage: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
            } else if passwordStatus == .missing {
                Label("Falta la contraseña de esta conexión", systemImage: "key")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
            } else if !vpn.helperReady {
                Label("Nuvex preparará el ayudante al conectar", systemImage: "wrench.adjustable")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
    }
}

struct PanelVPN: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var modelo: VPNModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        if let image = Paths.logo {
                            Image(nsImage: image).resizable().frame(width: 34, height: 34)
                        }
                        Text("Nuvex").font(.system(size: 21, weight: .bold, design: .rounded))
                    }
                    Text(modelo.conectadas == 0
                         ? "Sin conexiones activas"
                         : "\(modelo.conectadas) de \(modelo.vpns.count) VPN activas")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: modelo.conectadas > 0 ? "lock.shield.fill" : "lock.shield")
                    .font(.system(size: 23, weight: .light))
                    .foregroundStyle(modelo.conectadas > 0 ? .green : .secondary)
                    .accessibilityHidden(true)
            }

            if !modelo.desconexiones.isEmpty {
                Label("Una VPN se desconectó. Puedes reconectarla aquí.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            }

            if !modelo.vpns.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(modelo.vpns) { vpn in
                            FilaVPN(vpn: vpn,
                                    estado: modelo.estado(vpn),
                                    passwordStatus: modelo.passwordStatuses[vpn.id],
                                    alConectar: { modelo.conectar(vpn) },
                                    alDesconectar: { modelo.desconectar(vpn) },
                                    alConfigurar: {
                                        modelo.settingsTargetID = vpn.id
                                        openSettings()
                                    })
                                .disabled(modelo.instalandoAyudante)
                        }
                    }
                }
                .frame(height: min(CGFloat(modelo.vpns.count) * 120, 420))
            }

            if modelo.instalandoAyudante {
                ProgressView("Preparando el ayudante; espera la autorización de macOS…")
            }

            if modelo.vpns.isEmpty {
                if let error = modelo.errorConsulta ?? modelo.ultimoError {
                    ContentUnavailableView("No se pudo leer el estado",
                        systemImage: "network.slash", description: Text(error))
                        .frame(height: 150)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("Aún no tienes conexiones VPN")
                            .font(.headline)
                        Text("Añade tu primera conexión Fortinet SSL VPN en Configuración.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        SettingsLink { Label("Configurar primera VPN", systemImage: "plus") }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                }
            }

            if let aviso = modelo.avisoConvivencia {
                Label(aviso, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = modelo.ultimoError, !modelo.vpns.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = modelo.errorConsulta, !modelo.vpns.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                SettingsLink {
                    Label("Configuración", systemImage: "gearshape")
                }
                .controlSize(.small)
                Button("Actualizar") { modelo.refrescar() }
                    .controlSize(.small)
                Spacer()
                Button("Salir") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 410)
    }
}

private enum SettingsPage: Hashable {
    case general
    case connection(String)
}

struct ConfigurationView: View {
    @ObservedObject var modelo: VPNModel
    @AppStorage("avisarDesconexion") private var avisarDesconexion = true
    @AppStorage("intervaloRevision") private var intervaloRevision = 5
    @AppStorage(SecurityPreferences.confirmationKey) private var confirmarConTouchID = true
    @State private var drafts: [VPNProfile] = []
    @State private var passwords: [String: String] = [:]
    @State private var selection: SettingsPage?
    @State private var pendingDeletion: String?

    private var busy: Bool { modelo.guardandoConfiguracion || modelo.instalandoAyudante }
    private var hasChanges: Bool {
        drafts != modelo.profiles || passwords.values.contains { !$0.isEmpty }
    }

    private func normalizedDrafts(_ profiles: [VPNProfile]) -> [VPNProfile] {
        profiles.map { profile in
            var normalized = profile
            normalized.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized
        }
    }

    private func trustSelection(_ profile: Binding<VPNProfile>) -> Binding<String> {
        Binding(
            get: { profile.wrappedValue.trust.hasPrefix("sha256:") ? "sha256" : profile.wrappedValue.trust },
            set: { profile.wrappedValue.trust = $0 == "sha256" ? "sha256:" : $0 }
        )
    }

    private func addConnection() {
        let id = "vpn-" + UUID().uuidString.lowercased()
        drafts.append(VPNProfile(id: id, name: "", server: "", username: "",
                                 trust: "system", realm: "", manageRoutes: true,
                                 manageDNS: true, enabled: true))
        selection = .connection(id)
    }

    @ViewBuilder
    private func credentialStatus(_ profile: VPNProfile) -> some View {
        if !passwords[profile.id, default: ""].isEmpty {
            Label("Nueva contraseña lista para guardar", systemImage: "lock.fill")
                .foregroundStyle(.blue)
        } else if let saved = modelo.profiles.first(where: { $0.id == profile.id }),
                  saved.username != profile.username {
            if saved.username.trimmingCharacters(in: .whitespacesAndNewlines) == profile.username {
                Label("Se quitarán espacios del usuario y se migrará la contraseña al guardar", systemImage: "arrow.right.shield.lefthalf.filled")
                    .foregroundStyle(.orange)
            } else {
                Label("Escribe la contraseña del nuevo usuario", systemImage: "key")
                    .foregroundStyle(.orange)
            }
        } else {
            switch modelo.passwordStatuses[profile.id] {
            case .saved:
                Label("Contraseña guardada en el Llavero", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            case .missing:
                Label("Sin contraseña guardada para este usuario", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            case .error(let code):
                Label("No se pudo consultar el Llavero (código \(code))", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.red)
            case nil:
                ProgressView("Comprobando Llavero…")
            }
        }
    }

    private var generalForm: some View {
        Form {
            Section("Seguridad") {
                Toggle("Confirmar con Touch ID durante la preparación inicial", isOn: $confirmarConTouchID)
                Text("Se aplica a Nuvex completo y se solicita una sola vez. Después, basta pulsar Conectar. Si Touch ID no está disponible, macOS puede pedir la contraseña del equipo.")
                    .foregroundStyle(.secondary)
            }
            Section("Supervisión") {
                Toggle("Avisar cuando una VPN se desconecte", isOn: $avisarDesconexion)
                Stepper("Revisar estado cada \(intervaloRevision) segundos", value: $intervaloRevision, in: 2...60)
                    .onChange(of: intervaloRevision) { _, _ in modelo.actualizarIntervalo() }
                Text("Los avisos quedan en el Centro de notificaciones. El estilo del banner se configura en Ajustes del Sistema.")
                    .foregroundStyle(.secondary)
            }
            Section("Ayudante de red") {
                Text("Nuvex prepara el ayudante automáticamente al guardar cambios de conexión. macOS puede pedir autorización de administrador y decide si ofrece Touch ID.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func connectionForm(_ draft: Binding<VPNProfile>) -> some View {
        let id = draft.wrappedValue.id
        return Form {
            Section("Conexión") {
                Toggle("Conexión activa", isOn: draft.enabled)
                TextField("Nombre", text: draft.name)
                if draft.wrappedValue.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Ponle un nombre para identificar esta VPN.")
                        .foregroundStyle(.orange)
                }
                TextField("Servidor y puerto", text: draft.server)
                    .textContentType(.URL)
                if draft.wrappedValue.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Indica el servidor Fortinet y, si corresponde, el puerto.")
                        .foregroundStyle(.orange)
                }
            }
            Section("Acceso") {
                TextField("Usuario", text: draft.username)
                if draft.wrappedValue.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Indica el usuario de esta VPN.")
                        .foregroundStyle(.orange)
                }
                credentialStatus(draft.wrappedValue)
                SecureField("Nueva contraseña", text: Binding(
                    get: { passwords[id] ?? "" },
                    set: { passwords[id] = $0 }
                ))
                Text("La contraseña se guarda en el Llavero de macOS. Déjala vacía para conservar la guardada.")
                    .foregroundStyle(.secondary)
                Text("Si el servidor pide un código por correo o app, Nuvex lo solicitará al conectar.")
                    .foregroundStyle(.secondary)
            }
            Section("Seguridad y red") {
                Picker("Confianza TLS", selection: trustSelection(draft)) {
                    Text("Certificados del sistema").tag("system")
                    Text("Paquete de CA para Prepa incluido").tag("bundle")
                    Text("Huella SHA-256").tag("sha256")
                }
                if draft.wrappedValue.trust == "bundle" {
                    Text("Usa esta CA solo si tu servidor emplea esa cadena de certificados. Para otras VPN, utiliza los certificados del sistema o una huella verificada.")
                        .foregroundStyle(.secondary)
                }
                if draft.wrappedValue.trust.hasPrefix("sha256:") {
                    TextField("Huella de 64 caracteres", text: Binding(
                        get: { String(draft.wrappedValue.trust.dropFirst(7)) },
                        set: { draft.wrappedValue.trust = "sha256:" + $0 }
                    ))
                }
                DisclosureGroup("Opciones de red avanzadas") {
                    TextField("Realm (opcional)", text: draft.realm)
                    Toggle("Instalar rutas de esta VPN", isOn: draft.manageRoutes)
                    Toggle("Usar DNS de esta VPN", isOn: draft.manageDNS)
                    Text("Las rutas pueden incluir la salida general a Internet. Varias VPN con rutas o DNS superpuestos pueden entrar en conflicto.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Eliminar esta conexión", role: .destructive) { pendingDeletion = id }
                    .disabled(drafts.count == 1 || modelo.vpns.contains { $0.id == id && $0.connected })
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Label("General", systemImage: "gearshape")
                        .tag(SettingsPage.general)
                    Section("Conexiones") {
                        ForEach(drafts) { profile in
                            Label(profile.name.isEmpty ? "Nueva conexión" : profile.name,
                                  systemImage: "network.badge.shield.half.filled")
                                .tag(SettingsPage.connection(profile.id))
                        }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                Button(action: addConnection) {
                    Label("Añadir conexión", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(15)
                .disabled(drafts.count >= 64 || busy)
            }
            .frame(width: 225)
            Divider()
            VStack(spacing: 0) {
                if case .connection(let id) = selection,
                   let index = drafts.firstIndex(where: { $0.id == id }) {
                    VStack(spacing: 0) {
                        Text(drafts[index].name.isEmpty ? "Nueva conexión" : drafts[index].name)
                            .font(.system(size: 22, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                        Divider()
                        connectionForm($drafts[index])
                    }
                } else {
                    VStack(spacing: 0) {
                        Text(drafts.isEmpty ? "Configura tu primera VPN" : "General")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                        Divider()
                        if drafts.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Añade un servidor Fortinet SSL VPN, tu usuario y contraseña. Después, Nuvex preparará el ayudante de red al guardar.")
                                    .foregroundStyle(.secondary)
                                Button("Añadir primera conexión", action: addConnection)
                                    .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(24)
                        } else {
                            generalForm
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Button("Guardar y aplicar") {
                            modelo.guardarPerfiles(drafts, passwords: passwords)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || !hasChanges || drafts.contains {
                            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            ($0.enabled && ($0.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                            $0.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        })
                        Button("Instalar o actualizar ayudante") { modelo.instalarAyudante() }
                            .disabled(hasChanges || busy || drafts.isEmpty)
                        Spacer()
                        if hasChanges { Text("Cambios sin guardar").foregroundStyle(.orange) }
                    }
                    if modelo.guardandoConfiguracion { ProgressView("Guardando configuración…") }
                    if modelo.instalandoAyudante { ProgressView("Esperando autorización de macOS…") }
                    if let message = modelo.mensajeConfiguracion { Text(message).foregroundStyle(.green) }
                    if let message = modelo.mensajeAyudante { Text(message).foregroundStyle(.green) }
                    if let error = modelo.ultimoError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if modelo.hayAlgunaConectada {
                        Text("Para cambiar conexiones u opciones, desconecta las VPN activas. Puedes actualizar una contraseña sin desconectarte.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: 15))
        .frame(minWidth: 800, minHeight: 620)
        .onAppear {
            drafts = normalizedDrafts(modelo.profiles)
            if let id = modelo.settingsTargetID, drafts.contains(where: { $0.id == id }) {
                selection = .connection(id)
            } else {
                selection = drafts.first.map { .connection($0.id) } ?? .general
            }
            modelo.cargarConfiguracion()
        }
        .onChange(of: modelo.profiles) { oldValue, newValue in
            drafts = normalizedDrafts(newValue)
            if oldValue.isEmpty {
                if let id = modelo.settingsTargetID, newValue.contains(where: { $0.id == id }) {
                    selection = .connection(id)
                } else if let first = newValue.first {
                    selection = .connection(first.id)
                }
            }
            if case .connection(let id) = selection, !newValue.contains(where: { $0.id == id }) {
                selection = newValue.first.map { .connection($0.id) } ?? .general
            }
        }
        .onChange(of: modelo.settingsTargetID) { _, id in
            if let id, drafts.contains(where: { $0.id == id }) { selection = .connection(id) }
        }
        .onChange(of: modelo.mensajeConfiguracion) { _, message in
            if message != nil { passwords.removeAll() }
        }
        .confirmationDialog("Eliminar conexión", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Eliminar", role: .destructive) {
                if let id = pendingDeletion {
                    drafts.removeAll { $0.id == id }
                    passwords.removeValue(forKey: id)
                    selection = drafts.first.map { .connection($0.id) } ?? .general
                }
                pendingDeletion = nil
            }
        } message: {
            Text("Se eliminará al guardar la configuración.")
        }
    }
}

@main
struct NuvexApp: App {
    @StateObject private var modelo = VPNModel()

    var body: some Scene {
        MenuBarExtra {
            PanelVPN(modelo: modelo)
                .onAppear { modelo.arrancar() }
                .onOpenURL { modelo.solicitarDesdeEnlace($0) }
        } label: {
            HStack(spacing: 4) {
                if let image = Paths.menuLogo {
                    Image(nsImage: image)
                } else {
                    Image(systemName: "network.badge.shield.half.filled")
                }
                Circle()
                    .fill(!modelo.desconexiones.isEmpty ? Color.orange :
                          modelo.conectadas > 0 ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
            }
            .accessibilityLabel("Nuvex, \(modelo.conectadas) VPN conectadas")
        }
        .menuBarExtraStyle(.window)

        Settings {
            ConfigurationView(modelo: modelo)
        }
    }
}
