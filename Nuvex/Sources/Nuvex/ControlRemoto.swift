import AppKit
import NuvexControl

/// Atiende al comando `nuvex` (la Terminal, Claude Code o Codex). Usa los
/// mismos pasos que el panel, aplica los permisos de Ajustes › Automatización
/// y deja constancia en el registro y, si se quiere, en un aviso.
@MainActor
final class ControlRemoto {
    private unowned let modelo: VPNModel
    private var servidor: ServidorSocket?

    init(modelo: VPNModel) {
        self.modelo = modelo
    }

    func iniciar() {
        let servidor = ServidorSocket(ruta: RutaControl.socket(home: Paths.userHome),
                                      registro: { Log.escribir($0) }) { [weak self] peticion, cliente, emisor in
            guard let self else { return .resultado(.sinApp, titulo: "Nuvex se está cerrando") }
            return await self.atender(peticion, cliente, emisor)
        }
        do {
            try servidor.iniciar()
            self.servidor = servidor
        } catch {
            Log.escribir("no se inició el control por Terminal: \(error)")
        }
    }

    func detener() { servidor?.detener() }

    private var preferencias: AjustesApp { Preferencias.shared.ajustes }

    // MARK: Peticiones

    private func atender(_ peticion: Peticion, _ cliente: InfoCliente, _ emisor: Emisor) async -> Mensaje {
        Log.escribir("\(cliente.origen) pidió \(peticion.comando.rawValue)\(peticion.vpn.map { " «\($0)»" } ?? "")")
        await esperarCarga()
        switch peticion.comando {
        case .estado:
            return .resultado(.ok, conexiones: conexiones())
        case .diagnostico:
            return .resultado(.ok, conexiones: conexiones(), comprobaciones: diagnostico())
        case .conectar:
            return await conectar(peticion, cliente, emisor)
        case .desconectar:
            return await desconectar(peticion, cliente)
        case .codigo:
            return codigo(peticion, cliente)
        }
    }

    /// Si `nuvex` acaba de abrir la app, se espera a que lea la configuración.
    private func esperarCarga() async {
        let limite = Date().addingTimeInterval(8)
        while (!modelo.configuracionCargada || (modelo.vpns.isEmpty && !modelo.profiles.isEmpty)) && Date() < limite {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: Conectar

    private func conectar(_ peticion: Peticion, _ cliente: InfoCliente, _ emisor: Emisor) async -> Mensaje {
        let (info, fallo) = resolver(peticion.vpn)
        guard let info else { return fallo! }
        if let rechazo = await permiso(info, cliente, accion: "conectar") { return rechazo }
        guard let vpn = modelo.vpns.first(where: { $0.id == info.id }) else {
            return .resultado(.error, vpn: info.id, titulo: "No se pudo leer el estado de «\(info.nombre)»")
        }
        if vpn.connected {
            return .resultado(.ok, vpn: vpn.id, estado: "conectada", titulo: "«\(vpn.name)» ya estaba conectada",
                              conexiones: conexiones().filter { $0.id == vpn.id })
        }
        if let impedimento = impedimento(vpn) { return impedimento }

        emisor.enviar(.evento("estado", vpn: vpn.id, titulo: "Conectando «\(vpn.name)»…"))
        modelo.conectar(vpn)
        guard peticion.esperar ?? true else {
            return .resultado(.ok, vpn: vpn.id, estado: "conectando", titulo: "Conectando «\(vpn.name)»")
        }

        let limite = Date().addingTimeInterval(TimeInterval(min(max(peticion.limite ?? 180, 10), 600)))
        var avisoCodigo = false, avisoCorreo = false
        let inicio = Date()
        while Date() < limite {
            try? await Task.sleep(for: .milliseconds(300))
            if let solicitud = SolicitudCodigo.abiertas[vpn.id] {
                if !avisoCodigo {
                    avisoCodigo = true
                    let buscando = { if case .buscando = solicitud.estadoCorreo { return true } else { return false } }()
                    emisor.enviar(.evento("codigo_requerido", vpn: vpn.id, titulo: "El servidor pidió un código de verificación",
                                          detalle: buscando
                                            ? "Nuvex lo está buscando en el correo."
                                            : "Pídeselo a la persona y envíalo con: printf '%s' CODIGO | nuvex codigo \"\(vpn.name)\""))
                }
                if case .encontrado(let remitente) = solicitud.estadoCorreo, !avisoCorreo {
                    avisoCorreo = true
                    emisor.enviar(.evento("codigo_correo", vpn: vpn.id, titulo: "Código recibido por correo de \(remitente)"))
                }
            }
            switch modelo.estado(id: vpn.id) {
            case .conectada:
                avisar(cliente, "\(cliente.origen) conectó «\(vpn.name)»")
                return .resultado(.ok, vpn: vpn.id, estado: "conectada", titulo: "«\(vpn.name)» está conectada",
                                  conexiones: conexiones().filter { $0.id == vpn.id })
            case .error(let fallo):
                return .resultado(salida(de: fallo), vpn: vpn.id, estado: "error", titulo: fallo.titulo, detalle: fallo.detalle)
            case .desconectada where Date().timeIntervalSince(inicio) > 3 && !modelo.instalandoAyudante
                                     && SolicitudCodigo.abiertas[vpn.id] == nil:
                return .resultado(.error, vpn: vpn.id, estado: "desconectada", titulo: "La conexión no llegó a iniciarse")
            default:
                continue
            }
        }
        return .resultado(.tiempoAgotado, vpn: vpn.id, estado: "conectando",
                          titulo: "«\(vpn.name)» aún no termina de conectar",
                          detalle: SolicitudCodigo.abiertas[vpn.id] != nil
                            ? "Sigue esperando el código de verificación."
                            : "Nuvex sigue intentándolo. Consulta el estado con: nuvex estado")
    }

    /// Lo que impide conectar sin la persona delante.
    private func impedimento(_ vpn: VPNStatus) -> Mensaje? {
        if !vpn.enabled {
            return .resultado(.uso, vpn: vpn.id, titulo: "«\(vpn.name)» está oculta",
                              detalle: "Actívala en Ajustes de Nuvex › \(vpn.name) › Mostrar en la barra de menús.")
        }
        if !vpn.configured {
            return .resultado(.requierePersona, vpn: vpn.id, titulo: "A «\(vpn.name)» le falta el servidor o el usuario",
                              detalle: "Complétalos en Ajustes de Nuvex.")
        }
        if modelo.passwordStatuses[vpn.id] == .missing {
            return .resultado(.requierePersona, vpn: vpn.id, titulo: "Falta la contraseña de «\(vpn.name)»",
                              detalle: "Guárdala en Ajustes de Nuvex.")
        }
        if !vpn.helperReady {
            return .resultado(.requierePersona, vpn: vpn.id, titulo: "El ayudante de red necesita autorización",
                              detalle: "En la Mac, abre el menú de Nuvex y pulsa Autorizar. macOS pedirá la contraseña de administrador.")
        }
        if SecurityPreferences.needsInitialConfirmation() {
            return .resultado(.requierePersona, vpn: vpn.id, titulo: "Falta la confirmación inicial con Touch ID",
                              detalle: "Conecta una vez desde el menú de Nuvex en la Mac; después los asistentes podrán conectar sin ti.")
        }
        if modelo.chequeo?.llaveroPendiente == true {
            return .resultado(.requierePersona, vpn: vpn.id, titulo: "macOS debe permitir de nuevo el acceso al Llavero",
                              detalle: "En la Mac, abre el menú de Nuvex y pulsa Probar; elige «Permitir siempre».")
        }
        return nil
    }

    private func salida(de fallo: Fallo) -> CodigoSalida {
        if case .ajustes = fallo.accion { return .requierePersona }
        return .error
    }

    // MARK: Desconectar

    private func desconectar(_ peticion: Peticion, _ cliente: InfoCliente) async -> Mensaje {
        let objetivo: [VPNStatus]
        if peticion.todas == true {
            objetivo = modelo.vpns.filter(\.connected)
            for vpn in objetivo {
                guard let info = conexiones().first(where: { $0.id == vpn.id }) else { continue }
                if let rechazo = await permiso(info, cliente, accion: "desconectar") { return rechazo }
            }
        } else {
            let (info, fallo) = resolver(peticion.vpn)
            guard let info else { return fallo! }
            if let rechazo = await permiso(info, cliente, accion: "desconectar") { return rechazo }
            objetivo = modelo.vpns.filter { $0.id == info.id && $0.connected }
            if objetivo.isEmpty {
                return .resultado(.ok, vpn: info.id, estado: "desconectada", titulo: "«\(info.nombre)» ya estaba desconectada")
            }
        }
        guard !objetivo.isEmpty else { return .resultado(.ok, titulo: "No había VPN conectadas") }
        objetivo.forEach { modelo.desconectar($0) }
        let limite = Date().addingTimeInterval(20)
        while Date() < limite, modelo.vpns.contains(where: { vpn in vpn.connected && objetivo.contains { $0.id == vpn.id } }) {
            try? await Task.sleep(for: .milliseconds(300))
        }
        let nombres = objetivo.map { "«\($0.name)»" }.joined(separator: ", ")
        if modelo.vpns.contains(where: { vpn in vpn.connected && objetivo.contains { $0.id == vpn.id } }) {
            return .resultado(.error, titulo: "No se pudo desconectar \(nombres)", detalle: modelo.ultimoError)
        }
        avisar(cliente, "\(cliente.origen) desconectó \(nombres)")
        return .resultado(.ok, estado: "desconectada", titulo: "Desconectada: \(nombres)", conexiones: conexiones())
    }

    // MARK: Código

    private func codigo(_ peticion: Peticion, _ cliente: InfoCliente) -> Mensaje {
        let (info, fallo) = resolver(peticion.vpn)
        guard let info else { return fallo! }
        guard preferencias.politicaAsistentes != .noPermitir, info.permitida else {
            return .resultado(.noPermitido, vpn: info.id, titulo: "Los asistentes no pueden usar «\(info.nombre)»")
        }
        guard let solicitud = SolicitudCodigo.abiertas[info.id] else {
            return .resultado(.error, vpn: info.id, titulo: "«\(info.nombre)» no está esperando ningún código")
        }
        guard let texto = peticion.codigo, solicitud.recibirExterno(texto) else {
            return .resultado(.uso, vpn: info.id, titulo: "Falta el código", detalle: "Envíalo por la entrada estándar: printf '%s' CODIGO | nuvex codigo \"\(info.nombre)\"")
        }
        return .resultado(.ok, vpn: info.id, estado: "conectando", titulo: "Código enviado a «\(info.nombre)»")
    }

    // MARK: Permisos

    private func permiso(_ info: ConexionInfo, _ cliente: InfoCliente, accion: String) async -> Mensaje? {
        switch preferencias.politicaAsistentes {
        case .noPermitir:
            return .resultado(.noPermitido, vpn: info.id, titulo: "Nuvex no permite \(accion) desde la Terminal ni los asistentes",
                              detalle: "Se activa en Ajustes de Nuvex › Automatización.")
        case _ where !info.permitida:
            return .resultado(.noPermitido, vpn: info.id, titulo: "«\(info.nombre)» no está disponible para los asistentes",
                              detalle: "Se cambia en Ajustes de Nuvex › Automatización.")
        case .preguntar:
            NSApp.activate(ignoringOtherApps: true)
            let alerta = NSAlert()
            alerta.messageText = "\(cliente.origen) quiere \(accion) «\(info.nombre)»"
            alerta.informativeText = "La petición llegó desde la Terminal. Puedes cambiar este permiso en Ajustes de Nuvex › Automatización."
            alerta.addButton(withTitle: accion.prefix(1).uppercased() + accion.dropFirst())
            alerta.addButton(withTitle: "Rechazar")
            guard alerta.runModal() == .alertFirstButtonReturn else {
                return .resultado(.noPermitido, vpn: info.id, titulo: "Se rechazó en la Mac")
            }
            return nil
        case .permitir:
            return nil
        }
    }

    private func avisar(_ cliente: InfoCliente, _ titulo: String) {
        Log.escribir(titulo)
        guard preferencias.avisarAccionesAsistentes else { return }
        VPNNotifications.shared.accionAsistente(titulo: titulo, cuerpo: "Lo pidió desde la Terminal (proceso \(cliente.pid)).")
    }

    // MARK: Estado

    private func resolver(_ consulta: String?) -> (ConexionInfo?, Mensaje?) {
        let lista = conexiones()
        guard let consulta, !consulta.trimmingCharacters(in: .whitespaces).isEmpty else {
            return (nil, .resultado(.uso, titulo: "Indica qué conexión", detalle: "Conexiones: " + nombres(lista)))
        }
        switch Busqueda.buscar(consulta, en: lista) {
        case .una(let info): return (info, nil)
        case .ninguna:
            return (nil, .resultado(.uso, titulo: "No hay ninguna conexión llamada «\(consulta)»",
                                    detalle: "Conexiones: " + nombres(lista), conexiones: lista))
        case .varias(let opciones):
            return (nil, .resultado(.uso, titulo: "«\(consulta)» coincide con varias conexiones",
                                    detalle: "Elige una: " + nombres(opciones), conexiones: opciones))
        }
    }

    private func nombres(_ lista: [ConexionInfo]) -> String {
        lista.isEmpty ? "ninguna configurada" : lista.map { "«\($0.nombre)»" }.joined(separator: ", ")
    }

    func conexiones() -> [ConexionInfo] {
        modelo.vpns.filter(\.enabled).map { vpn in
            let estado: String
            var error: String?
            if SolicitudCodigo.abiertas[vpn.id] != nil {
                estado = "esperando_codigo"
            } else {
                switch modelo.estado(vpn) {
                case .conectada: estado = "conectada"
                case .conectando: estado = "conectando"
                case .error(let fallo): estado = "error"; error = fallo.titulo
                case .desconectada: estado = modelo.desconexiones[vpn.id] != nil ? "caida" : "desconectada"
                }
            }
            return ConexionInfo(id: vpn.id, nombre: vpn.name, estado: estado,
                                ip: vpn.ip.isEmpty ? nil : vpn.ip, desde: vpn.connected ? vpn.inicio : nil, error: error,
                                permitida: preferencias.politicaAsistentes != .noPermitir
                                    && !preferencias.bloqueadasParaAsistentes.contains(vpn.id),
                                codigoPorCorreo: preferencias.correo[vpn.id] != nil)
        }
    }

    private func diagnostico() -> [Comprobacion] {
        var lista = [
            Comprobacion(nombre: "Nuvex", ok: true, detalle: "Versión \(InfoVersion.actual.descripcion)"),
            Comprobacion(nombre: "Ayudante de red", ok: modelo.ayudanteListo == true,
                         detalle: modelo.ayudanteListo == true ? "Al día" : "Necesita autorización en la Mac"),
            Comprobacion(nombre: "Permiso para asistentes", ok: preferencias.politicaAsistentes == .permitir,
                         detalle: ["noPermitir": "No permitido", "preguntar": "Pide confirmación en la Mac",
                                   "permitir": "Conectan sin preguntar"][preferencias.politicaAsistentes.rawValue] ?? ""),
            Comprobacion(nombre: "Confirmación inicial con Touch ID", ok: !SecurityPreferences.needsInitialConfirmation(),
                         detalle: SecurityPreferences.needsInitialConfirmation() ? "Pendiente: conecta una vez desde la Mac" : "Hecha"),
            Comprobacion(nombre: "Firma de la app", ok: modelo.chequeo?.firmaEstable ?? false,
                         detalle: modelo.chequeo?.firmaEstable == true ? "Estable" : "Ad hoc: el Llavero puede preguntar tras cada actualización"),
            Comprobacion(nombre: "Acceso al Llavero", ok: modelo.chequeo?.llaveroPendiente != true,
                         detalle: modelo.chequeo?.llaveroPendiente == true ? "Pendiente de permitir en la Mac" : "Permitido"),
        ]
        for vpn in modelo.vpns where vpn.enabled {
            var problemas: [String] = []
            if !vpn.configured { problemas.append("falta servidor o usuario") }
            if modelo.passwordStatuses[vpn.id] == .missing { problemas.append("falta la contraseña") }
            if preferencias.bloqueadasParaAsistentes.contains(vpn.id) { problemas.append("no disponible para asistentes") }
            let correo = preferencias.correo[vpn.id] != nil ? "código por correo" : "código a mano si lo pide"
            lista.append(Comprobacion(nombre: "«\(vpn.name)»", ok: problemas.isEmpty,
                                      detalle: problemas.isEmpty ? "Lista · \(correo)" : problemas.joined(separator: ", ")))
        }
        return lista
    }
}
