import AppKit
import SwiftUI

// MARK: - Página «Cuenta de Google»

struct AjustesCuentaGoogle: View {
    @ObservedObject private var cuenta = CuentaGoogle.shared
    @State private var clienteID = ""
    @State private var secreto = ""
    @State private var cambiandoCliente = false
    @State private var confirmarOlvido = false

    static let guia = URL(string: "https://github.com/Simylar/Nuvex/blob/main/docs/gmail.md")!

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
                Text("Nuvex solo pide permiso para leer Gmail: no puede enviar, mover ni borrar correos. Busca únicamente los correos del remitente que indiques en cada conexión, recibidos después de empezar a conectar.")
                    .foregroundStyle(Paleta.textoSecundario)
            }

            if cuenta.estado == .sinCliente || cambiandoCliente {
                Section {
                    TextField("ID de cliente", text: $clienteID, prompt: Text("123…apps.googleusercontent.com"))
                    SecureField("Secreto de cliente", text: $secreto, prompt: Text("GOCSPX-…"))
                    HStack {
                        Link("Cómo crear el cliente OAuth…", destination: Self.guia)
                        Spacer()
                        if cambiandoCliente { Button("Cancelar") { cambiandoCliente = false } }
                        Button("Guardar") {
                            if cuenta.guardarCliente(id: clienteID, secreto: secreto) {
                                clienteID = ""; secreto = ""; cambiandoCliente = false
                            }
                        }
                        .estiloBoton(.principal)
                        .disabled(clienteID.isEmpty || secreto.isEmpty)
                    }
                } header: {
                    Text("Cliente OAuth de Google")
                } footer: {
                    Text("Créalo una vez en Google Cloud como «App de escritorio» y publica el proyecto para uso personal; si queda en modo de prueba, Google pide volver a iniciar sesión cada 7 días. El aviso «Google no verificó esta app» es normal en un cliente propio.")
                        .foregroundStyle(Paleta.textoSecundario)
                }
            } else {
                Section("Cliente OAuth") {
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
        .formularioNuvex()
        .navigationTitle("Cuenta de Google")
        .confirmationDialog("¿Olvidar la cuenta de Google?", isPresented: $confirmarOlvido) {
            Button("Olvidar", role: .destructive) { Task { await cuenta.olvidarCliente() } }
        } message: {
            Text("Nuvex retirará su acceso a Gmail y borrará el cliente del Llavero. Las conexiones que leen el código del correo volverán a pedírtelo.")
        }
    }

    private var titulo: String {
        switch cuenta.estado {
        case .sinCliente: return "Sin configurar"
        case .desconectada: return "Sin iniciar sesión"
        case .esperandoNavegador: return "Esperando a Google…"
        case .conectada(let correo): return correo
        case .caducada(let correo): return correo
        }
    }

    private var subtitulo: String {
        switch cuenta.estado {
        case .sinCliente: return "Añade tu cliente OAuth para leer los códigos que llegan por correo."
        case .desconectada: return "Inicia sesión con la cuenta de Gmail donde llegan los códigos."
        case .esperandoNavegador: return "Completa el inicio de sesión en el navegador."
        case .conectada: return "Conectada · solo lectura de Gmail"
        case .caducada: return "La sesión caducó. Vuelve a iniciar sesión."
        }
    }

    @ViewBuilder
    private var accionPrincipal: some View {
        switch cuenta.estado {
        case .sinCliente:
            EmptyView()
        case .desconectada, .caducada:
            Button("Iniciar sesión con Google") { cuenta.iniciarSesion() }
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
            Picker("Cómo obtenerlo", selection: usarCorreo) {
                Text("Preguntarme").tag(false)
                Text("Leer de Gmail").tag(true)
            }
            .disabled(cuenta.correo == nil && config == nil)
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
                 ? "Para leer el código del correo, conecta tu cuenta en Ajustes › Cuenta de Google."
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
