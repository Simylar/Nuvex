import AppKit
import SwiftUI

/// Recibe enlaces nuvex:// y archivos .nuvexvpn aunque el panel no esté abierto.
final class DelegadoApp: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let modelo = AppActual.modelo else { return true }
        if let solicitud = SolicitudCodigo.abiertas.values.first {
            VentanaCodigo.traerAlFrente(solicitud.perfilID)
            return true
        }
        if Bienvenida.reanudarSiPendiente(modelo: modelo) { return true }
        if modelo.configuracionCargada && modelo.profiles.isEmpty {
            Bienvenida.mostrar(modelo: modelo)
        } else {
            if let id = modelo.conexionParaReabrir {
                AperturaAjustes.abrir(modelo, conexion: id, pagina: .conexion(id))
            } else {
                AperturaAjustes.abrir(modelo, pagina: .general)
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach(AppActual.abrir) }
    }
}

/// Punto de acceso al modelo para lo que llega desde AppKit (archivos, enlaces).
@MainActor
enum AppActual {
    static weak var modelo: VPNModel?
    /// Lo que llega antes de que el modelo exista se atiende al crearlo.
    private static var pendientes: [URL] = []

    static func abrir(_ url: URL) {
        guard let modelo else { pendientes.append(url); return }
        if url.isFileURL {
            guard url.pathExtension.lowercased() == "nuvexvpn" else { return }
            VentanaImportar.mostrar(modelo: modelo, archivo: url)
        } else if url.scheme == "nuvex" {
            modelo.solicitarDesdeEnlace(url)
        }
    }

    static func abrirAjustes(pagina: PaginaAjustes) {
        guard let modelo else { return }
        AperturaAjustes.abrir(modelo, pagina: pagina)
    }

    static func registrar(_ modelo: VPNModel) {
        self.modelo = modelo
        let anteriores = pendientes
        pendientes.removeAll()
        anteriores.forEach(abrir)
    }
}

@main
struct NuvexApp: App {
    @NSApplicationDelegateAdaptor(DelegadoApp.self) private var delegado
    @StateObject private var modelo = VPNModel()
    @StateObject private var borradores = BorradoresAjustes()

    init() {
        #if DEBUG
        let args = CommandLine.arguments
        if args.contains("--verificar-interfaz") {
            VerificacionInterfaz.ejecutar()
            exit(0)
        }
        if let i = args.firstIndex(of: "--captura"), i + 1 < args.count {
            Captura.ejecutar(en: args[i + 1])
            exit(0)
        }
        if args.contains("--guia-estilo") {
            GuiaEstilo.ejecutar()
        }
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PanelVPN(modelo: modelo)
                .onAppear { modelo.arrancar() }
        } label: {
            EtiquetaBarra(modelo: modelo)
        }
        .menuBarExtraStyle(.window)

        Settings {
            ConfigurationView(modelo: modelo, borradores: borradores)
        }
        .commands {
            // La navegación de Ajustes depende de esta columna y no tiene una
            // alternativa cuando se oculta, así que se mantiene siempre visible.
            CommandGroup(replacing: .sidebar) {}
        }
    }
}
