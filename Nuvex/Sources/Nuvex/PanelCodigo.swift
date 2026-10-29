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
        /// `aviso`: un problema pasajero mientras se sigue buscando.
        case buscando(desde: Date, cuenta: String, aviso: ProblemaGmail? = nil)
        case encontrado(remitente: String)
        case sinResultado(String)
        /// No se pudo leer el correo; la persona puede resolverlo y reintentar.
        case problema(ProblemaGmail)
    }

    /// Fuente automática de códigos (la añade la lectura de Gmail).
    /// Distingue una conexión sin lector de un problema antes de iniciar la búsqueda.
    typealias Lector = @MainActor (_ perfilID: String, _ desde: Date,
                                   _ alCambiar: @escaping @MainActor (ProblemaGmail?) -> Void)
        -> InicioLectura
    enum InicioLectura {
        case noConfigurado
        case problema(ProblemaGmail)
        case disponible(cuenta: String, tarea: Task<LectorGmail.Resultado, Never>)
    }
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
    private var lectura: Task<LectorGmail.Resultado, Never>?
    private var tareaLectura: Task<Void, Never>?

    /// Espera el código. Devuelve nil si se cancela o se agota el tiempo.
    static func obtener(perfilID: String, nombre: String, inicio: Date, limite: Duration = .seconds(280),
                        alAgotarse: @escaping @MainActor () -> Void = {}) async -> String? {
        let solicitud = SolicitudCodigo(perfilID: perfilID, nombre: nombre, inicio: inicio)
        abiertas[perfilID] = solicitud
        NotificationCenter.default.post(name: .solicitudCodigoCambio, object: perfilID)
        return await withCheckedContinuation { continuacion in
            solicitud.continuacion = continuacion
            solicitud.empezar(limite: limite, alAgotarse: alAgotarse)
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

    private func empezar(limite: Duration, alAgotarse: @escaping @MainActor () -> Void) {
        empezarLectura()
        // El ayudante abandona el intento a los 300 s; se cierra un poco antes.
        tareas.append(Task { [weak self] in
            try? await Task.sleep(for: limite)
            guard !Task.isCancelled else { return }
            Log.escribir("se agotó el tiempo para escribir el código de \(self?.perfilID ?? "")")
            alAgotarse()
            self?.resolver(nil)
        })
        VentanaCodigo.mostrar(self)
    }

    /// Busca el código en el correo. Se puede repetir tras resolver un problema.
    private func empezarLectura() {
        lectura?.cancel()
        tareaLectura?.cancel()
        let alCambiar: @MainActor (ProblemaGmail?) -> Void = { [weak self] aviso in
            guard let self, case .buscando(let desde, let cuenta, _) = self.estadoCorreo else { return }
            self.estadoCorreo = .buscando(desde: desde, cuenta: cuenta, aviso: aviso)
        }
        let cuenta: String
        let tarea: Task<LectorGmail.Resultado, Never>
        switch Self.lector?(perfilID, inicio, alCambiar) ?? .noConfigurado {
        case .noConfigurado: estadoCorreo = .noConfigurado; return
        case .problema(let problema): estadoCorreo = .problema(problema); return
        case .disponible(let nombre, let lectura): cuenta = nombre; tarea = lectura
        }
        estadoCorreo = .buscando(desde: Date(), cuenta: cuenta)
        lectura = tarea
        tareaLectura = Task { [weak self] in
            let resultado = await tarea.value
            guard let self, !Task.isCancelled, self.continuacion != nil else { return }
            switch resultado {
            case .codigo(let recibido):
                self.usarDelCorreo(recibido)
            case .sinCorreo:
                self.estadoCorreo = .sinResultado("No llegó el correo con el código. Escríbelo a mano o vuelve a buscar.")
            case .problema(let problema):
                self.estadoCorreo = .problema(problema)
            }
        }
    }

    /// Reinicia sondeos afectados por reposo o pérdida de conectividad. El
    /// límite global de la solicitud sigue vigente y cancelará esta tarea.
    static func reanudarLecturasInterrumpidas() {
        for solicitud in abiertas.values where solicitud.continuacion != nil {
            switch solicitud.estadoCorreo {
            case .buscando, .sinResultado:
                solicitud.empezarLectura()
            case .problema(let problema) where !problema.definitivo:
                solicitud.empezarLectura()
            case .noConfigurado, .encontrado, .problema:
                break
            }
        }
    }

    /// Vuelve a buscar en el correo (tras iniciar sesión, activar la API…).
    func reintentarCorreo() {
        guard continuacion != nil else { return }
        envioAutomatico = nil
        empezarLectura()
    }

    private func usarDelCorreo(_ recibido: CodigoRecibido) {
        let recibido = CodigoRecibido(codigo: Self.limpiar(recibido.codigo), remitente: recibido.remitente)
        guard ExtractorCodigo.codigoValido(recibido.codigo) else { return }
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
        guard ExtractorCodigo.codigoValido(limpio) else { return }
        resolver(limpio)
    }

    func cancelar() { resolver(nil) }

    /// Detiene el envío automático para revisar o cambiar el código.
    func detenerEnvio() { envioAutomatico = nil }

    /// Respuesta de `nuvex code` (un asistente o la Terminal).
    func recibirExterno(_ texto: String) -> Bool {
        let limpio = Self.limpiar(texto)
        guard ExtractorCodigo.codigoValido(limpio), continuacion != nil else { return false }
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
        tareaLectura?.cancel()
        tareaLectura = nil
        codigo = ""
        envioAutomatico = nil
        if Self.abiertas[perfilID] === self { Self.abiertas[perfilID] = nil }
        NotificationCenter.default.post(name: .solicitudCodigoCambio, object: perfilID)
        VentanaCodigo.cerrar(self)
        continuacion.resume(returning: resultado)
    }

    /// Misma regla que el lector y la Terminal, sin alterar tokens alfanuméricos.
    nonisolated static func limpiar(_ texto: String) -> String {
        ExtractorCodigo.normalizar(texto)
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

    static func traerAlFrente(_ id: String) {
        guard let panel = paneles[id] else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Cerrar la ventana con el botón rojo equivale a Cancelar.
    private final class Delegado: NSObject, NSWindowDelegate {
        weak var solicitud: SolicitudCodigo?
        init(_ solicitud: SolicitudCodigo) { self.solicitud = solicitud }
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { solicitud?.cancelar() }
        }

        func windowDidChangeScreen(_ notification: Notification) {
            guard let panel = notification.object as? NSPanel else { return }
            MainActor.assumeIsolated { VentanaCodigo.ajustar(panel) }
        }
    }

    static func mostrar(_ solicitud: SolicitudCodigo) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Tamano.codigoAnchoIdeal,
                                                height: Tamano.codigoAltoIdeal),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        // El código pertenece a una operación en curso: debe seguir visible
        // sobre las ventanas normales aunque la persona cambie de aplicación.
        // `.floating` no invade los niveles reservados de menús y alertas de
        // macOS, a diferencia de niveles globales más agresivos.
        panel.level = GeometriaVentanaCodigo.nivelVentana
        panel.isFloatingPanel = GeometriaVentanaCodigo.esPanelFlotante
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isRestorable = false
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.title = "Código para «\(solicitud.nombre)»"
        panel.contentViewController = NSHostingController(rootView: PanelCodigoView(solicitud: solicitud))
        let delegado = Delegado(solicitud)
        panel.delegate = delegado
        delegados[solicitud.perfilID] = delegado
        paneles[solicitud.perfilID]?.close()
        paneles[solicitud.perfilID] = panel
        ajustar(panel, indice: max(0, paneles.count - 1))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    fileprivate static func ajustar(_ panel: NSPanel, indice: Int = 0) {
        let punto = NSEvent.mouseLocation
        let pantalla = panel.screen
            ?? NSScreen.screens.first(where: { NSMouseInRect(punto, $0.frame, false) })
            ?? NSApp.keyWindow?.screen
            ?? NSScreen.main
        guard let area = pantalla?.visibleFrame else { return }
        // El alto ideal ya contempla todos los estados habituales. Antes se
        // usaba el 62 % de la pantalla y en escritorios grandes la ventana
        // crecía hasta 560 pt aunque el contenido no lo necesitara.
        let alto = GeometriaVentanaCodigo.altoInicial(areaVisible: area)
        let ancho = min(Tamano.codigoAnchoIdeal, max(Tamano.codigoAnchoMinimo, area.width - Espacio.pantalla * 2))
        panel.contentMinSize = NSSize(width: min(Tamano.codigoAnchoMinimo, ancho),
                                      height: min(Tamano.codigoAltoMinimo, alto))
        panel.contentMaxSize = NSSize(width: max(ancho, Tamano.codigoAnchoMinimo),
                                      height: min(Tamano.codigoAltoMaximo, area.height - Espacio.pantalla))
        panel.setFrame(GeometriaVentanaCodigo.marco(
            areaVisible: area,
            tamanoIdeal: NSSize(width: ancho, height: alto),
            indice: indice
        ), display: true)
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
        ScrollView {
            VStack(spacing: Espacio.l) {
                IconoCuadrado(simbolo: "ellipsis.message.fill", color: Paleta.acento, lado: Tamano.iconoDestacado)
                    .sombra(.sutil)
                VStack(spacing: Espacio.xs) {
                    Text("Código para «\(solicitud.nombre)»").font(Tipo.encabezado)
                    Text("El servidor pidió un código de verificación. Nuvex no lo guarda.")
                        .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Código", text: $solicitud.codigo, prompt: Text("123456"))
                    .textContentType(.oneTimeCode)
                    .font(Tipo.codigo)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .campoDestacado(enfocado: enfocado)
                    .focused($enfocado)
                    .onSubmit { solicitud.enviar() }
                    .accessibilityLabel("Código de verificación para \(solicitud.nombre)")
                estadoCorreo
                HStack(spacing: Espacio.m) {
                    Button(role: .cancel) { solicitud.cancelar() } label: {
                        Text("Cancelar").frame(maxWidth: .infinity)
                    }
                    .estiloBoton(.secundario)
                    .keyboardShortcut(.cancelAction)
                    Button { solicitud.enviar() } label: {
                        Text("Conectar").frame(maxWidth: .infinity)
                    }
                    .estiloBoton(.principal)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ExtractorCodigo.codigoValido(SolicitudCodigo.limpiar(solicitud.codigo)))
                }
                .controlSize(.large)
            }
            .padding(.horizontal, Espacio.xxxl)
            .padding(.top, Espacio.bloque)
            .padding(.bottom, Espacio.xxl)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: Tamano.codigoAnchoMinimo, idealWidth: Tamano.codigoAnchoIdeal,
               minHeight: Tamano.codigoAltoMinimo, idealHeight: Tamano.codigoAltoIdeal)
        .fondoVentana()
        .onAppear { enfocado = true }
    }

    @ViewBuilder
    private var estadoCorreo: some View {
        switch solicitud.estadoCorreo {
        case .noConfigurado:
            EmptyView()
        case .buscando(let desde, let cuenta, let aviso):
            VStack(spacing: Espacio.xs) {
                TimelineView(.periodic(from: desde, by: 1)) { contexto in
                    let segundos = max(0, Int(contexto.date.timeIntervalSince(desde)))
                    HStack(spacing: Espacio.s) {
                        ProgressView().controlSize(.small)
                        Text("Buscando en \(cuenta)… \(segundos / 60):\(String(format: "%02d", segundos % 60))")
                            .monospacedDigit()
                    }
                    .font(Tipo.nota)
                    .foregroundStyle(Paleta.textoSecundario)
                }
                if let aviso {
                    Text("\(aviso.titulo). Reintentando…")
                        .font(Tipo.nota)
                        .foregroundStyle(Paleta.avisoTexto)
                        .help(aviso.detalle)
                }
            }
        case .encontrado(let remitente):
            if solicitud.envioAutomatico != nil {
                HStack(spacing: Espacio.s) {
                    Label("Código recibido de \(remitente). Conectando…", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Paleta.exitoTexto)
                    Button("Revisar") { solicitud.detenerEnvio() }
                        .buttonStyle(.link)
                }
                .font(Tipo.nota)
            } else {
                Label("Código recibido de \(remitente)", systemImage: "checkmark.circle.fill")
                    .font(Tipo.nota).foregroundStyle(Paleta.exitoTexto)
            }
        case .sinResultado(let mensaje):
            VStack(spacing: Espacio.xs) {
                Label(mensaje, systemImage: "envelope.badge")
                    .font(Tipo.nota).foregroundStyle(Paleta.avisoTexto)
                    .multilineTextAlignment(.center)
                Button("Volver a buscar") { solicitud.reintentarCorreo() }
                    .buttonStyle(.link).font(Tipo.nota)
            }
        case .problema(let problema):
            VStack(spacing: Espacio.xs) {
                Label(problema.titulo, systemImage: "exclamationmark.triangle.fill")
                    .font(Tipo.nota.weight(.semibold)).foregroundStyle(Paleta.avisoTexto)
                Text(problema.detalle + " Mientras tanto, puedes escribir el código.")
                    .font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Espacio.l) {
                    switch problema.accion {
                    case .conexion:
                        Button("Revisar conexión") { AppActual.abrirAjustes(pagina: .conexion(solicitud.perfilID)) }
                    case .cuentaGoogle:
                        Button("Abrir Cuenta de Google") { AppActual.abrirAjustes(pagina: .cuentaGoogle) }
                    case .activarAPI:
                        Button("Activar la Gmail API") { NSWorkspace.shared.open(ProblemaGmail.consolaGmailAPI) }
                    case .reintentar:
                        EmptyView()
                    }
                    Button("Volver a buscar") { solicitud.reintentarCorreo() }
                }
                .buttonStyle(.link).font(Tipo.nota)
            }
        }
    }
}
