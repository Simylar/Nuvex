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
    var guardandoID: String?
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

// MARK: - Piezas comunes

struct IconoCuadrado: View {
    let simbolo: String
    let color: Color
    var lado: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: lado * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: lado, height: lado)
            .overlay {
                Image(systemName: simbolo)
                    .font(.system(size: lado * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

enum ColorConexion {
    private static let paleta: [Color] = [.blue, .teal, .indigo, .purple, .pink, .orange, .green, .cyan, .mint, .brown]
    static func para(_ id: String) -> Color {
        paleta[id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % paleta.count]
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
        .onChange(of: modelo.mensajeConfiguracion) { _, mensaje in
            if mensaje != nil, let id = borradores.guardandoID {
                borradores.limpiar(id)
                borradores.guardandoID = nil
            }
        }
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
            Label { Text("General") } icon: { IconoCuadrado(simbolo: "gearshape.fill", color: .gray) }
                .tag(PaginaAjustes.general)
            FilaActualizacionLateral(actualizaciones: modelo.actualizaciones)
                .tag(PaginaAjustes.actualizacion)
            Label { Text("Ayudante de red") } icon: { IconoCuadrado(simbolo: "shield.lefthalf.filled", color: .indigo) }
                .tag(PaginaAjustes.ayudante)
            Label { Text("Automatización") } icon: { IconoCuadrado(simbolo: "terminal.fill", color: Color(white: 0.25)) }
                .tag(PaginaAjustes.automatizacion)
            Label { Text("Cuenta de Google") } icon: { IconoCuadrado(simbolo: "envelope.fill", color: .red) }
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
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 2) {
                    Button { borradores.nuevaConexion() } label: {
                        Image(systemName: "plus").frame(width: 22, height: 20)
                    }
                    .help("Añadir conexión")
                    .accessibilityLabel("Añadir conexión")
                    .disabled(borradores.drafts.count >= 64 || busy)
                    Button {
                        if case .conexion(let id) = borradores.seleccion { pendingDeletion = id }
                    } label: {
                        Image(systemName: "minus").frame(width: 22, height: 20)
                    }
                    .help(modelo.hayAlgunaConectada ? "Desconecta las VPN activas para eliminar conexiones" : "Eliminar conexión")
                    .accessibilityLabel("Eliminar conexión")
                    .disabled({
                        guard case .conexion(let id) = borradores.seleccion else { return true }
                        return !puedeEliminar(id)
                    }())
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    private func filaLateral(_ perfil: VPNProfile) -> some View {
        let cambios = borradores.tieneCambios(perfil, guardados: modelo.profiles)
        let guardado = modelo.profiles.contains { $0.id == perfil.id }
        let subtitulo: String = {
            if !guardado { return "Sin guardar" }
            if cambios { return "Cambios sin guardar" }
            if !perfil.enabled { return "Oculta · " + (perfil.server.isEmpty ? "sin servidor" : perfil.server) }
            return perfil.server.isEmpty ? "Sin servidor" : perfil.server
        }()
        return HStack(spacing: 8) {
            IconoCuadrado(simbolo: "lock.fill", color: ColorConexion.para(perfil.id))
            VStack(alignment: .leading, spacing: 0) {
                Text(perfil.name.isEmpty ? "Nueva conexión" : perfil.name).lineLimit(1)
                Text(subtitulo).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let color = colorEstado(perfil.id) {
                Circle().fill(color).frame(width: 7, height: 7)
                    .accessibilityLabel(color == .green ? "Conectada" : "Requiere atención")
            }
        }
    }

    private func colorEstado(_ id: String) -> Color? {
        guard let vpn = modelo.vpns.first(where: { $0.id == id }) else { return nil }
        if vpn.connected { return .green }
        if modelo.desconexiones[id] != nil || modelo.passwordStatuses[id] == .missing || !vpn.configured { return .orange }
        if case .error = modelo.estado(vpn) { return .red }
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
                Text("Nuvex \(InfoVersion.actual.descripcion)").foregroundStyle(.secondary)
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
    @AppStorage(SecurityPreferences.confirmationKey) private var confirmarConTouchID = true
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
                    HStack(spacing: 12) {
                        LogoNuvex(lado: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Aún no hay conexiones").font(.headline)
                            Text("Añade tu servidor Fortinet SSL VPN, tu usuario y tu contraseña.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Añadir conexión") { borradores.nuevaConexion() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
            }
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
                        Text("macOS necesita que lo apruebes en Ítems de inicio.").foregroundStyle(.orange)
                    }
                }
                if let errorInicio {
                    Text(errorInicio).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Section {
                Toggle("Avisar cuando una VPN se desconecte", isOn: $avisarDesconexion)
                EstiloAvisos()
                    .disabled(!avisarDesconexion)
                Picker("Comprobar el estado", selection: $intervaloRevision) {
                    ForEach(intervalos, id: \.self) { segundos in
                        Text("Cada \(segundos) s").tag(segundos)
                    }
                }
                .onChange(of: intervaloRevision) { _, _ in modelo.actualizarIntervalo() }
            } header: {
                Text("Avisos")
            } footer: {
                Text("Con el estilo «Alertas», el aviso de desconexión se queda en pantalla hasta que lo cierres o pulses Reconectar.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Confirmar con Touch ID la primera vez", isOn: $confirmarConTouchID)
            } header: {
                Text("Seguridad")
            } footer: {
                Text("Se pide una sola vez para todo Nuvex antes de usar una contraseña guardada. Si Touch ID no está disponible, macOS pide la contraseña del equipo.")
                    .foregroundStyle(.secondary)
            }
            SeccionCopias(modelo: modelo)
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear(perform: leerInicio)
    }
}

/// Estilo actual de los avisos de Nuvex y cómo cambiarlo.
private struct EstiloAvisos: View {
    @State private var estilo: VPNNotifications.Estilo?

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button("Probar") { VPNNotifications.shared.prueba() }
                    .disabled(estilo == .desactivados)
                if estilo != .alertas {
                    Button(estilo == .desactivados ? "Activar…" : "Cambiar a Alertas…") {
                        NSWorkspace.shared.open(VPNNotifications.ajustesDelSistema)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Estilo de los avisos")
                switch estilo {
                case .alertas?:
                    Label("Alertas: se quedan hasta que los cierras", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                case .banners?:
                    Label("Banners: desaparecen a los pocos segundos", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                case .sinPresentacion?:
                    Label("Solo en el Centro de notificaciones", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                case .desactivados?:
                    Label("Desactivados en Ajustes del Sistema", systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                case nil:
                    Text("Comprobando…").font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        if let actualizaciones {
            Contenido(actualizaciones: actualizaciones)
        } else {
            etiqueta
        }
    }

    private var etiqueta: some View {
        Label { Text("Actualización de software") } icon: {
            IconoCuadrado(simbolo: "arrow.triangle.2.circlepath", color: .gray)
        }
    }

    private struct Contenido: View {
        @ObservedObject var actualizaciones: Actualizaciones
        var body: some View {
            Label { Text("Actualización de software") } icon: {
                IconoCuadrado(simbolo: "arrow.triangle.2.circlepath", color: .gray)
            }
            .badge(actualizaciones.disponible == nil ? 0 : 1)
        }
    }
}

private struct SeccionCopias: View {
    @ObservedObject var modelo: VPNModel
    @State private var copias: [CopiaSeguridad] = []
    @State private var aRestaurar: CopiaSeguridad?
    @State private var error: String?

    private func cargar() { copias = Migraciones.copias() }

    var body: some View {
        Section {
            if copias.isEmpty {
                Text("Aún no hay copias. Nuvex guarda una antes de cada actualización.")
                    .foregroundStyle(.secondary)
            }
            ForEach(copias.prefix(5)) { copia in
                LabeledContent {
                    Button("Restaurar…") { aRestaurar = copia }
                        .disabled(modelo.hayAlgunaConectada || modelo.guardandoConfiguracion || modelo.instalandoAyudante)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(copia.fecha.formatted(date: .abbreviated, time: .shortened))
                        Text(descripcion(copia)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
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
                Spacer()
                Button("Mostrar en Finder") {
                    let carpeta = Migraciones.carpetaCopias(Preferencias.directorio)
                    NSWorkspace.shared.open(FileManager.default.fileExists(atPath: carpeta.path) ? carpeta : Preferencias.directorio)
                }
                .disabled(!FileManager.default.fileExists(atPath: Preferencias.directorio.path))
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: {
            Text("Copias de seguridad")
        } footer: {
            Text("Guardan conexiones y ajustes, sin contraseñas. Para una copia completa, exporta tus conexiones cifradas.")
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: cargar)
        .confirmationDialog("¿Restaurar esta copia?", isPresented: Binding(
            get: { aRestaurar != nil }, set: { if !$0 { aRestaurar = nil } })) {
            Button("Restaurar", role: .destructive) {
                if let copia = aRestaurar { modelo.restaurarCopia(copia) }
                aRestaurar = nil
                cargar()
            }
        } message: {
            Text("Las conexiones volverán a como estaban en la copia. Las que no estén en ella se eliminarán junto con su contraseña. Antes se guarda una copia del estado actual.")
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
                HStack(spacing: 12) {
                    IconoCuadrado(simbolo: "shield.lefthalf.filled", color: .indigo, lado: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titulo).font(.title3).fontWeight(.semibold)
                        HStack(spacing: 5) {
                            Circle().fill(modelo.ayudanteListo == true ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(subtitulo).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(modelo.ayudanteListo == true ? "Reinstalar…" : "Instalar…") { modelo.instalarAyudante() }
                        .disabled(modelo.instalandoAyudante || modelo.guardandoConfiguracion || modelo.profiles.isEmpty)
                }
                .padding(.vertical, 4)
                if modelo.instalandoAyudante {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Esperando la autorización de macOS…").foregroundStyle(.secondary)
                    }
                }
                if let mensaje = modelo.mensajeAyudante {
                    Label(mensaje, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if let error = modelo.ultimoError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Section("Qué hace") {
                Text("Crea el túnel y aplica rutas y DNS con permisos de administrador. Solo acepta las conexiones guardadas en Nuvex y las acciones previstas. macOS pide autorización al instalarlo o actualizarlo y decide si ofrece Touch ID.")
                    .foregroundStyle(.secondary)
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
        .formStyle(.grouped)
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
        if let motivo = Validacion.motivo(perfil) { return motivo }
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
        borradores.guardandoID = id
        modelo.guardarConexion(perfil, password: password.wrappedValue)
    }

    private func revertir() {
        if let guardado { borradores.revertir(id, a: guardado) } else { borradores.descartar(id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            cabecera
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 4)
            formulario
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { barraGuardado }
        .navigationTitle(perfil.name.isEmpty ? "Nueva conexión" : perfil.name)
        .onChange(of: perfil.name) { _, _ in borradores.tocados.insert(id + ".name") }
        .onChange(of: perfil.server) { _, _ in borradores.tocados.insert(id + ".server") }
        .onChange(of: perfil.username) { _, _ in borradores.tocados.insert(id + ".username") }
        .onChange(of: perfil.trust) { _, _ in borradores.tocados.insert(id + ".trust") }
    }

    // MARK: Cabecera con estado y conexión

    private var cabecera: some View {
        HStack(spacing: 12) {
            IconoCuadrado(simbolo: "lock.fill", color: ColorConexion.para(id), lado: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(perfil.name.isEmpty ? "Nueva conexión" : perfil.name)
                    .font(.title3).fontWeight(.semibold).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    let (color, texto) = estadoActual
                    HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(texto).foregroundStyle(color == .red ? Color.red : Color.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            botonConexion
        }
    }

    private var estadoActual: (Color, String) {
        if esNueva { return (.orange, "Sin guardar") }
        if !perfil.enabled { return (.secondary, "Oculta en la barra de menús") }
        guard let vpn else { return (.secondary, "Desconectada") }
        switch modelo.estado(vpn) {
        case .conectada:
            return (.green, vpn.inicio.map { "Conectada · \(Formato.duracion(desde: $0))" } ?? "Conectada")
        case .conectando: return (.accentColor, "Conectando…")
        case .error(let fallo): return (.red, fallo.titulo)
        case .desconectada:
            if let fecha = modelo.desconexiones[id] {
                return (.orange, "Se desconectó a las \(fecha.formatted(date: .omitted, time: .shortened))")
            }
            if modelo.passwordStatuses[id] == .missing { return (.orange, "Falta la contraseña") }
            return (.secondary, "Desconectada")
        }
    }

    @ViewBuilder
    private var botonConexion: some View {
        if let vpn, !esNueva, perfil.enabled || vpn.connected {
            switch modelo.estado(vpn) {
            case .conectada:
                Button("Desconectar") { modelo.desconectar(vpn) }
            case .conectando:
                ProgressView().controlSize(.small)
            default:
                Button("Conectar") { modelo.conectar(vpn) }
                    .buttonStyle(.borderedProminent)
                    .disabled(hayCambios || busy || !vpn.configured || modelo.passwordStatuses[id] == .missing)
                    .help(hayCambios ? "Guarda los cambios antes de conectar." : "")
            }
        }
    }

    // MARK: Formulario

    private var formulario: some View {
        Form {
            Section("Servidor") {
                TextField("Nombre", text: $perfil.name, prompt: Text("Oficina"))
                if aviso("name") && Validacion.vacio(perfil.name) {
                    AvisoCampo("Ponle un nombre para reconocerla en la barra de menús.")
                }
                TextField("Servidor", text: $perfil.server, prompt: Text("vpn.empresa.com:443"))
                    .textContentType(.URL)
                if aviso("server") {
                    if perfil.enabled && Validacion.vacio(perfil.server) {
                        AvisoCampo("Indica el servidor Fortinet y, si corresponde, el puerto.")
                    } else if !Validacion.vacio(perfil.server)
                                && !Validacion.servidorValido(perfil.server.trimmingCharacters(in: .whitespaces)) {
                        AvisoCampo("Usa la forma host:puerto, por ejemplo vpn.empresa.com:443.")
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
                    .foregroundStyle(.secondary)
            }
            SeccionCodigoCorreo(perfilID: id)
            Section {
                Picker("Confianza TLS", selection: seleccionConfianza) {
                    Text("Certificados del sistema").tag("system")
                    Text("Certificado incluido (Prepa)").tag("bundle")
                    Text("Huella SHA-256").tag("sha256")
                }
                if perfil.trust.hasPrefix("sha256:") {
                    TextField("Huella", text: huella, prompt: Text("64 caracteres hexadecimales"))
                        .font(.body.monospaced())
                    if aviso("trust") && !Validacion.huellaValida(perfil.trust) {
                        AvisoCampo("Faltan \(max(0, 64 - huella.wrappedValue.count)) caracteres de la huella.")
                    }
                }
            } header: {
                Text("Seguridad")
            } footer: {
                Text(textoConfianza).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Instalar las rutas de esta VPN", isOn: $perfil.manageRoutes)
                Toggle("Usar el DNS de esta VPN", isOn: $perfil.manageDNS)
                TextField("Realm", text: $perfil.realm, prompt: Text("Opcional"))
            } header: {
                Text("Red")
            } footer: {
                Text("Las rutas pueden incluir la salida general a Internet. Si varias VPN instalan rutas o DNS que se superponen, pueden entrar en conflicto.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Mostrar en la barra de menús", isOn: $perfil.enabled)
            } footer: {
                Text("Si la ocultas, la conexión se conserva pero no podrás conectarla.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(esNueva ? "Descartar conexión" : "Eliminar conexión…", role: .destructive, action: alEliminar)
                    .disabled(!puedeEliminar)
                    .help(puedeEliminar ? "" : "Desconecta las VPN activas para eliminar conexiones.")
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
    }

    private var textoConfianza: String {
        switch perfil.trust {
        case "system": return "Verifica el certificado con las autoridades de confianza de macOS. Es la opción recomendada."
        case "bundle": return "Usa esta CA solo si tu servidor emplea esa cadena de certificados. Para otras VPN, usa los certificados del sistema o una huella verificada."
        default: return "Fija el certificado exacto del servidor. Confirma la huella con su administrador antes de guardarla."
        }
    }

    private var seleccionConfianza: Binding<String> {
        Binding(
            get: { perfil.trust.hasPrefix("sha256:") ? "sha256" : perfil.trust },
            set: { perfil.trust = $0 == "sha256" ? "sha256:" : $0 }
        )
    }

    /// Acepta la huella pegada con dos puntos o espacios y la guarda en minúsculas.
    private var huella: Binding<String> {
        Binding(
            get: { String(perfil.trust.dropFirst(7)) },
            set: { perfil.trust = "sha256:" + $0.filter(\.isHexDigit).lowercased() }
        )
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
                HStack(spacing: 8) {
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
                .foregroundStyle(.secondary)
        } else if soloEspacios {
            Label("Se quitarán los espacios del usuario y se migrará la contraseña al guardar",
                  systemImage: "arrow.right.circle").foregroundStyle(.orange)
        } else if necesitaContrasena {
            Label("Escribe la contraseña del nuevo usuario", systemImage: "key.fill").foregroundStyle(.orange)
        } else if !esNueva {
            switch modelo.passwordStatuses[id] {
            case .saved:
                Label("Guardada en el Llavero", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            case .missing:
                Label("No hay contraseña guardada para este usuario", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .error(let code):
                Label("No se pudo consultar el Llavero (código \(code))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case nil:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Comprobando…").foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Barra de guardado

    private var barraGuardado: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                mensajeBarra
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(esNueva ? "Descartar" : "Revertir", action: revertir)
                    .disabled(!hayCambios || busy)
                Button("Guardar", action: guardar)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!hayCambios || busy || bloqueoPorConexion != nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var mensajeBarra: some View {
        Group {
            if modelo.guardandoConfiguracion {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Guardando…") }
                    .foregroundStyle(.secondary)
            } else if modelo.instalandoAyudante {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Esperando la autorización de macOS…") }
                    .foregroundStyle(.secondary)
            } else if borradores.intentos.contains(id), let motivo {
                Label(motivo, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let error = modelo.ultimoError {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
            } else if hayCambios, let bloqueo = bloqueoPorConexion {
                Label(bloqueo, systemImage: "lock.fill").foregroundStyle(.orange)
            } else if hayCambios {
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                    Text(cambiosDePerfil ? "Cambios sin guardar · macOS puede pedir autorización para aplicarlos"
                                         : "Contraseña nueva sin guardar")
                        .foregroundStyle(.secondary)
                }
            } else if let mensaje = modelo.mensajeConfiguracion {
                Label(mensaje, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            } else {
                Text("Sin cambios").foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .lineLimit(2)
    }
}

private struct AvisoCampo: View {
    let texto: String
    init(_ texto: String) { self.texto = texto }
    var body: some View {
        Label(texto, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
    }
}
