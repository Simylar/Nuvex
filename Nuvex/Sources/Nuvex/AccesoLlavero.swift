import Foundation
import LocalAuthentication
import Security

/// Un resultado de lectura, no una promesa de acceso permanente. macOS no
/// expone un permiso global del Llavero para todas las entradas.
enum AccesoLlavero: Equatable, Sendable {
    case disponible, ausente, requiereInteraccion, cancelado, fallo(Int32)

    init(codigo: OSStatus) {
        switch codigo {
        case errSecSuccess: self = .disponible
        case errSecItemNotFound: self = .ausente
        case errSecInteractionNotAllowed, errSecAuthFailed: self = .requiereInteraccion
        case errSecUserCanceled: self = .cancelado
        default: self = .fallo(codigo)
        }
    }

    var descripcion: String {
        switch self {
        case .disponible: return "Acceso comprobado ahora"
        case .ausente: return "No hay contraseña guardada"
        case .requiereInteraccion: return "Requiere desbloquear el Llavero o revisar el acceso"
        case .cancelado: return "Lectura cancelada"
        case .fallo(let codigo): return "No se pudo comprobar (código \(codigo))"
        }
    }

    static func comprobar(servicio: String, cuenta: String) -> AccesoLlavero {
        let contexto = LAContext()
        contexto.interactionNotAllowed = true
        let consulta: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicio, kSecAttrAccount as String: cuenta,
            kSecUseAuthenticationContext as String: contexto,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var dato: CFTypeRef?
        return AccesoLlavero(codigo: SecItemCopyMatching(consulta as CFDictionary, &dato))
    }
}
