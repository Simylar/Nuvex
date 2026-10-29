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
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrLabel as String: profile.etiquetaLlavero]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, nuevo in nuevo }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw ErrorVPN(mensaje: "El Llavero devolvió \(added)") }
        } else if update != errSecSuccess {
            throw ErrorVPN(mensaje: "El Llavero devolvió \(update)")
        }
    }

    /// Mantiene el nombre visible del Llavero sincronizado aunque al guardar
    /// el perfil no se haya escrito una contraseña nueva.
    nonisolated static func actualizarEtiquetaDelLlavero(profile: VPNProfile) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "nuvex.\(profile.id)",
                                    kSecAttrAccount as String: profile.username]
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecAttrLabel as String: profile.etiquetaLlavero] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ErrorVPN(mensaje: "No se pudo actualizar el nombre visible de la contraseña de \(profile.name).")
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
                                            reason: String? = nil,
                                            intentoConexion: String? = nil) async throws -> String {
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
        try await confirmarUsoInicial(razon: reason ?? "Usar la contraseña guardada para conectar a \(name)",
                                      intentoConexion: intentoConexion)
        let context = LAContext()
        if let intentoConexion {
            IntentosConexion.registrarContexto(intentoConexion, contexto: context)
        }
        defer {
            if let intentoConexion {
                IntentosConexion.retirarContexto(intentoConexion, contexto: context)
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
        if status == errSecUserCanceled {
            throw ErrorVPN(mensaje: "Se canceló el acceso al Llavero para \(name).",
                           fallo: Fallo(titulo: "Acceso al Llavero cancelado", detalle: "Vuelve a conectar cuando puedas permitir el acceso a la contraseña.", accion: .reintentar("Reintentar")))
        }
        if status == errSecItemNotFound {
            throw ErrorVPN(mensaje: "No hay contraseña guardada para \(name). Agrégala en Ajustes.",
                           fallo: Fallo(titulo: "Falta la contraseña", detalle: "No hay contraseña guardada en el Llavero para esta conexión.", accion: .ajustes("Añadir…")))
        }
        if status == errSecSuccess {
            throw ErrorVPN(mensaje: "La entrada del Llavero de \(name) no contiene una contraseña válida.",
                           fallo: Fallo(titulo: "Contraseña guardada no válida", detalle: "Vuelve a guardar la contraseña en Ajustes.", accion: .ajustes("Cambiar…")))
        }
        throw ErrorVPN(mensaje: "No se pudo usar la contraseña de \(name) (código \(status)). Desbloquea el Llavero o revisa su acceso en Acceso a Llaveros.",
                       fallo: Fallo(titulo: "No se pudo usar la contraseña", detalle: "El Llavero devolvió el código \(status). Desbloquéalo o revisa el acceso de Nuvex en Acceso a Llaveros.", accion: .ajustes("Revisar…")))
    }

    nonisolated static func confirmarUsoInicial(razon: String, intentoConexion: String? = nil) async throws {
        try await ConfirmacionInicial.shared.confirmar {
            let context = LAContext()
            if let intentoConexion { IntentosConexion.registrarContexto(intentoConexion, contexto: context) }
            defer {
                if let intentoConexion { IntentosConexion.retirarContexto(intentoConexion, contexto: context) }
            }
            var policyError: NSError?
            let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                             error: &policyError)
                ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
            guard context.canEvaluatePolicy(policy, error: &policyError) else {
                throw ErrorVPN(mensaje: "macOS no puede confirmar tu identidad. Revisa Touch ID o la contraseña del equipo en Ajustes del Sistema.",
                               fallo: Fallo(titulo: "macOS no puede confirmar tu identidad", detalle: "Revisa Touch ID o la contraseña del equipo en Ajustes del Sistema.", accion: .reintentar("Reintentar")))
            }
            do {
                try await context.evaluatePolicy(policy,
                    localizedReason: razon)
            } catch {
                throw ErrorVPN(mensaje: "Se canceló o falló la confirmación de macOS.",
                               fallo: Fallo(titulo: "Confirmación cancelada", detalle: "Se canceló o falló la confirmación de macOS con Touch ID o la contraseña del equipo.", accion: .reintentar("Reintentar")))
            }
        }
    }

    /// Contraseñas de varias conexiones para exportarlas. Pide una sola
    /// confirmación de la persona (Touch ID o la contraseña del equipo) para
    /// todo el lote. Las que no estén guardadas no se incluyen.
    nonisolated static func leerParaExportar(_ perfiles: [VPNProfile], razon: String) async throws -> [String: String] {
        let contexto = LAContext()
        do {
            try await contexto.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: razon)
        } catch {
            throw ErrorVPN(mensaje: "Se canceló la confirmación; no se exportaron contraseñas.")
        }
        var resultado: [String: String] = [:]
        for perfil in perfiles where !perfil.username.isEmpty {
            let consulta: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                           kSecAttrService as String: "nuvex.\(perfil.id)",
                                           kSecAttrAccount as String: perfil.username,
                                           kSecReturnData as String: true,
                                           kSecUseAuthenticationContext as String: contexto,
                                           kSecMatchLimit as String: kSecMatchLimitOne]
            var dato: CFTypeRef?
            let estado = SecItemCopyMatching(consulta as CFDictionary, &dato)
            if estado == errSecSuccess,
               let datos = dato as? Data, let password = String(data: datos, encoding: .utf8), !password.isEmpty {
                resultado[perfil.id] = password
            } else if estado != errSecItemNotFound {
                throw ErrorVPN(mensaje: "No se pudo leer la contraseña de \(perfil.name) (código \(estado)). No se exportaron contraseñas.")
            }
        }
        return resultado
    }
}
