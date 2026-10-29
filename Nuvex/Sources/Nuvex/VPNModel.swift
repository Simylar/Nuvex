import AppKit
import SwiftUI

@MainActor
final class VPNModel: ObservableObject {
    @Published var vpns: [VPNStatus] = []
    @Published var profiles: [VPNProfile] = []
    @Published var passwordStatuses: [String: PasswordStatus] = [:]
    @Published var estados: [String: EstadoUI] = [:]
    @Published var ultimoError: String?
    @Published var errorConsulta: String?
    /// VPN que se cayeron sin que el usuario lo pidiera, con la hora del aviso.
    @Published var desconexiones: [String: Date] = [:]
    @Published var mensajeAyudante: String?
    @Published var instalandoAyudante = false
    @Published var guardandoConfiguracion = false
    @Published var mensajeConfiguracion: String?
    /// Resultado del último guardado, paso a paso.
    @Published var resumenGuardado: ResumenGuardado?
    @Published var settingsTargetID: String?
    /// Página de Ajustes que debe mostrarse al abrir la ventana.
    @Published var paginaDestino: PaginaAjustes?
    @Published private(set) var configuracionCargada = false
    @Published private(set) var cargandoConfiguracion = false
    @Published private(set) var errorCargaConfiguracion: String?
    @Published private(set) var desconectando: Set<String> = []
    @Published private(set) var recuperando: Set<String> = []
    private var recuperacion = RecuperacionConexion()
    private var redDisponible = false
    private let permiteRecuperacion: @MainActor () -> Bool
    /// Los datos los guardó una versión más nueva de Nuvex: no se modifican.
    @Published private(set) var datosMasNuevos = false
    private(set) var actualizaciones: Actualizaciones?
    private(set) var chequeo: ChequeoActualizacion?
    private(set) var control: ControlRemoto?
    private var cicloVida: CicloVidaMac?
    #if DEBUG
    /// Modelo con datos de ejemplo para capturas: no consulta el motor.
    var esMuestra = false

    func confirmarConfiguracionDeMuestra() { configuracionCargada = true }

    func usarActualizacionesDeMuestra(_ actualizaciones: Actualizaciones) {
        self.actualizaciones = actualizaciones
    }
    #endif

    private var timer: Timer?
    private var refrescando = false
    /// Descarta una consulta iniciada antes de confirmar una desconexión.
    private var revisionEstado = 0
    /// Si se pidió otra consulta mientras había una en curso, se ejecuta en
    /// cuanto termine. Es importante al confirmar un túnel recién establecido.
    private var refrescoPendiente = false
    private var desconexionSolicitada: Set<String> = []
    private var faltas: [String: Int] = [:]
    private var conexionPendiente: String?
    /// Reconexiones pedidas desde el aviso: si fallan, el aviso lo dice.
    private var reconexionesDesdeAviso: Set<String> = []
    /// Cuándo empezó cada intento de conexión en curso, para mostrar el avance.
    @Published var inicioConexion: [String: Date] = [:]
    /// Conexiones que esperan el código de verificación.
    @Published private(set) var esperandoCodigo: Set<String> = []
    /// Intentos que la persona canceló (hasta el siguiente intento).
    private(set) var canceladas: Set<String> = []

    /// Modelo vacío sin consultar el motor; permite muestras y pruebas aisladas.
    init(sinArrancar: Void, permiteRecuperacion: @escaping @MainActor () -> Bool = {
        UserDefaults.standard.bool(forKey: "reconectarAutomaticamente") && !SecurityPreferences.needsInitialConfirmation()
    }) {
        self.permiteRecuperacion = permiteRecuperacion
    }

    convenience init() {
        self.init(sinArrancar: ())
        // Escribir en una tubería cuyo lector terminó no debe cerrar la app.
        signal(SIGPIPE, SIG_IGN)
        // Antes de leer nada: copia de seguridad y migraciones de esta versión.
        let migracion = Migraciones.ejecutar()
        _ = Preferencias.shared
        chequeo = ChequeoActualizacion(migracion: migracion)
        actualizaciones = Actualizaciones(modelo: self)
        SecurityPreferences.migrate()
        do {
            try IntegracionAsistentes.actualizarGestionados()
        } catch {
            Log.escribir("automatizacion estado=actualizacion_fallida")
        }
        VPNNotifications.shared.reconnect = { [weak self] id in
            Task { @MainActor in self?.reconectarDesdeAviso(id) }
        }
        VPNNotifications.shared.ignorar = { [weak self] id in
            Task { @MainActor in self?.descartarAviso(id) }
        }
        VPNNotifications.shared.abrirAjustes = { [weak self] id in
            Task { @MainActor in
                guard let self else { return }
                AperturaAjustes.abrir(self, conexion: id)
            }
        }
        VPNNotifications.shared.abrirActualizacion = { [weak self] in
            Task { @MainActor in self?.actualizaciones?.mostrar() }
        }
        VPNNotifications.shared.start()
        NotificationCenter.default.addObserver(forName: .solicitudCodigoCambio, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.esperandoCodigo = Set(SolicitudCodigo.abiertas.keys)
            }
        }
        arrancar()
        cargarConfiguracion()
        // El panel del código busca en Gmail si la conexión lo tiene configurado.
        SolicitudCodigo.lector = { perfilID, desde, alCambiar in
            guard let config = Preferencias.shared.ajustes.correo[perfilID] else { return .noConfigurado }
            guard !config.remitente.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .problema(.remitenteNoConfigurado)
            }
            if let problema = CuentaGoogle.shared.problemaParaLeerCorreo { return .problema(problema) }
            return .disponible(cuenta: CuentaGoogle.shared.correo ?? "Gmail",
                              tarea: Task { await LectorGmail.esperar(config, desde: desde, alCambiar: alCambiar) })
        }
        let control = ControlRemoto(modelo: self)
        control.iniciar()
        self.control = control
        let cicloVida = CicloVidaMac(modelo: self)
        cicloVida.iniciar()
        self.cicloVida = cicloVida
        AppActual.registrar(self)
        // Al salir se retira el socket; si la app termina de golpe, el
        // siguiente arranque lo reemplaza.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cicloVida?.detener()
                self?.control?.detener()
            }
        }
    }

    /// Idempotente: se llama al crear el modelo y tambien al abrir el panel.
    /// Debe arrancar al lanzar la app, no al abrir el menu, porque el icono de
    /// la barra ya refleja el estado antes de que el usuario haga clic.
    func arrancar() {
        guard timer == nil else { refrescar(); return }
        refrescar()
        let configured = UserDefaults.standard.object(forKey: "intervaloRevision") as? Int ?? 5
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(2, min(60, configured))), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refrescar() }
        }
    }

    func actualizarIntervalo() {
        timer?.invalidate()
        timer = nil
        arrancar()
    }

    var hayAlgunaConectada: Bool { vpns.contains { $0.connected } }
    var conectadas: Int { vpns.filter { $0.connected }.count }
    var hayConectando: Bool { estados.values.contains(.conectando) }
    /// Hay una operación que un reinicio de la app interrumpiría.
    var ocupado: Bool {
        hayConectando || !esperandoCodigo.isEmpty || !desconectando.isEmpty || !recuperando.isEmpty
            || guardandoConfiguracion || instalandoAyudante
    }
    var motivoBloqueoActualizacion: String {
        if guardandoConfiguracion { return "Esperando a que termine de guardar la configuración…" }
        if instalandoAyudante { return "Esperando a que termine la preparación del ayudante de red…" }
        if !esperandoCodigo.isEmpty { return "Esperando a que termine la verificación de una conexión…" }
        if !desconectando.isEmpty { return "Esperando a que termine la desconexión en curso…" }
        if !recuperando.isEmpty { return "Esperando a que termine la recuperación de la conexión…" }
        return "Esperando a que termine la conexión en curso…"
    }
    /// Una caída o un fallo de conexión: el icono de la barra lo señala.
    var requiereAtencion: Bool {
        !desconexiones.isEmpty || errorConsulta != nil || errorCargaConfiguracion != nil || estados.values.contains {
            if case .error = $0 { return true } else { return false }
        }
    }
    /// Las conexiones desactivadas se conservan pero no aparecen en el panel.
    var vpnsVisibles: [VPNStatus] { vpns.filter(\.enabled) }
    var ayudanteListo: Bool? { vpns.first?.helperReady }

    var avisoConvivencia: String? {
        let activeIds = Set(vpns.filter { $0.connected }.map(\.id))
        guard activeIds.count > 1 else { return nil }
        let activeProfiles = profiles.filter { activeIds.contains($0.id) }
        var shared: [String] = []
        if activeProfiles.filter(\.manageRoutes).count > 1 { shared.append("rutas") }
        if activeProfiles.filter(\.manageDNS).count > 1 { shared.append("DNS") }
        guard !shared.isEmpty else { return nil }
        return "Varias VPN administran \(shared.joined(separator: " y ")). Si sus redes se superponen, ajusta las opciones de red."
    }

    func estado(_ vpn: VPNStatus) -> EstadoUI {
        if let e = estados[vpn.id], e == .conectando { return .conectando }
        if vpn.connected { return .conectada }
        if let e = estados[vpn.id], case .error = e { return e }
        return .desconectada
    }

    func estado(id: String) -> EstadoUI {
        guard let vpn = vpns.first(where: { $0.id == id }) else { return estados[id] ?? .desconectada }
        return estado(vpn)
    }

    /// La tarea que tiene sentido revisar al reabrir; no inicia una conexión.
    var conexionParaReabrir: String? {
        ReaperturaNuvex.conexion(perfiles: profiles,
            estados: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, estado(id: $0.id)) }),
            enCurso: Set(profiles.filter { conexionEnCurso($0.id) || recuperando.contains($0.id) }.map(\.id)))
    }

    // MARK: Consulta de estado

    func refrescar() {
        #if DEBUG
        if esMuestra { return }
        #endif
        guard !refrescando else {
            refrescoPendiente = true
            return
        }
        refrescando = true
        let revision = revisionEstado
        Task.detached(priority: .utility) {
            let resultado: Resultado
            do {
                resultado = try Self.ejecutar(args: ["list"])
            } catch {
                Log.escribir("fallo al ejecutar el motor: \(error)")
                await MainActor.run {
                    guard self.revisionEstado == revision else { self.finalizarRefresco(); return }
                    self.errorConsulta = "No se pudo consultar el estado de las conexiones."
                    self.finalizarRefresco()
                }
                return
            }
            guard resultado.codigo == 0, let datos = resultado.salida.data(using: .utf8),
                  let decodificada = try? JSONDecoder().decode([VPNStatus].self, from: datos)
            else {
                Log.escribir("salida no interpretable: código=\(resultado.codigo), bytes de salida=\(resultado.salida.utf8.count), bytes de error=\(resultado.error.utf8.count)")
                await MainActor.run {
                    guard self.revisionEstado == revision else { self.finalizarRefresco(); return }
                    self.errorConsulta = resultado.error.isEmpty
                        ? "El motor devolvió una respuesta vacía (código \(resultado.codigo))."
                        : resultado.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.finalizarRefresco()
                }
                return
            }
            let lista = DetallesTunel.completar(decodificada)
            await MainActor.run {
                guard self.revisionEstado == revision else { self.finalizarRefresco(); return }
                self.errorConsulta = nil
                self.procesarTransiciones(lista)
                self.vpns = lista
                self.chequeo?.revisar(self)
                if let id = self.conexionPendiente,
                   let vpn = lista.first(where: { $0.id == id }) {
                    self.conexionPendiente = nil
                    self.confirmarConexionExterna(vpn)
                }
                // Si el motor ya la reporta conectada, se acabo el "conectando".
                for v in lista {
                    if v.connected {
                        self.estados[v.id] = .conectada
                        self.inicioConexion.removeValue(forKey: v.id)
                    } else if !v.connected, self.estados[v.id] == .conectada {
                        self.estados.removeValue(forKey: v.id)
                    }
                }
                self.finalizarRefresco()
            }
        }
    }

    private func finalizarRefresco() {
        refrescando = false
        guard refrescoPendiente else { return }
        refrescoPendiente = false
        refrescar()
    }

    private func procesarTransiciones(_ lista: [VPNStatus]) {
        let anteriores = Dictionary(uniqueKeysWithValues: vpns.map { ($0.id, $0) })
        for vpn in lista {
            if vpn.connected {
                faltas.removeValue(forKey: vpn.id)
                recuperando.remove(vpn.id)
                reconexionesDesdeAviso.remove(vpn.id)
                desconexiones.removeValue(forKey: vpn.id)
                VPNNotifications.shared.clear(id: vpn.id)
                continue
            }
            if desconexionSolicitada.remove(vpn.id) != nil {
                faltas.removeValue(forKey: vpn.id)
                continue
            }
            if anteriores[vpn.id]?.connected == true || faltas[vpn.id] != nil {
                faltas[vpn.id, default: 0] += 1
                if faltas[vpn.id] == 2 {
                    let fecha = Date()
                    desconexiones[vpn.id] = fecha
                    if programarRecuperacion(vpn) { continue }
                    if UserDefaults.standard.object(forKey: "avisarDesconexion") as? Bool ?? true {
                        VPNNotifications.shared.disconnected(id: vpn.id, name: vpn.name, fecha: fecha)
                    }
                }
            }
        }
    }

    // MARK: Acciones

    func actualizarDisponibilidadRed(_ disponible: Bool) {
        redDisponible = disponible
        guard disponible else { return }
        for vpn in vpns where desconexiones[vpn.id] != nil {
            _ = programarRecuperacion(vpn)
        }
    }

    /// Recupera solo una conexión cuya caída se confirmó. No instala el
    /// ayudante ni abre diálogos del Llavero en segundo plano.
    private func programarRecuperacion(_ vpn: VPNStatus) -> Bool {
        let activada = permiteRecuperacion()
        let disponible = redDisponible && !vpn.connected && vpn.enabled && vpn.configured && vpn.helperReady
            && configuracionCargada && errorCargaConfiguracion == nil && !cargandoConfiguracion
            && passwordStatuses[vpn.id] == .saved
            && !guardandoConfiguracion && !instalandoAyudante && !conexionEnCurso(vpn.id)
            && !desconectando.contains(vpn.id) && !desconexionSolicitada.contains(vpn.id)
        guard activada, disponible, recuperacion.puedeIntentar(vpn.id),
              !recuperando.contains(vpn.id) else { return false }
        let caida = desconexiones[vpn.id]
        recuperando.insert(vpn.id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.recuperando.contains(vpn.id), self.desconexiones[vpn.id] == caida else { return }
            self.recuperando.remove(vpn.id)
            guard self.permiteRecuperacion(), self.redDisponible,
                  self.errorConsulta == nil, !self.guardandoConfiguracion, !self.instalandoAyudante,
                  self.configuracionCargada, self.errorCargaConfiguracion == nil, !self.cargandoConfiguracion,
                  !self.conexionEnCurso(vpn.id), !self.desconectando.contains(vpn.id),
                  let actual = self.vpns.first(where: { $0.id == vpn.id }), !actual.connected,
                  actual.enabled, actual.configured, actual.helperReady,
                  self.profiles.contains(where: { $0.id == vpn.id && $0.enabled }),
                  self.recuperacion.reservar(vpn.id, activada: true, disponible: true) else { return }
            self.desconexiones.removeValue(forKey: vpn.id)
            VPNNotifications.shared.clear(id: vpn.id)
            self.iniciarConexion(actual, automaticamente: true)
        }
        return true
    }

    /// La acción del botón circular de cada fila.
    func alternar(_ vpn: VPNStatus) {
        switch estado(vpn) {
        case .conectada: desconectar(vpn)
        case .conectando: break
        case .desconectada, .error: conectar(vpn)
        }
    }

    func conectar(_ vpn: VPNStatus) {
        guard errorConsulta == nil else {
            ultimoError = "Vuelve a comprobar el estado antes de conectar."
            refrescar()
            return
        }
        guard !vpn.connected, estado(vpn) != .conectando,
              !desconectando.contains(vpn.id), !instalandoAyudante else { return }
        recuperando.remove(vpn.id)
        recuperacion.permitirNuevoIntento(vpn.id)
        desconexionSolicitada.remove(vpn.id)
        guard !guardandoConfiguracion else {
            ultimoError = "Espera a que termine de guardarse la configuración antes de conectar."
            return
        }
        guard vpn.enabled, vpn.configured else {
            estados[vpn.id] = .error(Fallo(titulo: "Falta configurar la conexión",
                                           detalle: "Completa el servidor y el usuario en Ajustes.",
                                           accion: .ajustes("Ajustes…")))
            return
        }
        guard estado(vpn) != .conectando else { return }
        desconexiones.removeValue(forKey: vpn.id)
        canceladas.remove(vpn.id)
        if !vpn.helperReady {
            instalarAyudante(conectarDespues: vpn)
            return
        }
        iniciarConexion(vpn)
    }

    private func iniciarConexion(_ vpn: VPNStatus, automaticamente: Bool = false) {
        guard estado(vpn) != .conectando else { return }
        let inicioIntento = Date()
        estados[vpn.id] = .conectando
        inicioConexion[vpn.id] = inicioIntento
        canceladas.remove(vpn.id)
        ultimoError = nil
        IntentosConexion.preparar(vpn.id)
        Task.detached(priority: .userInitiated) {
            let resultado = await Self.conectarProceso(id: vpn.id, name: vpn.name, sinInteraccion: automaticamente)
            await MainActor.run {
                guard VigenciaIntentoConexion.corresponde(inicioIntento, al: self.inicioConexion[vpn.id]) else { return }
                switch resultado {
                case .success:
                    // El ayudante ya vio el túnel activo, pero el estado público
                    // se confirma con `list`. Se conserva «conectando» para no
                    // abrir un hueco falso de «desconectada» entre ambas cosas.
                    self.reconexionesDesdeAviso.remove(vpn.id)
                    self.agotarConfirmacionSiNoAparece(vpn, intento: inicioIntento)
                case .failure(let e) where e.fallo?.codigo == .cancelada:
                    self.inicioConexion.removeValue(forKey: vpn.id)
                    self.estados.removeValue(forKey: vpn.id)
                    self.reconexionesDesdeAviso.remove(vpn.id)
                    self.canceladas.insert(vpn.id)
                case .failure(let e):
                    self.inicioConexion.removeValue(forKey: vpn.id)
                    self.estados[vpn.id] = .error(e.falloParaFila)
                    let avisarAutomaticamente = automaticamente &&
                        (UserDefaults.standard.object(forKey: "avisarDesconexion") as? Bool ?? true)
                    if self.reconexionesDesdeAviso.remove(vpn.id) != nil || avisarAutomaticamente {
                        VPNNotifications.shared.reconexionFallida(id: vpn.id, name: vpn.name, fallo: e.falloParaFila)
                    }
                }
                self.refrescar()
            }
        }
    }

    /// Un `list` normal confirma el túnel en milisegundos. Si el motor deja de
    /// responder después de informar éxito, se termina con un error explícito
    /// en lugar de mantener «conectando» indefinidamente.
    private func agotarConfirmacionSiNoAparece(_ vpn: VPNStatus, intento: Date) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self,
                  VigenciaIntentoConexion.corresponde(intento, al: self.inicioConexion[vpn.id]),
                  self.estados[vpn.id] == .conectando else { return }
            self.inicioConexion.removeValue(forKey: vpn.id)
            self.estados[vpn.id] = .error(Fallo(
                titulo: "No se pudo confirmar el estado",
                detalle: "El ayudante informó que el túnel inició, pero Nuvex no pudo confirmarlo al consultar su estado.",
                accion: .ninguna))
            self.refrescar()
        }
    }

    /// Cancela un intento de conexión en curso. Detiene el túnel a medio
    /// establecer; las VPN ya conectadas no se tocan.
    func cancelarConexion(_ id: String) {
        if recuperando.remove(id) != nil {
            // La desconexión explícita debe impedir que otro cambio de red
            // vuelva a programar la recuperación de esta misma caída.
            desconexiones.removeValue(forKey: id)
            faltas.removeValue(forKey: id)
            canceladas.insert(id)
            VPNNotifications.shared.clear(id: id)
            return
        }
        // La operación real prevalece sobre la representación visual: si un
        // error de consulta cambió la fila, la espera de OTP aún debe poder
        // cancelarse y limpiar su proceso.
        guard conexionEnCurso(id) else { return }
        Log.escribir("cancelando el intento de conectar \(id)")
        SolicitudCodigo.abiertas[id]?.cancelar()
        switch IntentosConexion.cancelar(id) {
        case .antesDelProceso:
            inicioConexion.removeValue(forKey: id)
            estados.removeValue(forKey: id)
            reconexionesDesdeAviso.remove(id)
            canceladas.insert(id)
            refrescar()
            return
        case .procesoEnCurso:
            return
        case .noEncontrado:
            break
        }
        // El proceso puede haber terminado justo antes de que `list` confirme
        // el túnel. En ese intervalo ya no hay proceso que cancelar: se detiene
        // explícitamente el túnel que acaba de iniciar.
        guard desconectando.insert(id).inserted else { return }
        Task.detached(priority: .userInitiated) {
            let detencion = try? Self.ejecutar(args: ["stop", id])
            let consulta = try? Self.ejecutar(args: ["list"])
            await MainActor.run {
                self.desconectando.remove(id)
                self.inicioConexion.removeValue(forKey: id)
                if self.aplicarDesconexionConfirmada(id, consulta: consulta) {
                    self.canceladas.insert(id)
                } else {
                    let detalle = detencion?.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    let mensaje = (detalle?.isEmpty == false ? detalle : nil)
                        ?? "El estado del túnel no confirmó la desconexión."
                    self.ultimoError = mensaje
                    self.estados[id] = .error(Fallo(titulo: "No se pudo confirmar la cancelación",
                                                    detalle: mensaje, accion: .ninguna))
                }
                self.refrescar()
            }
        }
    }

    func conexionEnCurso(_ id: String) -> Bool {
        recuperando.contains(id) || inicioConexion[id] != nil || estados[id] == .conectando || SolicitudCodigo.abiertas[id] != nil
    }

    func reconectarDesdeAviso(_ id: String) {
        guard let vpn = vpns.first(where: { $0.id == id }) else { return }
        reconexionesDesdeAviso.insert(id)
        conectar(vpn)
        // conectar(_:) puede rechazarlo sin intentarlo (por ejemplo, sin servidor).
        let enCurso = estados[id] == .conectando || instalandoAyudante
        if !enCurso, case .error(let fallo) = estados[id] {
            reconexionesDesdeAviso.remove(id)
            VPNNotifications.shared.reconexionFallida(id: id, name: vpn.name, fallo: fallo)
        }
    }

    func conectar(id: String) {
        guard let vpn = vpns.first(where: { $0.id == id }) else { return }
        conectar(vpn)
    }

    /// El ayudante acaba de confirmar este guardado; no se exige esperar al
    /// siguiente sondeo para iniciar. El túnel sigue confirmándose con `list`.
    func conectarTrasGuardar(id: String, resultado: ResultadoGuardado) {
        guard resultado.completo, resultado.confirmaImportacion([id]),
              let perfil = profiles.first(where: { $0.id == id }), perfil.enabled else { return }
        let ayudanteConfirmado = resultado.resumen.ayudante == .hecho || ayudanteListo == true
        guard ayudanteConfirmado else {
            estados[id] = .error(Fallo(titulo: "Falta preparar la conexión",
                detalle: "Tus datos están guardados. Pulsa Conectar para autorizar el ayudante de red.",
                accion: .reintentar("Conectar"), codigo: .ayudante))
            return
        }
        let anterior = vpns.first(where: { $0.id == id })
        // La lista anterior puede seguir reflejando el ayudante previo al guardado.
        let actual = VPNStatus(id: id, name: perfil.name, connected: anterior?.connected ?? false,
            pid: anterior?.pid ?? 0, ip: anterior?.ip ?? "", iface: anterior?.iface ?? "", networks: anterior?.networks ?? [],
            enabled: perfil.enabled, configured: Validacion.motivo(perfil) == nil, helperReady: true,
            inicio: anterior?.inicio)
        conectar(actual)
    }

    func solicitarDesdeEnlace(_ url: URL) {
        guard url.scheme == "nuvex", url.host == "connect" else { return }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard id.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil else { return }
        if let vpn = vpns.first(where: { $0.id == id }) { confirmarConexionExterna(vpn) }
        else { conexionPendiente = id; refrescar() }
    }

    private func confirmarConexionExterna(_ vpn: VPNStatus) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "¿Conectar a «\(vpn.name)»?"
        alert.informativeText = "Otra app o un enlace pidió iniciar esta VPN con Nuvex."
        alert.addButton(withTitle: "Conectar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn { conectar(vpn) }
    }

    func instalarAyudante(desdeGuardado: Bool = false, conectarDespues vpn: VPNStatus? = nil,
                         errorPrevio: String? = nil,
                         alTerminar: (@MainActor @Sendable (ResumenGuardado.Paso) -> Void)? = nil) {
        guard !guardandoConfiguracion else {
            alTerminar?(.pendiente("Espera a que termine de guardarse la configuración antes de preparar el ayudante."))
            return
        }
        guard !instalandoAyudante else {
            if desdeGuardado { resumenGuardado?.ayudante = .pendiente("Nuvex lo preparará la próxima vez que conectes.") }
            alTerminar?(.pendiente("La preparación del ayudante sigue en curso."))
            return
        }
        instalandoAyudante = true
        mensajeAyudante = nil
        ultimoError = errorPrevio
        Task.detached(priority: .utility) {
            do {
                let result = try Self.ejecutar(args: ["install-helper"])
                await MainActor.run {
                    self.instalandoAyudante = false
                    self.mensajeAyudante = result.codigo == 0
                        ? result.salida.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                    let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "nuvex: ", with: "")
                    let installError = detail.isEmpty ?
                        "No se pudo instalar el ayudante (código \(result.codigo))." :
                        "No se pudo instalar el ayudante: \(detail)."
                    self.ultimoError = result.codigo == 0 ? errorPrevio :
                        [errorPrevio, installError].compactMap { $0 }.joined(separator: " ")
                    if desdeGuardado {
                        self.mensajeConfiguracion = result.codigo == 0 ? "Cambios guardados y aplicados." :
                            "La configuración se guardó; el ayudante se actualizará al conectar."
                        self.resumenGuardado?.ayudante = result.codigo == 0 ? .hecho
                            : .fallo(installError + " Nuvex volverá a pedirlo al conectar.")
                    }
                    if result.codigo != 0, let vpn {
                        self.estados[vpn.id] = .error(Fallo(titulo: "No se preparó el ayudante",
                                                            detalle: installError,
                                                            accion: .reintentar("Reintentar")))
                    }
                    self.refrescar()
                    if result.codigo == 0, let vpn {
                        self.iniciarConexion(vpn)
                    }
                    alTerminar?(result.codigo == 0 ? .hecho : .fallo(installError))
                }
            } catch {
                await MainActor.run {
                    self.instalandoAyudante = false
                    self.ultimoError = [errorPrevio, error.localizedDescription]
                        .compactMap { $0 }.joined(separator: " ")
                    if desdeGuardado {
                        self.mensajeConfiguracion = "La configuración se guardó; el ayudante se actualizará al conectar."
                        self.resumenGuardado?.ayudante = .fallo(error.localizedDescription)
                    }
                    alTerminar?(.fallo(error.localizedDescription))
                }
            }
        }
    }

    func desconectar(_ vpn: VPNStatus) {
        guard !desconexionSolicitada.contains(vpn.id), desconectando.insert(vpn.id).inserted else { return }
        recuperando.remove(vpn.id)
        desconexionSolicitada.insert(vpn.id)
        desconexiones.removeValue(forKey: vpn.id)
        Task.detached(priority: .userInitiated) {
            let resultado = try? Self.ejecutar(args: ["stop", vpn.id])
            let consulta = try? Self.ejecutar(args: ["list"])
            await MainActor.run {
                self.desconectando.remove(vpn.id)
                if !self.aplicarDesconexionConfirmada(vpn.id, consulta: consulta) {
                    self.desconexionSolicitada.remove(vpn.id)
                    let detail = resultado?.error.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.ultimoError = detail.isEmpty ? "No se pudo confirmar la desconexión. Vuelve a intentarlo." : detail
                }
                self.refrescar()
            }
        }
    }

    /// Cancelar un túnel recién iniciado y desconectar uno activo deben
    /// invalidar por igual cualquier consulta anterior a su detención.
    func aplicarDesconexionConfirmada(_ id: String, consulta: Resultado?) -> Bool {
        guard let consulta,
              EstadoMotor.confirmaDesconexion([id], codigo: consulta.codigo, salida: consulta.salida),
              let datos = consulta.salida.data(using: .utf8),
              let lista = try? JSONDecoder().decode([VPNStatus].self, from: datos),
              let estado = lista.first(where: { $0.id == id }) else { return false }
        revisionEstado += 1
        if let indice = vpns.firstIndex(where: { $0.id == id }) { vpns[indice] = estado }
        desconexionSolicitada.remove(id)
        recuperando.remove(id)
        desconexiones.removeValue(forKey: id)
        faltas.removeValue(forKey: id)
        inicioConexion.removeValue(forKey: id)
        estados[id] = .desconectada
        return true
    }

    /// Descarta el aviso de caída o el error de una fila.
    func descartarAviso(_ id: String) {
        recuperando.remove(id)
        desconexiones.removeValue(forKey: id)
        if case .error = estados[id] { estados.removeValue(forKey: id) }
    }

    func cargarConfiguracion() {
        #if DEBUG
        if esMuestra { return }
        #endif
        guard !cargandoConfiguracion, !guardandoConfiguracion else { return }
        cargandoConfiguracion = true
        let errorAnterior = errorCargaConfiguracion
        errorCargaConfiguracion = nil
        Task.detached(priority: .utility) {
            let result = try? Self.ejecutar(args: ["config", "list"])
            guard let result, result.codigo == 0,
                  let data = result.salida.data(using: .utf8),
                  let profiles = try? JSONDecoder().decode([VPNProfile].self, from: data) else {
                // nuvexconfig.py rechaza versiones de profiles.json que no conoce:
                // los guardó una Nuvex más nueva y no deben sobrescribirse.
                let masNuevos = result?.error.contains("versión de configuración no compatible") == true
                await MainActor.run {
                    self.cargandoConfiguracion = false
                    self.datosMasNuevos = masNuevos
                    self.ultimoError = masNuevos
                        ? "Tus conexiones las guardó una versión más nueva de Nuvex. Actualiza Nuvex para usarlas; no se modificarán."
                        : "No se pudo leer la configuración."
                    self.errorCargaConfiguracion = self.ultimoError
                }
                return
            }
            let statuses = Dictionary(uniqueKeysWithValues: profiles.map {
                ($0.id, Self.passwordStatus(id: $0.id, username: $0.username))
            })
            await MainActor.run {
                self.cargandoConfiguracion = false
                if self.ultimoError == errorAnterior { self.ultimoError = nil }
                self.errorCargaConfiguracion = nil
                let primeraCarga = !self.configuracionCargada
                self.profiles = profiles
                self.passwordStatuses = statuses
                self.configuracionCargada = true
                self.datosMasNuevos = false
                self.chequeo?.revisar(self)
                // Una app de barra de menús no abre ventanas por sí sola: sin
                // conexiones, la bienvenida explica dónde está y qué hacer.
                if primeraCarga && profiles.isEmpty { Bienvenida.mostrar(modelo: self) }
            }
        }
    }

    /// Guarda una sola conexión conservando las demás tal como están.
    func guardarConexion(_ perfil: VPNProfile, password: String?,
                         alFinalizar: (@MainActor @Sendable (ResultadoGuardado) -> Void)? = nil) {
        var lista = profiles
        if let i = lista.firstIndex(where: { $0.id == perfil.id }) { lista[i] = perfil }
        else { lista.append(perfil) }
        var passwords: [String: String] = [:]
        if let password, !password.isEmpty { passwords[perfil.id] = password }
        guardarPerfiles(lista, passwords: passwords, alFinalizar: alFinalizar)
    }

    func eliminarConexion(_ id: String) {
        guardarPerfiles(profiles.filter { $0.id != id }, passwords: [:])
    }

    /// Vuelve a la configuración de una copia de seguridad. Antes guarda una
    /// copia del estado actual, para poder deshacerlo.
    func restaurarCopia(_ copia: CopiaSeguridad,
                       alFinalizar: (@MainActor @Sendable (ResultadoGuardado) -> Void)? = nil) {
        func rechazar(_ detalle: String) {
            ultimoError = detalle
            alFinalizar?(ResultadoGuardado(id: UUID(), resumen: .init(conexiones: .fallo(detalle)), idsConfirmados: []))
        }
        guard !ocupado, !hayAlgunaConectada, !datosMasNuevos, Preferencias.shared.soloLectura == nil else {
            rechazar("Termina las operaciones y desconecta las VPN antes de restaurar. Los perfiles y ajustes actuales deben poder modificarse.")
            return
        }
        do {
            let preparacion = try PreparacionRestauracion.leer(en: copia.url)
            _ = try Migraciones.crearCopia(etiqueta: "antes-de-restaurar", base: Preferencias.directorio,
                                           perfiles: URL(fileURLWithPath: Paths.perfiles))
            guardarPerfiles(preparacion.perfiles, passwords: [:], ajustes: preparacion.ajustes, alFinalizar: alFinalizar)
        } catch {
            rechazar("No se inició la restauración: \(error.localizedDescription)")
        }
    }

    func guardarPerfiles(_ profiles: [VPNProfile], passwords: [String: String],
                         ajustes: AjustesDelGuardado = .conservar,
                         alFinalizar: (@MainActor @Sendable (ResultadoGuardado) -> Void)? = nil) {
        let operacion = UUID()
        func rechazar(_ detalle: String) {
            ultimoError = detalle
            alFinalizar?(ResultadoGuardado(id: operacion,
                resumen: ResumenGuardado(conexiones: .fallo(detalle)), idsConfirmados: []))
        }
        guard configuracionCargada, errorCargaConfiguracion == nil, !cargandoConfiguracion else {
            rechazar("Primero vuelve a cargar tus conexiones. Nuvex no puede modificarlas sin comprobar los datos guardados.")
            return
        }
        guard !guardandoConfiguracion, !instalandoAyudante, !hayConectando,
              recuperando.isEmpty, desconectando.isEmpty else {
            rechazar("Espera a que termine la operación en curso antes de cambiar las conexiones.")
            return
        }
        guard !datosMasNuevos else {
            rechazar("Tus conexiones las guardó una versión más nueva de Nuvex. Actualiza Nuvex para cambiarlas.")
            return
        }
        let profiles = profiles.map(\.normalizado)
        do { try Validacion.validarColeccion(profiles) }
        catch { rechazar(error.localizedDescription); return }
        let migrations = profiles.compactMap { profile -> (old: VPNProfile, new: VPNProfile)? in
            guard let previous = self.profiles.first(where: { $0.id == profile.id }),
                  previous.username != profile.username,
                  previous.username.trimmingCharacters(in: .whitespacesAndNewlines) == profile.username,
                  passwords[profile.id, default: ""].isEmpty else { return nil }
            return (previous, profile)
        }
        for profile in profiles {
            if let previous = self.profiles.first(where: { $0.id == profile.id }),
               previous.username != profile.username,
               passwords[profile.id, default: ""].isEmpty,
               !migrations.contains(where: { $0.new.id == profile.id }) {
                rechazar("Al cambiar el usuario de \(profile.name), escribe la contraseña del nuevo usuario.")
                return
            }
        }
        if profiles != self.profiles, let active = vpns.first(where: { $0.connected }) {
            rechazar("Desconecta \(active.name) antes de cambiar las conexiones. Puedes actualizar las contraseñas sin desconectarte.")
            return
        }
        guard let data = try? JSONEncoder().encode(profiles),
              let json = String(data: data, encoding: .utf8),
              let anteriores = try? JSONEncoder().encode(self.profiles),
              let jsonAnterior = String(data: anteriores, encoding: .utf8) else {
            rechazar("No se pudieron preparar las conexiones para guardarlas.")
            return
        }
        let previousProfiles = self.profiles
        // Sin conexiones no hace falta pedir autorización para el ayudante.
        let shouldInstall = !profiles.isEmpty &&
            (profiles != previousProfiles || vpns.isEmpty || vpns.contains { !$0.helperReady })
        let canInstallNow = !hayAlgunaConectada
        guardandoConfiguracion = true
        mensajeConfiguracion = nil
        resumenGuardado = ResumenGuardado(conexiones: .enCurso)
        ultimoError = nil
        Task.detached(priority: .userInitiated) {
            var stagedMigrations: [VPNProfile] = []
            var configurationSaved = false
            var pasoAjustes: ResumenGuardado.Paso = .noAplica
            do {
                for migration in migrations {
                    guard Self.passwordStatus(id: migration.old.id, username: migration.new.username) == .missing else {
                        throw ErrorVPN(mensaje: "Ya existe una contraseña para el usuario corregido de \(migration.new.name). Escribe la contraseña en Ajustes para elegir cuál conservar.")
                    }
                    let password = try await Self.leerDelLlavero(id: migration.old.id,
                        name: migration.old.name,
                        reason: "Migrar la contraseña guardada de \(migration.old.name) al usuario corregido")
                    try Self.guardarEnLlavero(password, profile: migration.new)
                    stagedMigrations.append(migration.new)
                    guard Self.passwordStatus(id: migration.new.id, username: migration.new.username) == .saved else {
                        throw ErrorVPN(mensaje: "No se pudo verificar la contraseña migrada de \(migration.new.name).")
                    }
                }
                if ajustes.esRestauracion {
                    try await PersistenciaRestauracion.aplicar(
                        perfiles: { try Self.escribirPerfiles(json) },
                        ajustes: {
                            _ = try await ajustes.aplicar(en: Preferencias.shared, ids: Set(profiles.map(\.id)))
                        },
                        revertir: { try Self.escribirPerfiles(jsonAnterior) })
                    pasoAjustes = .hecho
                } else {
                    try Self.escribirPerfiles(json)
                }
                configurationSaved = true
                var keychainErrors: [String] = []
                var savedPasswordIDs = Set(migrations.map { $0.new.id })
                for profile in profiles {
                    if let password = passwords[profile.id], !password.isEmpty {
                        do {
                            try Self.guardarEnLlavero(password, profile: profile)
                            savedPasswordIDs.insert(profile.id)
                        }
                        catch { keychainErrors.append("No se guardó la contraseña de \(profile.name).") }
                    }
                }
                if !ajustes.esRestauracion {
                    do { pasoAjustes = try await ajustes.aplicar(en: Preferencias.shared, ids: Set(profiles.map(\.id))) }
                    catch { pasoAjustes = .fallo(error.localizedDescription) }
                }
                if keychainErrors.isEmpty {
                    for migration in migrations {
                        do { try Self.eliminarDelLlavero(profile: migration.old) }
                        catch { keychainErrors.append("No se pudo retirar la entrada antigua del Llavero de \(migration.new.name).") }
                    }
                    for previous in previousProfiles where !profiles.contains(where: {
                        $0.id == previous.id && $0.username == previous.username
                    }) && !migrations.contains(where: { $0.old.id == previous.id }) {
                        do { try Self.eliminarDelLlavero(profile: previous) }
                        catch { keychainErrors.append(error.localizedDescription) }
                    }
                }
                for profile in profiles {
                    do { try Self.actualizarEtiquetaDelLlavero(profile: profile) }
                    catch {
                        // La etiqueta es metadato descriptivo: su fallo no debe
                        // invalidar una contraseña que sigue siendo utilizable.
                        Log.escribir("no se actualizó la etiqueta del Llavero de \(profile.id): \(error.localizedDescription)")
                    }
                }
                let statuses = Dictionary(uniqueKeysWithValues: profiles.map {
                    ($0.id, Self.passwordStatus(id: $0.id, username: $0.username))
                })
                for profile in profiles where savedPasswordIDs.contains(profile.id) {
                    if statuses[profile.id] != .saved {
                        keychainErrors.append("No se pudo confirmar la contraseña de \(profile.name) en el Llavero.")
                    }
                }
                let pasoContrasenas: ResumenGuardado.Paso = !keychainErrors.isEmpty
                    ? .fallo(keychainErrors.joined(separator: " ") + " Vuelve a pulsar Guardar para reintentarlo.")
                    : savedPasswordIDs.isEmpty ? .noAplica : .hecho
                let prepararAhora = canInstallNow && keychainErrors.isEmpty
                let pasoAyudante: ResumenGuardado.Paso = !shouldInstall ? .noAplica
                    : prepararAhora ? .enCurso
                    : .pendiente(keychainErrors.isEmpty
                        ? "Hay una VPN conectada; Nuvex lo preparará la próxima vez que conectes."
                        : "Primero vuelve a guardar la contraseña; después se preparará la conexión.")
                let resumen = ResumenGuardado(conexiones: .hecho, contrasenas: pasoContrasenas,
                    ayudante: pasoAyudante, ajustes: pasoAjustes)
                await MainActor.run {
                    self.guardandoConfiguracion = false
                    self.resumenGuardado = resumen
                    let keychainError = keychainErrors.isEmpty ? nil :
                        "Se guardaron las conexiones, pero hubo errores en el Llavero: \(keychainErrors.joined(separator: " "))"
                    self.ultimoError = keychainError
                    self.mensajeConfiguracion = keychainErrors.isEmpty ?
                        (shouldInstall ? (canInstallNow ? "Cambios guardados. Aplicando…" :
                            "Cambios guardados. Nuvex preparará el ayudante al volver a conectar.") :
                            "Cambios guardados.") : nil
                    self.mensajeAyudante = nil
                    for previo in previousProfiles where !ajustes.esRestauracion && !profiles.contains(where: { $0.id == previo.id }) {
                        Preferencias.shared.olvidarConexion(previo.id)
                    }
                    self.profiles = profiles
                    self.passwordStatuses = statuses
                    for id in savedPasswordIDs { self.estados.removeValue(forKey: id) }
                    self.refrescar()
                    if shouldInstall && prepararAhora {
                        self.instalarAyudante(desdeGuardado: true, errorPrevio: keychainError, alTerminar: { paso in
                            var final = resumen
                            final.ayudante = paso
                            alFinalizar?(ResultadoGuardado(id: operacion, resumen: final, idsConfirmados: Set(profiles.map(\.id))))
                        })
                    } else {
                        alFinalizar?(ResultadoGuardado(id: operacion, resumen: resumen, idsConfirmados: Set(profiles.map(\.id))))
                    }
                }
            } catch {
                var rollbackFailed = false
                let recuperacionFallida = error is PersistenciaRestauracion.RecuperacionFallida
                if !configurationSaved && !recuperacionFallida {
                    for profile in stagedMigrations.reversed() {
                        do { try Self.eliminarDelLlavero(profile: profile) }
                        catch { rollbackFailed = true }
                    }
                }
                let failure = error.localizedDescription + (rollbackFailed ?
                    " También quedó una entrada nueva en el Llavero; revisa la contraseña de esta conexión antes de reintentar." : "")
                await MainActor.run {
                    self.guardandoConfiguracion = false
                    self.mensajeConfiguracion = nil
                    let resumen = ResumenGuardado(conexiones: recuperacionFallida ? .pendiente(failure) : .fallo(failure))
                    self.resumenGuardado = resumen
                    self.ultimoError = recuperacionFallida ? failure : "No se guardaron los cambios: \(failure)"
                    if recuperacionFallida { self.cargarConfiguracion() }
                    alFinalizar?(ResultadoGuardado(id: operacion, resumen: resumen, idsConfirmados: []))
                }
            }
        }
    }

    nonisolated private static func escribirPerfiles(_ json: String) throws {
        let resultado = try ejecutar(args: ["config", "set-all", json])
        guard resultado.codigo == 0 else {
            let detalle = resultado.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ErrorVPN(mensaje: detalle.isEmpty ? "No se guardaron las conexiones (código \(resultado.codigo))." : detalle)
        }
    }
}
