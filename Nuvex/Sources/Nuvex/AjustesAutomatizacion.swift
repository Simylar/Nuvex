import AppKit
import SwiftUI

/// Instala el comando `nuvex` y la habilidad para Claude Code y Codex sin
/// tocar nada que no haya creado Nuvex.
enum IntegracionAsistentes {
    static let marca = "<!-- nuvex-vpn: gestionado por Nuvex."
    private static let home = URL(fileURLWithPath: Paths.userHome, isDirectory: true)

    struct Destino: Identifiable {
        let id: String
        let nombre: String
        /// Carpeta de configuración de la herramienta (~/.claude, ~/.codex).
        let raiz: URL
        var carpeta: URL { raiz.appendingPathComponent("skills/nuvex-vpn", isDirectory: true) }
        var archivo: URL { carpeta.appendingPathComponent("SKILL.md") }
    }

    enum Estado: Equatable {
        case sinHerramienta, ausente, instalada, desactualizada, ajena
    }

    static let destinos = [
        Destino(id: "claude", nombre: "Claude Code", raiz: home.appendingPathComponent(".claude", isDirectory: true)),
        Destino(id: "codex", nombre: "Codex", raiz: home.appendingPathComponent(".codex", isDirectory: true)),
    ]

    static var plantilla: String? {
        Bundle.main.url(forResource: "nuvex-vpn-SKILL", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    static func estado(_ destino: Destino) -> Estado {
        let archivos = FileManager.default
        guard archivos.fileExists(atPath: destino.raiz.path) else { return .sinHerramienta }
        guard archivos.fileExists(atPath: destino.carpeta.path) else { return .ausente }
        guard let actual = try? String(contentsOf: destino.archivo, encoding: .utf8), actual.contains(marca) else {
            return .ajena
        }
        return actual == plantilla ? .instalada : .desactualizada
    }

    static func instalar(_ destino: Destino) throws {
        guard let plantilla else { throw CocoaError(.fileNoSuchFile) }
        guard estado(destino) != .ajena else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: destino.carpeta, withIntermediateDirectories: true)
        try plantilla.write(to: destino.archivo, atomically: true, encoding: .utf8)
    }

    static func quitar(_ destino: Destino) throws {
        guard estado(destino) == .instalada || estado(destino) == .desactualizada else { return }
        try FileManager.default.removeItem(at: destino.carpeta)
    }

    // MARK: Comando

    static let enlace = home.appendingPathComponent(".local/bin/nuvex")

    /// El ejecutable dentro de esta app.
    static var comandoIncluido: URL? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("bin/nuvex") }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    enum EstadoComando: Equatable {
        case noIncluido
        case ausente
        case instalado
        /// Apunta a otra copia de Nuvex.
        case otraCopia(String)
        /// Hay un archivo que no creó Nuvex.
        case ajeno
    }

    static func estadoComando() -> EstadoComando {
        guard let incluido = comandoIncluido else { return .noIncluido }
        guard let destino = try? FileManager.default.destinationOfSymbolicLink(atPath: enlace.path) else {
            return FileManager.default.fileExists(atPath: enlace.path) ? .ajeno : .ausente
        }
        if destino == incluido.path { return .instalado }
        return destino.contains("Nuvex") && destino.hasSuffix("/bin/nuvex") ? .otraCopia(destino) : .ajeno
    }

    static func instalarComando() throws {
        guard let incluido = comandoIncluido else { throw CocoaError(.fileNoSuchFile) }
        switch estadoComando() {
        case .ajeno: throw CocoaError(.fileWriteFileExists)
        case .otraCopia: try FileManager.default.removeItem(at: enlace)
        case .instalado: return
        default: break
        }
        try FileManager.default.createDirectory(at: enlace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: enlace, withDestinationURL: incluido)
    }

    static func quitarComando() throws {
        switch estadoComando() {
        case .instalado, .otraCopia: try FileManager.default.removeItem(at: enlace)
        default: break
        }
    }
}

// MARK: - Página de Ajustes

struct AjustesAutomatizacion: View {
    @ObservedObject var modelo: VPNModel
    @ObservedObject private var preferencias = Preferencias.shared
    @State private var estadoComando = IntegracionAsistentes.estadoComando()
    @State private var estados: [String: IntegracionAsistentes.Estado] = [:]
    @State private var error: String?

    private var politica: Binding<PoliticaAsistentes> {
        Binding(get: { preferencias.ajustes.politicaAsistentes },
                set: { nueva in preferencias.modificar { $0.politicaAsistentes = nueva } })
    }

    private func refrescar() {
        estadoComando = IntegracionAsistentes.estadoComando()
        estados = Dictionary(uniqueKeysWithValues: IntegracionAsistentes.destinos.map { ($0.id, IntegracionAsistentes.estado($0)) })
    }

    private func intentar(_ accion: () throws -> Void) {
        do { try accion(); error = nil } catch { self.error = "No se pudo completar: \(error.localizedDescription)" }
        refrescar()
    }

    var body: some View {
        Form {
            if let aviso = preferencias.soloLectura {
                Section { Label(aviso, systemImage: "lock.fill").foregroundStyle(.orange) }
            }
            Section {
                Picker("Terminal y asistentes", selection: politica) {
                    Text("No permitir").tag(PoliticaAsistentes.noPermitir)
                    Text("Pedir confirmación en la Mac").tag(PoliticaAsistentes.preguntar)
                    Text("Conectar sin preguntar").tag(PoliticaAsistentes.permitir)
                }
                Toggle("Avisar cuando un asistente conecte o desconecte", isOn: Binding(
                    get: { preferencias.ajustes.avisarAccionesAsistentes },
                    set: { valor in preferencias.modificar { $0.avisarAccionesAsistentes = valor } }))
            } header: {
                Text("Permisos")
            } footer: {
                Text("Con «Conectar sin preguntar», Claude Code o Codex pueden conectar tus VPN aunque no estés frente a la Mac. Consultar el estado siempre está permitido y no muestra servidores, usuarios ni contraseñas.")
                    .foregroundStyle(.secondary)
            }
            .disabled(preferencias.soloLectura != nil)

            if !modelo.profiles.isEmpty {
                Section {
                    ForEach(modelo.profiles) { perfil in
                        Toggle(isOn: Binding(
                            get: { !preferencias.ajustes.bloqueadasParaAsistentes.contains(perfil.id) },
                            set: { permitida in
                                preferencias.modificar {
                                    if permitida { $0.bloqueadasParaAsistentes.remove(perfil.id) }
                                    else { $0.bloqueadasParaAsistentes.insert(perfil.id) }
                                }
                            })) {
                            Label { Text(perfil.name) } icon: {
                                IconoCuadrado(simbolo: "lock.fill", color: ColorConexion.para(perfil.id))
                            }
                        }
                    }
                } header: {
                    Text("Conexiones disponibles para asistentes")
                }
                .disabled(preferencias.ajustes.politicaAsistentes == .noPermitir || preferencias.soloLectura != nil)
            }

            Section {
                LabeledContent {
                    switch estadoComando {
                    case .instalado:
                        Button("Quitar") { intentar(IntegracionAsistentes.quitarComando) }
                    case .ausente, .otraCopia:
                        Button("Instalar") { intentar(IntegracionAsistentes.instalarComando) }
                    case .noIncluido, .ajeno:
                        EmptyView()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Comando nuvex")
                        Text(descripcion(estadoComando)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("Crea ~/.local/bin/nuvex. Si tu Terminal no lo encuentra, añade ~/.local/bin a tu PATH.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(IntegracionAsistentes.destinos) { destino in
                    LabeledContent {
                        switch estados[destino.id] ?? .ausente {
                        case .ausente: Button("Instalar") { intentar { try IntegracionAsistentes.instalar(destino) } }
                        case .desactualizada: Button("Actualizar") { intentar { try IntegracionAsistentes.instalar(destino) } }
                        case .instalada: Button("Quitar") { intentar { try IntegracionAsistentes.quitar(destino) } }
                        case .sinHerramienta, .ajena: EmptyView()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(destino.nombre)
                            Text(descripcion(estados[destino.id] ?? .ausente, destino)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            } header: {
                Text("Habilidad para asistentes")
            } footer: {
                Text("Enseña a Claude Code y a Codex cuándo y cómo usar nuvex, por ejemplo al pedirles «conéctame a la VPN de la oficina». Si la VPN pide un código, te lo preguntarán en el chat o Nuvex lo leerá del correo.")
                    .foregroundStyle(.secondary)
            }

            Section("Ejemplos") {
                ForEach(["nuvex estado", "nuvex conectar oficina", "nuvex desconectar --todas", "nuvex diagnostico"], id: \.self) { ejemplo in
                    HStack {
                        Text(ejemplo).font(.body.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ejemplo, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copiar")
                        .accessibilityLabel("Copiar \(ejemplo)")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Automatización")
        .onAppear(perform: refrescar)
    }

    private func descripcion(_ estado: IntegracionAsistentes.EstadoComando) -> String {
        switch estado {
        case .noIncluido: return "Esta compilación no incluye el comando."
        case .ausente: return "No instalado"
        case .instalado: return "Instalado en ~/.local/bin/nuvex"
        case .otraCopia: return "Apunta a otra copia de Nuvex; instálalo para usar esta."
        case .ajeno: return "Ya existe un ~/.local/bin/nuvex que no creó Nuvex; no se modifica."
        }
    }

    private func descripcion(_ estado: IntegracionAsistentes.Estado, _ destino: IntegracionAsistentes.Destino) -> String {
        switch estado {
        case .sinHerramienta: return "\(destino.nombre) no está instalado en esta Mac."
        case .ausente: return "No instalada"
        case .instalada: return "Instalada"
        case .desactualizada: return "Hay una versión más nueva de la habilidad."
        case .ajena: return "Ya existe una habilidad nuvex-vpn que no creó Nuvex; no se modifica."
        }
    }
}
