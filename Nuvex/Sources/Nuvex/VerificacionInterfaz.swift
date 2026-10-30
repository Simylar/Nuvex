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
        comprobarCaidasYReintentos()
        comprobarReconciliacionLlavero()
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

    private static func comprobarCaidasYReintentos() {
        let perfil = VPNProfile(id: "recuperacion-muestra", name: "Muestra", server: "vpn.example.invalid:443",
            username: "persona", trust: "system", realm: "", manageRoutes: true, manageDNS: true, enabled: true)
        func estado(_ conectada: Bool) -> VPNStatus {
            VPNStatus(id: perfil.id, name: perfil.name, connected: conectada, pid: 0, ip: "", iface: "",
                      networks: [], enabled: true, configured: true, helperReady: true)
        }
        func preparar(_ modelo: VPNModel) {
            modelo.esMuestra = true
            modelo.confirmarConfiguracionDeMuestra()
            modelo.profiles = [perfil]
            modelo.passwordStatuses[perfil.id] = .saved
            modelo.vpns = [estado(true)]
            modelo.estados[perfil.id] = .conectada
            modelo.actualizarDisponibilidadRed(true)
        }
        func consultar(_ modelo: VPNModel) {
            let lista = [estado(false)]
            modelo.procesarTransiciones(lista)
            modelo.vpns = lista
            modelo.aplicarEstadosConsultados(lista, consultasCorreo: [:])
        }

        var avisosManuales = 0
        let manual = VPNModel(sinArrancar: (), permiteRecuperacion: { true }, notificarDesconexion: { _, _ in avisosManuales += 1 })
        preparar(manual)
        consultar(manual) // Primera ausencia: todavía no es una caída confirmada.
        manual.conectar(estado(false))
        precondition(manual.conexionEnCurso(perfil.id))
        consultar(manual)
        consultar(manual)
        precondition(avisosManuales == 0 && manual.desconexiones.isEmpty)
        manual.inicioConexion.removeValue(forKey: perfil.id)
        manual.estados[perfil.id] = .error(.interpretar("fallo de prueba"))
        manual.actualizarDisponibilidadRed(true)
        consultar(manual)
        precondition(manual.recuperando.isEmpty && manual.desconexiones.isEmpty && avisosManuales == 0,
                     "un fallo manual no reactiva el contador de una caída anterior")

        let descartada = VPNModel(sinArrancar: (), permiteRecuperacion: { false },
            notificarDesconexion: { _, _ in preconditionFailure("una caída descartada no reaparece") })
        preparar(descartada)
        consultar(descartada)
        descartada.descartarAviso(perfil.id)
        consultar(descartada)
        precondition(descartada.desconexiones.isEmpty)

        for impedimento in ["red", "consulta", "guardado", "preferencia"] {
            var activada = true
            var avisos = 0
            let modelo = VPNModel(sinArrancar: (), permiteRecuperacion: { activada },
                notificarDesconexion: { _, _ in avisos += 1 })
            preparar(modelo)
            consultar(modelo)
            consultar(modelo)
            let caida = modelo.desconexiones[perfil.id]!
            precondition(modelo.recuperando.contains(perfil.id) && avisos == 0)
            switch impedimento {
            case "red": modelo.actualizarDisponibilidadRed(false)
            case "consulta": modelo.errorConsulta = "Fallo simulado"
            case "guardado": modelo.guardandoConfiguracion = true
            default: activada = false
            }
            modelo.ejecutarRecuperacionProgramada(estado(false), caida: caida)
            consultar(modelo)
            precondition(modelo.recuperando.isEmpty && modelo.desconexiones[perfil.id] == caida && avisos == 1,
                         "abortar la espera conserva la caída y emite un solo aviso")
            activada = true
            modelo.errorConsulta = nil
            modelo.guardandoConfiguracion = false
            modelo.actualizarDisponibilidadRed(true)
            consultar(modelo)
            precondition(modelo.recuperando.contains(perfil.id), "al desaparecer el impedimento puede programarse la recuperación")
            modelo.ejecutarRecuperacionProgramada(estado(false), caida: caida)
            precondition(modelo.inicioConexion[perfil.id] != nil && modelo.desconexiones.isEmpty && avisos == 1,
                         "la espera abortada no debe haber consumido el intento")
        }
    }

    private static func comprobarReconciliacionLlavero() {
        let dominio = "NuvexVerificacionLlavero.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: dominio)!
        defer { defaults.removePersistentDomain(forName: dominio) }
        defaults.set(true, forKey: ChequeoActualizacion.claveLlaveroPendiente)
        let migracion = Migraciones.Resultado(versionNueva: false, anterior: nil, copia: nil)
        let chequeo = ChequeoActualizacion(migracion: migracion, defaults: defaults)
        let perfiles = ["uno", "dos"].map {
            VPNProfile(id: $0, name: "Muestra", server: "vpn.example.invalid:443", username: "persona",
                trust: "system", realm: "", manageRoutes: true, manageDNS: true, enabled: true)
        }
        chequeo.confirmarAccesosLlavero(perfiles: [], accesos: [:], configuracionCargada: false)
        precondition(chequeo.llaveroPendiente, "una carga pendiente no equivale a no tener contraseñas")
        chequeo.confirmarAccesosLlavero(perfiles: perfiles,
            accesos: ["uno": .disponible], configuracionCargada: true)
        precondition(chequeo.llaveroPendiente, "comprobar solo una entrada no acredita todas")
        chequeo.confirmarAccesosLlavero(perfiles: perfiles,
            accesos: ["uno": .disponible, "dos": .requiereInteraccion], configuracionCargada: true)
        precondition(chequeo.llaveroPendiente)
        chequeo.confirmarAccesosLlavero(perfiles: perfiles,
            accesos: ["uno": .disponible, "dos": .disponible], configuracionCargada: true)
        precondition(!chequeo.llaveroPendiente && !defaults.bool(forKey: ChequeoActualizacion.claveLlaveroPendiente))
        let recargado = ChequeoActualizacion(migracion: migracion, defaults: defaults)
        precondition(!recargado.llaveroPendiente, "el diagnóstico no debe reponer el aviso ya resuelto")
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
