import Foundation
import UserNotifications

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
