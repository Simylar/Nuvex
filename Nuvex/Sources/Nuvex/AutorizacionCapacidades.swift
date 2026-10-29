import Combine
import Foundation

/// La operación pertenece a la aplicación, no al ciclo de vida de una vista.
/// Revocar invalida cualquier autorización que aún espere la confirmación.
@MainActor
final class AutorizacionCapacidades: ObservableObject {
    @Published private(set) var trabajando = false
    @Published private(set) var mensaje: String?
    private var generacion = 0
    private let preferencias: Preferencias
    private let confirmar: () async throws -> Void
    private let preparar: () throws -> Void
    private let revocarConfirmacion: () -> Void
    private let retirarReglas: () -> [String]

    init(preferencias: Preferencias, confirmar: @escaping () async throws -> Void,
         preparar: @escaping () throws -> Void, revocarConfirmacion: @escaping () -> Void,
         retirarReglas: @escaping () -> [String]) {
        self.preferencias = preferencias
        self.confirmar = confirmar
        self.preparar = preparar
        self.revocarConfirmacion = revocarConfirmacion
        self.retirarReglas = retirarReglas
    }

    func autorizar() async {
        guard !trabajando else { return }
        guard preferencias.soloLectura == nil else {
            mensaje = preferencias.soloLectura
            return
        }
        generacion += 1
        let actual = generacion
        trabajando = true
        mensaje = nil
        defer { if actual == generacion { trabajando = false } }
        do {
            try await confirmar()
            guard actual == generacion else { return }
            try Task.checkCancellation()
            try preparar()
            guard preferencias.modificar({ $0.autorizarCapacidades() }) else {
                throw CocoaError(.fileWriteUnknown)
            }
            mensaje = "Decisión guardada. Revisa los permisos externos y las integraciones pendientes en el estado."
        } catch {
            guard actual == generacion else { return }
            mensaje = "No se completó la autorización: \(error.localizedDescription) Revisa el estado antes de reintentar; la preparación puede haber quedado parcial."
        }
    }

    func revocar() {
        guard preferencias.modificar({ $0.revocarCapacidades() }) else {
            mensaje = "No se pudo guardar la revocación. No se ha cambiado la autorización."
            return
        }
        generacion += 1
        trabajando = false
        revocarConfirmacion()
        let pendientes = retirarReglas()
        mensaje = pendientes.isEmpty ? "Autorización interna revocada."
            : "Automatización bloqueada. No se pudieron retirar las reglas de: \(pendientes.joined(separator: ", ")). Reintenta la revocación."
    }
}
