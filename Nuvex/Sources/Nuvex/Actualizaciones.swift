import AppKit
import Sparkle

/// Una versión publicada que se puede instalar.
struct VersionDisponible: Equatable {
    let version: String
    let compilacion: String
    let tamano: UInt64?
    let fecha: Date?
    /// Notas de la versión en el formato del CHANGELOG.
    let notas: String
    let esBeta: Bool
    let esCritica: Bool

    init(_ item: SUAppcastItem) {
        version = item.displayVersionString
        compilacion = item.versionString
        tamano = item.contentLength > 0 ? item.contentLength : nil
        fecha = item.date
        esBeta = item.channel == "beta"
        esCritica = item.isCriticalUpdate
        let descripcion = item.itemDescription ?? ""
        if item.itemDescriptionFormat == "html" {
            notas = TextoHTMLSeguro.convertir(descripcion)
        } else {
            notas = descripcion.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    init(version: String, compilacion: String = "", tamano: UInt64? = nil, fecha: Date? = nil,
         notas: String, esBeta: Bool = false, esCritica: Bool = false) {
        self.version = version
        self.compilacion = compilacion
        self.tamano = tamano
        self.fecha = fecha
        self.notas = notas
        self.esBeta = esBeta
        self.esCritica = esCritica
    }

}

/// Etapas de una actualización, como en «Actualización de software» de iOS.
enum EstadoActualizacion: Equatable {
    case inactivo
    case buscando
    case alDia
    case disponible(VersionDisponible)
    case descargando(VersionDisponible, recibido: UInt64, total: UInt64?)
    case preparando(VersionDisponible, progreso: Double)
    case lista(VersionDisponible)
    case programada(VersionDisponible)
    case esperando(VersionDisponible, detalle: String)
    case instalando(VersionDisponible)
    case error(String)

    var version: VersionDisponible? {
        switch self {
        case .disponible(let v), .descargando(let v, _, _), .preparando(let v, _),
             .lista(let v), .programada(let v), .esperando(let v, _), .instalando(let v): return v
        default: return nil
        }
    }
}

/// Actualizaciones con Sparkle y una interfaz propia. Sparkle descarga, verifica
/// la firma EdDSA e instala; Nuvex muestra cada etapa y las novedades.
@MainActor
final class Actualizaciones: NSObject, ObservableObject {
    static let claveBeta = "recibirVersionesBeta"
    static let claveNovedadesAlIniciar = "mostrarNovedadesAlIniciar"

    @Published private(set) var estado: EstadoActualizacion = .inactivo
    /// Versión anunciada que el usuario aún no ha abierto (fila del panel).
    @Published private(set) var disponible: String?
    @Published private(set) var puedeBuscar = false
    @Published private(set) var verificacionInicial: ResultadoInstalacionActualizacion?
    /// false si esta compilación no tiene clave pública ni dirección de avisos.
    private(set) var configuradas: Bool

    weak var modelo: VPNModel?
    private var updater: SPUUpdater?
    private var observacion: NSKeyValueObservation?
    private var esperaReinicio: Task<Void, Never>?
    private var instalarProgramadaAhora: (() -> Void)?
    private var instalarAlEstarLista = false
    private var candidatoActual: CandidatoActualizacion?
    /// Distingue el registro creado por este proceso de un diagnóstico antiguo
    /// que todavía no se le ha mostrado al usuario.
    private var instalacionRegistradaEnSesion = false

    // Respuestas pendientes que Sparkle espera.
    private var responderVersion: ((SPUUserUpdateChoice) -> Void)?
    private var responderLista: ((SPUUserUpdateChoice) -> Void)?
    private var cancelarDescarga: (() -> Void)?
    private var cancelarBusqueda: (() -> Void)?
    private var busquedaCanceladaPorUsuario = false

    init(modelo: VPNModel?) {
        self.modelo = modelo
        verificacionInicial = RegistroInstalacionActualizacion.resolver()
        let info = Bundle.main.infoDictionary ?? [:]
        configuradas = info["SUPublicEDKey"] is String && info["SUFeedURL"] is String
        super.init()
        if case .incompleta(_, _) = verificacionInicial {
            estado = .error(verificacionInicial?.mensaje ?? "No se pudo verificar la última actualización.")
        }
        guard configuradas else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        self.updater = updater
        // SPUUpdater publica sus cambios en el hilo principal.
        observacion = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, cambio in
            let puede = cambio.newValue ?? false
            Task { @MainActor in self?.puedeBuscar = puede }
        }
        do {
            try updater.start()
        } catch {
            Log.escribir("no se pudo iniciar el buscador de actualizaciones: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    /// Estado fijo para las capturas de depuración, sin Sparkle.
    init(muestra estado: EstadoActualizacion, disponible: String? = nil) {
        configuradas = true
        verificacionInicial = nil
        super.init()
        self.estado = estado
        self.disponible = disponible
        puedeBuscar = true
    }
    #endif

    /// Pantallas de «Actualización de software» abiertas ahora mismo. Mientras
    /// haya alguna, lo nuevo se muestra ahí y no como aviso.
    private var pantallasAbiertas = 0
    var pantallaVisible: Bool { pantallasAbiertas > 0 }

    func pantallaAparecio() {
        pantallasAbiertas += 1
        if case .incompleta(_, _)? = verificacionInicial {
            RegistroInstalacionActualizacion.confirmarLectura()
        }
    }
    func pantallaDesaparecio() { pantallasAbiertas = max(0, pantallasAbiertas - 1) }

    // MARK: Acciones

    /// Busca ahora. El resultado aparece en la pantalla que ya está abierta;
    /// no abre ninguna ventana.
    func buscar() {
        // Con una versión ya anunciada o descargada, no se pierde de vista.
        guard responderVersion == nil, responderLista == nil else { return }
        guard let updater, updater.canCheckForUpdates else { return }
        busquedaCanceladaPorUsuario = false
        estado = .buscando
        updater.checkForUpdates()
    }

    /// Lleva a Ajustes › Actualización de software (una sola ventana, la de
    /// Ajustes) y busca si no hay ya una versión anunciada.
    func mostrar() {
        if let modelo { AperturaAjustes.abrir(modelo, pagina: .actualizacion) }
        if responderVersion == nil && responderLista == nil,
           estado == .inactivo || estado == .alDia {
            buscar()
        }
    }

    func actualizarAhora() {
        if let candidatoActual {
            do {
                let preparada = responderLista != nil || instalarProgramadaAhora != nil
                    || estado.esPreparada
                if !preparada {
                    try Self.validar(candidatoActual, permiteBeta: recibirBeta)
                }
            } catch {
                responderVersion?(.dismiss)
                responderLista?(.dismiss)
                responderVersion = nil
                responderLista = nil
                instalarProgramadaAhora = nil
                instalarAlEstarLista = false
                self.candidatoActual = nil
                cancelarRegistroDeSesion()
                estado = .error(error.localizedDescription)
                return
            }
        }
        if let responder = responderLista {
            responderLista = nil
            instalarAlEstarLista = false
            prepararReinicio()
            if let version = estado.version { estado = .instalando(version) }
            responder(.install)
        } else if let instalar = instalarProgramadaAhora {
            instalarAlEstarLista = false
            prepararReinicio()
            if let version = estado.version { estado = .instalando(version) }
            instalar()
        } else if let responder = responderVersion {
            responderVersion = nil
            instalarAlEstarLista = true
            responder(.install)
        } else if let updater, updater.canCheckForUpdates {
            // Se pospuso antes: una búsqueda nueva retoma la versión y se instala.
            instalarAlEstarLista = true
            updater.checkForUpdates()
        }
    }

    func recordarMasTarde() {
        responderVersion?(.dismiss)
        responderVersion = nil
        instalarAlEstarLista = false
        disponible = estado.version?.version
        estado = .inactivo
    }

    func omitirVersion() {
        responderVersion?(.skip)
        responderVersion = nil
        instalarAlEstarLista = false
        candidatoActual = nil
        disponible = nil
        estado = .alDia
    }

    /// Deja la versión descargada para instalarla al cerrar Nuvex.
    func instalarAlCerrar() {
        guard let version = estado.version else { return }
        UserDefaults.standard.set(true, forKey: Self.claveNovedadesAlIniciar)
        registrarInstalacion(version: version.version, compilacion: version.compilacion)
        responderLista?(.dismiss)
        responderLista = nil
        instalarAlEstarLista = false
        estado = .programada(version)
    }

    func cancelar() {
        if case .buscando = estado {
            busquedaCanceladaPorUsuario = true
        }
        cancelarDescarga?()
        cancelarDescarga = nil
        cancelarBusqueda?()
        cancelarBusqueda = nil
        instalarAlEstarLista = false
        instalarProgramadaAhora = nil
        candidatoActual = nil
        estado = .inactivo
    }

    private func prepararReinicio() {
        // La versión nueva mostrará sus novedades al abrirse.
        UserDefaults.standard.set(true, forKey: Self.claveNovedadesAlIniciar)
    }

    private func registrarInstalacion(version: String, compilacion: String) {
        if RegistroInstalacionActualizacion.comenzar(version: version, compilacion: compilacion) {
            instalacionRegistradaEnSesion = true
        }
    }

    private func cancelarRegistroDeSesion() {
        guard instalacionRegistradaEnSesion else { return }
        RegistroInstalacionActualizacion.cancelar()
        instalacionRegistradaEnSesion = false
    }

    // MARK: Preferencias

    var buscarAutomaticamente: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    var instalarAutomaticamente: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    var recibirBeta: Bool {
        get { UserDefaults.standard.bool(forKey: Self.claveBeta) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.claveBeta)
            objectWillChange.send()
            updater?.resetUpdateCycleAfterShortDelay()
        }
    }

    var ultimaBusqueda: Date? { updater?.lastUpdateCheckDate }

    private static func candidato(_ item: SUAppcastItem) -> CandidatoActualizacion {
        CandidatoActualizacion(version: item.displayVersionString,
                               compilacion: item.versionString,
                               canal: item.channel,
                               direccion: item.fileURL,
                               tipoInstalacion: item.installationType,
                               tamano: item.contentLength > 0 ? item.contentLength : nil)
    }

    private static func validar(_ candidato: CandidatoActualizacion, permiteBeta: Bool,
                                comprobarEspacio: Bool = true) throws {
        let capacidades: [Int64] = comprobarEspacio
            ? [Bundle.main.bundleURL, FileManager.default.temporaryDirectory].compactMap {
                try? $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage
            }
            : []
        try PreparacionActualizacion.validar(candidato, actual: .actual,
                                             permiteBeta: permiteBeta,
                                             capacidadDisponible: comprobarEspacio ? capacidades.min() : nil)
    }
}

private extension EstadoActualizacion {
    var esPreparada: Bool {
        switch self {
        case .lista, .programada, .esperando, .instalando: return true
        default: return false
        }
    }
}

// MARK: - Delegado

extension Actualizaciones: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        recibirBeta ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        let candidato = Self.candidato(updateItem)
        try Self.validar(candidato, permiteBeta: recibirBeta)
        candidatoActual = candidato
    }

    /// Reiniciar la app no corta los túneles (los mantiene el ayudante), pero sí
    /// interrumpiría una conexión en curso, un código pendiente o un guardado.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let modelo, modelo.ocupado else { return false }
        Log.escribir("actualización \(item.displayVersionString) aplazada hasta terminar la operación en curso")
        let version = VersionDisponible(item)
        estado = .esperando(version, detalle: modelo.motivoBloqueoActualizacion)
        esperaReinicio?.cancel()
        esperaReinicio = Task { @MainActor [weak self] in
            while let modelo = self?.modelo, modelo.ocupado {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled, self.modelo != nil else { return }
            self.estado = .instalando(version)
            installHandler()
        }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = VersionDisponible(item)
        candidatoActual = Self.candidato(item)
        instalarProgramadaAhora = immediateInstallationBlock
        instalarAlEstarLista = false
        estado = .programada(version)
        disponible = version.version
        prepararReinicio()
        registrarInstalacion(version: item.displayVersionString,
                             compilacion: item.versionString)
        Log.escribir("actualización \(item.displayVersionString) preparada para instalarse al cerrar")
        if !pantallaVisible {
            VPNNotifications.shared.actualizacionDisponible(version: version.version)
        }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        prepararReinicio()
        registrarInstalacion(version: item.displayVersionString,
                             compilacion: item.versionString)
        Log.escribir("instalando Nuvex \(item.displayVersionString)")
    }
}

// MARK: - Interfaz propia

extension Actualizaciones: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        if busquedaCanceladaPorUsuario {
            cancellation()
            return
        }
        cancelarBusqueda = cancellation
        estado = .buscando
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancelarBusqueda = nil
        if busquedaCanceladaPorUsuario {
            busquedaCanceladaPorUsuario = false
            candidatoActual = nil
            estado = .inactivo
            reply(.dismiss)
            return
        }
        let version = VersionDisponible(appcastItem)
        candidatoActual = Self.candidato(appcastItem)
        let etapa: EtapaPresentacionActualizacion
        switch state.stage {
        case .installing: etapa = .instalando
        case .downloaded: etapa = .descargada
        default: etapa = .sinDescargar
        }
        switch PoliticaPresentacionActualizacion.accion(
            etapa: etapa, iniciadaPorUsuario: state.userInitiated,
            instalarAhora: instalarAlEstarLista) {
        case .iniciarDescarga:
            reply(.install)
        case .instalarAhora:
            instalarAlEstarLista = false
            prepararReinicio()
            estado = .instalando(version)
            reply(.install)
        case .mostrarDisponible:
            estado = .disponible(version)
            responderVersion = reply
        case .mantenerProgramada:
            instalarAlEstarLista = false
            estado = .programada(version)
            responderLista = nil
            reply(.dismiss)
        }
        let debeAvisar: Bool
        switch estado {
        case .disponible, .lista: debeAvisar = true
        default: debeAvisar = false
        }
        if !state.userInitiated && !pantallaVisible && debeAvisar {
            // Comprobación programada: aviso discreto, sin abrir ventanas.
            disponible = version.version
            VPNNotifications.shared.actualizacionDisponible(version: version.version)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancelarBusqueda = nil
        if busquedaCanceladaPorUsuario {
            busquedaCanceladaPorUsuario = false
            estado = .inactivo
            acknowledgement()
            return
        }
        estado = .alDia
        candidatoActual = nil
        instalarAlEstarLista = false
        disponible = nil
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancelarBusqueda = nil
        cancelarDescarga = nil
        if busquedaCanceladaPorUsuario {
            busquedaCanceladaPorUsuario = false
            estado = .inactivo
            acknowledgement()
            return
        }
        esperaReinicio?.cancel()
        esperaReinicio = nil
        instalarProgramadaAhora = nil
        instalarAlEstarLista = false
        cancelarRegistroDeSesion()
        Log.escribir("error de actualización: \(error.localizedDescription)")
        estado = .error(Self.mensaje(error))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelarDescarga = cancellation
        if let version = estado.version { estado = .descargando(version, recibido: 0, total: version.tamano) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        if case .descargando(let version, let recibido, _) = estado {
            estado = .descargando(version, recibido: recibido, total: expectedContentLength > 0 ? expectedContentLength : version.tamano)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if case .descargando(let version, let recibido, let total) = estado {
            estado = .descargando(version, recibido: recibido + length, total: total)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelarDescarga = nil
        if let version = estado.version { estado = .preparando(version, progreso: 0) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        if let version = estado.version { estado = .preparando(version, progreso: progress) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let version = estado.version else { reply(.dismiss); return }
        if instalarAlEstarLista {
            // Se pulsó «Actualizar ahora»: se instala sin volver a preguntar.
            instalarAlEstarLista = false
            estado = .instalando(version)
            prepararReinicio()
            reply(.install)
        } else {
            estado = .lista(version)
            responderLista = reply
            disponible = version.version
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        if let version = estado.version { estado = .instalando(version) }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        busquedaCanceladaPorUsuario = false
        estado = .alDia
        candidatoActual = nil
        instalarProgramadaAhora = nil
        instalarAlEstarLista = false
        instalacionRegistradaEnSesion = false
        disponible = nil
        acknowledgement()
    }

    func showUpdateInFocus() {
        if let modelo { AperturaAjustes.abrir(modelo, pagina: .actualizacion) }
    }

    func dismissUpdateInstallation() {
        busquedaCanceladaPorUsuario = false
        cancelarDescarga = nil
        cancelarBusqueda = nil
        responderVersion = nil
        responderLista = nil
        esperaReinicio?.cancel()
        esperaReinicio = nil
        if case .programada = estado {
            // Sparkle conserva la instalación para el cierre de la app.
            return
        }
        cancelarRegistroDeSesion()
        instalarProgramadaAhora = nil
        instalarAlEstarLista = false
        switch estado {
        case .buscando, .descargando, .preparando, .instalando: estado = .inactivo
        default: break
        }
    }

    private static func mensaje(_ error: any Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "No hay conexión con el servidor de actualizaciones. Revisa tu conexión a Internet."
        }
        return "No se pudo completar la actualización: \(nsError.localizedDescription)"
    }
}
