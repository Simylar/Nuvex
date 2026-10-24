import AppKit
import SwiftUI

/// Logotipo de Nuvex en las pantallas de actualización y novedades.
struct IconoNuvex: View {
    var lado: CGFloat = 64
    var body: some View {
        LogoNuvex(lado: lado).accessibilityHidden(true)
    }
}

/// «Actualización de software», en Ajustes. Es el único sitio donde se
/// muestra: el menú, el panel y los avisos llevan aquí.
struct ActualizacionSoftwareView: View {
    @ObservedObject var actualizaciones: Actualizaciones
    private let instalada: InfoVersion
    private let notasInstaladas: String?

    init(actualizaciones: Actualizaciones, instalada: InfoVersion = .actual) {
        self.actualizaciones = actualizaciones
        self.instalada = instalada
        notasInstaladas = ChequeoActualizacion.notas(de: instalada.corta)
    }

    var body: some View {
        Form {
            Section { tarjeta.padding(.vertical, Espacio.s) }
            if let verificacion = actualizaciones.verificacionInicial,
               actualizaciones.estado != .error(verificacion.mensaje) {
                Section("Última instalación") {
                    switch verificacion {
                    case .verificada:
                        etiquetaVerificacion(verificacion.mensaje,
                                             simbolo: "checkmark.seal.fill", color: Paleta.exito)
                    case .incompleta:
                        etiquetaVerificacion(verificacion.mensaje,
                                             simbolo: "exclamationmark.triangle.fill", color: Paleta.aviso)
                    }
                }
            }
            detallesInstalados
            if let version = actualizaciones.estado.version, !version.notas.isEmpty {
                Section("Novedades de Nuvex \(version.version)") {
                    NotasVersion(texto: version.notas)
                        .padding(.vertical, Espacio.xs)
                }
            }
            if actualizaciones.configuradas {
                Section {
                    Toggle("Buscar actualizaciones automáticamente", isOn: Binding(
                        get: { actualizaciones.buscarAutomaticamente },
                        set: { actualizaciones.buscarAutomaticamente = $0 }))
                    Toggle("Descargar e instalar automáticamente", isOn: Binding(
                        get: { actualizaciones.instalarAutomaticamente },
                        set: { actualizaciones.instalarAutomaticamente = $0 }))
                        .disabled(!actualizaciones.buscarAutomaticamente)
                    Toggle("Recibir versiones beta", isOn: Binding(
                        get: { actualizaciones.recibirBeta },
                        set: { actualizaciones.recibirBeta = $0 }))
                } header: {
                    Text("Actualizaciones automáticas")
                } footer: {
                    Text("Cada versión va firmada y se verifica antes de instalarse. Tus conexiones, contraseñas y ajustes se conservan, y las VPN activas siguen conectadas mientras Nuvex se actualiza.")
                        .foregroundStyle(Paleta.textoSecundario)
                }
            }
        }
        .formularioNuvex()
        .animacion(Movimiento.estandar, value: actualizaciones.estado)
        .onAppear { actualizaciones.pantallaAparecio() }
        .onDisappear { actualizaciones.pantallaDesaparecio() }
    }

    private var detallesInstalados: some View {
        Section("Versión instalada") {
            LabeledContent("Versión", value: instalada.corta)
            LabeledContent("Compilación", value: String(instalada.compilacion))
            LabeledContent("Canal", value: instalada.canalLegible)
            if !instalada.commit.isEmpty {
                LabeledContent("Commit") {
                    Text(instalada.commit).monospaced().textSelection(.enabled)
                }
            }
            if let notas = notasInstaladas, !notas.isEmpty {
                DisclosureGroup("Detalles de esta versión") {
                    NotasVersion(texto: notas)
                        .padding(.top, Espacio.m)
                }
            }
        }
    }

    // MARK: Tarjeta principal

    @ViewBuilder
    private var tarjeta: some View {
        if !actualizaciones.configuradas {
            centrado(titulo: "Nuvex \(instalada.descripcion)",
                     detalle: "Esta compilación se hizo antes de activar las actualizaciones automáticas. Instala la versión publicada una vez y, desde ahí, Nuvex se actualizará sola.") {
                Link("Ver versiones publicadas", destination: URL(string: "https://github.com/Simylar/Nuvex/releases/latest")!)
                    .padding(.top, Espacio.s)
            }
        } else {
            switch actualizaciones.estado {
            case .inactivo, .alDia:
                centrado(titulo: "Nuvex \(instalada.corta)",
                         detalle: actualizaciones.estado == .alDia
                            ? "Nuvex está actualizado"
                            : ultimaBusqueda ?? "Aún no se ha buscado") {
                    if actualizaciones.estado == .alDia, let ultimaBusqueda {
                        Text(ultimaBusqueda).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                    }
                    Button("Buscar actualizaciones") { actualizaciones.buscar() }
                        .estiloBoton(.secundario)
                        .disabled(!actualizaciones.puedeBuscar)
                        .padding(.top, Espacio.s)
                }
            case .buscando:
                VStack(spacing: Espacio.m) {
                    ProgressView().controlSize(.regular)
                    Text("Buscando actualizaciones…").foregroundStyle(Paleta.textoSecundario)
                    Button("Cancelar") { actualizaciones.cancelar() }
                        .estiloBoton(.secundario)
                        .padding(.top, Espacio.xs)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Espacio.xxxl)
            case .error(let mensaje):
                centrado(titulo: "No se pudo actualizar", detalle: mensaje, simbolo: "exclamationmark.triangle.fill") {
                    HStack {
                        if actualizaciones.puedeBuscar {
                            Button("Buscar de nuevo") { actualizaciones.buscar() }
                                .estiloBoton(.secundario)
                        }
                        Link("Ver versiones publicadas", destination: URL(string: "https://github.com/Simylar/Nuvex/releases/latest")!)
                    }
                    .padding(.top, Espacio.s)
                }
            case .disponible(let version):
                VStack(alignment: .leading, spacing: Espacio.l) {
                    cabecera(version)
                    Text("Tus VPN seguirán conectadas mientras se instala. Nuvex se cerrará y se abrirá de nuevo en unos segundos.")
                        .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Menu("Más tarde") {
                            Button("Recordármelo más tarde") { actualizaciones.recordarMasTarde() }
                            if !version.esCritica {
                                Button("Omitir esta versión") { actualizaciones.omitirVersion() }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Spacer()
                        Button("Actualizar ahora") { actualizaciones.actualizarAhora() }
                            .estiloBoton(.principal)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            case .descargando(let version, let recibido, let total):
                VStack(alignment: .leading, spacing: Espacio.l) {
                    cabecera(version)
                    progreso(valor: total.map { Double(recibido) / Double(max($0, 1)) },
                             texto: total.map { "Descargando… \(bytes(recibido)) de \(bytes($0))" } ?? "Descargando… \(bytes(recibido))")
                    HStack {
                        Spacer()
                        Button("Cancelar") { actualizaciones.cancelar() }
                            .estiloBoton(.secundario)
                    }
                }
            case .preparando(let version, let avance):
                VStack(alignment: .leading, spacing: Espacio.l) {
                    cabecera(version)
                    progreso(valor: avance, texto: "Verificando la firma y preparando la actualización…")
                }
            case .lista(let version):
                VStack(alignment: .leading, spacing: Espacio.l) {
                    cabecera(version)
                    Label("Lista para instalar", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Paleta.exitoTexto)
                    Text("Nuvex se cerrará y se abrirá de nuevo en unos segundos. Tus VPN seguirán conectadas.")
                        .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Al cerrar Nuvex") { actualizaciones.instalarAlCerrar() }
                            .estiloBoton(.secundario)
                        Spacer()
                        Button("Reiniciar ahora") { actualizaciones.actualizarAhora() }
                            .estiloBoton(.principal)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            case .programada(let version):
                VStack(alignment: .leading, spacing: Espacio.l) {
                    cabecera(version)
                    Label("Se instalará al cerrar Nuvex", systemImage: "clock.fill")
                        .foregroundStyle(Paleta.infoTexto)
                    Text("La descarga ya está verificada. Puedes seguir usando Nuvex o instalarla ahora.")
                        .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Instalar ahora") { actualizaciones.actualizarAhora() }
                            .estiloBoton(.principal)
                            .controlSize(.large)
                    }
                }
            case .esperando(let version, let detalle):
                VStack(alignment: .leading, spacing: Espacio.l) {
                    cabecera(version)
                    progreso(valor: nil, texto: detalle)
                    Text("Nuvex continuará automáticamente en cuanto sea seguro reiniciar la aplicación. Las VPN ya conectadas no se interrumpirán.")
                        .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .instalando(let version):
                VStack(alignment: .leading, spacing: Espacio.l) {
                    cabecera(version)
                    progreso(valor: nil, texto: "Instalando… Nuvex se abrirá de nuevo en unos segundos.")
                }
            }
        }
    }

    private var ultimaBusqueda: String? {
        guard let fecha = actualizaciones.ultimaBusqueda else { return nil }
        return "Última búsqueda: \(fecha.formatted(.relative(presentation: .named)))"
    }

    private func cabecera(_ version: VersionDisponible) -> some View {
        HStack(spacing: Espacio.l) {
            IconoNuvex(lado: Tamano.logoTarjeta)
            VStack(alignment: .leading, spacing: Espacio.xxs) {
                HStack(spacing: Espacio.s) {
                    Text("Nuvex \(version.version)").font(Tipo.titulo)
                    if version.esBeta { Pastilla(texto: "Beta", color: Paleta.aviso) }
                    if version.esCritica { Pastilla(texto: "Importante", color: Paleta.error) }
                }
                Text(metadatos(version))
                    .font(Tipo.apoyo)
                    .foregroundStyle(Paleta.textoSecundario)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func metadatos(_ version: VersionDisponible) -> String {
        var valores = ["Simylar"]
        if !version.compilacion.isEmpty {
            valores.append("Compilación \(version.compilacion)")
        }
        if let tamano = version.tamano {
            valores.append(bytes(tamano))
        }
        if let fecha = version.fecha {
            valores.append(fecha.formatted(date: .abbreviated, time: .omitted))
        }
        return valores.joined(separator: " · ")
    }

    private func etiquetaVerificacion(_ mensaje: String, simbolo: String, color: Color) -> some View {
        Label {
            Text(mensaje)
        } icon: {
            Image(systemName: simbolo).foregroundStyle(color)
        }
    }

    private func progreso(valor: Double?, texto: String) -> some View {
        VStack(alignment: .leading, spacing: Espacio.s) {
            if let valor {
                ProgressView(value: min(max(valor, 0), 1))
                    .accessibilityLabel(Text(texto))
            } else {
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel(Text(texto))
            }
            Text(texto).font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario).monospacedDigit()
                .accessibilityHidden(true)
        }
    }

    private func centrado<Contenido: View>(titulo: String, detalle: String, simbolo: String? = nil,
                                           @ViewBuilder contenido: () -> Contenido) -> some View {
        VStack(spacing: Espacio.m) {
            if let simbolo {
                Image(systemName: simbolo).font(.system(size: Tamano.simboloDestacado)).foregroundStyle(Paleta.aviso)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            } else {
                IconoNuvex(lado: Tamano.logoPantalla)
            }
            Text(titulo).font(Tipo.titulo)
            Text(detalle)
                .foregroundStyle(Paleta.textoSecundario)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            contenido()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Espacio.m)
    }

    private func bytes(_ valor: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(valor), countStyle: .file)
    }
}

/// Notas de versión en el formato del CHANGELOG: `### Sección` y `- elemento`.
struct NotasVersion: View {
    let texto: String

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.s) {
            ForEach(Array(texto.components(separatedBy: "\n").enumerated()), id: \.offset) { indice, linea in
                fila(linea, primera: indice == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func fila(_ linea: String, primera: Bool) -> some View {
        let limpia = linea.trimmingCharacters(in: .whitespaces)
        if limpia.hasPrefix("### ") {
            Text(limpia.dropFirst(4)).font(Tipo.encabezado).padding(.top, primera ? 0 : Espacio.m)
        } else if limpia.hasPrefix("- ") || limpia.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: Espacio.m) {
                Text("•").foregroundStyle(Paleta.textoSecundario)
                Text(Self.markdown(String(limpia.dropFirst(2))))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !limpia.isEmpty {
            Text(Self.markdown(limpia)).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func markdown(_ texto: String) -> AttributedString {
        (try? AttributedString(markdown: texto)) ?? AttributedString(texto)
    }
}
