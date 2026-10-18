import AppKit
import SwiftUI

/// Código de verificación encontrado por una fuente automática.
struct CodigoRecibido: Equatable, Sendable {
    let codigo: String
    /// Quién lo envió, para mostrarlo ("noreply@empresa.com").
    let remitente: String
}

/// Pide el código de verificación de una conexión. Compiten varias fuentes y
/// gana la primera: la persona escribiéndolo, el lector de correo y un
/// asistente o la Terminal con `nuvex code`. No guarda el código.
@MainActor
final class SolicitudCodigo: ObservableObject, Identifiable {
    enum EstadoCorreo: Equatable {
        case noConfigurado
        case buscando(desde: Date, cuenta: String)
        case encontrado(remitente: String)
        case sinResultado(String)
    }

    /// Fuente automática de códigos (la añade la lectura de Gmail).
    /// Devuelve nil si no hay nada configurado para esa conexión.
    typealias Lector = @MainActor (_ perfilID: String, _ desde: Date) -> (cuenta: String, tarea: Task<CodigoRecibido?, Never>)?
    static var lector: Lector?

    /// Solicitudes abiertas, por conexión, para que `nuvex code` pueda responder.
    /// Cada cambio se anuncia con `.solicitudCodigoCambio`.
    private(set) static var abiertas: [String: SolicitudCodigo] = [:]

    let perfilID: String
    let nombre: String
    let inicio: Date
    @Published var codigo = ""
    @Published private(set) var estadoCorreo: EstadoCorreo = .noConfigurado
    /// Código del correo a punto de enviarse; se puede detener.
    @Published private(set) var envioAutomatico: CodigoRecibido?

    private var continuacion: CheckedContinuation<String?, Never>?
    private var tareas: [Task<Void, Never>] = []
    private var lectura: Task<CodigoRecibido?, Never>?

    /// Espera el código. Devuelve nil si se cancela o se agota el tiempo.
    static func obtener(perfilID: String, nombre: String, inicio: Date, limite: Duration = .seconds(280)) async -> String? {
        let solicitud = SolicitudCodigo(perfilID: perfilID, nombre: nombre, inicio: inicio)
        abiertas[perfilID] = solicitud
        NotificationCenter.default.post(name: .solicitudCodigoCambio, object: perfilID)
        return await withCheckedContinuation { continuacion in
            solicitud.continuacion = continuacion
            solicitud.empezar(limite: limite)
        }
    }

    #if DEBUG
    /// Solicitud de ejemplo para las capturas: no abre ventanas ni espera.
    static func muestra(nombre: String, codigo: String = "", correo: EstadoCorreo, automatico: Bool = false) -> SolicitudCodigo {
        let solicitud = SolicitudCodigo(perfilID: "muestra", nombre: nombre, inicio: Date())
        solicitud.codigo = codigo
        solicitud.estadoCorreo = correo
        if automatico { solicitud.envioAutomatico = CodigoRecibido(codigo: codigo, remitente: "noreply@empresa.com") }
        return solicitud
    }
    #endif

    private init(perfilID: String, nombre: String, inicio: Date) {
        self.perfilID = perfilID
        self.nombre = nombre
        self.inicio = inicio
    }

    private func empezar(limite: Duration) {
        if let (cuenta, tarea) = Self.lector?(perfilID, inicio) {
            estadoCorreo = .buscando(desde: Date(), cuenta: cuenta)
            tareas.append(Task { [weak self] in
                let recibido = await tarea.value
                guard let self, !Task.isCancelled else { return }
                if let recibido {
                    self.usarDelCorreo(recibido)
                } else {
                    self.estadoCorreo = .sinResultado("No llegó el correo con el código. Escríbelo a mano.")
                }
            })
            lectura = tarea
        }
        // El ayudante abandona el intento a los 300 s; se cierra un poco antes.
        tareas.append(Task { [weak self] in
            try? await Task.sleep(for: limite)
            guard !Task.isCancelled else { return }
            Log.escribir("se agotó el tiempo para escribir el código de \(self?.perfilID ?? "")")
            self?.resolver(nil)
        })
        VentanaCodigo.mostrar(self)
    }

    private func usarDelCorreo(_ recibido: CodigoRecibido) {
        codigo = recibido.codigo
        estadoCorreo = .encontrado(remitente: recibido.remitente)
        envioAutomatico = recibido
        Log.escribir("código de \(perfilID) recibido por correo")
        tareas.append(Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled, self.envioAutomatico == recibido else { return }
            self.resolver(recibido.codigo)
        })
    }

    // MARK: Acciones

    func enviar() {
        let limpio = Self.limpiar(codigo)
        guard !limpio.isEmpty else { return }
        resolver(limpio)
    }

    func cancelar() { resolver(nil) }

    /// Detiene el envío automático para revisar o cambiar el código.
    func detenerEnvio() { envioAutomatico = nil }

    /// Respuesta de `nuvex code` (un asistente o la Terminal).
    func recibirExterno(_ texto: String) -> Bool {
        let limpio = Self.limpiar(texto)
        guard !limpio.isEmpty, continuacion != nil else { return false }
        Log.escribir("código de \(perfilID) recibido desde la Terminal")
        resolver(limpio)
        return true
    }

    private func resolver(_ resultado: String?) {
        guard let continuacion else { return }
        self.continuacion = nil
        tareas.forEach { $0.cancel() }
        tareas.removeAll()
        lectura?.cancel()
        lectura = nil
        codigo = ""
        envioAutomatico = nil
        if Self.abiertas[perfilID] === self { Self.abiertas[perfilID] = nil }
        NotificationCenter.default.post(name: .solicitudCodigoCambio, object: perfilID)
        VentanaCodigo.cerrar(self)
        continuacion.resume(returning: resultado)
    }

    /// Quita espacios y guiones: «482 913» y «482-913» son el mismo código.
    nonisolated static func limpiar(_ texto: String) -> String {
        texto.filter { !$0.isWhitespace && $0 != "-" }
    }
}

extension Notification.Name {
    static let solicitudCodigoCambio = Notification.Name("NuvexSolicitudCodigoCambio")
}

// MARK: - Ventana

@MainActor
enum VentanaCodigo {
    private static var paneles: [String: NSPanel] = [:]
    private static var delegados: [String: Delegado] = [:]

    /// Cerrar la ventana con el botón rojo equivale a Cancelar.
    private final class Delegado: NSObject, NSWindowDelegate {
        weak var solicitud: SolicitudCodigo?
        init(_ solicitud: SolicitudCodigo) { self.solicitud = solicitud }
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { solicitud?.cancelar() }
        }
    }

    static func mostrar(_ solicitud: SolicitudCodigo) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.title = "Código para «\(solicitud.nombre)»"
        panel.contentViewController = NSHostingController(rootView: PanelCodigoView(solicitud: solicitud))
        let delegado = Delegado(solicitud)
        panel.delegate = delegado
        delegados[solicitud.perfilID] = delegado
        paneles[solicitud.perfilID]?.close()
        paneles[solicitud.perfilID] = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    static func cerrar(_ solicitud: SolicitudCodigo) {
        guard let panel = paneles.removeValue(forKey: solicitud.perfilID) else { return }
        panel.delegate = nil
        delegados[solicitud.perfilID] = nil
        panel.close()
    }
}

struct PanelCodigoView: View {
    @ObservedObject var solicitud: SolicitudCodigo
    @FocusState private var enfocado: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "ellipsis.message.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Código para «\(solicitud.nombre)»").font(.headline)
                Text("El servidor pidió un código de verificación. Nuvex no lo guarda.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Código", text: $solicitud.codigo, prompt: Text("123456"))
                .textContentType(.oneTimeCode)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($enfocado)
                .onSubmit { solicitud.enviar() }
                .accessibilityLabel("Código de verificación para \(solicitud.nombre)")
            estadoCorreo
            HStack(spacing: 10) {
                Button("Cancelar", role: .cancel) { solicitud.cancelar() }
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity)
                Button("Conectar") { solicitud.enviar() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(SolicitudCodigo.limpiar(solicitud.codigo).isEmpty)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 360)
        .onAppear { enfocado = true }
    }

    @ViewBuilder
    private var estadoCorreo: some View {
        switch solicitud.estadoCorreo {
        case .noConfigurado:
            EmptyView()
        case .buscando(let desde, let cuenta):
            TimelineView(.periodic(from: desde, by: 1)) { contexto in
                let segundos = max(0, Int(contexto.date.timeIntervalSince(desde)))
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Buscando en \(cuenta)… \(segundos / 60):\(String(format: "%02d", segundos % 60))")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .encontrado(let remitente):
            if solicitud.envioAutomatico != nil {
                HStack(spacing: 6) {
                    Label("Código recibido de \(remitente). Conectando…", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Revisar") { solicitud.detenerEnvio() }
                        .buttonStyle(.link)
                }
                .font(.caption)
            } else {
                Label("Código recibido de \(remitente)", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        case .sinResultado(let mensaje):
            Label(mensaje, systemImage: "envelope.badge")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
