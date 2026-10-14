import Foundation
import Darwin

enum SecurityPreferences {
    static let confirmationKey = "confirmarConTouchID"
    static let authorizedKey = "touchIDPrimerUsoCompletado"
    private static let legacyPrefix = "confirmarConexion."

    static func needsInitialConfirmation(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: confirmationKey) as? Bool ?? true) &&
            !defaults.bool(forKey: authorizedKey)
    }

    static func migrate(defaults: UserDefaults = .standard,
                        existingHelper: Bool = FileManager.default.fileExists(
                            atPath: "/Library/PrivilegedHelperTools/Nuvex/helper-\(getuid())")) {
        let legacy = defaults.dictionaryRepresentation().compactMapValues { $0 as? Bool }
            .filter { $0.key.hasPrefix(legacyPrefix) }
        if defaults.object(forKey: confirmationKey) == nil, !legacy.isEmpty {
            defaults.set(legacy.values.contains(true), forKey: confirmationKey)
        }
        // El ayudante instalado indica que macOS ya autorizó la preparación.
        if defaults.object(forKey: authorizedKey) == nil, existingHelper {
            defaults.set(true, forKey: authorizedKey)
        }
        for key in legacy.keys { defaults.removeObject(forKey: key) }
    }

    static func markInitialUseAuthorized(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: authorizedKey)
    }
}
