import AppKit
import SwiftUI

/// Ventana de primer uso. Se crea con AppKit porque una app de barra de menús
/// no tiene escena desde la que abrir ventanas al arrancar.
@MainActor
enum Bienvenida {
    private static var ventana: NSWindow?

    static func mostrar(modelo: VPNModel) {
        let ventana = ventana ?? crearVentana()
        Self.ventana = ventana
        // Cada apertura empieza desde el primer paso.
        ventana.contentViewController = NSHostingController(
            rootView: BienvenidaView(modelo: modelo, cerrar: { ventana.close() }))
        ventana.center()
        NSApp.activate(ignoringOtherApps: true)
        ventana.makeKeyAndOrderFront(nil)
    }

    private static func crearVentana() -> NSWindow {
        let ventana = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                               styleMask: [.titled, .closable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        ventana.title = "Bienvenida a Nuvex"
        ventana.titlebarAppearsTransparent = true
        ventana.titleVisibility = .hidden
        ventana.isMovableByWindowBackground = true
        ventana.isReleasedWhenClosed = false
        return ventana
    }
}

struct BienvenidaView: View {
    @ObservedObject var modelo: VPNModel
    let cerrar: () -> Void

    private enum Paso { case inicio, formulario, preparando, listo }

    @State private var paso: Paso = .inicio
    @State private var perfil = VPNProfile.nuevo()
    @State private var password = ""
    @State private var intento = false
    @State private var errorGuardado: String?
    @State private var avisoAyudante: String?

    private var busy: Bool { modelo.guardandoConfiguracion || modelo.instalandoAyudante }

    var body: some View {
        VStack(spacing: 0) {
            switch paso {
            case .inicio: inicio
            case .formulario: formulario
            case .preparando: preparando
            case .listo: listo
            }
        }
        .frame(width: 460)
        .animation(.snappy(duration: 0.25), value: paso)
        .onChange(of: busy) { antes, ahora in
            // Al terminar de guardar (y de instalar el ayudante), decide el paso.
            guard paso == .preparando, antes, !ahora else { return }
            if modelo.profiles.contains(where: { $0.id == perfil.id }) {
                avisoAyudante = modelo.ultimoError
                password = ""
                paso = .listo
            } else {
                errorGuardado = modelo.ultimoError ?? "No se pudo guardar la conexión."
                paso = .formulario
            }
        }
    }

    // MARK: Pasos

    private var inicio: some View {
        VStack(spacing: 14) {
            if let logo = Paths.logo {
                Image(nsImage: logo).resizable().frame(width: 64, height: 64)
            }
            Text("Te damos la bienvenida a Nuvex")
                .font(.title2).fontWeight(.bold)
            Text("Conecta tus VPN Fortinet desde la barra de menús. Configurarlo lleva un par de minutos.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                PasoBienvenida(numero: 1, titulo: "Añade tu servidor y usuario",
                               detalle: "La contraseña se guarda en el Llavero de macOS.")
                PasoBienvenida(numero: 2, titulo: "Autoriza el ayudante de red",
                               detalle: "macOS pedirá tu contraseña de administrador una vez.")
                PasoBienvenida(numero: 3, titulo: "Conecta desde la barra de menús",
                               detalle: "Busca el icono de Nuvex arriba a la derecha.")
            }
            .padding(.vertical, 6)
            Button("Añadir primera conexión") { paso = .formulario }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Button("Ahora no", action: cerrar)
                .buttonStyle(.link)
        }
        .padding(.horizontal, 36)
        .padding(.top, 40)
        .padding(.bottom, 26)
    }

    private var formulario: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Tu primera conexión").font(.title3).fontWeight(.semibold)
                Text("Podrás ajustar rutas, DNS y más opciones en Ajustes.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 34)
            Form {
                Section {
                    TextField("Nombre", text: $perfil.name, prompt: Text("Oficina"))
                    TextField("Servidor", text: $perfil.server, prompt: Text("vpn.empresa.com:443"))
                        .textContentType(.URL)
                }
                Section {
                    TextField("Usuario", text: $perfil.username, prompt: Text("usuario"))
                        .textContentType(.username)
                    SecureField("Contraseña", text: $password, prompt: Text("Contraseña de la VPN"))
                }
                Section {
                    Picker("Confianza TLS", selection: $perfil.trust) {
                        Text("Certificados del sistema").tag("system")
                        Text("Certificado incluido (Prepa)").tag("bundle")
                    }
                } footer: {
                    Text("Para fijar una huella SHA-256, usa Ajustes después de guardar.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 300)

            VStack(alignment: .leading, spacing: 8) {
                if let mensaje = mensajeFormulario {
                    Label(mensaje, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(errorGuardado != nil ? .red : .orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Atrás") { paso = .inicio }
                    Spacer()
                    Button("Guardar y continuar", action: guardar)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    private var mensajeFormulario: String? {
        if let errorGuardado { return errorGuardado }
        guard intento else { return nil }
        if let motivo = Validacion.motivo(perfil) { return motivo }
        if password.isEmpty { return "Escribe la contraseña de la VPN." }
        return nil
    }

    private func guardar() {
        intento = true
        errorGuardado = nil
        guard Validacion.motivo(perfil) == nil, !password.isEmpty else { return }
        paso = .preparando
        modelo.guardarConexion(perfil, password: password)
        // guardarPerfiles puede rechazar el cambio sin empezar a guardar.
        if !busy {
            errorGuardado = modelo.ultimoError ?? "No se pudo guardar la conexión."
            paso = .formulario
        }
    }

    private var preparando: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(modelo.instalandoAyudante ? "Esperando la autorización de macOS…" : "Guardando la conexión…")
                .font(.headline)
            Text("macOS pedirá tu contraseña de administrador para instalar el ayudante de red. Nuvex no la ve ni la guarda.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 90)
    }

    private var listo: some View {
        VStack(spacing: 14) {
            Image(systemName: avisoAyudante == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(avisoAyudante == nil ? Color.green : Color.orange)
            Text(avisoAyudante == nil ? "Todo listo" : "Conexión guardada")
                .font(.title2).fontWeight(.bold)
            Text("Encontrarás Nuvex en la barra de menús, arriba a la derecha. Desde ahí conectas y desconectas con un clic.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let avisoAyudante {
                Text("\(avisoAyudante) Nuvex lo intentará de nuevo al conectar.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button("Cerrar", action: cerrar)
                Button("Conectar ahora") {
                    modelo.conectar(id: perfil.id)
                    cerrar()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!modelo.vpns.contains { $0.id == perfil.id })
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 60)
    }
}

private struct PasoBienvenida: View {
    let numero: Int
    let titulo: String
    let detalle: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(numero)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(titulo).fontWeight(.medium)
                Text(detalle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
