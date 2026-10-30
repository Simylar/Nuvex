import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Página «Cuenta de Google»

struct AjustesCuentaGoogle: View {
    @ObservedObject private var cuenta: CuentaGoogle
    @ObservedObject private var preferencias: Preferencias
    @State private var clienteID = ""
    @State private var secreto = ""
    @State private var cambiandoCliente = false
    @State private var confirmarOlvido = false
    @State private var errorImportacion: String?
    @State private var clientePendiente: (id: String, secreto: String)?
    @State private var confirmarPapelera = false
    @State private var errorPreferencia: String?

    static let guia = URL(string: "https://github.com/Simylar/Nuvex/blob/main/docs/gmail.md")!

    init(cuenta: CuentaGoogle? = nil, preferencias: Preferencias? = nil) {
        self.cuenta = cuenta ?? .shared
        self.preferencias = preferencias ?? .shared
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: Espacio.l) {
                    IconoCuadrado(simbolo: "envelope.fill", color: Paleta.iconoCorreo, lado: Tamano.iconoCabecera)
                    VStack(alignment: .leading, spacing: Espacio.xxs) {
                        Text(titulo).font(Tipo.titulo)
                        Text(subtitulo).foregroundStyle(Paleta.textoSecundario).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    accionPrincipal
                }
                .padding(.vertical, Espacio.xs)
                if let error = cuenta.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Paleta.errorTexto).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("Nuvex busca los correos del remitente que indiques en cada conexión, recibidos después de empezar a conectar. Por defecto solo solicita lectura. Mover los correos usados a la papelera requiere tu autorización adicional.")
                    .foregroundStyle(Paleta.textoSecundario)
            }

            if cuenta.estado == .sinCliente || cambiandoCliente {
                Section {
                    Text("Google requiere un cliente de escritorio para permitir la lectura de códigos. Puedes importar el archivo que descargues de Google Cloud.")
                        .foregroundStyle(Paleta.textoSecundario)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Importar archivo de Google…", action: importarCliente)
                        .estiloBoton(.principal)
                    Link("Cómo obtener el archivo…", destination: Self.guia)
                    DisclosureGroup("Introducir los datos manualmente") {
                        TextField("ID de cliente", text: $clienteID, prompt: Text("123…apps.googleusercontent.com"))
                        SecureField("Secreto de cliente", text: $secreto)
                        Button("Guardar") {
                            proponerCliente(id: clienteID, secreto: secreto)
                        }
                        .disabled(clienteID.isEmpty || secreto.isEmpty)
                    }
                    if let errorImportacion {
                        Text(errorImportacion).foregroundStyle(Paleta.avisoTexto)
                    }
                    if cambiandoCliente { Button("Cancelar") { cambiandoCliente = false } }
                } header: {
                    Text("Preparar la lectura de códigos · Opcional")
                } footer: {
                    Text("Puedes seguir conectándote y escribir el código cuando se solicite. Importar el archivo guarda el cliente en el Llavero; el acceso a Gmail se autoriza después en Google.")
                        .foregroundStyle(Paleta.textoSecundario)
                }
            } else if case .llaveroNoDisponible = cuenta.estado {
                Section {
                    Text("Desbloquea el Llavero y permite el acceso de esta copia de Nuvex. Si macOS ofrece «Permitir siempre», esa decisión pertenece al Llavero. No necesitas crear otro cliente OAuth.")
                        .foregroundStyle(Paleta.textoSecundario)
                }
            } else {
                Section {
                    DisclosureGroup("Opciones de la cuenta") {
                        LabeledContent("ID de cliente") {
                            Text(cuenta.clienteID ?? "").font(Tipo.monoNota).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        HStack {
                            Button("Cambiar cliente…") { cambiandoCliente = true }
                            Spacer()
                            Button("Olvidar cuenta y cliente…", role: .destructive) { confirmarOlvido = true }
                                .estiloBoton(.destructivo)
                        }
                    }
                }
            }

            Section {
                Toggle("Enviar el correo a la papelera después de usar el código", isOn: Binding(
                    get: { preferencias.ajustes.enviarCorreoPapelera },
                    set: { activar in
                        if activar && !cuenta.puedeModificarCorreo { confirmarPapelera = true }
                        else { guardarPapelera(activar) }
                    }))
                    .disabled(preferencias.soloLectura != nil || cuenta.estado == .esperandoNavegador)
                if preferencias.ajustes.enviarCorreoPapelera && !cuenta.puedeModificarCorreo {
                    Text(cuenta.mensajePapeleraPendiente)
                        .foregroundStyle(Paleta.textoSecundario)
                    if cuenta.clienteID != nil && cuenta.correo != nil {
                        Button("Autorizar la papelera…") { confirmarPapelera = true }
                    }
                }
                if let aviso = cuenta.avisoPapelera {
                    Label(aviso, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Paleta.avisoTexto)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Ocultar aviso") { cuenta.descartarAvisoPapelera() }
                        .buttonStyle(.link)
                }
                if let error = errorPreferencia ?? preferencias.soloLectura {
                    Text(error).foregroundStyle(Paleta.errorTexto)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Correos con códigos")
            } footer: {
                Text("Se aplica a todas las conexiones que leen de Gmail, solo tras confirmar la VPN. Probar la lectura no mueve correos. Puedes recuperarlos desde la papelera de Gmail. Desactivar esta opción no revoca el permiso ya concedido en Google.")
                    .foregroundStyle(Paleta.textoSecundario)
            }
        }
        .formularioNuvex()
        .navigationTitle("Cuenta de Google")
        .confirmationDialog("¿Permitir mover los correos usados a la papelera?", isPresented: $confirmarPapelera) {
            Button(cuenta.clienteID == nil ? "Activar" : "Activar y autorizar en Google…") {
                guard guardarPapelera(true) else { return }
                if case .llaveroNoDisponible = cuenta.estado { return }
                if cuenta.clienteID != nil { cuenta.iniciarSesion(modificarCorreo: true) }
            }
        } message: {
            Text("Google requiere un permiso que también permite modificar y enviar correo. Nuvex lo usará solo para leer códigos y enviar a la papelera el mensaje utilizado tras confirmar la VPN. No borrará mensajes definitivamente. Si cancelas Google, la opción quedará pendiente de autorización.")
        }
        .confirmationDialog("¿Olvidar la cuenta de Google?", isPresented: $confirmarOlvido) {
            Button("Olvidar", role: .destructive) { Task { await cuenta.olvidarCliente() } }
        } message: {
            Text("Nuvex retirará su acceso a Gmail y borrará el cliente del Llavero. Las conexiones que leen el código del correo volverán a pedírtelo.")
        }
        .confirmationDialog("¿Reemplazar la configuración de Google?", isPresented: Binding(
            get: { clientePendiente != nil },
            set: { if !$0 { clientePendiente = nil } })) {
            Button("Reemplazar") {
                if let cliente = clientePendiente { guardarCliente(id: cliente.id, secreto: cliente.secreto) }
                clientePendiente = nil
            }
        } message: {
            Text("Tendrás que volver a iniciar sesión en Google para leer códigos. Tus conexiones VPN se conservan.")
        }
        .onDisappear { secreto = ""; clientePendiente = nil }
    }

    @discardableResult
    private func guardarPapelera(_ activar: Bool) -> Bool {
        let guardado = preferencias.modificar { $0.enviarCorreoPapelera = activar }
        errorPreferencia = guardado ? nil : "No se pudo guardar la opción. Revisa el acceso a los ajustes y vuelve a intentarlo."
        return guardado
    }

    private func proponerCliente(id: String, secreto: String) {
        if cuenta.correo != nil { clientePendiente = (id, secreto) }
        else { guardarCliente(id: id, secreto: secreto) }
    }

    private func guardarCliente(id: String, secreto: String) {
        if cuenta.guardarCliente(id: id, secreto: secreto) {
            clienteID = ""; self.secreto = ""; cambiandoCliente = false
        }
    }

    private func importarCliente() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Selecciona el archivo del cliente de escritorio descargado de Google Cloud."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        errorImportacion = nil
        do {
            let atributos = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard atributos.isRegularFile == true, let bytes = atributos.fileSize, bytes <= 128 * 1024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let datos = try Data(contentsOf: url)
            guard datos.count <= 128 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let cliente = try JSONDecoder().decode(ClienteGoogleImportado.self, from: datos)
            proponerCliente(id: cliente.id, secreto: cliente.secreto)
        } catch {
            errorImportacion = "No se pudo importar. Elige el archivo JSON de un cliente de tipo «App de escritorio» de Google Cloud."
        }
    }

    private var titulo: String {
        switch cuenta.estado {
        case .sinCliente: return "Sin configurar"
        case .llaveroNoDisponible: return "Cuenta guardada sin comprobar"
        case .desconectada: return "Sin iniciar sesión"
        case .esperandoNavegador: return "Esperando a Google…"
        case .conectada(let correo): return correo
        case .caducada(let correo): return correo
        }
    }

    private var subtitulo: String {
        switch cuenta.estado {
        case .sinCliente: return "Lee automáticamente los códigos de Gmail. Puedes configurarlo cuando quieras."
        case .llaveroNoDisponible: return "Permite el acceso al Llavero para recuperar tu cuenta guardada."
        case .desconectada: return "Inicia sesión con la cuenta de Gmail donde llegan los códigos."
        case .esperandoNavegador: return "Completa el inicio de sesión en el navegador."
        case .conectada: return "Sesión guardada · el acceso a Gmail se comprueba al leer"
        case .caducada: return "La sesión caducó. Vuelve a iniciar sesión."
        }
    }

    @ViewBuilder
    private var accionPrincipal: some View {
        switch cuenta.estado {
        case .sinCliente:
            EmptyView()
        case .llaveroNoDisponible:
            Button("Recuperar acceso…") { cuenta.recuperarDelLlavero() }
                .estiloBoton(.principal)
        case .desconectada, .caducada:
            Button("Iniciar sesión con Google") {
                cuenta.iniciarSesion(modificarCorreo: preferencias.ajustes.enviarCorreoPapelera)
            }
                .estiloBoton(.principal)
        case .esperandoNavegador:
            HStack(spacing: Espacio.m) {
                ProgressView().controlSize(.small)
                Button("Cancelar") { cuenta.cancelarInicio() }
            }
        case .conectada:
            Button("Cerrar sesión") { Task { await cuenta.cerrarSesion() } }
        }
    }
}

// MARK: - Sección por conexión

/// «Código de verificación» en el detalle de una conexión. Se guarda al
/// momento en ajustes.json: no cambia la conexión ni reinstala el ayudante.
struct SeccionCodigoCorreo: View {
    let perfilID: String
    @ObservedObject private var preferencias = Preferencias.shared
    @ObservedObject private var cuenta = CuentaGoogle.shared
    @State private var prueba: String?
    @State private var probando = false

    private var config: ConfigCorreo? { preferencias.ajustes.correo[perfilID] }

    private func cambiar(_ cambio: @escaping (inout ConfigCorreo) -> Void) {
        preferencias.modificar { ajustes in
            var nueva = ajustes.correo[perfilID] ?? ConfigCorreo(remitente: "")
            cambio(&nueva)
            ajustes.correo[perfilID] = nueva
        }
        prueba = nil
    }

    private var usarCorreo: Binding<Bool> {
        Binding(get: { config != nil }, set: { usar in
            preferencias.modificar { ajustes in
                // Por defecto, el formato de FortiToken por correo; se puede cambiar.
                ajustes.correo[perfilID] = usar ? ConfigCorreo.fortinet : nil
            }
            prueba = nil
        })
    }

    private func campo(_ ruta: WritableKeyPath<ConfigCorreo, String>) -> Binding<String> {
        Binding(get: { config?[keyPath: ruta] ?? "" }, set: { valor in cambiar { $0[keyPath: ruta] = valor } })
    }

    var body: some View {
        Section {
            if cuenta.correo == nil && config == nil {
                Text("Si el servidor pide un código, podrás escribirlo al conectar.")
                Button("Configurar lectura desde Gmail…") { AppActual.abrirAjustes(pagina: .cuentaGoogle) }
                    .buttonStyle(.link)
            } else {
                Picker("Cómo obtenerlo", selection: usarCorreo) {
                    Text("Preguntarme").tag(false)
                    Text("Leer de Gmail").tag(true)
                }
            }
            if let config {
                TextField("Remitente", text: campo(\.remitente), prompt: Text("noreply@empresa.com"))
                if config.remitente.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label("Indica quién envía el código; Nuvex solo busca sus correos.", systemImage: "exclamationmark.triangle.fill")
                        .font(Tipo.apoyo).foregroundStyle(Paleta.avisoTexto)
                }
                TextField("Asunto contiene", text: campo(\.asunto), prompt: Text("Opcional"))
                if config.remitente != ConfigCorreo.fortinet.remitente || config.asunto != ConfigCorreo.fortinet.asunto {
                    Button("Usar el formato de FortiToken (DoNotReply@notification.fortinet.net)") {
                        cambiar { $0.remitente = ConfigCorreo.fortinet.remitente; $0.asunto = ConfigCorreo.fortinet.asunto }
                    }
                    .buttonStyle(.link)
                }
                Picker("Esperar el correo", selection: Binding(get: { config.espera }, set: { valor in cambiar { $0.espera = valor } })) {
                    ForEach(Array(Set([60, 120, 180, config.espera])).sorted(), id: \.self) { Text("Hasta \($0) s").tag($0) }
                }
                DisclosureGroup("Patrón avanzado") {
                    TextField("Expresión regular", text: campo(\.patron), prompt: Text(#"Opcional, p. ej. Código: (\d{6})"#))
                        .font(Tipo.mono)
                    if !ExtractorCodigo.patronValido(config.patron) {
                        Label("La expresión regular no es válida.", systemImage: "exclamationmark.triangle.fill")
                            .font(Tipo.apoyo).foregroundStyle(Paleta.errorTexto)
                    }
                }
                HStack {
                    Button("Probar con el último correo") { probar(config) }
                        .disabled(probando || cuenta.correo == nil || config.remitente.isEmpty)
                    if probando { ProgressView().controlSize(.small) }
                    if let prueba { Text(prueba).font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario).textSelection(.enabled) }
                }
            }
        } header: {
            Text("Código de verificación")
        } footer: {
            Text(cuenta.correo == nil && config == nil
                 ? "La lectura automática de Gmail es opcional."
                 : config == nil
                    ? "Si el servidor pide un código, Nuvex te lo preguntará al conectar."
                    : "Al conectar, Nuvex buscará en \(cuenta.correo ?? "Gmail") el correo del remitente y usará el código; si no llega a tiempo, te lo pedirá. Se guarda al momento.")
                .foregroundStyle(Paleta.textoSecundario)
        }
    }

    private func probar(_ config: ConfigCorreo) {
        probando = true
        prueba = nil
        Task {
            defer { probando = false }
            do {
                if let hallazgo = try await LectorGmail.probar(config) {
                    let hace = hallazgo.fecha.formatted(.relative(presentation: .named))
                    prueba = "Encontrado: \(ExtractorCodigo.enmascarar(hallazgo.codigo)) · \(hace)"
                } else {
                    prueba = "No hay correos de ese remitente con un código en los últimos 7 días."
                }
            } catch {
                let problema = LectorGmail.problema(de: error)
                prueba = "\(problema.titulo). \(problema.detalle)"
            }
        }
    }
}
