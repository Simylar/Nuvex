import Foundation
import AppKit
import SwiftUI

/// Comprobaciones de la lógica de interfaz que no depende de AppKit:
/// traducción de fallos del motor, validación de campos y duraciones.
@main
struct InterfazChecks {
    static func main() {
        let intentoAnterior = Date(timeIntervalSince1970: 1)
        let intentoNuevo = Date(timeIntervalSince1970: 2)
        precondition(VigenciaIntentoConexion.corresponde(intentoNuevo, al: intentoNuevo))
        precondition(!VigenciaIntentoConexion.corresponde(intentoAnterior, al: intentoNuevo),
                     "un temporizador anterior no debe afectar una reconexión")
        precondition(GeometriaVentanaCodigo.nivelVentana == .floating)
        precondition(GeometriaVentanaCodigo.esPanelFlotante)

        // La ventana del código permanece dentro del área visible, incluso en
        // una pantalla pequeña, secundaria o al escalonar varias solicitudes.
        func contiene(_ exterior: NSRect, _ interior: NSRect) -> Bool {
            interior.minX >= exterior.minX && interior.maxX <= exterior.maxX
                && interior.minY >= exterior.minY && interior.maxY <= exterior.maxY
        }
        let principal = NSRect(x: 0, y: 40, width: 1_280, height: 680)
        precondition(GeometriaVentanaCodigo.altoInicial(areaVisible: principal) == 340)
        let marcoPrincipal = GeometriaVentanaCodigo.marco(
            areaVisible: principal, tamanoIdeal: NSSize(width: 360, height: 340), indice: 0)
        precondition(contiene(principal, marcoPrincipal))
        let secundaria = NSRect(x: -1_024, y: 23, width: 1_024, height: 745)
        let marcoSecundario = GeometriaVentanaCodigo.marco(
            areaVisible: secundaria, tamanoIdeal: NSSize(width: 360, height: 560), indice: 3)
        precondition(contiene(secundaria, marcoSecundario))
        let pequena = NSRect(x: 100, y: 100, width: 320, height: 240)
        precondition(GeometriaVentanaCodigo.altoInicial(areaVisible: pequena) == 160)
        let marcoPequeno = GeometriaVentanaCodigo.marco(
            areaVisible: pequena, tamanoIdeal: NSSize(width: 360, height: 340), indice: 1)
        precondition(contiene(pequena, marcoPequeno))

        let activa = #"[{"id":"vpn-a","name":"Oficina","connected":true,"pid":123,"ip":"","iface":"","networks":[],"enabled":true,"configured":true,"helperReady":true}]"#
        let detenida = activa.replacingOccurrences(of: "\"connected\":true", with: "\"connected\":false")
        precondition(!EstadoMotor.confirmaDesconexion(["vpn-a"], codigo: 0, salida: activa))
        precondition(EstadoMotor.confirmaDesconexion(["vpn-a"], codigo: 0, salida: detenida))
        precondition(!EstadoMotor.confirmaDesconexion(["vpn-a"], codigo: 1, salida: detenida))
        precondition(!EstadoMotor.confirmaDesconexion(["vpn-a"], codigo: 0, salida: "respuesta incompleta"))
        precondition(!EstadoMotor.confirmaDesconexion(["vpn-a"], codigo: 0, salida: "[]"))

        // Fallos del motor → mensaje y acción para la fila del panel.
        let credenciales = Fallo.interpretar("ERROR:  Could not authenticate to gateway. Please check the password, client certificate, etc.\n")
        precondition(credenciales.titulo == "Autenticación rechazada")
        precondition(credenciales.accion == .ajustes("Cambiar…"))
        precondition(credenciales.codigo == .autenticacion)
        let tunel = Fallo.interpretar("ERROR:  Could not authenticate to the gateway. Please make sure tunnel mode is allowed by the gateway.")
        precondition(tunel.titulo == "El servidor rechazó el túnel")
        precondition(tunel.accion == .ajustes("Revisar…"))
        precondition(Fallo.interpretar("NUVEX_TLS_VERIFY_FAILED\nERROR: Gateway certificate validation failed").titulo == "Certificado no verificado")
        precondition(Fallo.interpretar("ERROR:  getaddrinfo: nodename nor servname provided, or not known").titulo == "No se encuentra el servidor")
        let sinRespuesta = Fallo.interpretar("ERROR:  connect: Operation timed out")
        precondition(sinRespuesta.accion == .reintentar("Reintentar"))
        precondition(sinRespuesta.codigo == .servidorNoResponde)
        let cancelado = Fallo.interpretar("Could not authenticate to gateway", codigoCancelado: true)
        precondition(cancelado.titulo == "Conexión cancelada")
        precondition(cancelado.codigo == .cancelada)
        let generico = Fallo.interpretar("NUVEX_OTP_REQUIRED\nnuvex: perfil desactivado\n")
        precondition(generico.titulo == "No se pudo conectar")
        precondition(generico.detalle.contains("Internet"))
        precondition(!generico.detalle.contains("perfil desactivado"))
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

        // El nombre automático solo se propone al crear desde la interfaz.
        var alta = VPNProfile.nuevo()
        alta.server = " https://vpn.empresa.com:10443/ "
        alta.username = " persona "
        precondition(alta.conNombreSugerido.name == "vpn.empresa.com")
        precondition(alta.conNombreSugerido.server == "https://vpn.empresa.com:10443/")
        precondition(alta.conNombreSugerido.username == "persona")
        precondition(alta.conNombreSugerido.trust == "system")
        alta.name = "Mi oficina"
        precondition(alta.conNombreSugerido.name == "Mi oficina")
        alta.name = ""
        alta.server = "vpn empresa"
        precondition(alta.conNombreSugerido.name.isEmpty)
        alta.server = String(repeating: "a", count: 61) + ".example"
        precondition(alta.conNombreSugerido.name.count == 60)
        alta.server = "[2001:db8::1]:443"
        precondition(!alta.conNombreSugerido.name.isEmpty)

        var recuperacion = RecuperacionConexion()
        precondition(!recuperacion.reservar("oficina", activada: false, disponible: true))
        precondition(!recuperacion.reservar("oficina", activada: true, disponible: false))
        precondition(recuperacion.reservar("oficina", activada: true, disponible: true))
        precondition(!recuperacion.reservar("oficina", activada: true, disponible: true))
        precondition(recuperacion.reservar("escuela", activada: true, disponible: true))
        recuperacion.permitirNuevoIntento("oficina")
        precondition(recuperacion.reservar("oficina", activada: true, disponible: true))
        precondition(!recuperacion.reservar("escuela", activada: true, disponible: true))

        // Una recuperación aplazada sin red no consume el único intento.
        var aplazada = RecuperacionConexion()
        precondition(aplazada.puedeIntentar("oficina"))
        precondition(!aplazada.reservar("oficina", activada: true, disponible: false))
        precondition(aplazada.puedeIntentar("oficina"))
        precondition(aplazada.reservar("oficina", activada: true, disponible: true))
        precondition(!aplazada.puedeIntentar("oficina"))

        var primera = alta
        primera.name = "Oficina"; primera.server = "vpn.example"; primera.username = "persona"
        var segunda = VPNProfile.nuevo()
        segunda.name = "Escuela"; segunda.server = "vpn.example"; segunda.username = "persona"
        let fallo = Fallo.interpretar("Operation timed out")
        precondition(ReaperturaNuvex.conexion(perfiles: [primera, segunda],
            estados: [primera.id: .conectada, segunda.id: .error(fallo)], enCurso: []) == segunda.id)
        precondition(ReaperturaNuvex.conexion(perfiles: [primera, segunda],
            estados: [primera.id: .conectada], enCurso: [segunda.id]) == segunda.id)
        segunda.enabled = false
        precondition(ReaperturaNuvex.conexion(perfiles: [segunda, primera],
            estados: [segunda.id: .error(fallo)], enCurso: []) == primera.id)
        precondition(ReaperturaNuvex.conexion(perfiles: [], estados: [:], enCurso: []) == nil)

        // Colores informativos opacos con las dos apariencias reales de AppKit.
        func luminancia(_ color: Color) -> Double {
            let rgb = NSColor(color).usingColorSpace(.sRGB)!
            func lineal(_ valor: Double) -> Double {
                valor <= 0.04045 ? valor / 12.92 : pow((valor + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lineal(rgb.redComponent) + 0.7152 * lineal(rgb.greenComponent)
                + 0.0722 * lineal(rgb.blueComponent)
        }
        for apariencia in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: apariencia)!.performAsCurrentDrawingAppearance {
                for fondo in [Paleta.fondo, Paleta.superficie, Paleta.superficieElevada, Paleta.superficieFlotante] {
                    for texto in [Paleta.textoSecundario, Paleta.avisoTexto, Paleta.errorTexto, Paleta.exitoTexto] {
                        let a = luminancia(fondo), b = luminancia(texto)
                        precondition((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5,
                                     "el texto informativo debe alcanzar contraste AA")
                    }
                }
            }
        }

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
