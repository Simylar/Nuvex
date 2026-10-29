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

/// Comparte la confirmación entre conexiones concurrentes. Una revocación
/// invalida también una respuesta de autenticación que llegue tarde.
@MainActor
final class ConfirmacionInicial {
    static let shared = ConfirmacionInicial()
    private let defaults: UserDefaults
    private var tarea: (id: UUID, valor: Task<Void, Error>)?
    private var generacion = 0

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func confirmar(autenticar: @escaping @Sendable () async throws -> Void) async throws {
        guard SecurityPreferences.needsInitialConfirmation(defaults: defaults) else { return }
        let actual = generacion
        let id: UUID
        let compartida: Task<Void, Error>
        if let tarea { compartida = tarea.valor; id = tarea.id }
        else {
            id = UUID()
            compartida = Task { try await autenticar() }
            tarea = (id, compartida)
        }
        do {
            try await compartida.value
            guard actual == generacion else { throw CancellationError() }
            SecurityPreferences.markInitialUseAuthorized(defaults: defaults)
            if tarea?.id == id { tarea = nil }
        } catch {
            if tarea?.id == id { tarea = nil }
            throw error
        }
    }

    func revocar() {
        generacion += 1
        tarea?.valor.cancel()
        tarea = nil
        defaults.set(true, forKey: SecurityPreferences.confirmationKey)
        defaults.set(false, forKey: SecurityPreferences.authorizedKey)
    }
}
