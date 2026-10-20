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
    /// Los datos los guardó una versión más nueva de Nuvex: no se modifican.
    @Published private(set) var datosMasNuevos = false
    private(set) var actualizaciones: Actualizaciones?
    private(set) var chequeo: ChequeoActualizacion?
    private(set) var control: ControlRemoto?
    #if DEBUG
    /// Modelo con datos de ejemplo para capturas: no consulta el motor.
    var esMuestra = false
    #endif

    private var timer: Timer?
    private var refrescando = false
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

    /// Estado vacío sin consultar el motor; lo usan las capturas de depuración.
    init(sinArrancar: Void) {}

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
            guard let config = Preferencias.shared.ajustes.correo[perfilID],
                  !config.remitente.trimmingCharacters(in: .whitespaces).isEmpty,
                  let cuenta = CuentaGoogle.shared.correo else { return nil }
            return (cuenta, Task { await LectorGmail.esperar(config, desde: desde, alCambiar: alCambiar) })
        }
        let control = ControlRemoto(modelo: self)
        control.iniciar()
        self.control = control
        AppActual.registrar(self)
        // Al salir se retira el socket; si la app termina de golpe, el
        // siguiente arranque lo reemplaza.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.control?.detener() }
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
        hayConectando || !esperandoCodigo.isEmpty || !desconexionSolicitada.isEmpty
            || guardandoConfiguracion || instalandoAyudante
    }
    var motivoBloqueoActualizacion: String {
        if guardandoConfiguracion { return "Esperando a que termine de guardar la configuración…" }
        if instalandoAyudante { return "Esperando a que termine la preparación del ayudante de red…" }
        if !esperandoCodigo.isEmpty { return "Esperando a que termine la verificación de una conexión…" }
        if !desconexionSolicitada.isEmpty { return "Esperando a que termine la desconexión en curso…" }
        return "Esperando a que termine la conexión en curso…"
    }
    /// Una caída o un fallo de conexión: el icono de la barra lo señala.
    var requiereAtencion: Bool {
        !desconexiones.isEmpty || errorConsulta != nil || estados.values.contains {
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
        guard let vpn = vpns.first(where: { $0.id == id }) else { return .desconectada }
        return estado(vpn)
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
        Task.detached(priority: .utility) {
            let resultado: Resultado
            do {
                resultado = try Self.ejecutar(args: ["list"])
            } catch {
                Log.escribir("fallo al ejecutar el motor: \(error)")
                await MainActor.run {
                    self.errorConsulta = "No se pudo consultar el estado de las VPN: \(error.localizedDescription)"
                    self.finalizarRefresco()
                }
                return
            }
            guard let datos = resultado.salida.data(using: .utf8),
                  let decodificada = try? JSONDecoder().decode([VPNStatus].self, from: datos)
            else {
                Log.escribir("salida no interpretable: código=\(resultado.codigo), bytes de salida=\(resultado.salida.utf8.count), bytes de error=\(resultado.error.utf8.count)")
                await MainActor.run {
                    self.errorConsulta = resultado.error.isEmpty
                        ? "El motor devolvió una respuesta vacía (código \(resultado.codigo))."
                        : resultado.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.finalizarRefresco()
                }
                return
            }
            let lista = DetallesTunel.completar(decodificada)
            await MainActor.run {
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
                    if UserDefaults.standard.object(forKey: "avisarDesconexion") as? Bool ?? true {
                        VPNNotifications.shared.disconnected(id: vpn.id, name: vpn.name, fecha: fecha)
                    }
                }
            }
        }
    }

    // MARK: Acciones

    /// La acción del botón circular de cada fila.
    func alternar(_ vpn: VPNStatus) {
        switch estado(vpn) {
        case .conectada: desconectar(vpn)
        case .conectando: break
        case .desconectada, .error: conectar(vpn)
        }
    }

    func conectar(_ vpn: VPNStatus) {
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

    private func iniciarConexion(_ vpn: VPNStatus) {
        guard estado(vpn) != .conectando else { return }
        estados[vpn.id] = .conectando
        inicioConexion[vpn.id] = Date()
        canceladas.remove(vpn.id)
        ultimoError = nil
        IntentosConexion.preparar(vpn.id)
        Task.detached(priority: .userInitiated) {
            let resultado = await Self.conectarProceso(id: vpn.id, name: vpn.name)
            await MainActor.run {
                switch resultado {
                case .success:
                    // El ayudante ya vio el túnel activo, pero el estado público
                    // se confirma con `list`. Se conserva «conectando» para no
                    // abrir un hueco falso de «desconectada» entre ambas cosas.
                    self.reconexionesDesdeAviso.remove(vpn.id)
                    self.agotarConfirmacionSiNoAparece(vpn)
                case .failure(let e) where e.fallo == .canceladaPorPersona:
                    self.inicioConexion.removeValue(forKey: vpn.id)
                    self.estados.removeValue(forKey: vpn.id)
                    self.reconexionesDesdeAviso.remove(vpn.id)
                    self.canceladas.insert(vpn.id)
                case .failure(let e):
                    self.inicioConexion.removeValue(forKey: vpn.id)
                    self.estados[vpn.id] = .error(e.falloParaFila)
                    if self.reconexionesDesdeAviso.remove(vpn.id) != nil {
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
    private func agotarConfirmacionSiNoAparece(_ vpn: VPNStatus) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, self.inicioConexion[vpn.id] != nil,
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
        guard estados[id] == .conectando else { return }
        Log.escribir("cancelando el intento de conectar \(id)")
        SolicitudCodigo.abiertas[id]?.cancelar()
        guard !IntentosConexion.cancelar(id) else { return }
        // El proceso puede haber terminado justo antes de que `list` confirme
        // el túnel. En ese intervalo ya no hay proceso que cancelar: se detiene
        // explícitamente el túnel que acaba de iniciar.
        Task.detached(priority: .userInitiated) {
            let detencion = try? Self.ejecutar(args: ["stop", id])
            let consulta = try? Self.ejecutar(args: ["list"])
            let confirmada = consulta.map {
                EstadoMotor.confirmaDesconexion([id], codigo: $0.codigo, salida: $0.salida)
            } ?? false
            await MainActor.run {
                self.inicioConexion.removeValue(forKey: id)
                if confirmada {
                    self.estados.removeValue(forKey: id)
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
        inicioConexion[id] != nil || estados[id] == .conectando || SolicitudCodigo.abiertas[id] != nil
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
                         errorPrevio: String? = nil) {
        guard !instalandoAyudante else {
            if desdeGuardado { resumenGuardado?.ayudante = .pendiente("Nuvex lo preparará la próxima vez que conectes.") }
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
                }
            }
        }
    }

    func desconectar(_ vpn: VPNStatus) {
        desconexionSolicitada.insert(vpn.id)
        desconexiones.removeValue(forKey: vpn.id)
        Task.detached(priority: .userInitiated) {
            let resultado = try? Self.ejecutar(args: ["stop", vpn.id])
            await MainActor.run {
                if resultado?.codigo == 0 {
                    self.estados[vpn.id] = .desconectada
                } else {
                    self.desconexionSolicitada.remove(vpn.id)
                    let detail = resultado?.error.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.ultimoError = detail.isEmpty ? "No se pudo desconectar \(vpn.name)." : detail
                }
                self.refrescar()
            }
        }
    }

    /// Descarta el aviso de caída o el error de una fila.
    func descartarAviso(_ id: String) {
        desconexiones.removeValue(forKey: id)
        if case .error = estados[id] { estados.removeValue(forKey: id) }
    }

    func cargarConfiguracion() {
        #if DEBUG
        if esMuestra { return }
        #endif
        Task.detached(priority: .utility) {
            let result = try? Self.ejecutar(args: ["config", "list"])
            guard let result, result.codigo == 0,
                  let data = result.salida.data(using: .utf8),
                  let profiles = try? JSONDecoder().decode([VPNProfile].self, from: data) else {
                // nuvexconfig.py rechaza versiones de profiles.json que no conoce:
                // los guardó una Nuvex más nueva y no deben sobrescribirse.
                let masNuevos = result?.error.contains("versión de configuración no compatible") == true
                await MainActor.run {
                    self.datosMasNuevos = masNuevos
                    self.ultimoError = masNuevos
                        ? "Tus conexiones las guardó una versión más nueva de Nuvex. Actualiza Nuvex para usarlas; no se modificarán."
                        : "No se pudo leer la configuración."
                }
                return
            }
            let statuses = Dictionary(uniqueKeysWithValues: profiles.map {
                ($0.id, Self.passwordStatus(id: $0.id, username: $0.username))
            })
            await MainActor.run {
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
    func guardarConexion(_ perfil: VPNProfile, password: String?) {
        var lista = profiles
        if let i = lista.firstIndex(where: { $0.id == perfil.id }) { lista[i] = perfil }
        else { lista.append(perfil) }
        var passwords: [String: String] = [:]
        if let password, !password.isEmpty { passwords[perfil.id] = password }
        guardarPerfiles(lista, passwords: passwords)
    }

    func eliminarConexion(_ id: String) {
        guardarPerfiles(profiles.filter { $0.id != id }, passwords: [:])
    }

    /// Vuelve a la configuración de una copia de seguridad. Antes guarda una
    /// copia del estado actual, para poder deshacerlo.
    func restaurarCopia(_ copia: CopiaSeguridad) {
        guard let perfiles = Migraciones.perfiles(en: copia.url) else {
            ultimoError = "La copia no contiene conexiones válidas."
            return
        }
        if let activa = vpns.first(where: \.connected) {
            ultimoError = "Desconecta «\(activa.name)» antes de restaurar una copia."
            return
        }
        do {
            _ = try Migraciones.crearCopia(etiqueta: "antes-de-restaurar", base: Preferencias.directorio,
                                           perfiles: URL(fileURLWithPath: Paths.perfiles))
        } catch {
            ultimoError = "No se pudo guardar una copia del estado actual: \(error.localizedDescription)"
            return
        }
        Log.escribir("restaurando la copia \(copia.id)")
        if let datos = try? Data(contentsOf: copia.url.appendingPathComponent("ajustes.json")) {
            do {
                try ArchivoAjustes.guardarAtomico(datos, en: Preferencias.archivo)
                Preferencias.shared.cargar()
            } catch {
                Log.escribir("no se restauraron los ajustes de la copia: \(error.localizedDescription)")
            }
        }
        guardarPerfiles(perfiles, passwords: [:])
    }

    func guardarPerfiles(_ profiles: [VPNProfile], passwords: [String: String]) {
        guard !datosMasNuevos else {
            ultimoError = "Tus conexiones las guardó una versión más nueva de Nuvex. Actualiza Nuvex para cambiarlas."
            return
        }
        let profiles = profiles.map(\.normalizado)
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
                ultimoError = "Al cambiar el usuario de \(profile.name), escribe la contraseña del nuevo usuario."
                return
            }
        }
        if profiles != self.profiles, let active = vpns.first(where: { $0.connected }) {
            ultimoError = "Desconecta \(active.name) antes de cambiar las conexiones. Puedes actualizar las contraseñas sin desconectarte."
            return
        }
        guard let data = try? JSONEncoder().encode(profiles),
              let json = String(data: data, encoding: .utf8) else { return }
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
                let result = try Self.ejecutar(args: ["config", "set-all", json])
                guard result.codigo == 0 else {
                    let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw ErrorVPN(mensaje: detail.isEmpty ? "El configurador terminó con código \(result.codigo)." : detail)
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
                let pasoAyudante: ResumenGuardado.Paso = !shouldInstall ? .noAplica
                    : canInstallNow ? .enCurso
                    : .pendiente("Hay una VPN conectada; Nuvex lo preparará la próxima vez que conectes.")
                await MainActor.run {
                    self.guardandoConfiguracion = false
                    self.resumenGuardado = ResumenGuardado(conexiones: .hecho, contrasenas: pasoContrasenas,
                                                           ayudante: pasoAyudante)
                    let keychainError = keychainErrors.isEmpty ? nil :
                        "Se guardaron las conexiones, pero hubo errores en el Llavero: \(keychainErrors.joined(separator: " "))"
                    self.ultimoError = keychainError
                    self.mensajeConfiguracion = keychainErrors.isEmpty ?
                        (shouldInstall ? (canInstallNow ? "Cambios guardados. Aplicando…" :
                            "Cambios guardados. Nuvex preparará el ayudante al volver a conectar.") :
                            "Cambios guardados.") : nil
                    self.mensajeAyudante = nil
                    for previo in previousProfiles where !profiles.contains(where: { $0.id == previo.id }) {
                        Preferencias.shared.olvidarConexion(previo.id)
                    }
                    self.profiles = profiles
                    self.passwordStatuses = statuses
                    for id in savedPasswordIDs { self.estados.removeValue(forKey: id) }
                    self.refrescar()
                    if shouldInstall && canInstallNow {
                        self.instalarAyudante(desdeGuardado: true, errorPrevio: keychainError)
                    }
                }
            } catch {
                var rollbackFailed = false
                if !configurationSaved {
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
                    self.resumenGuardado = ResumenGuardado(conexiones: .fallo(failure))
                    self.ultimoError = "No se guardaron los cambios: \(failure)"
                }
            }
        }
    }
}
