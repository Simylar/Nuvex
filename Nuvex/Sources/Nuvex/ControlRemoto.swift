import AppKit
import NuvexControl

/// Atiende al comando `nuvex` (la Terminal, Claude Code o Codex). Usa los
/// mismos pasos que el panel, aplica los permisos de Ajustes › Automatización
/// y deja constancia en el registro y, si se quiere, en un aviso.
@MainActor
final class ControlRemoto {
    private unowned let modelo: VPNModel
    private var servidor: ServidorSocket?
    private var operaciones = CoordinadorOperacionesRemotas()
    private(set) var disponible = false

    init(modelo: VPNModel) {
        self.modelo = modelo
    }

    func iniciar() {
        let servidor = ServidorSocket(ruta: RutaControl.socket(home: Paths.userHome),
                                      registro: { Log.escribir($0) },
                                      autorizarCliente: Self.esClienteOficial) { [weak self] peticion, cliente, emisor in
            guard let self else { return .resultado(.sinApp, titulo: "Nuvex se está cerrando") }
            return await self.atender(peticion, cliente, emisor)
        }
        do {
            try servidor.iniciar()
            self.servidor = servidor
            disponible = true
        } catch {
            disponible = false
            Log.escribir("no se inició el control por Terminal: \(error)")
        }
    }

    func detener() {
        servidor?.detener()
        servidor = nil
        disponible = false
    }

    /// El socket normalmente sobrevive al reposo. Si falló al arrancar o dejó
    /// de estar disponible, el despertar ofrece un punto seguro para abrirlo
    /// de nuevo sin crear un segundo servidor.
    func reanudarSiHaceFalta() {
        guard !disponible else { return }
        iniciar()
    }

    private var preferencias: AjustesApp { Preferencias.shared.ajustes }

    nonisolated private static func esClienteOficial(_ cliente: InfoCliente) -> Bool {
        guard !cliente.ejecutable.isEmpty,
              let incluido = Bundle.main.resourceURL?.appendingPathComponent("bin/nuvex") else { return false }
        let ejecutable = URL(fileURLWithPath: cliente.ejecutable).resolvingSymlinksInPath().standardizedFileURL.path
        let esperado = incluido.resolvingSymlinksInPath().standardizedFileURL.path
        return ejecutable == esperado
    }

    // MARK: Peticiones

    private func atender(_ peticion: Peticion, _ cliente: InfoCliente, _ emisor: Emisor) async -> Mensaje {
        let operacion = peticion.operacion.map {
            String($0.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(12))
        }.flatMap { $0.isEmpty ? nil : $0 } ?? "sin-id"
        Log.escribir("control op=\(operacion) origen=\(cliente.origen) comando=\(peticion.comando.rawValue) vpn=\(peticion.vpn == nil ? "no" : "si")")
        await esperarCarga()
        switch peticion.comando {
        case .estado:
            return .resultado(.ok, conexiones: conexiones())
        case .diagnostico:
            let comprobaciones = await diagnostico(profundo: peticion.profundo == true)
            let salida = CodigoSalida.paraDiagnostico(comprobaciones)
            return .resultado(salida, motivo: salida == .ok ? nil : .diagnosticoIncompleto,
                              conexiones: conexiones(), comprobaciones: comprobaciones)
        case .conectar:
            return await conectar(peticion, cliente, emisor)
        case .desconectar:
            return await desconectar(peticion, cliente, emisor)
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
        if let rechazo = await permiso(info, cliente, emisor, accion: "conectar") { return rechazo }
        guard let vpn = modelo.vpns.first(where: { $0.id == info.id }) else {
            return .resultado(.error, vpn: info.id, motivo: .estadoNoConfirmado,
                              titulo: "No se pudo leer el estado de «\(info.nombre)»")
        }
        if vpn.connected {
            return .resultado(.ok, vpn: vpn.id, estado: .conectada, motivo: .yaConectada,
                              titulo: "«\(vpn.name)» ya estaba conectada",
                              conexiones: conexiones().filter { $0.id == vpn.id })
        }
        if let impedimento = impedimento(vpn) { return impedimento }
        let ids = Set([vpn.id])
        guard operaciones.reservar(ids) else {
            return .resultado(.error, vpn: vpn.id, estado: .conectando, motivo: .operacionEnCurso,
                              titulo: "Ya hay una operación en curso para «\(vpn.name)»")
        }

        emisor.enviar(.evento(.estado, vpn: vpn.id, titulo: "Conectando «\(vpn.name)»…"))
        guard emisor.clienteConectado() else {
            operaciones.liberar(ids)
            return .resultado(.tiempoAgotado, vpn: vpn.id, motivo: .tiempoAgotado,
                              titulo: "La petición terminó antes de iniciar la conexión")
        }
        modelo.conectar(vpn)
        guard modelo.conexionEnCurso(vpn.id) else {
            operaciones.liberar(ids)
            return .resultado(.error, vpn: vpn.id, estado: .desconectada, motivo: .estadoNoConfirmado,
                              titulo: "La conexión no llegó a iniciarse")
        }
        guard peticion.esperar ?? true else {
            liberarCuandoTermine(ids, limite: 600)
            return .resultado(.ok, vpn: vpn.id, estado: .conectando, motivo: .conectando,
                              titulo: "Conectando «\(vpn.name)»")
        }
        var liberarAlSalir = true
        defer { if liberarAlSalir { operaciones.liberar(ids) } }

        let limite = Date().addingTimeInterval(TimeInterval(min(max(peticion.limite ?? 180, 10), 600)))
        var avisoCodigo = false, avisoCorreo = false
        while Date() < limite {
            try? await Task.sleep(for: .milliseconds(300))
            if let solicitud = SolicitudCodigo.abiertas[vpn.id] {
                if !avisoCodigo {
                    avisoCodigo = true
                    let buscando = { if case .buscando = solicitud.estadoCorreo { return true } else { return false } }()
                    emisor.enviar(.evento(.codigoRequerido, vpn: vpn.id, titulo: "El servidor pidió un código de verificación",
                                          detalle: buscando
                                            ? "Nuvex lo está buscando en el correo."
                                            : "Pídeselo a la persona y envíalo con: printf '%s' CODIGO | nuvex codigo \"\(vpn.name)\""))
                }
                if case .encontrado(let remitente) = solicitud.estadoCorreo, !avisoCorreo {
                    avisoCorreo = true
                    emisor.enviar(.evento(.codigoCorreo, vpn: vpn.id, titulo: "Código recibido por correo de \(remitente)"))
                }
            }
            switch modelo.estado(id: vpn.id) {
            case .conectada:
                avisar(cliente, accion: "conectar", titulo: "\(cliente.origen) conectó «\(vpn.name)»")
                return .resultado(.ok, vpn: vpn.id, estado: .conectada, motivo: .conectada,
                                  titulo: "«\(vpn.name)» está conectada",
                                  conexiones: conexiones().filter { $0.id == vpn.id })
            case .error(let fallo):
                return .resultado(salida(de: fallo), vpn: vpn.id, estado: .error, motivo: motivo(de: fallo),
                                  titulo: fallo.titulo, detalle: fallo.detalle)
            case .desconectada where modelo.canceladas.contains(vpn.id):
                return .resultado(.error, vpn: vpn.id, estado: .desconectada, motivo: .cancelada,
                                  titulo: "Se canceló la conexión desde la Mac")
            default:
                continue
            }
        }
        // El límite solo deja de esperar al cliente; el intento continúa en
        // Nuvex, así que la conexión sigue reservada hasta que realmente acabe.
        liberarAlSalir = false
        liberarCuandoTermine(ids, limite: 600)
        return .resultado(.tiempoAgotado, vpn: vpn.id, estado: .conectando, motivo: .tiempoAgotado,
                          titulo: "«\(vpn.name)» aún no termina de conectar",
                          detalle: SolicitudCodigo.abiertas[vpn.id] != nil
                            ? "Sigue esperando el código de verificación."
                            : "Nuvex sigue intentándolo. Consulta el estado con: nuvex estado")
    }

    /// Lo que impide conectar sin la persona delante.
    private func impedimento(_ vpn: VPNStatus) -> Mensaje? {
        if !vpn.enabled {
            return .resultado(.uso, vpn: vpn.id, motivo: .configuracionIncompleta, titulo: "«\(vpn.name)» está oculta",
                              detalle: "Actívala en Ajustes de Nuvex › \(vpn.name) › Mostrar en la barra de menús.")
        }
        if !vpn.configured {
            return .resultado(.requierePersona, vpn: vpn.id, motivo: .configuracionIncompleta,
                              titulo: "A «\(vpn.name)» le falta el servidor o el usuario",
                              detalle: "Complétalos en Ajustes de Nuvex.")
        }
        if modelo.passwordStatuses[vpn.id] == .missing {
            return .resultado(.requierePersona, vpn: vpn.id, motivo: .llaveroNoDisponible,
                              titulo: "Falta la contraseña de «\(vpn.name)»",
                              detalle: "Guárdala en Ajustes de Nuvex.")
        }
        if !vpn.helperReady {
            return .resultado(.requierePersona, vpn: vpn.id, motivo: .ayudanteNoDisponible,
                              titulo: "El ayudante de red necesita autorización",
                              detalle: "En la Mac, abre el menú de Nuvex y pulsa Autorizar. macOS pedirá la contraseña de administrador.")
        }
        if SecurityPreferences.needsInitialConfirmation() {
            return .resultado(.requierePersona, vpn: vpn.id, motivo: .confirmacionRequerida,
                              titulo: "Falta la confirmación inicial con Touch ID",
                              detalle: "Conecta una vez desde el menú de Nuvex en la Mac; después los asistentes podrán conectar sin ti.")
        }
        if modelo.chequeo?.llaveroPendiente == true {
            return .resultado(.requierePersona, vpn: vpn.id, motivo: .llaveroNoDisponible,
                              titulo: "macOS debe permitir de nuevo el acceso al Llavero",
                              detalle: "En la Mac, abre el menú de Nuvex y pulsa Probar; elige «Permitir siempre».")
        }
        return nil
    }

    private func salida(de fallo: Fallo) -> CodigoSalida {
        if case .ajustes = fallo.accion { return .requierePersona }
        return .error
    }

    private func motivo(de fallo: Fallo) -> MotivoResultado {
        switch fallo.codigo {
        case .servidorNoResponde: return .servidorNoResponde
        case .servidorNoEncontrado: return .servidorNoEncontrado
        case .autenticacion: return .autenticacionRechazada
        case .certificado: return .certificadoNoVerificado
        case .tunelRechazado: return .tunelRechazado
        case .tunelActivo: return .tunelActivo
        case .ayudante: return .ayudanteNoDisponible
        case .cancelada: return .cancelada
        case .agotado: return .tiempoAgotado
        default: return .errorConexion
        }
    }

    // MARK: Desconectar

    private func desconectar(_ peticion: Peticion, _ cliente: InfoCliente, _ emisor: Emisor) async -> Mensaje {
        let objetivo: [VPNStatus]
        if peticion.todas == true {
            objetivo = modelo.vpns.filter { $0.connected || modelo.conexionEnCurso($0.id) }
            for vpn in objetivo {
                guard let info = conexiones().first(where: { $0.id == vpn.id }) else { continue }
                if let rechazo = await permiso(info, cliente, emisor, accion: "desconectar") { return rechazo }
            }
        } else {
            let (info, fallo) = resolver(peticion.vpn)
            guard let info else { return fallo! }
            if let rechazo = await permiso(info, cliente, emisor, accion: "desconectar") { return rechazo }
            objetivo = modelo.vpns.filter { $0.id == info.id && ($0.connected || modelo.conexionEnCurso($0.id)) }
            if objetivo.isEmpty {
                return .resultado(.ok, vpn: info.id, estado: .desconectada, motivo: .desconectada,
                                  titulo: "«\(info.nombre)» ya estaba desconectada")
            }
        }
        guard !objetivo.isEmpty else { return .resultado(.ok, titulo: "No había VPN conectadas") }
        let conectando = Set(objetivo.filter { modelo.conexionEnCurso($0.id) }.map(\.id))
        let idsAReservar = Set(objetivo.filter { !conectando.contains($0.id) }.map(\.id))
        if !idsAReservar.isEmpty, !operaciones.reservar(idsAReservar) {
            return .resultado(.error, motivo: .operacionEnCurso,
                              titulo: "Ya hay una operación en curso para una de las conexiones")
        }
        defer { operaciones.liberar(idsAReservar) }
        emisor.enviar(.evento(.estado, titulo: "Desconectando conexiones…"))
        guard emisor.clienteConectado() else {
            return .resultado(.tiempoAgotado, motivo: .tiempoAgotado,
                              titulo: "La petición terminó antes de desconectar")
        }
        objetivo.forEach { vpn in
            if conectando.contains(vpn.id) { modelo.cancelarConexion(vpn.id) }
            else { modelo.desconectar(vpn) }
        }
        let limite = Date().addingTimeInterval(20)
        let ids = Set(objetivo.map(\.id))
        while Date() < limite, ids.contains(where: { id in
            modelo.vpns.first(where: { $0.id == id })?.connected == true || modelo.conexionEnCurso(id)
        }) {
            try? await Task.sleep(for: .milliseconds(300))
        }
        let nombres = objetivo.map { "«\($0.name)»" }.joined(separator: ", ")
        if ids.contains(where: modelo.conexionEnCurso) {
            return .resultado(.error, motivo: .errorConexion,
                              titulo: "No se pudo desconectar \(nombres)", detalle: modelo.ultimoError)
        }
        // `vpns` puede seguir mostrando una consulta anterior. Una respuesta
        // nueva del motor es necesaria antes de informar éxito al cliente.
        let consulta = await Task.detached(priority: .userInitiated) {
            try? VPNModel.ejecutar(args: ["list"])
        }.value
        guard let consulta,
              EstadoMotor.confirmaDesconexion(ids, codigo: consulta.codigo, salida: consulta.salida) else {
            return .resultado(.error, motivo: .estadoNoConfirmado,
                              titulo: "No se pudo confirmar la desconexión de \(nombres)",
                              detalle: "El motor no confirmó que todos los túneles estén detenidos. Consulta el estado antes de volver a intentarlo.")
        }
        avisar(cliente, accion: "desconectar", titulo: "\(cliente.origen) desconectó \(nombres)")
        return .resultado(.ok, estado: .desconectada, motivo: conectando.isEmpty ? .desconectada : .cancelada,
                          titulo: conectando.isEmpty ? "Desconectada: \(nombres)" : "Cancelada o desconectada: \(nombres)",
                          conexiones: conexiones())
    }

    // MARK: Código

    private func codigo(_ peticion: Peticion, _ cliente: InfoCliente) -> Mensaje {
        let (info, fallo) = resolver(peticion.vpn)
        guard let info else { return fallo! }
        guard preferencias.politicaAsistentes != .noPermitir, info.permitida else {
            return .resultado(.noPermitido, vpn: info.id, motivo: .noPermitido,
                              titulo: "Los asistentes no pueden usar «\(info.nombre)»")
        }
        guard let solicitud = SolicitudCodigo.abiertas[info.id] else {
            return .resultado(.error, vpn: info.id, motivo: .codigoNoEsperado,
                              titulo: "«\(info.nombre)» no está esperando ningún código")
        }
        guard let texto = peticion.codigo, solicitud.recibirExterno(texto) else {
            return .resultado(.uso, vpn: info.id, motivo: .codigoInvalido, titulo: "Falta el código",
                              detalle: "Envía un código imprimible de 4 a 64 caracteres por la entrada estándar: printf '%s' CODIGO | nuvex codigo \"\(info.nombre)\"")
        }
        return .resultado(.ok, vpn: info.id, estado: .conectando, motivo: .conectando,
                          titulo: "Código enviado a «\(info.nombre)»")
    }

    // MARK: Permisos

    private func permiso(_ info: ConexionInfo, _ cliente: InfoCliente, _ emisor: Emisor, accion: String) async -> Mensaje? {
        switch preferencias.decisionParaAsistente(conexion: info.id) {
        case .rechazarGlobal:
            return .resultado(.noPermitido, vpn: info.id, motivo: .noPermitido,
                              titulo: "Nuvex no permite \(accion) desde la Terminal ni los asistentes",
                              detalle: "Se activa en Ajustes de Nuvex › Automatización.")
        case .rechazarConexion:
            return .resultado(.noPermitido, vpn: info.id, motivo: .noPermitido,
                              titulo: "«\(info.nombre)» no está disponible para los asistentes",
                              detalle: "Se cambia en Ajustes de Nuvex › Automatización.")
        case .confirmar:
            emisor.enviar(.evento(.estado, vpn: info.id, titulo: "Esperando confirmación en la Mac"))
            guard emisor.clienteConectado() else {
                return .resultado(.tiempoAgotado, vpn: info.id, motivo: .tiempoAgotado,
                                  titulo: "La petición terminó antes de la confirmación")
            }
            NSApp.activate(ignoringOtherApps: true)
            let alerta = NSAlert()
            alerta.messageText = "\(cliente.origen) quiere \(accion) «\(info.nombre)»"
            alerta.informativeText = "La petición llegó desde la Terminal. Puedes cambiar este permiso en Ajustes de Nuvex › Automatización."
            alerta.addButton(withTitle: accion.prefix(1).uppercased() + accion.dropFirst())
            alerta.addButton(withTitle: "Rechazar")
            guard alerta.runModal() == .alertFirstButtonReturn else {
                return .resultado(.noPermitido, vpn: info.id, motivo: .noPermitido, titulo: "Se rechazó en la Mac")
            }
            emisor.enviar(.evento(.estado, vpn: info.id, titulo: "Confirmado en la Mac"))
            guard emisor.clienteConectado() else {
                return .resultado(.tiempoAgotado, vpn: info.id, motivo: .tiempoAgotado,
                                  titulo: "La petición terminó antes de la confirmación")
            }
            return nil
        case .permitir:
            return nil
        }
    }

    /// `--no-esperar` devuelve el control al cliente, pero conserva la reserva
    /// hasta que la conexión deje de estar arrancando o expire el límite.
    private func liberarCuandoTermine(_ ids: Set<String>, limite: TimeInterval) {
        Task { [weak self] in
            guard let self else { return }
            let fin = Date().addingTimeInterval(limite)
            while Date() < fin, ids.contains(where: { id in
                self.modelo.conexionEnCurso(id) || SolicitudCodigo.abiertas[id] != nil
            }) {
                try? await Task.sleep(for: .milliseconds(300))
            }
            self.operaciones.liberar(ids)
        }
    }

    private func avisar(_ cliente: InfoCliente, accion: String, titulo: String) {
        // El aviso visible puede usar el nombre elegido por la persona; el
        // registro solo conserva metadatos operativos y no nombres de clientes.
        Log.escribir("control origen=\(cliente.origen) estado=accion_completada accion=\(accion)")
        guard preferencias.avisarAccionesAsistentes else { return }
        VPNNotifications.shared.accionAsistente(titulo: titulo, cuerpo: "Lo pidió desde la Terminal (proceso \(cliente.pid)).")
    }

    // MARK: Estado

    private func resolver(_ consulta: String?) -> (ConexionInfo?, Mensaje?) {
        let lista = conexiones()
        guard let consulta, !consulta.trimmingCharacters(in: .whitespaces).isEmpty else {
            return (nil, .resultado(.uso, motivo: .noEncontrada,
                                    titulo: "Indica qué conexión", detalle: "Conexiones: " + nombres(lista)))
        }
        switch Busqueda.buscar(consulta, en: lista) {
        case .una(let info): return (info, nil)
        case .ninguna:
            return (nil, .resultado(.uso, motivo: .noEncontrada, titulo: "No hay ninguna conexión llamada «\(consulta)»",
                                    detalle: "Conexiones: " + nombres(lista), conexiones: lista))
        case .varias(let opciones):
            return (nil, .resultado(.uso, motivo: .ambigua, titulo: "«\(consulta)» coincide con varias conexiones",
                                    detalle: "Elige una: " + nombres(opciones), conexiones: opciones))
        }
    }

    private func nombres(_ lista: [ConexionInfo]) -> String {
        lista.isEmpty ? "ninguna configurada" : lista.map { "«\($0.nombre)»" }.joined(separator: ", ")
    }

    func conexiones() -> [ConexionInfo] {
        modelo.vpns.filter(\.enabled).map { vpn in
            let estado: EstadoConexionRemota
            var error: String?
            if SolicitudCodigo.abiertas[vpn.id] != nil {
                estado = .esperandoCodigo
            } else {
                switch modelo.estado(vpn) {
                case .conectada: estado = .conectada
                case .conectando: estado = .conectando
                case .error(let fallo): estado = .error; error = fallo.titulo
                case .desconectada: estado = modelo.desconexiones[vpn.id] != nil ? .caida : .desconectada
                }
            }
            return ConexionInfo(id: vpn.id, nombre: vpn.name, estado: estado,
                                ip: vpn.ip.isEmpty ? nil : vpn.ip, desde: vpn.connected ? vpn.inicio : nil, error: error,
                                permitida: preferencias.politicaAsistentes != .noPermitir
                                    && !preferencias.bloqueadasParaAsistentes.contains(vpn.id),
                                codigoPorCorreo: preferencias.correo[vpn.id] != nil)
        }
    }

    func diagnostico() -> [Comprobacion] {
        var lista = [
            Comprobacion(nombre: "Nuvex", ok: true, detalle: "Versión \(InfoVersion.actual.descripcion)"),
            Comprobacion(nombre: "Control remoto", ok: disponible,
                         detalle: disponible ? "Disponible" : "No pudo iniciar; cierra otras copias de Nuvex y vuelve a abrir la app"),
            Comprobacion(nombre: "Ayudante de red", ok: modelo.ayudanteListo == true,
                         detalle: modelo.ayudanteListo == true ? "Al día" : "Necesita autorización en la Mac"),
            Comprobacion(nombre: "Permiso para asistentes", ok: preferencias.politicaAsistentes == .permitir,
                         detalle: ["noPermitir": "No permitido", "preguntar": "Pide confirmación en la Mac",
                                   "permitir": "Conectan sin preguntar"][preferencias.politicaAsistentes.rawValue] ?? ""),
            Comprobacion(nombre: "Confirmación inicial con Touch ID", ok: !SecurityPreferences.needsInitialConfirmation(),
                         detalle: SecurityPreferences.needsInitialConfirmation() ? "Pendiente: conecta una vez desde la Mac" : "Hecha"),
            Comprobacion(nombre: "Firma de la app", ok: modelo.chequeo?.firmaEstable ?? false,
                         detalle: modelo.chequeo?.firmaEstable == true ? "Estable" : "Ad hoc: el Llavero puede preguntar tras cada actualización"),
            Comprobacion(nombre: "Estado del Llavero", ok: modelo.chequeo?.llaveroPendiente != true,
                         detalle: modelo.chequeo?.llaveroPendiente == true
                            ? "Pendiente de permitir en la Mac"
                            : "Sin autorización pendiente detectada; la lectura no se probó"),
        ]
        for vpn in modelo.vpns where vpn.enabled {
            var problemas: [String] = []
            if !vpn.configured { problemas.append("falta servidor o usuario") }
            switch modelo.passwordStatuses[vpn.id] {
            case .missing: problemas.append("falta la contraseña")
            case .error: problemas.append("no se pudo comprobar la entrada del Llavero")
            case .saved: break
            case nil: problemas.append("estado de contraseña desconocido")
            }
            if preferencias.bloqueadasParaAsistentes.contains(vpn.id) { problemas.append("no disponible para asistentes") }
            let correo = preferencias.correo[vpn.id] != nil ? "código por correo" : "código a mano si lo pide"
            lista.append(Comprobacion(nombre: "«\(vpn.name)»", ok: problemas.isEmpty,
                                      detalle: problemas.isEmpty
                                        ? "Configurada localmente · \(correo) · servidor y credenciales no probados"
                                        : problemas.joined(separator: ", ")))
        }
        return lista
    }

    private func diagnostico(profundo: Bool) async -> [Comprobacion] {
        var lista = diagnostico()
        guard profundo else { return lista }
        for vpn in modelo.vpns where vpn.enabled && vpn.configured {
            guard modelo.passwordStatuses[vpn.id] == .saved else { continue }
            do {
                _ = try await VPNModel.leerDelLlavero(
                    id: vpn.id, name: vpn.name,
                    reason: "Comprobar que Automatización puede usar la contraseña de \(vpn.name)")
                lista.append(Comprobacion(nombre: "Lectura del Llavero · «\(vpn.name)»", ok: true,
                                          detalle: "Nuvex pudo leerla; el valor no se mostró ni se guardó"))
            } catch {
                lista.append(Comprobacion(nombre: "Lectura del Llavero · «\(vpn.name)»", ok: false,
                                          detalle: error.localizedDescription))
            }
        }
        return lista
    }
}
