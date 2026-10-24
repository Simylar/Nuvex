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
        .fondoVentana()
        .animacion(Movimiento.suave, value: paso)
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
        VStack(spacing: Espacio.l) {
            LogoNuvex(lado: Tamano.logoPantalla)
                .padding(.bottom, Espacio.xs)
            Text("Te damos la bienvenida a Nuvex")
                .font(Tipo.pantalla)
            Text("Conecta tus VPN Fortinet desde la barra de menús. Configurarlo lleva un par de minutos.")
                .font(Tipo.entradilla)
                .foregroundStyle(Paleta.textoSecundario)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Espacio.xl) {
                PasoBienvenida(numero: 1, simbolo: "server.rack", titulo: "Añade tu servidor y usuario",
                               detalle: "La contraseña se guarda en el Llavero de macOS.")
                PasoBienvenida(numero: 2, simbolo: "lock.shield", titulo: "Autoriza el ayudante de red",
                               detalle: "macOS pedirá tu contraseña de administrador una vez.")
                PasoBienvenida(numero: 3, simbolo: "menubar.arrow.up.rectangle", titulo: "Conecta desde la barra de menús",
                               detalle: "Busca el icono de Nuvex arriba a la derecha.")
            }
            .padding(.horizontal, Espacio.m)
            .padding(.vertical, Espacio.xl)
            Button("Añadir primera conexión") { paso = .formulario }
                .estiloBoton(.principal)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Button("Ahora no", action: cerrar)
                .buttonStyle(.link)
        }
        .padding(.horizontal, Espacio.pantalla)
        .padding(.top, Espacio.pantalla)
        .padding(.bottom, Espacio.xxxl)
    }

    private var formulario: some View {
        VStack(spacing: 0) {
            VStack(spacing: Espacio.xs) {
                Text("Tu primera conexión").font(Tipo.titulo)
                Text("Podrás ajustar rutas, DNS y más opciones en Ajustes.")
                    .foregroundStyle(Paleta.textoSecundario)
            }
            .padding(.top, Espacio.bloque)
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
                        .foregroundStyle(Paleta.textoSecundario)
                }
            }
            .formularioNuvex()
            .scrollDisabled(true)
            .frame(height: 300)

            VStack(alignment: .leading, spacing: Espacio.m) {
                if let mensaje = mensajeFormulario {
                    Label(mensaje, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(errorGuardado != nil ? Paleta.errorTexto : Paleta.avisoTexto)
                        .font(Tipo.apoyo)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Atrás") { paso = .inicio }
                        .estiloBoton(.secundario)
                    Spacer()
                    Button("Guardar y continuar", action: guardar)
                        .estiloBoton(.principal)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, Espacio.xxxl)
            .padding(.bottom, Espacio.xxl)
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
        VStack(spacing: Espacio.l) {
            ProgressView().controlSize(.large)
            Text(modelo.instalandoAyudante ? "Esperando la autorización de macOS…" : "Guardando la conexión…")
                .font(Tipo.encabezado)
            Text("macOS pedirá tu contraseña de administrador para instalar el ayudante de red. Nuvex no la ve ni la guarda.")
                .foregroundStyle(Paleta.textoSecundario)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Espacio.pantalla)
        .padding(.vertical, Espacio.pantalla * 2)
    }

    private var listo: some View {
        VStack(spacing: Espacio.l) {
            let conAviso = avisoAyudante != nil || modelo.resumenGuardado?.hayProblemas == true
            Image(systemName: conAviso ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: Tamano.simboloDestacado))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(conAviso ? Paleta.aviso : Paleta.exito)
            Text(conAviso ? "Conexión guardada" : "Todo listo")
                .font(Tipo.pantalla)
            Text("Encontrarás Nuvex en la barra de menús, arriba a la derecha. Desde ahí conectas y desconectas con un clic.")
                .foregroundStyle(Paleta.textoSecundario)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let resumen = modelo.resumenGuardado, resumen.hayProblemas {
                GroupBox {
                    ListaResumenGuardado(modelo: modelo, resumen: resumen)
                        .padding(Espacio.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let avisoAyudante {
                Text("\(avisoAyudante) Nuvex lo intentará de nuevo al conectar.")
                    .font(Tipo.apoyo)
                    .foregroundStyle(Paleta.avisoTexto)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: Espacio.m) {
                Button("Cerrar", action: cerrar)
                    .estiloBoton(.secundario)
                Button("Conectar ahora") {
                    modelo.conectar(id: perfil.id)
                    cerrar()
                }
                .estiloBoton(.principal)
                .keyboardShortcut(.defaultAction)
                .disabled(!modelo.vpns.contains { $0.id == perfil.id })
            }
            .controlSize(.large)
            .padding(.top, Espacio.s)
        }
        .padding(.horizontal, Espacio.pantalla)
        .padding(.vertical, Espacio.pantalla + Espacio.xxl)
    }
}

/// Un paso de la presentación: símbolo en la columna del acento, título y
/// detalle. Sin contenedor: la alineación y el espacio bastan para agruparlos.
private struct PasoBienvenida: View {
    let numero: Int
    let simbolo: String
    let titulo: String
    let detalle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Espacio.l) {
            Image(systemName: simbolo)
                .font(Tipo.titulo)
                .foregroundStyle(Paleta.acento)
                .frame(width: Espacio.bloque)
            VStack(alignment: .leading, spacing: Espacio.xxs) {
                Text(titulo).font(Tipo.cuerpoEnfasis)
                Text(detalle).font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Paso \(numero): \(titulo). \(detalle)")
    }
}
