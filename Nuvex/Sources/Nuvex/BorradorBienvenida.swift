import Combine
import Foundation

/// Conserva el formulario durante la sesión, incluso si se cierra la ventana
/// mientras macOS autoriza el ayudante. La contraseña nunca se persiste aquí.
@MainActor
final class BorradorBienvenida: ObservableObject {
    enum Paso { case formulario, preparando, guardada }
    @Published var paso: Paso = .formulario
    @Published var perfil = VPNProfile.nuevo()
    @Published var password = ""
    @Published var intento = false
    @Published var error: String?
    @Published var resumen: ResumenGuardado?
    var conexionCompletada = false

    @discardableResult
    func completar(_ resultado: ResultadoGuardado, contrasenaDisponible: Bool = false) -> Bool {
        error = nil
        resumen = resultado.resumen
        guard resultado.confirmaImportacion([perfil.id]) else {
            error = resultado.avisos.first ?? "No se pudo guardar la conexión. Vuelve a intentarlo."
            paso = .formulario
            return false
        }
        guard resultado.resumen.contrasenas == .hecho ||
                (resultado.resumen.contrasenas == .noAplica && contrasenaDisponible) else {
            error = "La conexión se guardó, pero su contraseña no. Permite el acceso al Llavero y vuelve a guardar."
            paso = .formulario
            return false
        }
        password = ""
        paso = .guardada
        return resultado.completo
    }

    var tieneAvance: Bool {
        paso != .formulario || !perfil.server.isEmpty || !perfil.username.isEmpty
            || !perfil.name.isEmpty || !password.isEmpty || perfil.trust != "system"
            || !perfil.realm.isEmpty || !perfil.manageRoutes || !perfil.manageDNS
    }
}
