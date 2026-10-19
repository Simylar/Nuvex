import AppKit
import SwiftUI

/// Recibe enlaces nuvex:// y archivos .nuvexvpn aunque el panel no esté abierto.
final class DelegadoApp: NSObject, NSApplicationDelegate {
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
        if let i = args.firstIndex(of: "--captura"), i + 1 < args.count {
            Captura.ejecutar(en: args[i + 1])
            exit(0)
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
