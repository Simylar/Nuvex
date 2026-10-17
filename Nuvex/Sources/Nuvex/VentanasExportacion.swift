import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declarado en el Info.plist: doble clic en un .nuvexvpn abre la importación.
    static let exportacionNuvex = UTType(exportedAs: "local.gertcode.nuvex.exportacion", conformingTo: .data)
}

/// Ventana sencilla para una vista SwiftUI desde código AppKit.
@MainActor
private enum Ventanas {
    static var abiertas: [String: NSWindow] = [:]

    static func mostrar<V: View>(_ clave: String, titulo: String, vista: V, tamano: NSSize) {
        let ventana = abiertas[clave] ?? {
            let v = NSWindow(contentRect: NSRect(origin: .zero, size: tamano), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            v.isReleasedWhenClosed = false
            return v
        }()
        abiertas[clave] = ventana
        ventana.title = titulo
        ventana.contentViewController = NSHostingController(rootView: vista)
        ventana.center()
        NSApp.activate(ignoringOtherApps: true)
        ventana.makeKeyAndOrderFront(nil)
    }

    static func cerrar(_ clave: String) { abiertas[clave]?.close() }
}

/// Escribe el archivo exportado con permisos privados, de forma atómica.
private func escribirPrivado(_ datos: Data, en url: URL) throws {
    try datos.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

// MARK: - Exportar

@MainActor
enum VentanaExportar {
    static func mostrar(modelo: VPNModel, preseleccion: String? = nil) {
        Ventanas.mostrar("exportar", titulo: "Exportar conexiones",
                         vista: VistaExportar(modelo: modelo, cerrar: { Ventanas.cerrar("exportar") },
                                              seleccion: Set(preseleccion.map { [$0] } ?? modelo.profiles.map(\.id))),
                         tamano: NSSize(width: 520, height: 600))
    }
}

struct VistaExportar: View {
    @ObservedObject var modelo: VPNModel
    let cerrar: () -> Void
    @State var seleccion: Set<String>
    @State private var incluirContrasenas = false
    @State private var incluirCorreo = true
    @State private var frase = ""
    @State private var repetir = ""
    @State private var exportando = false
    @State private var error: String?
    @State private var guardado: (url: URL, contrasenas: Int, faltantes: Int)?

    private var fuerza: Int { CifradoExportacion.fuerza(frase) }
    private var puedeExportar: Bool {
        !seleccion.isEmpty && frase.count >= CifradoExportacion.longitudMinima && frase == repetir && !exportando
    }

    var body: some View {
        Form {
            if let guardado {
                Section {
                    Label("Conexiones exportadas", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(resumen(guardado)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([guardado.url]) }
                        Spacer()
                        Button("Listo", action: cerrar).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                Section("Conexiones") {
                    ForEach(modelo.profiles) { perfil in
                        Toggle(isOn: Binding(get: { seleccion.contains(perfil.id) },
                                             set: { if $0 { seleccion.insert(perfil.id) } else { seleccion.remove(perfil.id) } })) {
                            Label { VStack(alignment: .leading, spacing: 1) {
                                Text(perfil.name)
                                Text(perfil.server).font(.caption).foregroundStyle(.secondary)
                            } } icon: { IconoCuadrado(simbolo: "lock.fill", color: ColorConexion.para(perfil.id)) }
                        }
                    }
                }
                Section {
                    Toggle("Incluir contraseñas", isOn: $incluirContrasenas)
                    Toggle("Incluir el código por correo", isOn: $incluirCorreo)
                } footer: {
                    Text(incluirContrasenas
                         ? "macOS pedirá Touch ID o la contraseña del equipo para leerlas del Llavero. Viajan cifradas dentro del archivo."
                         : "Sin contraseñas, tendrás que escribirlas al importar. La cuenta de Google nunca se exporta.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    SecureField("Frase", text: $frase, prompt: Text("Al menos \(CifradoExportacion.longitudMinima) caracteres"))
                    SecureField("Repítela", text: $repetir)
                    if !frase.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(0..<3, id: \.self) { nivel in
                                Capsule().fill(nivel < fuerza ? colorFuerza : Color.secondary.opacity(0.2)).frame(height: 4)
                            }
                            Text(textoFuerza).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                        }
                    }
                    if !repetir.isEmpty && frase != repetir {
                        Label("Las frases no coinciden.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Frase para cifrar el archivo")
                } footer: {
                    Text("El archivo siempre va cifrado. Sin la frase nadie puede abrirlo, tampoco Nuvex: guárdala en tu gestor de contraseñas. Una frase de varias palabras es fácil de recordar y difícil de adivinar.")
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Section { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled) }
                }
                Section {
                    HStack {
                        Button("Cancelar", action: cerrar).keyboardShortcut(.cancelAction)
                        Spacer()
                        if exportando { ProgressView().controlSize(.small) }
                        Button("Exportar…", action: exportar)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!puedeExportar)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
    }

    private var colorFuerza: Color { [Color.red, .orange, .yellow, .green][fuerza] }
    private var textoFuerza: String { ["Demasiado corta", "Débil", "Aceptable", "Muy buena"][fuerza] }

    private func resumen(_ guardado: (url: URL, contrasenas: Int, faltantes: Int)) -> String {
        var texto = "Se guardó \(guardado.url.lastPathComponent)"
        if guardado.contrasenas > 0 { texto += " con \(guardado.contrasenas) contraseña\(guardado.contrasenas == 1 ? "" : "s")" }
        texto += "."
        if guardado.faltantes > 0 { texto += " \(guardado.faltantes) conexión(es) no tenían contraseña guardada." }
        return texto + " Para importarlo, ábrelo con Nuvex en la otra Mac."
    }

    private func exportar() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.exportacionNuvex]
        panel.nameFieldStringValue = "Conexiones Nuvex \(Date().formatted(.iso8601.year().month().day())).nuvexvpn"
        panel.message = "El archivo va cifrado con tu frase."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let perfiles = modelo.profiles.filter { seleccion.contains($0.id) }
        let correo = incluirCorreo ? Preferencias.shared.ajustes.correo.filter { seleccion.contains($0.key) } : [:]
        let fraseUsada = frase
        let conContrasenas = incluirContrasenas
        exportando = true
        error = nil
        Task {
            defer { exportando = false }
            do {
                var contrasenas: [String: String]?
                if conContrasenas {
                    contrasenas = try await VPNModel.leerParaExportar(
                        perfiles, razon: "Exportar las contraseñas de \(perfiles.count) conexión(es) de Nuvex")
                }
                let contenido = ContenidoExportado(creado: Date(), app: InfoVersion.actual.corta, conexiones: perfiles,
                                                   contrasenas: contrasenas, correo: correo.isEmpty ? nil : correo)
                let datos = try await Task.detached(priority: .userInitiated) {
                    try CifradoExportacion.cifrar(contenido, frase: fraseUsada)
                }.value
                try escribirPrivado(datos, en: url)
                Log.escribir("exportadas \(perfiles.count) conexiones\(conContrasenas ? " con contraseñas" : "")")
                frase = ""
                repetir = ""
                guardado = (url, contrasenas?.count ?? 0, conContrasenas ? perfiles.count - (contrasenas?.count ?? 0) : 0)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Importar

@MainActor
enum VentanaImportar {
    static func mostrar(modelo: VPNModel, archivo: URL? = nil) {
        Ventanas.mostrar("importar", titulo: "Importar conexiones",
                         vista: VistaImportar(modelo: modelo, cerrar: { Ventanas.cerrar("importar") }, archivo: archivo),
                         tamano: NSSize(width: 540, height: 560))
    }
}

/// Qué hacer con cada conexión del archivo.
enum AccionImportacion: Hashable {
    case agregar
    case reemplazar
    case copia
    case omitir
}

struct ElementoImportacion: Identifiable {
    let perfil: VPNProfile
    let contrasena: String?
    let correo: ConfigCorreo?
    /// Conexión instalada con el mismo id, si la hay.
    let existente: VPNProfile?
    var accion: AccionImportacion
    var motivoInvalido: String?
    var id: String { perfil.id }
}

struct VistaImportar: View {
    @ObservedObject var modelo: VPNModel
    let cerrar: () -> Void
    @State var archivo: URL?
    @State private var frase = ""
    @State private var abriendo = false
    @State private var elementos: [ElementoImportacion]?
    @State private var importando = false
    @State private var error: String?
    @State private var terminado: String?
    @State private var idsFinales: [String: String] = [:]

    private var busy: Bool { modelo.guardandoConfiguracion || modelo.instalandoAyudante }

    var body: some View {
        Form {
            if let terminado {
                Section {
                    Label("Importación completa", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(terminado).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack { Spacer(); Button("Listo", action: cerrar).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                }
            } else if let elementos {
                vistaPrevia(elementos)
            } else {
                Section {
                    LabeledContent("Archivo") {
                        HStack {
                            Text(archivo?.lastPathComponent ?? "Ninguno").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Elegir…", action: elegir)
                        }
                    }
                    SecureField("Frase", text: $frase, prompt: Text("La que se usó al exportar"))
                        .onSubmit(abrir)
                } footer: {
                    Text("Nada cambia hasta que revises las conexiones y pulses Importar.").foregroundStyle(.secondary)
                }
                if let error {
                    Section { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled) }
                }
                Section {
                    HStack {
                        Button("Cancelar", action: cerrar).keyboardShortcut(.cancelAction)
                        Spacer()
                        if abriendo { ProgressView().controlSize(.small) }
                        Button("Abrir", action: abrir)
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(archivo == nil || frase.isEmpty || abriendo)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 560)
        .onChange(of: busy) { antes, ahora in
            guard importando, antes, !ahora else { return }
            terminarImportacion()
        }
    }

    @ViewBuilder
    private func vistaPrevia(_ lista: [ElementoImportacion]) -> some View {
        Section {
            ForEach(lista.indices, id: \.self) { indice in
                let elemento = lista[indice]
                HStack(alignment: .top, spacing: 10) {
                    IconoCuadrado(simbolo: "lock.fill", color: ColorConexion.para(elemento.perfil.id))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(elemento.perfil.name)
                        Text([elemento.perfil.server, elemento.perfil.username,
                              elemento.contrasena == nil ? "sin contraseña" : "con contraseña",
                              elemento.correo == nil ? nil : "código por correo"]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let motivo = elemento.motivoInvalido {
                            Text(motivo).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { elementos?[indice].accion ?? .omitir },
                                                  set: { elementos?[indice].accion = $0 })) {
                        if elemento.existente != nil {
                            Text("Reemplazar «\(elemento.existente!.name)»").tag(AccionImportacion.reemplazar)
                            Text("Importar como copia").tag(AccionImportacion.copia)
                        } else {
                            Text("Añadir").tag(AccionImportacion.agregar)
                        }
                        Text("Omitir").tag(AccionImportacion.omitir)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(elemento.motivoInvalido != nil)
                }
            }
        } header: {
            Text("Conexiones del archivo")
        } footer: {
            Text("Reemplazar actualiza la conexión que ya tienes con ese mismo origen. Importar como copia crea una nueva y conserva la actual.")
                .foregroundStyle(.secondary)
        }
        if let activa = modelo.vpns.first(where: \.connected) {
            Section { Label("Desconecta «\(activa.name)» para importar: las conexiones no pueden cambiar con una VPN activa.",
                            systemImage: "lock.fill").foregroundStyle(.orange) }
        }
        if let error {
            Section { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled) }
        }
        Section {
            HStack {
                Button("Cancelar", action: cerrar).keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                let cuenta = lista.filter { $0.accion != .omitir && $0.motivoInvalido == nil }.count
                Button(cuenta == 1 ? "Importar 1 conexión" : "Importar \(cuenta) conexiones", action: importar)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(cuenta == 0 || busy || modelo.hayAlgunaConectada)
            }
        }
    }

    private func elegir() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.exportacionNuvex, .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { archivo = panel.url; error = nil }
    }

    private func abrir() {
        guard let archivo, !frase.isEmpty else { return }
        let fraseUsada = frase
        abriendo = true
        error = nil
        Task {
            defer { abriendo = false }
            do {
                let datos = try Data(contentsOf: archivo)
                let contenido = try await Task.detached(priority: .userInitiated) {
                    try CifradoExportacion.descifrar(datos, frase: fraseUsada)
                }.value
                frase = ""
                elementos = contenido.conexiones.map { perfil in
                    let existente = modelo.profiles.first { $0.id == perfil.id }
                    let mismoNombre = modelo.profiles.contains { $0.id != perfil.id && $0.name == perfil.name }
                    return ElementoImportacion(perfil: perfil, contrasena: contenido.contrasenas?[perfil.id],
                                               correo: contenido.correo?[perfil.id], existente: existente,
                                               accion: existente != nil ? .reemplazar : (mismoNombre ? .omitir : .agregar),
                                               motivoInvalido: Validacion.motivo(perfil))
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func importar() {
        guard let elementos else { return }
        var perfiles = modelo.profiles
        var contrasenas: [String: String] = [:]
        idsFinales = [:]
        for elemento in elementos where elemento.motivoInvalido == nil {
            var perfil = elemento.perfil.normalizado
            switch elemento.accion {
            case .omitir: continue
            case .agregar:
                perfiles.append(perfil)
            case .reemplazar:
                if let i = perfiles.firstIndex(where: { $0.id == perfil.id }) { perfiles[i] = perfil } else { perfiles.append(perfil) }
            case .copia:
                perfil = VPNProfile(id: VPNProfile.nuevo().id, name: perfil.name + " (importada)", server: perfil.server,
                                    username: perfil.username, trust: perfil.trust, realm: perfil.realm,
                                    manageRoutes: perfil.manageRoutes, manageDNS: perfil.manageDNS, enabled: perfil.enabled)
                perfiles.append(perfil)
            }
            idsFinales[elemento.perfil.id] = perfil.id
            if let contrasena = elemento.contrasena { contrasenas[perfil.id] = contrasena }
        }
        guard perfiles.count <= 64 else { error = "Nuvex admite hasta 64 conexiones."; return }
        error = nil
        importando = true
        modelo.guardarPerfiles(perfiles, passwords: contrasenas)
        // guardarPerfiles puede rechazarlo sin empezar a guardar.
        if !busy { terminarImportacion() }
    }

    private func terminarImportacion() {
        importando = false
        let importados = idsFinales.values.filter { id in modelo.profiles.contains { $0.id == id } }
        guard !importados.isEmpty, modelo.ultimoError == nil || importados.count == idsFinales.count else {
            error = modelo.ultimoError ?? "No se pudieron importar las conexiones."
            return
        }
        // El código por correo vive en ajustes.json, fuera de las conexiones.
        Preferencias.shared.modificar { ajustes in
            for elemento in elementos ?? [] {
                if let destino = idsFinales[elemento.perfil.id], let correo = elemento.correo { ajustes.correo[destino] = correo }
            }
        }
        Log.escribir("importadas \(importados.count) conexiones")
        let sinContrasena = elementos?.filter { idsFinales[$0.perfil.id] != nil && $0.contrasena == nil }.count ?? 0
        terminado = "Se importaron \(importados.count) conexión(es)."
            + (sinContrasena > 0 ? " \(sinContrasena) no traían contraseña: añádela en Ajustes antes de conectar." : "")
            + (modelo.ultimoError.map { " Aviso: \($0)" } ?? "")
        elementos = nil
    }
}
