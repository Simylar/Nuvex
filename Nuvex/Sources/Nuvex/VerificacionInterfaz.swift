#if DEBUG
import AppKit
import SwiftUI

/// Pruebas de componentes con eventos dirigidos exclusivamente a esta ventana.
/// No equivalen a un recorrido humano ni activan permisos de Accesibilidad.
@MainActor
enum VerificacionInterfaz {
    static func ejecutar() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let modelo = VPNModel(muestra: ())
        precondition(modelo.conexionParaReabrir == "norte", "la reapertura debe priorizar el error visible")
        modelo.estados["pendiente"] = .conectando
        precondition(modelo.estado(id: "pendiente") == .conectando,
                     "un intento recién guardado se muestra antes del siguiente sondeo")
        comprobarCancelacionDeRecuperacion(modelo)
        comprobarDesconexionConfirmada()
        let borrador = BorradorBienvenida()
        var cierres = 0
        let vista = BienvenidaView(modelo: modelo, borrador: borrador, cerrar: { cierres += 1 })
        let host = NSHostingView(rootView: vista)
        let ventana = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        ventana.isReleasedWhenClosed = false
        ventana.contentView = host
        ventana.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(ventana.firstResponder is NSTextView, "el servidor debe recibir foco de edición")
        let inicial = (ventana.firstResponder as? NSView).map { $0.convert($0.bounds, to: host) }
        let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: ventana.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48)!
        ventana.sendEvent(tab)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(ventana.firstResponder is NSTextView, "Tab debe alcanzar otro campo editable")
        let siguiente = (ventana.firstResponder as? NSView).map { $0.convert($0.bounds, to: host) }
        precondition(inicial != nil && siguiente != nil && inicial != siguiente,
                     "la navegación debe cambiar de campo, aunque se comparta el editor")
        let retorno = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: ventana.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)!
        _ = ventana.performKeyEquivalent(with: retorno)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(borrador.intento && borrador.paso == .formulario,
                     "Retorno debe validar sin guardar datos incompletos ni conectar")
        precondition(borrador.password.isEmpty && borrador.perfil.server.isEmpty)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: ventana.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        _ = ventana.performKeyEquivalent(with: escape)
        precondition(cierres == 1, "Escape debe ofrecer salir del formulario")
        ventana.orderOut(nil)
        print("Componentes de interfaz: foco editable, navegación, Retorno y Escape comprobados con eventos locales; sin VPN ni Llavero reales")
    }

    private static func comprobarCancelacionDeRecuperacion(_ muestra: VPNModel) {
        let modelo = VPNModel(sinArrancar: (), permiteRecuperacion: { true })
        modelo.esMuestra = true
        modelo.confirmarConfiguracionDeMuestra()
        let perfil = muestra.profiles.first { $0.id == "prepa" }!
        modelo.profiles = [perfil]
        modelo.vpns = muestra.vpns.filter { $0.id == perfil.id }
        modelo.passwordStatuses[perfil.id] = .saved
        modelo.desconexiones[perfil.id] = Date()
        modelo.actualizarDisponibilidadRed(true)
        precondition(modelo.recuperando.contains(perfil.id))
        precondition(modelo.conexionEnCurso(perfil.id),
                     "Terminal debe detectar la espera automática como operación cancelable")
        modelo.cancelarConexion(perfil.id)
        precondition(!modelo.conexionEnCurso(perfil.id) && !modelo.ocupado)
        precondition(modelo.canceladas.contains(perfil.id) && modelo.desconexiones[perfil.id] == nil)
        modelo.actualizarDisponibilidadRed(false)
        modelo.actualizarDisponibilidadRed(true)
        precondition(modelo.recuperando.isEmpty,
                     "recuperar la red no debe reconectar después de una cancelación explícita")
    }

    private static func comprobarDesconexionConfirmada() {
        let modelo = VPNModel(muestra: ())
        let id = "oficina"
        modelo.inicioConexion[id] = Date()
        modelo.estados[id] = .conectando
        modelo.desconexiones[id] = Date()
        let salida = #"[{"id":"oficina","name":"Oficina","connected":false,"pid":0,"ip":"","iface":"","networks":[],"enabled":true,"configured":true,"helperReady":true}]"#
        precondition(!modelo.aplicarDesconexionConfirmada(id, consulta: nil))
        precondition(!modelo.aplicarDesconexionConfirmada(id,
            consulta: .init(salida: salida, error: "", codigo: 1)))
        precondition(!modelo.aplicarDesconexionConfirmada(id,
            consulta: .init(salida: "[]", error: "", codigo: 0)))
        precondition(modelo.vpns.first { $0.id == id }!.connected && modelo.conexionEnCurso(id),
                     "una respuesta fallida no debe declarar cancelado un túnel")
        precondition(modelo.aplicarDesconexionConfirmada(id,
            consulta: .init(salida: salida, error: "", codigo: 0)))
        precondition(modelo.estado(id: id) == .desconectada && !modelo.conexionEnCurso(id))
        precondition(modelo.desconexiones[id] == nil,
                     "una detención confirmada no debe conservar una caída recuperable")
    }
}
#endif
