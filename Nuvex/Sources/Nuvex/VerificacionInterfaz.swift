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
        comprobarUsoCorreoEnModelo()
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
        var origenComprobado = false
        Task {
            await comprobarOrigenCodigo()
            origenComprobado = true
        }
        let limite = Date().addingTimeInterval(5)
        while !origenComprobado && Date() < limite {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(origenComprobado, "la comprobación del origen del código debe terminar")
        print("Componentes de interfaz: foco editable, navegación, Retorno y Escape comprobados con eventos locales; sin VPN ni Llavero reales")
    }

    private static func comprobarOrigenCodigo() async {
        let mensaje = MensajeCodigoGmail(id: "abc123", sesion: UUID())
        let recibido = CodigoRecibido(codigo: "123456", remitente: "muestra@example.invalid", mensaje: mensaje)
        for modo in 0...3 {
            let entrega = await SolicitudCodigo.obtenerDeMuestra(recibido) { solicitud in
                solicitud.detenerEnvio()
                switch modo {
                case 0: solicitud.enviar()
                case 1: solicitud.codigo = "654321"; solicitud.enviar()
                case 2: precondition(solicitud.recibirExterno("123456"))
                default: solicitud.cancelar()
                }
            }
            if modo == 0 { precondition(entrega?.mensaje == mensaje && entrega?.codigo == "123456") }
            else if modo < 3 { precondition(entrega != nil && entrega?.mensaje == nil) }
            else { precondition(entrega == nil) }
        }
    }

    private static func comprobarUsoCorreoEnModelo() {
        let id = "correo-muestra"
        let mensaje = MensajeCodigoGmail(id: "abc123", sesion: UUID())
        func estado(_ conectada: Bool) -> VPNStatus {
            VPNStatus(id: id, name: "Muestra", connected: conectada, pid: 0, ip: "", iface: "",
                      networks: [], enabled: true, configured: true, helperReady: true)
        }
        for seAdelantaList in [false, true] {
            for desaparece in [false, true] {
                let modelo = VPNModel(sinArrancar: ())
                modelo.esMuestra = true
                let inicio = Date()
                modelo.inicioConexion[id] = inicio
                modelo.estados[id] = .conectando
                let uso = modelo.prepararUsoCorreo(para: id) { _ in
                    preconditionFailure("una caída o un perfil ausente no autoriza trasladar el mensaje anterior")
                }
                uso.registrarEntrega(mensaje)
                if seAdelantaList {
                    modelo.aplicarEstadosConsultados([estado(true)], consultasCorreo: [:])
                    precondition(modelo.inicioConexion[id] == nil)
                }
                modelo.finalizarIntentoConexion(estado(false), inicioIntento: inicio, resultado: .success(()), usoCorreo: uso)
                let consulta = uso.consultaPendiente!
                modelo.aplicarEstadosConsultados(desaparece ? [] : [estado(false)], consultasCorreo: [id: consulta])
                precondition(uso.consultaPendiente == nil, "la caída debe invalidar incluso la rama donde list llegó primero")
                modelo.aplicarEstadosConsultados([estado(true)], consultasCorreo: [id: consulta])
            }
        }

        let modelo = VPNModel(sinArrancar: ())
        modelo.esMuestra = true
        var trasladados = 0
        let anterior = modelo.prepararUsoCorreo(para: id) { _ in preconditionFailure("intento reemplazado") }
        anterior.registrarEntrega(mensaje)
        anterior.confirmarProceso()
        let consultaAnterior = anterior.consultaPendiente!
        let actual = modelo.prepararUsoCorreo(para: id) { _ in trasladados += 1 }
        actual.registrarEntrega(mensaje)
        actual.confirmarProceso()
        modelo.estados[id] = .conectando
        modelo.aplicarEstadosConsultados([estado(false)], consultasCorreo: [id: consultaAnterior])
        precondition(actual.consultaPendiente != nil, "una respuesta negativa de otro intento no cancela el actual")
        let consultaActual = actual.consultaPendiente!
        modelo.aplicarEstadosConsultados([estado(true)], consultasCorreo: [id: consultaActual])
        modelo.aplicarEstadosConsultados([estado(true)], consultasCorreo: [id: consultaActual])
        precondition(trasladados == 1)

        let cancelado = modelo.prepararUsoCorreo(para: id) { _ in preconditionFailure("intento cancelado") }
        cancelado.registrarEntrega(mensaje)
        cancelado.confirmarProceso()
        let consultaCancelada = cancelado.consultaPendiente!
        modelo.inicioConexion[id] = Date()
        modelo.estados[id] = .conectando
        let acumulado = Acumulador()
        IntentosConexion.preparar(id)
        IntentosConexion.registrar(id, proceso: nil, acumulado: acumulado)
        modelo.cancelarConexion(id)
        IntentosConexion.retirar(id, acumulado: acumulado)
        modelo.aplicarEstadosConsultados([estado(true)], consultasCorreo: [id: consultaCancelada])
        precondition(cancelado.consultaPendiente == nil)
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
