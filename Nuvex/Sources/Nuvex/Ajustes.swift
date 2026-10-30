import AppKit
import SwiftUI

enum PaginaAjustes: Hashable {
    case general
    case actualizacion
    case automatizacion
    case cuentaGoogle
    case ayudante
    case conexion(String)
}

/// Borradores de Ajustes. Viven fuera de la ventana para que cerrarla no
/// pierda los cambios sin guardar; las contraseñas escritas sí se descartan.
@MainActor
final class BorradoresAjustes: ObservableObject {
    @Published var drafts: [VPNProfile] = []
    @Published var passwords: [String: String] = [:]
    @Published var seleccion: PaginaAjustes? = .general
    /// Conexiones en las que se pulsó Guardar con datos incompletos.
    @Published var intentos: Set<String> = []
    /// Campos editados ("id.campo"): sus avisos se muestran después de escribir.
    @Published var tocados: Set<String> = []
    @Published var editandoContrasena: Set<String> = []
    private var ultimosGuardados: [VPNProfile] = []

    /// Incorpora los perfiles guardados sin pisar ediciones pendientes ni
    /// conexiones nuevas que aún no se guardaron.
    func sincronizar(con guardados: [VPNProfile]) {
        let anteriores = ultimosGuardados
        var resultado: [VPNProfile] = []
        for guardado in guardados {
            let base = guardado.normalizado
            if let borrador = drafts.first(where: { $0.id == guardado.id }),
               let previo = anteriores.first(where: { $0.id == guardado.id }),
               borrador != previo.normalizado, borrador != base {
                resultado.append(borrador)
            } else {
                resultado.append(base)
            }
        }
        for borrador in drafts where !guardados.contains(where: { $0.id == borrador.id })
            && !anteriores.contains(where: { $0.id == borrador.id }) {
            resultado.append(borrador)
        }
        drafts = resultado
        ultimosGuardados = guardados
        if case .conexion(let id) = seleccion, !drafts.contains(where: { $0.id == id }) {
            seleccion = drafts.first.map { .conexion($0.id) } ?? .general
        }
    }

    func nuevaConexion() {
        let perfil = VPNProfile.nuevo()
        drafts.append(perfil)
        seleccion = .conexion(perfil.id)
    }

    func descartar(_ id: String) {
        drafts.removeAll { $0.id == id }
        Preferencias.shared.olvidarConexion(id)
        limpiar(id)
        if seleccion == .conexion(id) { seleccion = drafts.first.map { .conexion($0.id) } ?? .general }
    }

    func revertir(_ id: String, a guardado: VPNProfile) {
        if let i = drafts.firstIndex(where: { $0.id == id }) { drafts[i] = guardado.normalizado }
        limpiar(id)
    }

    func limpiar(_ id: String) {
        passwords[id] = nil
        intentos.remove(id)
        editandoContrasena.remove(id)
        tocados = tocados.filter { !$0.hasPrefix(id + ".") }
    }

    func tieneCambios(_ perfil: VPNProfile, guardados: [VPNProfile]) -> Bool {
        guard let guardado = guardados.first(where: { $0.id == perfil.id }) else { return true }
        return perfil != guardado || !(passwords[perfil.id] ?? "").isEmpty
    }
}

// MARK: - Ventana de Ajustes

struct ConfigurationView: View {
    @ObservedObject var modelo: VPNModel
    @ObservedObject var borradores: BorradoresAjustes
    @State private var pendingDeletion: String?

    private var busy: Bool { modelo.guardandoConfiguracion || modelo.instalandoAyudante }

    var body: some View {
        NavigationSplitView {
            barraLateral
                .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 300)
        } detail: {
            detalle
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 780, minHeight: 580)
        .onAppear {
            borradores.sincronizar(con: modelo.profiles)
            aplicarDestino(modelo.settingsTargetID)
            aplicarPagina(modelo.paginaDestino)
            if borradores.seleccion == nil {
                borradores.seleccion = borradores.drafts.first.map { .conexion($0.id) } ?? .general
            }
            modelo.cargarConfiguracion()
        }
        .onDisappear {
            // Las contraseñas escritas no se conservan con la ventana cerrada.
            borradores.passwords.removeAll()
            borradores.editandoContrasena.removeAll()
        }
        .onChange(of: modelo.profiles) { _, nuevos in borradores.sincronizar(con: nuevos) }
        .onChange(of: modelo.settingsTargetID) { _, id in aplicarDestino(id) }
        .onChange(of: modelo.paginaDestino) { _, pagina in aplicarPagina(pagina) }
        .confirmationDialog(tituloEliminacion, isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Eliminar", role: .destructive) {
                if let id = pendingDeletion { eliminar(id) }
                pendingDeletion = nil
            }
        } message: {
            Text(mensajeEliminacion)
        }
    }

    private func aplicarDestino(_ id: String?) {
        guard let id else { return }
        if borradores.drafts.contains(where: { $0.id == id }) { borradores.seleccion = .conexion(id) }
        modelo.settingsTargetID = nil
    }

    private func aplicarPagina(_ pagina: PaginaAjustes?) {
        guard let pagina else { return }
        borradores.seleccion = pagina
        modelo.paginaDestino = nil
    }

    private var tituloEliminacion: String {
        let nombre = borradores.drafts.first { $0.id == pendingDeletion }?.name ?? ""
        return nombre.isEmpty ? "¿Eliminar esta conexión?" : "¿Eliminar «\(nombre)»?"
    }

    private var mensajeEliminacion: String {
        guard let id = pendingDeletion, modelo.profiles.contains(where: { $0.id == id }) else {
            return "Se descartará la conexión que aún no guardaste."
        }
        return "Se borrarán la conexión y su contraseña del Llavero. No se puede deshacer."
    }

    private func eliminar(_ id: String) {
        if modelo.profiles.contains(where: { $0.id == id }) {
            borradores.limpiar(id)
            modelo.eliminarConexion(id)
        } else {
            borradores.descartar(id)
        }
    }

    private func puedeEliminar(_ id: String) -> Bool {
        guard modelo.profiles.contains(where: { $0.id == id }) else { return true }
        return !busy && !modelo.hayAlgunaConectada
    }

    // MARK: Barra lateral

    private var barraLateral: some View {
        List(selection: $borradores.seleccion) {
            Label { Text("General") } icon: { IconoCuadrado(simbolo: "gearshape.fill", color: Paleta.neutro) }
                .foregroundStyle(colorTextoLateral(.general))
                .tag(PaginaAjustes.general)
            FilaActualizacionLateral(actualizaciones: modelo.actualizaciones,
                                     seleccionada: borradores.seleccion == .actualizacion)
                .tag(PaginaAjustes.actualizacion)
            Label { Text("Ayudante de red") } icon: { IconoCuadrado(simbolo: "shield.lefthalf.filled", color: Paleta.iconoAyudante) }
                .foregroundStyle(colorTextoLateral(.ayudante))
                .tag(PaginaAjustes.ayudante)
            Label { Text("Automatización") } icon: { IconoCuadrado(simbolo: "terminal.fill", color: Paleta.grafito) }
                .foregroundStyle(colorTextoLateral(.automatizacion))
                .tag(PaginaAjustes.automatizacion)
            Label { Text("Cuenta de Google") } icon: { IconoCuadrado(simbolo: "envelope.fill", color: Paleta.iconoCorreo) }
                .foregroundStyle(colorTextoLateral(.cuentaGoogle))
                .tag(PaginaAjustes.cuentaGoogle)
            Section("Conexiones") {
                ForEach(borradores.drafts) { perfil in
                    filaLateral(perfil)
                        .tag(PaginaAjustes.conexion(perfil.id))
                        .contextMenu { menuContextual(perfil) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: Espacio.xxs) {
                Button { borradores.nuevaConexion() } label: {
                    Image(systemName: "plus").frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .help("Añadir conexión")
                .accessibilityLabel("Añadir conexión")
                .disabled(borradores.drafts.count >= 64 || busy)
                Button {
                    if case .conexion(let id) = borradores.seleccion { pendingDeletion = id }
                } label: {
                    Image(systemName: "minus").frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .help(modelo.hayAlgunaConectada ? "Desconecta las VPN activas para eliminar conexiones" : "Eliminar conexión")
                .accessibilityLabel("Eliminar conexión")
                .disabled({
                    guard case .conexion(let id) = borradores.seleccion else { return true }
                    return !puedeEliminar(id)
                }())
                Spacer()
                Menu {
                    Button("Exportar conexiones…") { VentanaExportar.mostrar(modelo: modelo) }
                        .disabled(modelo.profiles.isEmpty)
                    Button("Importar conexiones…") { VentanaImportar.mostrar(modelo: modelo) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Exportar o importar conexiones")
                .accessibilityLabel("Exportar o importar conexiones")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Espacio.m)
            .padding(.vertical, Espacio.s)
        }
    }

    /// Las etiquetas dibujadas a medida no heredan siempre el color de texto
    /// de la selección de una barra lateral (en especial al capturarla fuera
    /// de pantalla). Se usa el color semántico de AppKit para mantener el
    /// contraste con cualquier color de acento y estado de la ventana.
    private func colorTextoLateral(_ pagina: PaginaAjustes) -> Color {
        Color(nsColor: borradores.seleccion == pagina ? .alternateSelectedControlTextColor : .labelColor)
    }

    private func filaLateral(_ perfil: VPNProfile) -> some View {
        let pagina = PaginaAjustes.conexion(perfil.id)
        let cambios = borradores.tieneCambios(perfil, guardados: modelo.profiles)
        let guardado = modelo.profiles.contains { $0.id == perfil.id }
        let subtitulo: String = {
            if !guardado { return "Sin guardar" }
            if cambios { return "Cambios sin guardar" }
            if !perfil.enabled { return "Oculta · " + (perfil.server.isEmpty ? "sin servidor" : perfil.server) }
            return perfil.server.isEmpty ? "Sin servidor" : perfil.server
        }()
        return HStack(spacing: Espacio.m) {
            IconoCuadrado(simbolo: "lock.fill", color: ColorConexion.para(perfil.id))
            VStack(alignment: .leading, spacing: 0) {
                Text(perfil.name.isEmpty ? "Nueva conexión" : perfil.name).lineLimit(1)
                Text(subtitulo)
                    .font(Tipo.nota)
                    .foregroundStyle(Color(nsColor: borradores.seleccion == pagina
                                           ? .alternateSelectedControlTextColor : .secondaryLabelColor))
                    .lineLimit(1)
            }
            Spacer(minLength: Espacio.xs)
            if let color = colorEstado(perfil.id) {
                Indicador(color: color)
                    .accessibilityLabel(color == Paleta.exito ? "Conectada" : "Requiere atención")
            }
        }
        .foregroundStyle(colorTextoLateral(pagina))
    }

    private func colorEstado(_ id: String) -> Color? {
        guard let vpn = modelo.vpns.first(where: { $0.id == id }) else { return nil }
        if vpn.connected { return Paleta.exito }
        if modelo.desconexiones[id] != nil || modelo.passwordStatuses[id] == .missing || !vpn.configured { return Paleta.aviso }
        if case .error = modelo.estado(vpn) { return Paleta.error }
        return nil
    }

    @ViewBuilder
    private func menuContextual(_ perfil: VPNProfile) -> some View {
        if let vpn = modelo.vpns.first(where: { $0.id == perfil.id }), vpn.enabled {
            if vpn.connected {
                Button("Desconectar") { modelo.desconectar(vpn) }
            } else {
                Button("Conectar") { modelo.conectar(vpn) }
                    .disabled(borradores.tieneCambios(perfil, guardados: modelo.profiles) || busy)
            }
            Divider()
        }
        if modelo.profiles.contains(where: { $0.id == perfil.id }) {
            Button("Exportar…") { VentanaExportar.mostrar(modelo: modelo, preseleccion: perfil.id) }
        }
        Button("Eliminar…", role: .destructive) { pendingDeletion = perfil.id }
            .disabled(!puedeEliminar(perfil.id))
    }

    // MARK: Detalle

    @ViewBuilder
    private var detalle: some View {
        switch borradores.seleccion {
        case .conexion(let id):
            if let indice = borradores.drafts.firstIndex(where: { $0.id == id }) {
                DetalleConexion(modelo: modelo, borradores: borradores,
                                perfil: $borradores.drafts[indice],
                                alEliminar: { pendingDeletion = id },
                                puedeEliminar: puedeEliminar(id))
                    .id(id)
            } else {
                AjustesGenerales(modelo: modelo, borradores: borradores)
            }
        case .actualizacion:
            if let actualizaciones = modelo.actualizaciones {
                ActualizacionSoftwareView(actualizaciones: actualizaciones)
                    .navigationTitle("Actualización de software")
            } else {
                Text("Nuvex \(InfoVersion.actual.descripcion)").foregroundStyle(Paleta.textoSecundario)
                    .navigationTitle("Actualización de software")
            }
        case .ayudante:
            AjustesAyudante(modelo: modelo)
        case .automatizacion:
            AjustesAutomatizacion(modelo: modelo)
        case .cuentaGoogle:
            AjustesCuentaGoogle()
        case .general, nil:
            AjustesGenerales(modelo: modelo, borradores: borradores)
        }
    }
}

// MARK: - General

private struct AjustesGenerales: View {
    @ObservedObject var modelo: VPNModel
    @ObservedObject var borradores: BorradoresAjustes
    @AppStorage("avisarDesconexion") private var avisarDesconexion = true
    @AppStorage("intervaloRevision") private var intervaloRevision = 5
    @AppStorage("reconectarAutomaticamente") private var reconectarAutomaticamente = false
    @State private var inicioActivo = false
    @State private var inicioPendiente = false
    @State private var errorInicio: String?

    private var intervalos: [Int] {
        Array(Set([2, 5, 10, 30, 60, intervaloRevision])).sorted()
    }

    private func leerInicio() {
        inicioActivo = InicioDeSesion.activo
        inicioPendiente = InicioDeSesion.requiereAprobacion
    }

    var body: some View {
        Form {
            if borradores.drafts.isEmpty {
                Section {
                    HStack(spacing: Espacio.l) {
                        LogoNuvex(lado: 40)
                        VStack(alignment: .leading, spacing: Espacio.xxs) {
                            Text("Aún no hay conexiones").font(Tipo.encabezado)
                            Text("Añade tu servidor Fortinet SSL VPN, tu usuario y tu contraseña.")
                                .foregroundStyle(Paleta.textoSecundario)
                        }
                        Spacer()
                        Button("Añadir conexión") { borradores.nuevaConexion() }
                            .estiloBoton(.principal)
                    }
                    .padding(.vertical, Espacio.xs)
                }
            }
            SeccionPermisosNuvex(modelo: modelo) { borradores.seleccion = $0 }
            Section("Inicio") {
                Toggle("Abrir Nuvex al iniciar sesión", isOn: Binding(
                    get: { inicioActivo },
                    set: { activar in
                        do { try InicioDeSesion.cambiar(activar); errorInicio = nil }
                        catch {
                            errorInicio = InicioDeSesion.requiereAprobacion ? nil :
                                "macOS no permitió el cambio: \(error.localizedDescription)"
                        }
                        leerInicio()
                    }))
                if inicioPendiente {
                    LabeledContent {
                        Button("Abrir Ajustes del Sistema…") { InicioDeSesion.abrirAjustesDelSistema() }
                    } label: {
                        Text("macOS necesita que lo apruebes en Ítems de inicio.").foregroundStyle(Paleta.avisoTexto)
                    }
                }
                if let errorInicio {
                    Text(errorInicio).foregroundStyle(Paleta.errorTexto).textSelection(.enabled)
                }
            }
            Section {
                Toggle("Avisar cuando una VPN se desconecte", isOn: $avisarDesconexion)
                EstiloAvisos()
                    .disabled(!avisarDesconexion)
                DisclosureGroup("Frecuencia de comprobación") {
                    Picker("Comprobar el estado", selection: $intervaloRevision) {
                        ForEach(intervalos, id: \.self) { segundos in
                            Text("Cada \(segundos) s").tag(segundos)
                        }
                    }
                    .onChange(of: intervaloRevision) { _, _ in modelo.actualizarIntervalo() }
                }
            } header: {
                Text("Avisos")
            } footer: {
                Text("Con el estilo «Alertas», el aviso de desconexión se queda en pantalla hasta que lo cierres o pulses Reconectar.")
                    .foregroundStyle(Paleta.textoSecundario)
            }
            Section {
                Toggle("Reconectar si se pierde la conexión", isOn: $reconectarAutomaticamente)
            } header: {
                Text("Recuperación")
            } footer: {
                Text("Nuvex hará un solo intento cuando haya red, usando los permisos existentes. Puede pedir el código de verificación. Si falla o falta un permiso, podrás volver a conectar manualmente.")
                    .foregroundStyle(Paleta.textoSecundario)
            }
            SeccionCopias(modelo: modelo)
        }
        .formularioNuvex()
        .navigationTitle("General")
        .onAppear(perform: leerInicio)
    }
}

/// Estilo actual de los avisos de Nuvex y cómo cambiarlo.
private struct EstiloAvisos: View {
    @State private var estilo: VPNNotifications.Estilo?

    var body: some View {
        LabeledContent {
            HStack(spacing: Espacio.m) {
                Button("Probar") { VPNNotifications.shared.prueba() }
                    .disabled(estilo == nil || estilo == .noDisponible || estilo == .desactivados || estilo == .sinAutorizar)
                if estilo == .sinAutorizar {
                    Button("Autorizar…") {
                        Task {
                            _ = await VPNNotifications.shared.solicitarAutorizacion()
                            await leer()
                        }
                    }
                } else if let estilo, estilo != .alertas && estilo != .noDisponible {
                    Button(estilo == .desactivados ? "Activar…" : "Cambiar a Alertas…") {
                        NSWorkspace.shared.open(VPNNotifications.ajustesDelSistema)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: Espacio.xxs) {
                Text("Estilo de los avisos")
                switch estilo {
                case .sinAutorizar?:
                    Label("Pendiente: autoriza los avisos una sola vez", systemImage: "bell.badge.fill")
                        .font(Tipo.nota).foregroundStyle(Paleta.avisoTexto)
                case .noDisponible?:
                    Text("Sin comprobar: ejecuta una copia empaquetada de Nuvex.")
                        .font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                case .alertas?:
                    Label("Alertas: se quedan hasta que los cierras", systemImage: "checkmark.circle.fill")
                        .font(Tipo.nota).foregroundStyle(Paleta.exitoTexto)
                case .banners?:
                    Label("Banners: desaparecen a los pocos segundos", systemImage: "exclamationmark.triangle.fill")
                        .font(Tipo.nota).foregroundStyle(Paleta.avisoTexto)
                case .sinPresentacion?:
                    Label("Solo en el Centro de notificaciones", systemImage: "exclamationmark.triangle.fill")
                        .font(Tipo.nota).foregroundStyle(Paleta.avisoTexto)
                case .desactivados?:
                    Label("Desactivados en Ajustes del Sistema", systemImage: "xmark.octagon.fill")
                        .font(Tipo.nota).foregroundStyle(Paleta.errorTexto)
                case nil:
                    Text("Comprobando…").font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                }
            }
        }
        .task { await leer() }
        // Al volver de Ajustes del Sistema se refleja el cambio.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await leer() }
        }
    }

    private func leer() async {
        estilo = await VPNNotifications.shared.estilo()
    }
}

// MARK: - Actualizaciones y copias

/// Fila de la barra lateral con un globo cuando hay una versión pendiente.
private struct FilaActualizacionLateral: View {
    let actualizaciones: Actualizaciones?
    let seleccionada: Bool

    private var colorTexto: Color {
        Color(nsColor: seleccionada ? .alternateSelectedControlTextColor : .labelColor)
    }

    var body: some View {
        if let actualizaciones {
            Contenido(actualizaciones: actualizaciones, seleccionada: seleccionada)
        } else {
            etiqueta
        }
    }

    private var etiqueta: some View {
        Label { Text("Actualización de software") } icon: {
            IconoCuadrado(simbolo: "arrow.triangle.2.circlepath", color: Paleta.neutro)
        }
        .foregroundStyle(colorTexto)
    }

    private struct Contenido: View {
        @ObservedObject var actualizaciones: Actualizaciones
        let seleccionada: Bool

        private var colorTexto: Color {
            Color(nsColor: seleccionada ? .alternateSelectedControlTextColor : .labelColor)
        }

        var body: some View {
            Label { Text("Actualización de software") } icon: {
                IconoCuadrado(simbolo: "arrow.triangle.2.circlepath", color: Paleta.neutro)
            }
            .foregroundStyle(colorTexto)
            .badge(actualizaciones.disponible == nil && !actualizaciones.requiereAtencion ? 0 : 1)
        }
    }
}

private struct SeccionCopias: View {
    @ObservedObject var modelo: VPNModel
    @State private var copias: [CopiaSeguridad] = []
    @State private var aRestaurar: CopiaSeguridad?
    @State private var error: String?
    @State private var restaurando = false
    @State private var resultadoRestauracion: ResultadoGuardado?

    private var esMuestra: Bool {
        #if DEBUG
        modelo.esMuestra
        #else
        false
        #endif
    }

    private func cargar() { copias = esMuestra ? [] : Migraciones.copias() }

    var body: some View {
        Section {
            if copias.isEmpty {
                Text("Aún no hay copias. Nuvex guarda una antes de cada actualización.")
                    .foregroundStyle(Paleta.textoSecundario)
            }
            ForEach(copias.prefix(5)) { copia in
                LabeledContent {
                    Button("Restaurar…") { aRestaurar = copia }
                        .disabled(modelo.hayAlgunaConectada || modelo.ocupado || restaurando)
                } label: {
                    VStack(alignment: .leading, spacing: Espacio.xxs / 2) {
                        Text(copia.fecha.formatted(date: .abbreviated, time: .shortened))
                        Text(descripcion(copia)).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                    }
                }
            }
            HStack {
                Button("Exportar cifradas…") { VentanaExportar.mostrar(modelo: modelo) }
                    .disabled(modelo.profiles.isEmpty)
                Button("Crear copia ahora") {
                    do {
                        _ = try Migraciones.crearCopia(etiqueta: "manual", base: Preferencias.directorio,
                                                       perfiles: URL(fileURLWithPath: Paths.perfiles))
                        Migraciones.rotar(base: Preferencias.directorio)
                        error = nil
                    } catch {
                        self.error = "No se pudo crear la copia: \(error.localizedDescription)"
                    }
                    cargar()
                }
                .disabled(esMuestra || modelo.ocupado || restaurando)
                Spacer()
                Button("Mostrar en Finder") {
                    let carpeta = Migraciones.carpetaCopias(Preferencias.directorio)
                    NSWorkspace.shared.open(FileManager.default.fileExists(atPath: carpeta.path) ? carpeta : Preferencias.directorio)
                }
                .disabled(esMuestra || !FileManager.default.fileExists(atPath: Preferencias.directorio.path))
            }
            if let error {
                Text(error).foregroundStyle(Paleta.errorTexto).textSelection(.enabled)
            }
            if restaurando {
                HStack(spacing: Espacio.s) { ProgressView().controlSize(.small); Text("Restaurando conexiones…") }
            }
            if let resultado = resultadoRestauracion {
                Label(resultado.completo ? "Restauración completa" : "Restauración con pendientes",
                      systemImage: resultado.completo ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(resultado.completo ? Paleta.exitoTexto : Paleta.avisoTexto)
                Text("Se conservaron tus autorizaciones actuales.").foregroundStyle(Paleta.textoSecundario)
                ForEach(resultado.avisos, id: \.self) { Text($0).foregroundStyle(Paleta.avisoTexto).textSelection(.enabled) }
            }
        } header: {
            Text("Copias de seguridad")
        } footer: {
            Text("Guardan conexiones y ajustes, sin contraseñas. Para una copia completa, exporta tus conexiones cifradas.")
                .foregroundStyle(Paleta.textoSecundario)
        }
        .onAppear(perform: cargar)
        .confirmationDialog("¿Restaurar esta copia?", isPresented: Binding(
            get: { aRestaurar != nil }, set: { if !$0 { aRestaurar = nil } })) {
            Button("Restaurar", role: .destructive) {
                if let copia = aRestaurar {
                    restaurando = true
                    error = nil
                    resultadoRestauracion = nil
                    modelo.restaurarCopia(copia) { resultado in
                        restaurando = false
                        if resultado.resumen.conexiones == .hecho { resultadoRestauracion = resultado }
                        else { error = resultado.avisos.first ?? "No se pudo completar la restauración." }
                        cargar()
                    }
                }
                aRestaurar = nil
                cargar()
            }
        } message: {
            Text("Se restaurarán las conexiones y su lectura de códigos, conservando tus autorizaciones actuales. Las conexiones que no estén en la copia se eliminarán junto con su contraseña. Antes se guarda una copia del estado actual, sin contraseñas.")
        }
    }

    private func descripcion(_ copia: CopiaSeguridad) -> String {
        let conexiones = copia.conexiones == 1 ? "1 conexión" : "\(copia.conexiones) conexiones"
        switch copia.etiqueta {
        case "manual": return "Manual · \(conexiones)"
        case "antes-de-restaurar": return "Antes de restaurar · \(conexiones)"
        case "vanterior": return "Antes de actualizar · \(conexiones)"
        case let etiqueta where etiqueta.hasPrefix("v"): return "Antes de actualizar desde \(etiqueta) · \(conexiones)"
        default: return conexiones
        }
    }
}

// MARK: - Ayudante de red

private struct AjustesAyudante: View {
    @ObservedObject var modelo: VPNModel

    private var titulo: String {
        switch modelo.ayudanteListo {
        case true?: return "Ayudante instalado"
        case false?: return modelo.profiles.isEmpty ? "Sin instalar" : "El ayudante necesita actualizarse"
        case nil: return "Sin instalar"
        }
    }

    private var subtitulo: String {
        switch modelo.ayudanteListo {
        case true?:
            let n = modelo.profiles.count
            return n == 1 ? "Al día con 1 conexión" : "Al día con \(n) conexiones"
        case false? where !modelo.profiles.isEmpty:
            return "Se actualizará al guardar cambios o al conectar."
        default:
            return "Se instalará al guardar tu primera conexión."
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: Espacio.l) {
                    IconoCuadrado(simbolo: "shield.lefthalf.filled", color: Paleta.iconoAyudante, lado: Tamano.iconoCabecera)
                    VStack(alignment: .leading, spacing: Espacio.xxs) {
                        Text(titulo).font(Tipo.titulo)
                        HStack(spacing: Espacio.s) {
                            Indicador(color: modelo.ayudanteListo == true ? Paleta.exito : Paleta.aviso)
                            Text(subtitulo).foregroundStyle(Paleta.textoSecundario)
                        }
                    }
                    Spacer()
                    Button(modelo.ayudanteListo == true ? "Reinstalar…" : "Instalar…") { modelo.instalarAyudante() }
                        .estiloBoton(modelo.ayudanteListo == true ? .secundario : .principal)
                        .disabled(modelo.instalandoAyudante || modelo.guardandoConfiguracion || modelo.profiles.isEmpty)
                }
                .padding(.vertical, Espacio.xs)
                if modelo.instalandoAyudante {
                    HStack(spacing: Espacio.m) {
                        ProgressView().controlSize(.small)
                        Text("Esperando la autorización de macOS…").foregroundStyle(Paleta.textoSecundario)
                    }
                }
                if let mensaje = modelo.mensajeAyudante {
                    Label(mensaje, systemImage: "checkmark.circle.fill").foregroundStyle(Paleta.exitoTexto)
                }
                if let error = modelo.ultimoError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Paleta.errorTexto).textSelection(.enabled)
                }
            }
            Section("Qué hace") {
                Text("Crea el túnel y aplica rutas y DNS con permisos de administrador. Solo acepta las conexiones guardadas en Nuvex y las acciones previstas. macOS pide autorización al instalarlo o actualizarlo y decide si ofrece Touch ID.")
                    .foregroundStyle(Paleta.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Diagnóstico") {
                LabeledContent("Registro de Nuvex") {
                    Button("Mostrar en Consola") { Log.mostrar() }
                }
                LabeledContent("Archivo de conexiones") {
                    Button("Mostrar en Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Paths.perfiles)])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: Paths.perfiles))
                }
            }
        }
        .formularioNuvex()
        .navigationTitle("Ayudante de red")
    }
}

// MARK: - Conexión

private struct DetalleConexion: View {
    @ObservedObject var modelo: VPNModel
    @ObservedObject var borradores: BorradoresAjustes
    @Binding var perfil: VPNProfile
    let alEliminar: () -> Void
    let puedeEliminar: Bool

    private var id: String { perfil.id }
    private var guardado: VPNProfile? { modelo.profiles.first { $0.id == id } }
    private var esNueva: Bool { guardado == nil }
    private var vpn: VPNStatus? { modelo.vpns.first { $0.id == id } }
    private var busy: Bool { modelo.guardandoConfiguracion || modelo.instalandoAyudante }

    private var password: Binding<String> {
        Binding(get: { borradores.passwords[id] ?? "" },
                set: { borradores.passwords[id] = $0 })
    }
    private var cambiosDePerfil: Bool { guardado.map { perfil != $0 } ?? true }
    private var hayCambios: Bool { cambiosDePerfil || !password.wrappedValue.isEmpty }
    private var usuarioCambiado: Bool { guardado.map { $0.username != perfil.username } ?? false }
    private var soloEspacios: Bool {
        guard let guardado, usuarioCambiado else { return false }
        return guardado.username.trimmingCharacters(in: .whitespacesAndNewlines) == perfil.username
    }
    private var necesitaContrasena: Bool { usuarioCambiado && !soloEspacios }

    private var motivo: String? {
        if let motivo = Validacion.motivo(esNueva ? perfil.conNombreSugerido : perfil) { return motivo }
        if necesitaContrasena && password.wrappedValue.isEmpty { return "Escribe la contraseña del nuevo usuario." }
        return bloqueoPorConexion
    }

    /// Cambiar conexiones exige reinstalar el ayudante, y eso no se permite
    /// con túneles activos. Solo la contraseña puede cambiarse conectada.
    private var bloqueoPorConexion: String? {
        guard cambiosDePerfil, let activa = modelo.vpns.first(where: \.connected) else { return nil }
        return "Desconecta «\(activa.name)» para guardar cambios de conexión. La contraseña sí se puede cambiar conectada."
    }

    private func aviso(_ campo: String) -> Bool {
        borradores.intentos.contains(id) || borradores.tocados.contains(id + "." + campo)
    }

    private func guardar() {
        guard motivo == nil else { borradores.intentos.insert(id); return }
        let idGuardado = id
        modelo.guardarConexion(esNueva ? perfil.conNombreSugerido : perfil, password: password.wrappedValue) { resultado in
            guard resultado.confirmaImportacion([idGuardado]) else { return }
            if case .fallo = resultado.resumen.contrasenas { return }
            borradores.limpiar(idGuardado)
        }
    }

    private func revertir() {
        if let guardado { borradores.revertir(id, a: guardado) } else { borradores.descartar(id) }
    }

    var body: some View {
        formulario
            // Barra del sistema: el formulario se desvanece bajo ella al desplazarse.
            .barraAcciones { barraGuardado }
        .navigationTitle(perfil.name.isEmpty ? "Nueva conexión" : perfil.name)
        .onChange(of: perfil.name) { _, _ in borradores.tocados.insert(id + ".name") }
        .onChange(of: perfil.server) { _, _ in borradores.tocados.insert(id + ".server") }
        .onChange(of: perfil.username) { _, _ in borradores.tocados.insert(id + ".username") }
        .onChange(of: perfil.trust) { _, _ in borradores.tocados.insert(id + ".trust") }
    }

    // MARK: Cabecera con estado y conexión

    private var cabecera: some View {
        HStack(spacing: Espacio.l) {
            IconoCuadrado(simbolo: "lock.fill", color: ColorConexion.para(id), lado: Tamano.iconoCabecera)
            VStack(alignment: .leading, spacing: Espacio.xxs) {
                Text(perfil.name.isEmpty ? "Nueva conexión" : perfil.name)
                    .font(Tipo.titulo).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    let (color, texto) = estadoActual
                    HStack(spacing: Espacio.s) {
                        Indicador(color: color)
                        Text(texto)
                            .foregroundStyle(color == Paleta.error || color == Paleta.aviso
                                             ? Paleta.texto(color) : Paleta.textoSecundario)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: Espacio.m)
            botonConexion
        }
    }

    private var estadoActual: (Color, String) {
        if esNueva { return (Paleta.aviso, "Sin guardar") }
        if modelo.errorConsulta != nil { return (Paleta.aviso, "Estado sin comprobar") }
        if modelo.desconectando.contains(id) { return (Paleta.acento, "Desconectando…") }
        if modelo.recuperando.contains(id) { return (Paleta.acento, "Reconectando en unos segundos…") }
        if !perfil.enabled { return (.secondary, "Oculta en la barra de menús") }
        guard let vpn else { return (.secondary, "Desconectada") }
        switch modelo.estado(vpn) {
        case .conectada:
            return (Paleta.exito, vpn.inicio.map { "Conectada · \(Formato.duracion(desde: $0))" } ?? "Conectada")
        case .conectando: return (Paleta.acento, "Conectando…")
        case .error(let fallo): return (Paleta.error, fallo.titulo)
        case .desconectada:
            if let fecha = modelo.desconexiones[id] {
                return (Paleta.aviso, "Se desconectó a las \(fecha.formatted(date: .omitted, time: .shortened))")
            }
            if modelo.passwordStatuses[id] == .missing { return (Paleta.aviso, "Falta la contraseña") }
            return (.secondary, "Desconectada")
        }
    }

    @ViewBuilder
    private var botonConexion: some View {
        if modelo.errorConsulta != nil {
            Button("Comprobar estado") { modelo.refrescar() }.estiloBoton(.secundario)
        } else if modelo.recuperando.contains(id) {
            Button("Cancelar reconexión") { modelo.cancelarConexion(id) }.estiloBoton(.secundario)
        } else if let vpn, !esNueva, perfil.enabled || vpn.connected {
            switch modelo.estado(vpn) {
            case .conectada:
                Button(modelo.desconectando.contains(id) ? "Desconectando…" : "Desconectar") { modelo.desconectar(vpn) }
                    .estiloBoton(.secundario)
                    .disabled(modelo.desconectando.contains(id))
            case .conectando:
                Button("Cancelar") { modelo.cancelarConexion(id) }
                    .estiloBoton(.secundario)
            default:
                Button("Conectar") { modelo.conectar(vpn) }
                    .estiloBoton(.principal)
                    .disabled(hayCambios || busy || modelo.errorConsulta != nil || !vpn.configured || modelo.passwordStatuses[id] == .missing)
                    .help(hayCambios ? "Guarda los cambios antes de conectar." : "")
            }
        }
    }

    // MARK: Formulario

    private var formulario: some View {
        Form {
            // La cabecera es la primera sección, como en Ayudante y Cuenta de
            // Google: se desplaza con el contenido y comparte sus márgenes.
            Section { cabecera.padding(.vertical, Espacio.xs) }
            Group {
                Section("Servidor") {
                    TextField(esNueva ? "Nombre (opcional)" : "Nombre", text: $perfil.name,
                              prompt: Text(esNueva ? perfil.conNombreSugerido.name : "Oficina"))
                    if !esNueva && aviso("name") && Validacion.vacio(perfil.name) {
                        AvisoCampo("Ponle un nombre para reconocerla en la barra de menús.")
                    }
                    TextField("Servidor", text: $perfil.server, prompt: Text("vpn.empresa.com"))
                        .textContentType(.URL)
                    if aviso("server") {
                        if perfil.enabled && Validacion.vacio(perfil.server) {
                            AvisoCampo("Indica el servidor Fortinet y, si corresponde, el puerto.")
                        } else if !Validacion.vacio(perfil.server)
                                    && !Validacion.servidorValido(perfil.server.trimmingCharacters(in: .whitespaces)) {
                            AvisoCampo("Escribe una dirección como vpn.empresa.com. Añade :puerto solo si te lo indicaron.")
                        }
                    }
                }
                Section {
                    TextField("Usuario", text: $perfil.username, prompt: Text("usuario"))
                        .textContentType(.username)
                    if aviso("username") && perfil.enabled && Validacion.vacio(perfil.username) {
                        AvisoCampo("Indica el usuario de esta VPN.")
                    }
                    filaContrasena
                } header: {
                    Text("Cuenta")
                } footer: {
                    Text("La contraseña se guarda en el Llavero de macOS.")
                        .foregroundStyle(Paleta.textoSecundario)
                }
                SeccionCodigoCorreo(perfilID: id, perfilGuardado: !esNueva)
                OpcionesServidor(perfil: $perfil)
                Section {
                    Toggle("Mostrar en la barra de menús", isOn: $perfil.enabled)
                } footer: {
                    Text("Si la ocultas, la conexión se conserva pero no podrás conectarla.")
                        .foregroundStyle(Paleta.textoSecundario)
                }
                Section {
                    Button(esNueva ? "Descartar conexión" : "Eliminar conexión…", role: .destructive, action: alEliminar)
                        .estiloBoton(.destructivo)
                        .disabled(!puedeEliminar)
                        .help(puedeEliminar ? "" : "Desconecta las VPN activas para eliminar conexiones.")
                }
            }
            .disabled(busy)
        }
        .formularioNuvex()
    }

    @ViewBuilder
    private var filaContrasena: some View {
        let editando = esNueva || necesitaContrasena || borradores.editandoContrasena.contains(id)
            || modelo.passwordStatuses[id] == .missing || !password.wrappedValue.isEmpty
        if editando {
            SecureField("Contraseña", text: password,
                        prompt: Text(esNueva || modelo.passwordStatuses[id] == .missing ? "Contraseña de la VPN" : "Nueva contraseña"))
            estadoCredencial
            if borradores.editandoContrasena.contains(id) && !esNueva && !necesitaContrasena {
                Button("Conservar la contraseña guardada") {
                    borradores.passwords[id] = nil
                    borradores.editandoContrasena.remove(id)
                }
                .buttonStyle(.link)
            }
        } else {
            LabeledContent("Contraseña") {
                HStack(spacing: Espacio.m) {
                    estadoCredencial
                    Button("Cambiar…") { borradores.editandoContrasena.insert(id) }
                }
            }
        }
    }

    @ViewBuilder
    private var estadoCredencial: some View {
        if !password.wrappedValue.isEmpty {
            Label("Se guardará en el Llavero al pulsar Guardar", systemImage: "lock.fill")
                .foregroundStyle(Paleta.textoSecundario)
        } else if soloEspacios {
            Label("Se quitarán los espacios del usuario y se migrará la contraseña al guardar",
                  systemImage: "arrow.right.circle").foregroundStyle(Paleta.avisoTexto)
        } else if necesitaContrasena {
            Label("Escribe la contraseña del nuevo usuario", systemImage: "key.fill").foregroundStyle(Paleta.avisoTexto)
        } else if !esNueva {
            switch modelo.passwordStatuses[id] {
            case .saved:
                Label("Guardada en el Llavero", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Paleta.textoSecundario)
                    .symbolRenderingMode(.multicolor)
            case .missing:
                Label("No hay contraseña guardada para este usuario", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Paleta.avisoTexto)
            case .error(let code):
                Label("No se pudo comprobar la contraseña. Desbloquea el Llavero y vuelve a conectar.", systemImage: "exclamationmark.triangle.fill")
                    .help("Diagnóstico del Llavero: \(code)")
                    .foregroundStyle(Paleta.errorTexto)
            case nil:
                HStack(spacing: Espacio.s) { ProgressView().controlSize(.small); Text("Comprobando…").foregroundStyle(Paleta.textoSecundario) }
            }
        }
    }

    // MARK: Barra de guardado

    private var barraGuardado: some View {
        HStack(spacing: Espacio.m) {
            mensajeBarra
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
            Button(esNueva ? "Descartar" : "Revertir", action: revertir)
                .estiloBoton(.secundario)
                .disabled(!hayCambios || busy)
            Button("Guardar", action: guardar)
                .estiloBoton(.principal)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hayCambios || busy || bloqueoPorConexion != nil)
        }
        .animacion(Movimiento.estandar, value: hayCambios)
    }

    @ViewBuilder
    private var mensajeBarra: some View {
        Group {
            if modelo.guardandoConfiguracion {
                HStack(spacing: Espacio.s) { ProgressView().controlSize(.small); Text("Guardando…") }
                    .foregroundStyle(Paleta.textoSecundario)
            } else if modelo.instalandoAyudante {
                HStack(spacing: Espacio.s) { ProgressView().controlSize(.small); Text("Esperando la autorización de macOS…") }
                    .foregroundStyle(Paleta.textoSecundario)
            } else if borradores.intentos.contains(id), let motivo {
                Label(motivo, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Paleta.avisoTexto)
            } else if !hayCambios, let resumen = modelo.resumenGuardado, resumen.hayProblemas {
                BarraResumenGuardado(modelo: modelo, resumen: resumen)
            } else if let error = modelo.ultimoError {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Paleta.errorTexto).textSelection(.enabled)
            } else if hayCambios, let bloqueo = bloqueoPorConexion {
                Label(bloqueo, systemImage: "lock.fill").foregroundStyle(Paleta.avisoTexto)
            } else if hayCambios {
                HStack(spacing: Espacio.s) {
                    Indicador(color: Paleta.aviso)
                    Text(cambiosDePerfil ? "Cambios sin guardar · macOS puede pedir autorización para aplicarlos"
                                         : "Contraseña nueva sin guardar")
                        .foregroundStyle(Paleta.textoSecundario)
                }
            } else if let mensaje = modelo.mensajeConfiguracion {
                Label(mensaje, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Paleta.textoSecundario)
                    .symbolRenderingMode(.multicolor)
            } else {
                Text("Sin cambios").foregroundStyle(Paleta.textoTerciario)
            }
        }
        .font(Tipo.apoyo)
        .lineLimit(2)
    }
}

/// Línea de la barra de guardado cuando algo quedó pendiente, con el
/// detalle de cada paso a un clic.
private struct BarraResumenGuardado: View {
    @ObservedObject var modelo: VPNModel
    let resumen: ResumenGuardado
    @State private var detalles = false

    var body: some View {
        HStack(spacing: Espacio.s) {
            Label(resumen.resumen, systemImage: grave ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(grave ? Paleta.errorTexto : Paleta.avisoTexto)
                .lineLimit(1)
            Button("Detalles") { detalles = true }
                .buttonStyle(.link)
                .popover(isPresented: $detalles, arrowEdge: .top) {
                    ListaResumenGuardado(modelo: modelo, resumen: resumen)
                        .padding(Espacio.xl)
                        .frame(width: 380)
                }
        }
    }

    private var grave: Bool { if case .fallo = resumen.conexiones { return true }; return false }
}

/// Cada paso del guardado con su estado y, si quedó algo pendiente, cómo
/// resolverlo. La usan Ajustes y la bienvenida.
struct ListaResumenGuardado: View {
    @ObservedObject var modelo: VPNModel
    let resumen: ResumenGuardado

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.m) {
            ForEach(resumen.pasos, id: \.titulo) { titulo, paso in
                HStack(alignment: .firstTextBaseline, spacing: Espacio.m) {
                    icono(paso).frame(width: 16)
                    VStack(alignment: .leading, spacing: Espacio.xxs) {
                        Text(titulo).fontWeight(.medium)
                        if let detalle = detalle(paso) {
                            Text(detalle).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if puedeAutorizar {
                Button("Autorizar el ayudante ahora") { modelo.instalarAyudante(desdeGuardado: true) }
                    .disabled(modelo.instalandoAyudante || modelo.guardandoConfiguracion)
            }
        }
    }

    private var puedeAutorizar: Bool {
        switch resumen.ayudante {
        case .fallo, .pendiente: return !modelo.hayAlgunaConectada
        default: return false
        }
    }

    @ViewBuilder
    private func icono(_ paso: ResumenGuardado.Paso) -> some View {
        switch paso {
        case .hecho: Image(systemName: "checkmark.circle.fill").foregroundStyle(Paleta.exito)
        case .enCurso: ProgressView().controlSize(.mini)
        case .pendiente: Image(systemName: "clock.fill").foregroundStyle(Paleta.aviso)
        case .fallo: Image(systemName: "xmark.circle.fill").foregroundStyle(Paleta.error)
        case .noAplica: EmptyView()
        }
    }

    private func detalle(_ paso: ResumenGuardado.Paso) -> String? {
        switch paso {
        case .hecho: return "Hecho."
        case .enCurso: return "En curso…"
        case .pendiente(let texto), .fallo(let texto): return texto
        case .noAplica: return nil
        }
    }
}

private struct AvisoCampo: View {
    let texto: String
    init(_ texto: String) { self.texto = texto }
    var body: some View {
        Label(texto, systemImage: "exclamationmark.triangle.fill")
            .font(Tipo.apoyo)
            .foregroundStyle(Paleta.avisoTexto)
    }
}
