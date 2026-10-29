import AppKit
import Network

/// Observa únicamente transiciones que requieren reconciliar estado. No
/// intenta ejecutar trabajo durante la suspensión real: macOS detiene CPU y
/// red; Nuvex reanuda y verifica al despertar.
@MainActor
final class CicloVidaMac {
    private weak var modelo: VPNModel?
    private var observadores: [NSObjectProtocol] = []
    private var inicioSuspension: Date?
    private var monitorRed: MonitorRed?

    init(modelo: VPNModel) {
        self.modelo = modelo
    }

    func iniciar() {
        guard observadores.isEmpty else { return }
        let centro = NSWorkspace.shared.notificationCenter
        observadores.append(centro.addObserver(forName: NSWorkspace.willSleepNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.inicioSuspension = Date()
                Log.escribir("ciclo estado=suspension_inminente")
            }
        })
        observadores.append(centro.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reanudar(origen: "despertar") }
        })
        observadores.append(centro.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.escribir("ciclo estado=sesion_activa")
                self?.modelo?.refrescar()
            }
        })
        monitorRed = MonitorRed { [weak self] disponible, recuperada in
            Task { @MainActor in
                self?.modelo?.actualizarDisponibilidadRed(disponible)
                if recuperada { self?.reanudar(origen: "red_recuperada", reiniciarCorreo: true) }
            }
        }
        monitorRed?.iniciar()
    }

    func detener() {
        let centro = NSWorkspace.shared.notificationCenter
        observadores.forEach(centro.removeObserver)
        observadores.removeAll()
        monitorRed?.detener()
        monitorRed = nil
    }

    private func reanudar(origen: String, reiniciarCorreo: Bool = true) {
        let duracion = inicioSuspension.map { max(0, Int(Date().timeIntervalSince($0))) }
        inicioSuspension = nil
        let sufijo = duracion.map { " suspension_s=\($0)" } ?? ""
        Log.escribir("ciclo estado=\(origen)\(sufijo)")
        modelo?.control?.reanudarSiHaceFalta()
        modelo?.refrescar()
        if reiniciarCorreo { SolicitudCodigo.reanudarLecturasInterrumpidas() }
    }
}

/// NWPathMonitor consume muy pocos recursos y solo se usa para adelantar la
/// recuperación después de una pérdida de red; no reemplaza los timeouts ni
/// los reintentos de cada operación.
private final class MonitorRed: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let cola = DispatchQueue(label: "local.gertcode.nuvex.red", qos: .utility)
    private let cerrojo = NSLock()
    private var estadoAnterior: NWPath.Status?
    private let alCambiar: @Sendable (Bool, Bool) -> Void

    init(alCambiar: @escaping @Sendable (Bool, Bool) -> Void) {
        self.alCambiar = alCambiar
    }

    func iniciar() {
        monitor.pathUpdateHandler = { [weak self] ruta in
            guard let self else { return }
            cerrojo.lock()
            let anterior = estadoAnterior
            estadoAnterior = ruta.status
            cerrojo.unlock()
            alCambiar(ruta.status == .satisfied,
                      anterior != nil && anterior != .satisfied && ruta.status == .satisfied)
        }
        monitor.start(queue: cola)
    }

    func detener() {
        monitor.cancel()
    }
}
