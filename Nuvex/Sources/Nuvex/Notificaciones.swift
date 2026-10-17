import Foundation
import UserNotifications

/// Los avisos de macOS quedan en el Centro de notificaciones. La presentación
/// como banner persistente depende de la preferencia del usuario en macOS.
final class VPNNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = VPNNotifications()
    var reconnect: ((String) -> Void)?
    var abrirActualizacion: (() -> Void)?

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

    /// Tras actualizar Nuvex, si el ayudante necesita autorización: así se da
    /// con la persona delante y no cuando un asistente intente conectar.
    func avisoAyudante() {
        let content = UNMutableNotificationContent()
        content.title = "Nuvex necesita tu autorización"
        content.body = "Esta versión actualiza el ayudante de red. Ábrelo desde el menú de Nuvex y pulsa Autorizar."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ayudante-pendiente", content: content, trigger: nil))
    }

    /// Aviso discreto de una versión nueva, como en iOS.
    func actualizacionDisponible(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Nuvex \(version) está disponible"
        content.body = "Abre Actualización de software para ver las novedades e instalarla."
        content.categoryIdentifier = "ACTUALIZACION"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "actualizacion-\(version)", content: content, trigger: nil))
    }

    func clear(id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["drop-\(id)"])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.categoryIdentifier == "ACTUALIZACION" {
            abrirActualizacion?()
        } else if response.actionIdentifier == "RECONNECT" || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
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
