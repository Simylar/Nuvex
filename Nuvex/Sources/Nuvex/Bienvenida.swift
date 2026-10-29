import AppKit
import Combine
import SwiftUI

@MainActor
enum Bienvenida {
    private static var ventana: NSWindow?
    private static var borrador = BorradorBienvenida()
    private static var observadorConexion: AnyCancellable?

    static func mostrar(modelo: VPNModel) {
        if let ventana, ventana.isVisible, !borrador.conexionCompletada {
            NSApp.activate(ignoringOtherApps: true)
            ventana.makeKeyAndOrderFront(nil)
            return
        }
        if borrador.conexionCompletada {
            borrador = BorradorBienvenida()
        }
        let actual = borrador
        // Sigue la finalización aunque la ventana se haya cerrado. Una caída
        // posterior no convierte un primer uso terminado en un borrador pendiente.
        observadorConexion = modelo.$estados.sink { estados in
            if estados[actual.perfil.id] == .conectada { actual.conexionCompletada = true }
        }
        let ventana = ventana ?? crearVentana()
        Self.ventana = ventana
        ventana.contentViewController = NSHostingController(
            rootView: BienvenidaView(modelo: modelo, borrador: borrador, cerrar: { ventana.close() }))
        ventana.center()
        NSApp.activate(ignoringOtherApps: true)
        ventana.makeKeyAndOrderFront(nil)
    }

    static func reanudarSiPendiente(modelo: VPNModel) -> Bool {
        guard borrador.tieneAvance, !borrador.conexionCompletada else { return false }
        mostrar(modelo: modelo)
        return true
    }

    private static func crearVentana() -> NSWindow {
        let ventana = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        ventana.title = "Añadir conexión"
        ventana.minSize = NSSize(width: 520, height: 520)
        ventana.isReleasedWhenClosed = false
        return ventana
    }
}

struct BienvenidaView: View {
    @ObservedObject var modelo: VPNModel
    @ObservedObject var borrador: BorradorBienvenida
    let cerrar: () -> Void
    private enum Campo: Hashable { case servidor, usuario, password, nombre }
    @FocusState private var foco: Campo?
    @State private var cambiarContrasena = false

    private var busy: Bool { modelo.guardandoConfiguracion || modelo.instalandoAyudante }
    private var perfilParaGuardar: VPNProfile { borrador.perfil.conNombreSugerido }
    private var contrasenaGuardada: Bool {
        modelo.passwordStatuses[borrador.perfil.id] == .saved &&
            modelo.profiles.contains { $0.id == borrador.perfil.id && $0.username == perfilParaGuardar.username }
    }

    var body: some View {
        Group {
            switch borrador.paso {
            case .formulario: formulario
            case .preparando: preparando
            case .guardada: guardada
            }
        }
        .frame(minWidth: 520, idealWidth: 520, minHeight: 520, idealHeight: 620)
        .fondoVentana()
        .onAppear { foco = .servidor }
        .onChange(of: borrador.paso) { _, paso in
            if paso == .formulario { foco = contrasenaGuardada ? .servidor : .password }
        }
    }

    private var formulario: some View {
        Form {
            Section {
                HStack(spacing: Espacio.l) {
                    LogoNuvex(lado: Tamano.iconoCabecera)
                    VStack(alignment: .leading, spacing: Espacio.xs) {
                        Text("Conecta con tu trabajo o escuela").font(Tipo.titulo)
                        Text("Añade los datos de tu VPN Fortinet. Después podrás conectarte desde la barra de menús.")
                            .foregroundStyle(Paleta.textoSecundario)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section {
                TextField("Servidor", text: $borrador.perfil.server, prompt: Text("vpn.empresa.com"))
                    .textContentType(.URL).focused($foco, equals: .servidor)
                    .onSubmit { foco = .usuario }
                TextField("Usuario", text: $borrador.perfil.username)
                    .textContentType(.username).focused($foco, equals: .usuario)
                    .onSubmit { foco = .password }
                if contrasenaGuardada && !cambiarContrasena && borrador.password.isEmpty {
                    LabeledContent("Contraseña") {
                        Text("Guardada en el Llavero").foregroundStyle(Paleta.textoSecundario)
                        Button("Cambiar…") { cambiarContrasena = true; foco = .password }
                    }
                } else {
                    SecureField("Contraseña", text: $borrador.password,
                                prompt: Text(contrasenaGuardada ? "En blanco conserva la guardada" : "Contraseña de la VPN"))
                        .textContentType(.password)
                        .focused($foco, equals: .password)
                        .onSubmit(guardar)
                }
            } footer: {
                Text("Usa los datos que te dio tu organización. La contraseña se guarda en el Llavero de macOS. Si hace falta un código, te lo pediremos al conectar.")
                    .foregroundStyle(Paleta.textoSecundario)
            }
            Section {
                TextField("Nombre (opcional)", text: $borrador.perfil.name,
                          prompt: Text(perfilParaGuardar.name.isEmpty ? "Oficina" : perfilParaGuardar.name))
                    .focused($foco, equals: .nombre)
            } footer: {
                Text("Si lo dejas vacío, usaremos la dirección del servidor para reconocer la conexión.")
            }
            OpcionesServidor(perfil: $borrador.perfil)
        }
        .formularioNuvex()
        .disabled(busy)
        .barraAcciones {
            VStack(alignment: .leading, spacing: Espacio.s) {
                if let mensaje = mensajeFormulario {
                    Label(mensaje, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Paleta.avisoTexto).font(Tipo.apoyo)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Al conectar, guardaremos tus datos. macOS puede pedir autorización para preparar la red y acceder al Llavero.")
                    .font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                HStack {
                    Button("Ahora no", action: cerrar).estiloBoton(.secundario)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Importar…") { VentanaImportar.mostrar(modelo: modelo) }
                        .estiloBoton(.secundario)
                        .help("Recupera conexiones desde un archivo de Nuvex.")
                        .disabled(busy)
                    Button("Conectar", action: guardar)
                        .estiloBoton(.principal).keyboardShortcut(.defaultAction)
                        .disabled(busy || !modelo.configuracionCargada || modelo.errorCargaConfiguracion != nil)
                }
            }
        }
    }

    private var mensajeFormulario: String? {
        if let error = borrador.error { return error }
        guard borrador.intento else { return nil }
        if let motivo = Validacion.motivo(perfilParaGuardar) { return motivo }
        return borrador.password.isEmpty && !contrasenaGuardada ? "Escribe la contraseña de la VPN." : nil
    }

    private func guardar() {
        guard !busy else { return }
        borrador.intento = true
        borrador.error = nil
        guard Validacion.motivo(perfilParaGuardar) == nil, !borrador.password.isEmpty || contrasenaGuardada else {
            if !Validacion.servidorValido(perfilParaGuardar.server) { foco = .servidor }
            else if Validacion.vacio(perfilParaGuardar.username) { foco = .usuario }
            else if borrador.password.isEmpty && !contrasenaGuardada { foco = .password }
            else { foco = .nombre }
            return
        }
        borrador.perfil = perfilParaGuardar
        borrador.conexionCompletada = false
        borrador.paso = .preparando
        let conservarContrasena = contrasenaGuardada
        modelo.guardarConexion(borrador.perfil, password: borrador.password) { resultado in
            if borrador.completar(resultado, contrasenaDisponible: conservarContrasena) {
                modelo.conectarTrasGuardar(id: borrador.perfil.id, resultado: resultado)
            }
        }
    }

    private var preparando: some View {
        VStack(spacing: Espacio.l) {
            ProgressView().controlSize(.large)
            Text(modelo.instalandoAyudante ? "Autoriza la conexión en macOS" : "Guardando la conexión…")
                .font(Tipo.encabezado)
            Text(modelo.instalandoAyudante
                 ? "El ayudante permite crear la conexión de red. Usa Touch ID o tu contraseña de administrador si macOS lo ofrece. Nuvex no recibe esa contraseña."
                 : "Estamos guardando tus datos y comprobando qué hace falta para conectar.")
                .foregroundStyle(Paleta.textoSecundario).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Espacio.pantalla)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var estadoConexion: EstadoUI { modelo.estado(id: borrador.perfil.id) }
    private var esperandoCodigo: Bool { modelo.esperandoCodigo.contains(borrador.perfil.id) }
    private var sinComprobar: Bool { modelo.errorConsulta != nil }

    private var simboloResultado: String {
        if sinComprobar { return "questionmark.circle" }
        if case .error = estadoConexion { return "exclamationmark.triangle.fill" }
        if estadoConexion == .conectada { return "checkmark.circle.fill" }
        return modelo.ayudanteListo == false ? "lock.shield" : "info.circle"
    }

    private var colorResultado: Color {
        if sinComprobar { return Paleta.aviso }
        if case .error = estadoConexion { return Paleta.error }
        if estadoConexion == .conectada { return Paleta.exito }
        return modelo.ayudanteListo == false ? Paleta.aviso : .secondary
    }

    private var tituloResultado: String {
        if modelo.instalandoAyudante { return "Autoriza la conexión en macOS" }
        if sinComprobar { return "No se pudo comprobar la conexión" }
        switch estadoConexion {
        case .conectada: return "Conectada a \(borrador.perfil.name)"
        case .conectando: return esperandoCodigo ? "Introduce el código de verificación" : "Conectando…"
        case .error(let fallo): return fallo.titulo
        case .desconectada:
            return modelo.canceladas.contains(borrador.perfil.id) ? "Conexión cancelada" : "Conexión guardada"
        }
    }

    private var explicacionResultado: String {
        if sinComprobar { return "Tus datos están guardados. Comprueba el estado antes de volver a conectar." }
        switch estadoConexion {
        case .conectada: return "La próxima vez, abre Nuvex en la barra de menús para conectar o desconectar."
        case .conectando:
            return esperandoCodigo ? "El servidor necesita un código. Puedes abrir la ventana para introducirlo."
                : "Puedes cancelar este intento. Tus datos guardados se conservan."
        case .error(let fallo): return fallo.detalle
        case .desconectada:
            return modelo.ayudanteListo == false
                ? "Falta autorizar el ayudante de red. Pulsa Conectar para volver a intentarlo cuando estés listo."
                : "Puedes volver a conectar o revisar los datos sin empezar de nuevo."
        }
    }

    private var guardada: some View {
        GeometryReader { geometria in
            ScrollView {
                VStack(spacing: Espacio.l) {
                    if estadoConexion == .conectando || modelo.instalandoAyudante {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: simboloResultado)
                            .font(.system(size: Tamano.simboloDestacado))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(colorResultado)
                    }
                    Text(tituloResultado).font(Tipo.pantalla).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(explicacionResultado).foregroundStyle(Paleta.textoSecundario)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    accionesResultado
                }
                .padding(Espacio.pantalla)
                .frame(maxWidth: .infinity, minHeight: geometria.size.height)
            }
        }
    }

    @ViewBuilder
    private var accionesResultado: some View {
        HStack(spacing: Espacio.m) {
            if modelo.instalandoAyudante {
                Button("Cerrar ventana", action: cerrar).estiloBoton(.secundario)
            } else if estadoConexion == .conectando {
                Button("Cancelar") { modelo.cancelarConexion(borrador.perfil.id) }
                    .estiloBoton(.secundario).keyboardShortcut(.cancelAction)
                if esperandoCodigo {
                    Button("Introducir código") { VentanaCodigo.traerAlFrente(borrador.perfil.id) }
                        .estiloBoton(.principal).keyboardShortcut(.defaultAction)
                }
            } else if estadoConexion == .conectada && !sinComprobar {
                Button("Cerrar", action: cerrar).estiloBoton(.principal)
                    .keyboardShortcut(.defaultAction)
            } else if sinComprobar {
                Button("Cerrar", action: cerrar).estiloBoton(.secundario).keyboardShortcut(.cancelAction)
                Button("Comprobar estado") { modelo.refrescar() }.estiloBoton(.principal)
                    .keyboardShortcut(.defaultAction)
            } else if case .error(let fallo) = estadoConexion {
                Button("Cerrar", action: cerrar).estiloBoton(.secundario).keyboardShortcut(.cancelAction)
                switch fallo.accion {
                case .ajustes:
                    Button("Revisar datos") { borrador.paso = .formulario; foco = .servidor }
                        .estiloBoton(.principal).keyboardShortcut(.defaultAction)
                case .reintentar(let titulo):
                    Button(titulo) { modelo.conectar(id: borrador.perfil.id) }
                        .estiloBoton(.principal).keyboardShortcut(.defaultAction).disabled(busy)
                case .ninguna:
                    Button("Comprobar estado") { modelo.refrescar() }
                        .estiloBoton(.principal).keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Editar datos") { borrador.paso = .formulario; foco = .servidor }
                    .estiloBoton(.secundario)
                Button("Conectar") { modelo.conectar(id: borrador.perfil.id) }
                    .estiloBoton(.principal).keyboardShortcut(.defaultAction)
                    .disabled(busy || !modelo.vpns.contains { $0.id == borrador.perfil.id })
            }
        }
        .controlSize(.large)
    }
}
