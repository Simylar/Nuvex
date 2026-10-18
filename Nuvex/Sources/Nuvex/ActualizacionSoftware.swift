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

    var body: some View {
        Form {
            Section { tarjeta.padding(.vertical, 6) }
            if let version = actualizaciones.estado.version, !version.notas.isEmpty {
                Section("Novedades") {
                    NotasVersion(texto: version.notas)
                        .padding(.vertical, 4)
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
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.snappy(duration: 0.25), value: actualizaciones.estado)
        .onAppear { actualizaciones.pantallaAparecio() }
        .onDisappear { actualizaciones.pantallaDesaparecio() }
    }

    // MARK: Tarjeta principal

    @ViewBuilder
    private var tarjeta: some View {
        if !actualizaciones.configuradas {
            centrado(titulo: "Nuvex \(InfoVersion.actual.descripcion)",
                     detalle: "Esta compilación se hizo antes de activar las actualizaciones automáticas. Instala la versión publicada una vez y, desde ahí, Nuvex se actualizará sola.") {
                Link("Ver versiones publicadas", destination: URL(string: "https://github.com/Simylar/Nuvex/releases/latest")!)
                    .padding(.top, 6)
            }
        } else {
            switch actualizaciones.estado {
            case .inactivo, .alDia:
                centrado(titulo: "Nuvex \(InfoVersion.actual.corta)",
                         detalle: actualizaciones.estado == .alDia ? "Nuvex está actualizado" : ultimaBusqueda) {
                    if actualizaciones.estado == .alDia {
                        Text(ultimaBusqueda).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Buscar actualizaciones") { actualizaciones.buscar() }
                        .disabled(!actualizaciones.puedeBuscar)
                        .padding(.top, 6)
                }
            case .buscando:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text("Buscando actualizaciones…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            case .error(let mensaje):
                centrado(titulo: "No se pudo actualizar", detalle: mensaje, simbolo: "exclamationmark.triangle.fill") {
                    Button("Reintentar") { actualizaciones.buscar() }
                        .disabled(!actualizaciones.puedeBuscar)
                        .padding(.top, 6)
                }
            case .disponible(let version):
                VStack(alignment: .leading, spacing: 14) {
                    cabecera(version)
                    Text("Tus VPN seguirán conectadas mientras se instala. Nuvex se cerrará y se abrirá de nuevo en unos segundos.")
                        .font(.callout).foregroundStyle(.secondary)
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
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            case .descargando(let version, let recibido, let total):
                VStack(alignment: .leading, spacing: 14) {
                    cabecera(version)
                    progreso(valor: total.map { Double(recibido) / Double(max($0, 1)) },
                             texto: total.map { "Descargando… \(bytes(recibido)) de \(bytes($0))" } ?? "Descargando… \(bytes(recibido))")
                    HStack {
                        Spacer()
                        Button("Cancelar") { actualizaciones.cancelar() }
                    }
                }
            case .preparando(let version, let avance):
                VStack(alignment: .leading, spacing: 14) {
                    cabecera(version)
                    progreso(valor: avance, texto: "Verificando la firma y preparando la actualización…")
                }
            case .lista(let version):
                VStack(alignment: .leading, spacing: 14) {
                    cabecera(version)
                    Label("Lista para instalar", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Nuvex se cerrará y se abrirá de nuevo en unos segundos. Tus VPN seguirán conectadas.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Al cerrar Nuvex") { actualizaciones.instalarAlCerrar() }
                        Spacer()
                        Button("Reiniciar ahora") { actualizaciones.actualizarAhora() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            case .instalando(let version):
                VStack(alignment: .leading, spacing: 14) {
                    cabecera(version)
                    progreso(valor: nil, texto: "Instalando… Nuvex se abrirá de nuevo en unos segundos.")
                }
            }
        }
    }

    private var ultimaBusqueda: String {
        guard let fecha = actualizaciones.ultimaBusqueda else { return "Aún no se ha buscado" }
        return "Última búsqueda: \(fecha.formatted(.relative(presentation: .named)))"
    }

    private func cabecera(_ version: VersionDisponible) -> some View {
        HStack(spacing: 14) {
            IconoNuvex(lado: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Nuvex \(version.version)").font(.title3).fontWeight(.semibold)
                    if version.esBeta { Etiqueta(texto: "Beta", color: .orange) }
                    if version.esCritica { Etiqueta(texto: "Importante", color: .red) }
                }
                Text(["Simylar", version.tamano.map(bytes), version.fecha?.formatted(date: .abbreviated, time: .omitted)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func progreso(valor: Double?, texto: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let valor {
                ProgressView(value: min(max(valor, 0), 1))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(texto).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func centrado<Contenido: View>(titulo: String, detalle: String, simbolo: String? = nil,
                                           @ViewBuilder contenido: () -> Contenido) -> some View {
        VStack(spacing: 8) {
            if let simbolo {
                Image(systemName: simbolo).font(.system(size: 40)).foregroundStyle(.orange)
            } else {
                IconoNuvex(lado: 72)
            }
            Text(titulo).font(.title3).fontWeight(.semibold)
            Text(detalle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            contenido()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func bytes(_ valor: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(valor), countStyle: .file)
    }
}

private struct Etiqueta: View {
    let texto: String
    let color: Color
    var body: some View {
        Text(texto)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// Notas de versión en el formato del CHANGELOG: `### Sección` y `- elemento`.
struct NotasVersion: View {
    let texto: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            Text(limpia.dropFirst(4)).font(.headline).padding(.top, primera ? 0 : 8)
        } else if limpia.hasPrefix("- ") || limpia.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
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
