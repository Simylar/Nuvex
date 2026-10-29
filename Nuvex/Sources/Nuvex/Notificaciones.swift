import AppKit
import Foundation
import UserNotifications

/// Avisos de macOS. Que un aviso se quede en pantalla hasta cerrarlo depende
/// del estilo «Alertas», que elige el usuario en Ajustes del Sistema; Nuvex lo
/// pide por defecto (NSUserNotificationAlertStyle) y ayuda a activarlo.
final class VPNNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = VPNNotifications()
    static let ajustesDelSistema = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=local.gertcode.nuvex")!

    var reconnect: ((String) -> Void)?
    var ignorar: ((String) -> Void)?
    var abrirAjustes: ((String?) -> Void)?
    var abrirActualizacion: (() -> Void)?

    private enum Categoria {
        static let desconexion = "VPN_DISCONNECTED"
        static let reconexionFallida = "VPN_RECONEXION_FALLIDA"
        static let actualizacion = "ACTUALIZACION"
        static let ayudante = "AYUDANTE"
        static let asistente = "ASISTENTE"
    }

    private enum Accion {
        static let reconectar = "RECONNECT"
        static let ignorar = "IGNORAR"
        static let ajustes = "AJUSTES"
        static let ver = "VER"
    }

    /// Sin paquete .app (compilaciones de depuración) el centro de avisos no existe.
    private var disponible: Bool { Bundle.main.bundleIdentifier != nil }

    func start() {
        guard disponible else { return }
        // Reconectar no trae la app al frente: si el servidor pide un código,
        // la ventana del código aparece por sí sola.
        let reconectar = UNNotificationAction(identifier: Accion.reconectar, title: "Reconectar", options: [])
        let reintentar = UNNotificationAction(identifier: Accion.reconectar, title: "Reintentar", options: [])
        let ignorar = UNNotificationAction(identifier: Accion.ignorar, title: "Ignorar", options: [])
        let ajustes = UNNotificationAction(identifier: Accion.ajustes, title: "Abrir Ajustes", options: [.foreground])
        let ver = UNNotificationAction(identifier: Accion.ver, title: "Ver novedades", options: [.foreground])
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Categoria.desconexion, actions: [reconectar, ignorar], intentIdentifiers: []),
            UNNotificationCategory(identifier: Categoria.reconexionFallida, actions: [reintentar, ajustes], intentIdentifiers: []),
            UNNotificationCategory(identifier: Categoria.actualizacion, actions: [ver], intentIdentifiers: []),
            UNNotificationCategory(identifier: Categoria.ayudante, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Categoria.asistente, actions: [], intentIdentifiers: []),
        ])
        // La autorización se pide desde Ajustes, en contexto. Solicitarla al
        // arrancar apilaba un diálogo de macOS con el onboarding del ayudante,
        // Llavero y Google aunque la persona aún no hubiera pedido avisos.
    }

    // MARK: Avisos

    func disconnected(id: String, name: String, fecha: Date = Date()) {
        let content = UNMutableNotificationContent()
        content.title = "«\(name)» se desconectó"
        content.body = "Perdió la conexión a las \(fecha.formatted(date: .omitted, time: .shortened)). Pulsa Reconectar para volver a conectarla."
        content.categoryIdentifier = Categoria.desconexion
        content.threadIdentifier = "vpn"
        content.userInfo = ["profile": id]
        content.sound = .default
        content.interruptionLevel = .active
        publicar(content, id: "drop-\(id)")
    }

    /// Sustituye al aviso de desconexión cuando reconectar desde él falla.
    func reconexionFallida(id: String, name: String, fallo: Fallo) {
        let content = UNMutableNotificationContent()
        content.title = "No se pudo reconectar «\(name)»"
        content.body = "\(fallo.titulo). \(fallo.detalle)"
        content.categoryIdentifier = Categoria.reconexionFallida
        content.threadIdentifier = "vpn"
        content.userInfo = ["profile": id]
        content.sound = .default
        content.interruptionLevel = .active
        publicar(content, id: "drop-\(id)")
    }

    /// Tras actualizar Nuvex, si el ayudante necesita autorización: así se da
    /// con la persona delante y no cuando un asistente intente conectar.
    func avisoAyudante() {
        let content = UNMutableNotificationContent()
        content.title = "Nuvex necesita tu autorización"
        content.body = "Esta versión actualiza el ayudante de red. Ábrelo desde el menú de Nuvex y pulsa Autorizar."
        content.categoryIdentifier = Categoria.ayudante
        content.sound = .default
        publicar(content, id: "ayudante-pendiente")
    }

    /// Aviso discreto de una versión nueva, como en iOS.
    func actualizacionDisponible(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Nuvex \(version) está disponible"
        content.body = "Abre Actualización de software para ver las novedades e instalarla."
        content.categoryIdentifier = Categoria.actualizacion
        publicar(content, id: "actualizacion-\(version)")
    }

    /// Informa de lo que hizo un asistente o la Terminal.
    func accionAsistente(titulo: String, cuerpo: String) {
        let content = UNMutableNotificationContent()
        content.title = titulo
        content.body = cuerpo
        content.categoryIdentifier = Categoria.asistente
        content.threadIdentifier = "asistentes"
        content.interruptionLevel = .passive
        publicar(content, id: "asistente-\(UUID().uuidString)")
    }

    /// Ejemplo para ver cómo se presentan los avisos con el estilo actual.
    func prueba() {
        let content = UNMutableNotificationContent()
        content.title = "«Oficina» se desconectó"
        content.body = "Así se verá el aviso cuando una VPN pierda la conexión. Este es solo un ejemplo."
        content.categoryIdentifier = Categoria.ayudante
        content.sound = .default
        publicar(content, id: "prueba")
    }

    func clear(id: String) {
        guard disponible else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["drop-\(id)"])
    }

    private func publicar(_ content: UNMutableNotificationContent, id: String) {
        guard disponible else { return }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { Log.escribir("no se pudo mostrar un aviso: \(error.localizedDescription)") }
        }
    }

    // MARK: Estilo

    enum Estilo: Equatable {
        case noDisponible
        case sinAutorizar
        case desactivados
        case alertas
        case banners
        case sinPresentacion
    }

    func estilo() async -> Estilo {
        guard disponible else { return .noDisponible }
        let ajustes = await UNUserNotificationCenter.current().notificationSettings()
        switch ajustes.authorizationStatus {
        case .denied: return .desactivados
        case .notDetermined: return .sinAutorizar
        default: break
        }
        switch ajustes.alertStyle {
        case .alert: return .alertas
        case .banner: return .banners
        default: return .sinPresentacion
        }
    }

    /// Único punto que solicita el permiso de avisos. macOS decide si debe
    /// mostrar el diálogo y conserva o revoca la autorización.
    func solicitarAutorizacion() async -> Bool {
        guard disponible else { return false }
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.escribir("permisos componente=avisos estado=fallo")
            return false
        }
    }

    // MARK: Respuestas

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let contenido = response.notification.request.content
        let id = contenido.userInfo["profile"] as? String
        switch (contenido.categoryIdentifier, response.actionIdentifier) {
        case (Categoria.actualizacion, _):
            abrirActualizacion?()
        case (_, Accion.ignorar):
            if let id { ignorar?(id) }
        case (_, Accion.ajustes):
            abrirAjustes?(id)
        case (Categoria.desconexion, _), (Categoria.reconexionFallida, Accion.reconectar):
            if let id { reconnect?(id) }
        case (Categoria.reconexionFallida, _):
            abrirAjustes?(id)
        default:
            break
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
