import SwiftUI

@main
struct NuvexApp: App {
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
                .onOpenURL { modelo.solicitarDesdeEnlace($0) }
        } label: {
            EtiquetaBarra(modelo: modelo)
        }
        .menuBarExtraStyle(.window)

        Settings {
            ConfigurationView(modelo: modelo, borradores: borradores)
        }
    }
}
