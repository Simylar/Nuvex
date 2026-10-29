import AppKit
import SwiftUI

// MARK: - Fila de una VPN

/// Fila compacta al estilo del Centro de control: cuando está desconectada,
/// toda la cabecera conecta; en los demás estados conserva controles separados.
struct FilaVPN: View {
    let vpn: VPNStatus
    let estado: EstadoUI
    let passwordStatus: PasswordStatus?
    let caidaEn: Date?
    /// Inicio del intento en curso y si espera el código, para mostrar el avance.
    var conectandoDesde: Date? = nil
    var esperandoCodigo = false
    var recuperando = false
    var desconectando = false
    var estadoSinConfirmar = false
    let atajo: Int?
    let bloqueada: Bool
    let alAlternar: () -> Void
    let alConfigurar: () -> Void
    let alDescartar: () -> Void
    var alCancelar: () -> Void = {}

    @State private var hover = false
    @State private var expandida = false
    @Environment(\.accessibilityReduceMotion) private var reducirMovimiento

    private enum Situacion {
        case conectada, conectando, caida(Date), error(Fallo)
        case faltaConfigurar, faltaContrasena, desconectada
    }

    private var situacion: Situacion {
        if recuperando { return .conectando }
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
        if estadoSinConfirmar { return "questionmark" }
        switch situacion {
        case .conectada: return "lock.fill"
        case .conectando, .desconectada: return "lock.open.fill"
        case .caida, .error: return "exclamationmark.triangle.fill"
        case .faltaContrasena: return "key.fill"
        case .faltaConfigurar: return "slider.horizontal.3"
        }
    }

    private var tinte: Color {
        if estadoSinConfirmar { return .secondary }
        switch situacion {
        case .conectada, .conectando, .desconectada: return .primary
        case .error: return Paleta.error
        case .caida, .faltaContrasena, .faltaConfigurar: return Paleta.aviso
        }
    }

    /// El panel ya es vidrio del sistema: el círculo es un relleno opaco,
    /// como los controles del Centro de control. Acento al conectar.
    private var fondoCirculo: Color {
        if estadoSinConfirmar { return Paleta.rellenoIntenso }
        switch situacion {
        case .conectada: return Paleta.acento
        case .conectando, .desconectada: return Paleta.rellenoIntenso
        default: return tinte.opacity(0.16)
        }
    }

    private var descripcion: String {
        if desconectando { return "Desconectando…" }
        if estadoSinConfirmar { return "Estado sin comprobar" }
        if recuperando { return "Reconectando en unos segundos…" }
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
        if estadoSinConfirmar { return .secondary }
        switch situacion {
        case .error: return Paleta.errorTexto
        case .caida, .faltaContrasena, .faltaConfigurar: return Paleta.avisoTexto
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            encabezado

            if expandida && puedeExpandir {
                detalles
                    // Alineados con el nombre: margen + círculo + separación.
                    .padding(.leading, Espacio.m + Tamano.circuloEstado + Espacio.l)
                    .padding(.trailing, Espacio.l)
                    .padding(.bottom, Espacio.m)
                    .transition(Movimiento.aparicion(reducir: reducirMovimiento))
            }
        }
        // Una fila que conecta entera ya resalta con su estilo de botón.
        .background(RoundedRectangle.nuvex(Radio.m).fill(hover && !conectaDesdeFila ? Paleta.relleno : .clear))
        .onHover { hover = $0 }
        .animacion(Movimiento.rapida, value: hover)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var encabezado: some View {
        if conectaDesdeFila {
            Button(action: alAlternar) {
                contenidoEncabezado
            }
            .buttonStyle(EstiloFila())
            .disabled(bloqueada)
            .accessibilityLabel("Conectar \(vpn.name)")
            .accessibilityValue(descripcion)
            .modifier(AtajoNumerico(numero: atajo))
        } else {
            contenidoEncabezado
        }
    }

    private var contenidoEncabezado: some View {
        HStack(spacing: Espacio.l) {
            circulo
            textos
            accesorio
        }
        .padding(.horizontal, Espacio.m)
        .padding(.vertical, Espacio.s)
        .frame(minHeight: Tamano.filaPanel)
        .contentShape(Rectangle())
    }

    private var textos: some View {
        VStack(alignment: .leading, spacing: Espacio.xxs / 2) {
            Text(vpn.name)
                .font(Tipo.cuerpoEnfasis)
                .lineLimit(1)
            TimelineView(.periodic(from: .now, by: estado == .conectando ? 1 : 30)) { _ in
                Text(descripcion)
                    .font(Tipo.apoyo)
                    .monospacedDigit()
                    .foregroundStyle(colorDescripcion)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alternarDetalles() {
        withAnimation(reducirMovimiento ? Movimiento.reducida : Movimiento.estandar) { expandida.toggle() }
    }

    private var puedeExpandir: Bool {
        switch situacion {
        case .conectada, .error: return true
        default: return false
        }
    }

    private var conectaDesdeFila: Bool {
        if case .desconectada = situacion { return !estadoSinConfirmar }
        return false
    }

    private var circulo: some View {
        contenidoCirculo.accessibilityHidden(true)
    }

    private var contenidoCirculo: some View {
        ZStack {
            Image(systemName: simbolo)
                .font(.system(size: Tamano.simboloCirculo, weight: .semibold))
                .foregroundStyle(estado == .conectada && !estadoSinConfirmar ? Color.white : tinte)
                .contentTransition(.symbolEffect(.replace))
            if case .conectando = situacion { AnilloGiratorio() }
        }
        .frame(width: Tamano.circuloEstado, height: Tamano.circuloEstado)
        .background(Circle().fill(fondoCirculo))
        .animacion(Movimiento.estandar, value: estado == .conectada)
        .contentShape(Circle())
    }

    @ViewBuilder
    private var accesorio: some View {
        switch situacion {
        case .caida:
            BotonFila(titulo: "Reconectar", accion: alAlternar).disabled(bloqueada || estadoSinConfirmar)
                .modifier(AtajoNumerico(numero: atajo))
        case .error(let fallo):
            switch fallo.accion {
            case .reintentar(let titulo):
                BotonFila(titulo: titulo, accion: alAlternar).disabled(bloqueada || estadoSinConfirmar)
                    .modifier(AtajoNumerico(numero: atajo))
            case .ajustes(let titulo):
                BotonFila(titulo: titulo, accion: alConfigurar).modifier(AtajoNumerico(numero: atajo))
            case .ninguna: BotonFila(titulo: "Descartar", accion: alDescartar)
            }
            chevron
        case .faltaContrasena:
            BotonFila(titulo: "Añadir…", accion: alConfigurar).modifier(AtajoNumerico(numero: atajo))
        case .faltaConfigurar:
            BotonFila(titulo: "Completar…", accion: alConfigurar).modifier(AtajoNumerico(numero: atajo))
        case .conectada:
            BotonFila(titulo: desconectando ? "Desconectando…" : "Desconectar", accion: alAlternar)
                .disabled(bloqueada || desconectando)
                .modifier(AtajoNumerico(numero: atajo))
                .accessibilityLabel("Desconectar \(vpn.name)")
            chevron
        case .conectando:
            if esperandoCodigo {
                BotonFila(titulo: "Código…") { VentanaCodigo.traerAlFrente(vpn.id) }
                    .accessibilityLabel("Introducir el código para \(vpn.name)")
            }
            BotonFila(titulo: "Cancelar", accion: alCancelar)
                .accessibilityLabel("Cancelar la conexión de \(vpn.name)")
                .help("Detiene este intento de conexión. Las demás VPN no se tocan.")
        case .desconectada:
            Text("Conectar")
                .font(Tipo.apoyo)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var chevron: some View {
        Button {
            alternarDetalles()
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: Tamano.simboloPequeno, weight: .semibold))
                .rotationEffect(.degrees(expandida ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expandida ? "Ocultar detalles" : "Mostrar detalles")
        .accessibilityLabel((expandida ? "Ocultar detalles de " : "Mostrar detalles de ") + vpn.name)
        .accessibilityValue(expandida ? "Expandido" : "Contraído")
    }

    @ViewBuilder
    private var detalles: some View {
        if case .error(let fallo) = situacion {
            VStack(alignment: .leading, spacing: Espacio.s) {
                Text(fallo.detalle)
                    .font(Tipo.nota)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Mostrar registro") { Log.mostrar() }
                    .buttonStyle(.link)
                    .font(Tipo.nota)
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: Espacio.l, verticalSpacing: Espacio.xs) {
                if !vpn.ip.isEmpty {
                    GridRow {
                        Text("IP").foregroundStyle(.secondary)
                        HStack(spacing: Espacio.xs) {
                            Text(vpn.ip).monospaced().textSelection(.enabled)
                            BotonCopiar(texto: vpn.ip, etiqueta: "Copiar IP")
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
            .font(Tipo.nota)
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
            .stroke(Paleta.acento, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: Tamano.circuloEstado + Espacio.xs, height: Tamano.circuloEstado + Espacio.xs)
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
            .estiloBoton(.secundario)
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
            .padding(.horizontal, Espacio.m)
            .padding(.vertical, Espacio.xs)
            .foregroundStyle(hover ? Color.white : Color.primary)
            .background(RoundedRectangle.nuvex(Radio.s).fill(hover ? Paleta.acento : .clear))
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
        if modelo.errorConsulta != nil || modelo.errorCargaConfiguracion != nil { return "Requiere atención" }
        if modelo.instalandoAyudante { return "Preparando conexión…" }
        if !modelo.desconectando.isEmpty { return "Desconectando…" }
        if modelo.hayConectando || !modelo.recuperando.isEmpty { return "Conectando…" }
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
        modelo.ultimoError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nuvex").font(Tipo.encabezado)
                Spacer()
                Text(resumen).font(Tipo.nota).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Espacio.m)
            .padding(.top, Espacio.s)
            .padding(.bottom, Espacio.s)

            if modelo.errorCargaConfiguracion != nil {
                problemaConfiguracion
            } else if modelo.vpnsVisibles.isEmpty {
                vacio
            } else {
                // Hasta 8 filas caben sin desplazamiento; con más, la lista se
                // desplaza dentro de una altura fija para no tapar la pantalla.
                if modelo.vpnsVisibles.count <= 8 {
                    filas
                } else {
                    ScrollView { filas }.frame(height: 8 * Tamano.filaPanel)
                }
            }

            if modelo.instalandoAyudante {
                Nota(simbolo: nil, color: .secondary,
                     texto: "Preparando el ayudante de red. Autoriza el cambio en el diálogo de macOS.")
            } else if modelo.errorConsulta == nil && modelo.ayudanteListo == false && !modelo.profiles.isEmpty {
                NotaConAccion(simbolo: "shield.lefthalf.filled", color: Paleta.aviso,
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
                Nota(simbolo: "exclamationmark.triangle.fill", color: Paleta.aviso, texto: aviso)
            }
            if modelo.errorConsulta != nil, !modelo.vpnsVisibles.isEmpty {
                NotaConAccion(simbolo: "exclamationmark.circle.fill", color: Paleta.aviso,
                              texto: "No se pudo comprobar el estado. Vuelve a intentarlo antes de conectar.",
                              accion: "Reintentar") { modelo.refrescar() }
            } else if errorGeneral != nil, modelo.errorCargaConfiguracion == nil {
                VStack(alignment: .leading, spacing: Espacio.s) {
                    NotaConAccion(simbolo: "exclamationmark.circle.fill", color: Paleta.aviso,
                                  texto: "No se completó la operación. Revisa los permisos o vuelve a intentarlo.",
                                  accion: "Revisar") { abrirAjustes() }
                    DisclosureGroup("Detalles del problema") {
                        Text(errorGeneral ?? "").font(Tipo.nota).textSelection(.enabled)
                        Button("Mostrar registro") { Log.mostrar() }.buttonStyle(.link)
                    }
                    .font(Tipo.nota).padding(.horizontal, Espacio.m)
                }
            }

            Divider().padding(.horizontal, Espacio.m).padding(.vertical, Espacio.s)
            if let actualizaciones = modelo.actualizaciones, actualizaciones.configuradas {
                ElementoMenu(titulo: "Buscar actualizaciones…", atajo: "", tecla: nil) { actualizaciones.mostrar() }
            }
            if !modelo.profiles.isEmpty {
                ElementoMenu(titulo: "Añadir conexión…", atajo: "⌘N", tecla: "n") { Bienvenida.mostrar(modelo: modelo) }
            }
            ElementoMenu(titulo: "Ajustes de Nuvex…", atajo: "⌘,", tecla: ",") { abrirAjustes() }
            ElementoMenu(titulo: "Salir de Nuvex", atajo: "⌘Q", tecla: "q") { NSApp.terminate(nil) }
        }
        .padding(Espacio.s)
        .frame(width: Tamano.panel)
    }

    private var problemaConfiguracion: some View {
        EstadoVacio("No se pudieron cargar tus conexiones",
                    detalle: modelo.datosMasNuevos
                        ? "Actualiza Nuvex para usar estos datos."
                        : "Tus datos guardados se conservan. Vuelve a cargarlos para continuar.",
                    simbolo: "exclamationmark.triangle") {
            Button("Volver a cargar") { modelo.cargarConfiguracion(); modelo.refrescar() }
                .estiloBoton(.principal).disabled(modelo.cargandoConfiguracion)
            Button("Mostrar registro") { Log.mostrar() }.estiloBoton(.secundario)
        }
        .padding(Espacio.xl)
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
                        recuperando: modelo.recuperando.contains(vpn.id),
                        desconectando: modelo.desconectando.contains(vpn.id),
                        estadoSinConfirmar: modelo.errorConsulta != nil,
                        atajo: indice + 1,
                        bloqueada: modelo.instalandoAyudante || modelo.guardandoConfiguracion,
                        alAlternar: { modelo.alternar(vpn) },
                        alConfigurar: { abrirAjustes(vpn.id) },
                        alDescartar: { modelo.descartarAviso(vpn.id) },
                        alCancelar: { modelo.cancelarConexion(vpn.id) })
            }
        }
    }

    @ViewBuilder
    private var vacio: some View {
        Group {
            if modelo.cargandoConfiguracion || (!modelo.configuracionCargada && modelo.errorCargaConfiguracion == nil) {
                ProgressView("Cargando conexiones…")
            } else if modelo.errorConsulta != nil {
                EstadoVacio("No se pudo comprobar el estado",
                            detalle: "Tus conexiones se conservan. Vuelve a intentarlo para consultar su estado.", simbolo: "network.slash") {
                    Button("Reintentar") { modelo.refrescar() }.estiloBoton(.principal)
                    Button("Mostrar registro") { Log.mostrar() }.estiloBoton(.secundario)
                }
            } else if modelo.profiles.isEmpty {
                EstadoVacio("Aún no hay conexiones",
                            detalle: "Añade tu servidor Fortinet para conectarte desde aquí.",
                            icono: { LogoNuvex(lado: Tamano.iconoCabecera) }) {
                    Button("Añadir conexión…") { Bienvenida.mostrar(modelo: modelo) }.estiloBoton(.principal)
                }
            } else {
                EstadoVacio("No hay conexiones visibles",
                            detalle: "Activa «Mostrar en la barra de menús» en Ajustes.", simbolo: "eye.slash") {
                    Button("Abrir Ajustes…") { abrirAjustes() }.estiloBoton(.secundario)
                }
            }
        }
        .padding(.horizontal, Espacio.xl)
        .padding(.vertical, Espacio.xxl)
    }
}

private struct Nota: View {
    let simbolo: String?
    let color: Color
    let texto: String
    var seleccionable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Espacio.l) {
            Group {
                if let simbolo {
                    Image(systemName: simbolo).foregroundStyle(color)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: Tamano.circuloEstado)
            Text(texto)
                .foregroundStyle(simbolo != nil && color == Paleta.error ? Paleta.errorTexto : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(Seleccionable(activo: seleccionable))
        }
        .font(Tipo.nota)
        .padding(.horizontal, Espacio.m)
        .padding(.vertical, Espacio.s)
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
        HStack(alignment: .center, spacing: Espacio.l) {
            Image(systemName: simbolo).foregroundStyle(color)
                .frame(width: Tamano.circuloEstado)
            Text(texto)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if ocupado {
                ProgressView().controlSize(.mini)
            } else {
                Button(accion, action: alPulsar)
                    .estiloBoton(.secundario)
                    .controlSize(.small)
            }
        }
        .font(Tipo.nota)
        .padding(.horizontal, Espacio.m)
        .padding(.vertical, Espacio.xs)
    }
}

/// Avisos del primer arranque de una versión nueva.
private struct AvisosChequeo: View {
    @ObservedObject var chequeo: ChequeoActualizacion
    @ObservedObject var modelo: VPNModel

    var body: some View {
        if chequeo.llaveroPendiente {
            NotaConAccion(simbolo: "key.fill", color: Paleta.aviso,
                          texto: chequeo.firmaEstable
                            ? "Nuvex cambió de firma. Pruébalo ahora y elige «Permitir siempre» para que el Llavero no vuelva a preguntar."
                            : "Esta compilación no tiene firma estable: macOS pedirá acceso al Llavero tras cada actualización.",
                          accion: "Probar", ocupado: chequeo.probandoLlavero) { chequeo.probarLlavero(modelo) }
            if let error = chequeo.errorLlavero {
                Nota(simbolo: "exclamationmark.circle.fill", color: Paleta.error, texto: error, seleccionable: true)
            }
        }
        if let version = chequeo.novedades {
            NotaConAccion(simbolo: "sparkles", color: Paleta.acento,
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
        if actualizaciones.requiereAtencion {
            NotaConAccion(simbolo: "exclamationmark.triangle.fill", color: Paleta.aviso,
                          texto: "La última actualización necesita atención.", accion: "Revisar") {
                actualizaciones.mostrar()
            }
        } else if let version = actualizaciones.disponible {
            NotaConAccion(simbolo: "arrow.down.circle.fill", color: Paleta.acento,
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
