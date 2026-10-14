import Foundation

@main
struct SecurityPreferencesChecks {
    private static func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "NuvexTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    static func main() {
        withDefaults { defaults in
            defaults.set(false, forKey: "confirmarConexion.sicert")
            defaults.set(false, forKey: "confirmarConexion.prepa")
            SecurityPreferences.migrate(defaults: defaults, existingHelper: false)
            precondition(defaults.bool(forKey: SecurityPreferences.confirmationKey) == false)
            precondition(defaults.object(forKey: "confirmarConexion.sicert") == nil)
            precondition(defaults.object(forKey: "confirmarConexion.prepa") == nil)
        }
        withDefaults { defaults in
            defaults.set(false, forKey: "confirmarConexion.sicert")
            defaults.set(true, forKey: "confirmarConexion.prepa")
            SecurityPreferences.migrate(defaults: defaults, existingHelper: false)
            precondition(defaults.bool(forKey: SecurityPreferences.confirmationKey))
        }
        withDefaults { defaults in
            defaults.set(false, forKey: SecurityPreferences.confirmationKey)
            defaults.set(true, forKey: "confirmarConexion.sicert")
            SecurityPreferences.migrate(defaults: defaults, existingHelper: false)
            precondition(defaults.bool(forKey: SecurityPreferences.confirmationKey) == false)
            precondition(defaults.object(forKey: "confirmarConexion.sicert") == nil)
        }
        withDefaults { defaults in
            SecurityPreferences.migrate(defaults: defaults, existingHelper: true)
            precondition(SecurityPreferences.needsInitialConfirmation(defaults: defaults) == false)
        }
        withDefaults { defaults in
            SecurityPreferences.migrate(defaults: defaults, existingHelper: false)
            precondition(SecurityPreferences.needsInitialConfirmation(defaults: defaults))
            SecurityPreferences.markInitialUseAuthorized(defaults: defaults)
            precondition(SecurityPreferences.needsInitialConfirmation(defaults: defaults) == false)
        }
        print("SecurityPreferences: 5 checks passed")
    }
}
