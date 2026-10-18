import AppKit
import SwiftUI

// MARK: - Fila de una VPN

/// Fila compacta al estilo del Centro de control: el círculo de la izquierda
/// conecta o desconecta y el texto secundario explica el estado.
struct FilaVPN: View {
    let vpn: VPNStatus
    let estado: EstadoUI
    let passwordStatus: PasswordStatus?
    let caidaEn: Date?
    /// Inicio del intento en curso y si espera el código, para mostrar el avance.
    var conectandoDesde: Date? = nil
    var esperandoCodigo = false
    let atajo: Int?
    let bloqueada: Bool
    let alAlternar: () -> Void
    let alConfigurar: () -> Void
    let alDescartar: () -> Void
    var alCancelar: () -> Void = {}

    @State private var hover = false
    @State private var expandida = false

    private enum Situacion {
        case conectada, conectando, caida(Date), error(Fallo)
        case faltaConfigurar, faltaContrasena, desconectada
    }

    private var situacion: Situacion {
        switch estado {
        case .conectada: return .conectada
        case .conectando: return .conectando
        case .error(let fallo): return .error(fallo)
        case .desconectada:
            if let caidaEn { return .caida(caidaEn) }
            if !vpn.configured { return .faltaConfigurar }
            if passwordStatus == .missing { return .faltaContrasena }
            return .desconectada
        }
    }

    private var simbolo: String {
        switch situacion {
        case .conectada: return "lock.fill"
        case .conectando, .desconectada: return "lock.open.fill"
        case .caida, .error: return "exclamationmark.triangle.fill"
        case .faltaContrasena: return "key.fill"
        case .faltaConfigurar: return "slider.horizontal.3"
        }
    }

    private var tinte: Color {
        switch situacion {
        case .conectada, .conectando, .desconectada: return .primary
        case .error: return .red
        case .caida, .faltaContrasena, .faltaConfigurar: return .orange
        }
    }

    private var fondoCirculo: Color {
        switch situacion {
        case .conectada: return .accentColor
        case .conectando, .desconectada: return .primary.opacity(0.09)
        default: return tinte.opacity(0.16)
        }
    }

    private var descripcion: String {
        switch situacion {
        case .conectada:
            guard let inicio = vpn.inicio else { return "Conectada" }
            return "Conectada · \(Formato.duracion(desde: inicio))"
        case .conectando:
            let base = esperandoCodigo ? "Esperando el código" : "Conectando"
            guard let conectandoDesde else { return base + "…" }
            let segundos = max(0, Int(Date().timeIntervalSince(conectandoDesde)))
            return "\(base)… \(segundos / 60):\(String(format: "%02d", segundos % 60))"
        case .caida(let fecha): return "Se desconectó a las \(fecha.formatted(date: .omitted, time: .shortened))"
        case .error(let fallo): return fallo.titulo
        case .faltaConfigurar: return "Falta el servidor o el usuario"
        case .faltaContrasena: return "Falta la contraseña"
        case .desconectada:
            return vpn.helperReady ? "Desconectada" : "Se pedirá autorización de macOS al conectar"
        }
    }

    private var colorDescripcion: Color {
        switch situacion {
        case .error: return .red
        case .caida, .faltaContrasena, .faltaConfigurar: return .orange
        default: return .secondary
        }
    }

    private var etiquetaCirculo: String {
        switch situacion {
        case .conectada: return "Desconectar \(vpn.name)"
        case .conectando: return "\(vpn.name), conectando"
        case .faltaConfigurar, .faltaContrasena: return "Configurar \(vpn.name)"
        default: return "Conectar \(vpn.name)"
        }
    }

    private func accionCirculo() {
        switch situacion {
        case .faltaConfigurar, .faltaContrasena: alConfigurar()
        case .conectando: break
        default: alAlternar()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                circulo
                VStack(alignment: .leading, spacing: 1) {
                    Text(vpn.name)
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: estado == .conectando ? 1 : 30)) { _ in
                        Text(descripcion)
                            .font(.caption)
                            .foregroundStyle(colorDescripcion)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if puedeExpandir { withAnimation(.snappy(duration: 0.2)) { expandida.toggle() } } }
                accesorio
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            if expandida && puedeExpandir {
                detalles
                    .padding(.leading, 44)
                    .padding(.trailing, 10)
                    .padding(.bottom, 7)
                    .transition(.opacity)
            }
        }
        .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hover = $0 }
        .help(ayuda)
        .accessibilityElement(children: .contain)
    }

    private var ayuda: String {
        if case .error(let fallo) = situacion { return fallo.detalle }
        return ""
    }

    private var puedeExpandir: Bool {
        switch situacion {
        case .conectada, .error: return true
        default: return false
        }
    }

    private var circulo: some View {
        Button(action: accionCirculo) {
            ZStack {
                Circle().fill(fondoCirculo)
                Image(systemName: simbolo)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(estado == .conectada ? Color.white : tinte)
                if case .conectando = situacion { AnilloGiratorio() }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(bloqueada || estado == .conectando)
        .accessibilityLabel(etiquetaCirculo)
        .accessibilityValue(descripcion)
        .modifier(AtajoNumerico(numero: atajo))
    }

    @ViewBuilder
    private var accesorio: some View {
        switch situacion {
        case .caida:
            BotonFila(titulo: "Reconectar", accion: alAlternar).disabled(bloqueada)
        case .error(let fallo):
            switch fallo.accion {
            case .reintentar(let titulo): BotonFila(titulo: titulo, accion: alAlternar).disabled(bloqueada)
            case .ajustes(let titulo): BotonFila(titulo: titulo, accion: alConfigurar)
            case .ninguna: BotonFila(titulo: "Descartar", accion: alDescartar)
            }
            chevron
        case .faltaContrasena, .faltaConfigurar:
            BotonFila(titulo: "Ajustes…", accion: alConfigurar)
        case .conectada:
            chevron
        case .conectando:
            BotonFila(titulo: "Cancelar", accion: alCancelar)
                .help("Detiene este intento de conexión. Las demás VPN no se tocan.")
        case .desconectada:
            if let atajo, atajo <= 9 {
                Text("⌘\(atajo)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var chevron: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { expandida.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(expandida ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expandida ? "Ocultar detalles" : "Mostrar detalles")
    }

    @ViewBuilder
    private var detalles: some View {
        if case .error(let fallo) = situacion {
            VStack(alignment: .leading, spacing: 6) {
                Text(fallo.detalle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Mostrar registro") { Log.mostrar() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                if !vpn.ip.isEmpty {
                    GridRow {
                        Text("IP").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text(vpn.ip).monospaced().textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(vpn.ip, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Copiar IP")
                            .accessibilityLabel("Copiar IP")
                        }
                    }
                }
                if !vpn.iface.isEmpty {
                    GridRow { Text("Interfaz").foregroundStyle(.secondary); Text(vpn.iface).monospaced() }
                }
                if !vpn.iface.isEmpty {
                    GridRow { Text("Rutas").foregroundStyle(.secondary); Text("\(vpn.networks.count)").monospacedDigit() }
                }
                if let inicio = vpn.inicio {
                    GridRow {
                        Text("Desde").foregroundStyle(.secondary)
                        Text(inicio.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                    }
                }
                if vpn.ip.isEmpty && vpn.iface.isEmpty && vpn.inicio == nil {
                    Text("No se pudieron leer los detalles del túnel.").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }
}

private struct AtajoNumerico: ViewModifier {
    let numero: Int?
    func body(content: Content) -> some View {
        if let numero, (1...9).contains(numero), let tecla = String(numero).first {
            content.keyboardShortcut(KeyEquivalent(tecla), modifiers: .command)
        } else {
            content
        }
    }
}

private struct AnilloGiratorio: View {
    @Environment(\.accessibilityReduceMotion) private var reducirMovimiento
    @State private var girando = false

    var body: some View {
        Circle()
            .trim(from: 0, to: reducirMovimiento ? 1 : 0.28)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 30, height: 30)
            .rotationEffect(.degrees(girando ? 360 : 0))
            .animation(reducirMovimiento ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: girando)
            .onAppear { girando = true }
    }
}

private struct BotonFila: View {
    let titulo: String
    let accion: () -> Void
    var body: some View {
        Button(titulo, action: accion)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

// MARK: - Elementos de menú

/// Elemento con aspecto de menú de macOS: resaltado con el color de acento al
/// pasar el puntero y atajo alineado a la derecha.
private struct ElementoMenu: View {
    let titulo: String
    let atajo: String
    let tecla: KeyEquivalent?
    let accion: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: accion) {
            HStack {
                Text(titulo)
                Spacer()
                Text(atajo).foregroundStyle(hover ? Color.white.opacity(0.8) : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(hover ? Color.white : Color.primary)
            .background(hover ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(AtajoOpcional(tecla: tecla))
        .onHover { hover = $0 }
    }
}

private struct AtajoOpcional: ViewModifier {
    let tecla: KeyEquivalent?
    func body(content: Content) -> some View {
        if let tecla { content.keyboardShortcut(tecla, modifiers: .command) } else { content }
    }
}

// MARK: - Panel

struct PanelVPN: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var modelo: VPNModel

    private var resumen: String {
        switch modelo.conectadas {
        case 0: return modelo.vpnsVisibles.isEmpty ? "" : "Sin conexiones activas"
        case 1: return "1 conectada"
        case let n: return "\(n) conectadas"
        }
    }

    private func abrirAjustes(_ id: String? = nil) {
        if let id { modelo.settingsTargetID = id }
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    /// Un error que no corresponde a ninguna fila (por ejemplo, del ayudante).
    private var errorGeneral: String? {
        if let error = modelo.errorConsulta { return error }
        return modelo.ultimoError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nuvex").fontWeight(.semibold)
                Spacer()
                Text(resumen).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if modelo.vpnsVisibles.isEmpty {
                vacio
            } else {
                // Hasta 8 filas caben sin desplazamiento; con más, la lista se
                // desplaza dentro de una altura fija para no tapar la pantalla.
                if modelo.vpnsVisibles.count <= 8 {
                    filas
                } else {
                    ScrollView { filas }.frame(height: 8 * 37)
                }
            }

            if modelo.instalandoAyudante {
                Nota(simbolo: nil, color: .secondary,
                     texto: "Preparando el ayudante de red. Autoriza el cambio en el diálogo de macOS.")
            } else if modelo.ayudanteListo == false && !modelo.profiles.isEmpty {
                NotaConAccion(simbolo: "shield.lefthalf.filled", color: .orange,
                              texto: "El ayudante de red necesita tu autorización.",
                              accion: "Autorizar") { modelo.instalarAyudante() }
            }
            if let chequeo = modelo.chequeo {
                AvisosChequeo(chequeo: chequeo, modelo: modelo)
            }
            if let actualizaciones = modelo.actualizaciones {
                AvisoActualizacion(actualizaciones: actualizaciones)
            }
            if let aviso = modelo.avisoConvivencia {
                Nota(simbolo: "exclamationmark.triangle.fill", color: .orange, texto: aviso)
            }
            if let error = errorGeneral, !modelo.vpnsVisibles.isEmpty {
                Nota(simbolo: "exclamationmark.circle.fill", color: .red, texto: error, seleccionable: true)
            }

            Divider().padding(.horizontal, 10).padding(.vertical, 5)
            if let actualizaciones = modelo.actualizaciones, actualizaciones.configuradas {
                ElementoMenu(titulo: "Buscar actualizaciones…", atajo: "", tecla: nil) { actualizaciones.mostrar() }
            }
            ElementoMenu(titulo: "Ajustes de Nuvex…", atajo: "⌘,", tecla: ",") { abrirAjustes() }
            ElementoMenu(titulo: "Salir de Nuvex", atajo: "⌘Q", tecla: "q") { NSApp.terminate(nil) }
        }
        .padding(6)
        .frame(width: 320)
    }

    private var filas: some View {
        VStack(spacing: 0) {
            ForEach(Array(modelo.vpnsVisibles.enumerated()), id: \.element.id) { indice, vpn in
                FilaVPN(vpn: vpn,
                        estado: modelo.estado(vpn),
                        passwordStatus: modelo.passwordStatuses[vpn.id],
                        caidaEn: modelo.desconexiones[vpn.id],
                        conectandoDesde: modelo.inicioConexion[vpn.id],
                        esperandoCodigo: modelo.esperandoCodigo.contains(vpn.id),
                        atajo: indice + 1,
                        bloqueada: modelo.instalandoAyudante,
                        alAlternar: { modelo.alternar(vpn) },
                        alConfigurar: { abrirAjustes(vpn.id) },
                        alDescartar: { modelo.descartarAviso(vpn.id) },
                        alCancelar: { modelo.cancelarConexion(vpn.id) })
            }
        }
    }

    @ViewBuilder
    private var vacio: some View {
        VStack(spacing: 6) {
            if let error = modelo.errorConsulta {
                Image(systemName: "network.slash").font(.title2).foregroundStyle(.secondary)
                Text("No se pudo leer el estado").fontWeight(.semibold)
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                Button("Mostrar registro") { Log.mostrar() }.controlSize(.small).padding(.top, 4)
            } else if modelo.profiles.isEmpty {
                LogoNuvex(lado: 34)
                Text("Aún no hay conexiones").fontWeight(.semibold)
                Text("Añade tu servidor Fortinet para conectarte desde aquí.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Añadir conexión…") { Bienvenida.mostrar(modelo: modelo) }
                    .buttonStyle(.borderedProminent).controlSize(.small).padding(.top, 4)
            } else {
                Image(systemName: "eye.slash").font(.title2).foregroundStyle(.secondary)
                Text("No hay conexiones visibles").fontWeight(.semibold)
                Text("Activa «Mostrar en la barra de menús» en Ajustes.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Abrir Ajustes…") { abrirAjustes() }.controlSize(.small).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
    }
}

private struct Nota: View {
    let simbolo: String?
    let color: Color
    let texto: String
    var seleccionable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if let simbolo {
                Image(systemName: simbolo).foregroundStyle(color)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(texto)
                .foregroundStyle(simbolo == nil ? Color.secondary : (color == .red ? Color.red : Color.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .modifier(Seleccionable(activo: seleccionable))
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

/// Nota con un botón que resuelve lo que indica.
private struct NotaConAccion: View {
    let simbolo: String
    let color: Color
    let texto: String
    let accion: String
    var ocupado = false
    let alPulsar: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: simbolo).foregroundStyle(color)
            Text(texto)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if ocupado {
                ProgressView().controlSize(.mini)
            } else {
                Button(accion, action: alPulsar)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// Avisos del primer arranque de una versión nueva.
private struct AvisosChequeo: View {
    @ObservedObject var chequeo: ChequeoActualizacion
    @ObservedObject var modelo: VPNModel

    var body: some View {
        if chequeo.llaveroPendiente {
            NotaConAccion(simbolo: "key.fill", color: .orange,
                          texto: chequeo.firmaEstable
                            ? "Nuvex cambió de firma. Pruébalo ahora y elige «Permitir siempre» para que el Llavero no vuelva a preguntar."
                            : "Esta compilación no tiene firma estable: macOS pedirá acceso al Llavero tras cada actualización.",
                          accion: "Probar", ocupado: chequeo.probandoLlavero) { chequeo.probarLlavero(modelo) }
            if let error = chequeo.errorLlavero {
                Nota(simbolo: "exclamationmark.circle.fill", color: .red, texto: error, seleccionable: true)
            }
        }
        if let version = chequeo.novedades {
            NotaConAccion(simbolo: "sparkles", color: .accentColor,
                          texto: "Nuvex se actualizó a la versión \(version).", accion: "Novedades") {
                VentanaNovedades.mostrar(version: version)
                chequeo.novedadesVistas()
            }
        }
    }
}

private struct AvisoActualizacion: View {
    @ObservedObject var actualizaciones: Actualizaciones

    var body: some View {
        if let version = actualizaciones.disponible {
            NotaConAccion(simbolo: "arrow.down.circle.fill", color: .accentColor,
                          texto: "Nuvex \(version) está disponible.", accion: "Ver") {
                actualizaciones.mostrar()
            }
        }
    }
}

private struct Seleccionable: ViewModifier {
    let activo: Bool
    func body(content: Content) -> some View {
        if activo { content.textSelection(.enabled) } else { content }
    }
}
