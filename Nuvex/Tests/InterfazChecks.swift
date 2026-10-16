import Foundation

/// Comprobaciones de la lógica de interfaz que no depende de AppKit:
/// traducción de fallos del motor, validación de campos y duraciones.
@main
struct InterfazChecks {
    static func main() {
        // Fallos del motor → mensaje y acción para la fila del panel.
        let credenciales = Fallo.interpretar("ERROR:  Could not authenticate to gateway. Please check the password, client certificate, etc.\n")
        precondition(credenciales.titulo == "Autenticación rechazada")
        precondition(credenciales.accion == .ajustes("Cambiar…"))
        let tunel = Fallo.interpretar("ERROR:  Could not authenticate to the gateway. Please make sure tunnel mode is allowed by the gateway.")
        precondition(tunel.titulo == "El servidor rechazó el túnel")
        precondition(tunel.accion == .ajustes("Revisar…"))
        precondition(Fallo.interpretar("NUVEX_TLS_VERIFY_FAILED\nERROR: Gateway certificate validation failed").titulo == "Certificado no verificado")
        precondition(Fallo.interpretar("ERROR:  getaddrinfo: nodename nor servname provided, or not known").titulo == "No se encuentra el servidor")
        precondition(Fallo.interpretar("ERROR:  connect: Operation timed out").accion == .reintentar("Reintentar"))
        let cancelado = Fallo.interpretar("Could not authenticate to gateway", codigoCancelado: true)
        precondition(cancelado.titulo == "Conexión cancelada")
        let generico = Fallo.interpretar("NUVEX_OTP_REQUIRED\nnuvex: perfil desactivado\n")
        precondition(generico.titulo == "No se pudo conectar")
        precondition(generico.detalle == "perfil desactivado")
        precondition(Fallo.interpretar("").detalle.contains("registro"))

        // Validación con las mismas reglas que nuvexconfig.py.
        for valido in ["vpn.empresa.com", "vpn.empresa.com:443", "https://vpn.empresa.com:10443/", "[fe80::1]:443"] {
            precondition(Validacion.servidorValido(valido), valido)
        }
        for invalido in ["vpn empresa", "vpn.empresa.com:0", "vpn.empresa.com:70000", "ftp://vpn", "-vpn.com"] {
            precondition(!Validacion.servidorValido(invalido), invalido)
        }
        precondition(Validacion.huellaValida("system"))
        precondition(Validacion.huellaValida("sha256:" + String(repeating: "a", count: 64)))
        precondition(!Validacion.huellaValida("sha256:" + String(repeating: "a", count: 63)))
        precondition(!Validacion.huellaValida("sha256:" + String(repeating: "g", count: 64)))
        precondition(!Validacion.huellaValida("sha256:" + String(repeating: "Ａ", count: 64)))
        precondition(!Validacion.huellaValida("otro"))

        var perfil = VPNProfile.nuevo()
        precondition(Validacion.motivo(perfil) == "Falta el nombre de la conexión.")
        perfil.name = "Oficina"
        precondition(Validacion.motivo(perfil) == "Falta el servidor.")
        perfil.enabled = false
        precondition(Validacion.motivo(perfil) == nil, "una conexión oculta puede guardarse incompleta")
        perfil.enabled = true
        perfil.server = " vpn.empresa.com:443 "
        perfil.username = "ana"
        precondition(Validacion.motivo(perfil) == nil)
        precondition(perfil.normalizado.server == "vpn.empresa.com:443")
        perfil.username = "  ana "
        precondition(perfil.normalizado.username == "ana")
        perfil.trust = "otro"
        precondition(Validacion.motivo(perfil) != nil)
        perfil.trust = "system"
        perfil.realm = String(repeating: "r", count: 129)
        precondition(Validacion.motivo(perfil)?.contains("realm") == true)
        perfil.realm = ""
        perfil.name = "Oficina\nOtra"
        precondition(Validacion.motivo(perfil) != nil)
        perfil.name = String(repeating: "e\u{0301}", count: 31)
        precondition(Validacion.motivo(perfil)?.contains("60 caracteres") == true)
        perfil.name = "Oficina"
        perfil.username = "ana\nb"
        precondition(Validacion.motivo(perfil) != nil)
        perfil.username = "ana"
        precondition(Validacion.motivo(perfil) == nil)
        precondition(VPNProfile.nuevo().id.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil)

        // Duraciones que muestra el panel.
        let inicio = Date(timeIntervalSince1970: 0)
        precondition(Formato.duracion(desde: inicio, hasta: inicio.addingTimeInterval(30)) == "ahora")
        precondition(Formato.duracion(desde: inicio, hasta: inicio.addingTimeInterval(12 * 60)) == "12 min")
        precondition(Formato.duracion(desde: inicio, hasta: inicio.addingTimeInterval(72 * 60)) == "1 h 12 min")
        precondition(Formato.duracion(desde: inicio, hasta: inicio.addingTimeInterval(2 * 3600)) == "2 h")
        precondition(Formato.duracion(desde: inicio, hasta: inicio.addingTimeInterval(51 * 3600)) == "2 d 3 h")
        precondition(Formato.duracion(desde: inicio, hasta: inicio.addingTimeInterval(-60)) == "ahora")

        print("Interfaz: comprobaciones superadas")
    }
}
