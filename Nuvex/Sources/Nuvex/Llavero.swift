import Foundation
import Security
import LocalAuthentication

// MARK: - Llavero de macOS

extension VPNModel {
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
            throw ErrorVPN(mensaje: "No hay contraseña guardada para \(name). Agrégala en Ajustes.",
                           fallo: Fallo(titulo: "Falta la contraseña", detalle: "No hay contraseña guardada en el Llavero para esta conexión.", accion: .ajustes("Añadir…")))
        }
        let context = LAContext()
        if SecurityPreferences.needsInitialConfirmation() {
            var policyError: NSError?
            let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                             error: &policyError)
                ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
            guard context.canEvaluatePolicy(policy, error: &policyError) else {
                throw ErrorVPN(mensaje: "macOS no puede confirmar tu identidad para \(name). Revisa Touch ID o la contraseña del equipo en Ajustes del Sistema.",
                               fallo: Fallo(titulo: "macOS no puede confirmar tu identidad", detalle: "Revisa Touch ID o la contraseña del equipo en Ajustes del Sistema.", accion: .reintentar("Reintentar")))
            }
            do {
                try await context.evaluatePolicy(policy,
                    localizedReason: reason ?? "Usar la contraseña guardada para conectar a \(name)")
                SecurityPreferences.markInitialUseAuthorized()
            } catch {
                throw ErrorVPN(mensaje: "Se canceló o falló la confirmación de macOS para \(name).",
                               fallo: Fallo(titulo: "Confirmación cancelada", detalle: "Se canceló o falló la confirmación de macOS con Touch ID o la contraseña del equipo.", accion: .reintentar("Reintentar")))
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
            throw ErrorVPN(mensaje: "No se autorizó el acceso al Llavero para \(name). Vuelve a conectar y permite el acceso de Nuvex.",
                           fallo: Fallo(titulo: "Acceso al Llavero denegado", detalle: "Vuelve a conectar y permite que Nuvex use la contraseña guardada.", accion: .reintentar("Reintentar")))
        }
        if let password = leerConHerramientaDeMacOS(id: id, username: username) {
            return password
        }
        if case .missing = passwordStatus(id: id, username: username) {
            throw ErrorVPN(mensaje: "No hay contraseña guardada para \(name). Agrégala en Ajustes.",
                           fallo: Fallo(titulo: "Falta la contraseña", detalle: "No hay contraseña guardada en el Llavero para esta conexión.", accion: .ajustes("Añadir…")))
        }
        throw ErrorVPN(mensaje: "La contraseña de \(name) está en el Llavero, pero no se pudo usar (código \(status)). Revisa sus permisos en Acceso a Llaveros o vuelve a guardarla en Ajustes.",
                       fallo: Fallo(titulo: "No se pudo usar la contraseña", detalle: "La contraseña está en el Llavero, pero macOS no permitió usarla (código \(status)). Vuelve a guardarla en Ajustes.", accion: .ajustes("Cambiar…")))
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
}
