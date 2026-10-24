import AppKit
import NuvexControl
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
        switch ArchivoGestionado.estado(carpeta: destino.carpeta, archivo: destino.archivo, marca: marca) {
        case .ausente:
            return .ausente
        case .gestionado(let actual):
            return actual == plantilla ? .instalada : .desactualizada
        case .ajeno:
            return .ajena
        }
    }

    static func instalar(_ destino: Destino) throws {
        guard let plantilla else { throw CocoaError(.fileNoSuchFile) }
        guard estado(destino) != .ajena else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: destino.carpeta, withIntermediateDirectories: true)
        try plantilla.write(to: destino.archivo, atomically: true, encoding: .utf8)
    }

    static func quitar(_ destino: Destino) throws {
        try ArchivoGestionado.quitar(carpeta: destino.carpeta, archivo: destino.archivo, marca: marca)
    }

    // MARK: Comando

    static let enlace = home.appendingPathComponent(".local/bin/nuvex")
    /// Forma que los agentes escriben en Bash y que sus motores de reglas
    /// comparan antes de que el shell expanda el directorio personal.
    static let comandoParaAgentes = "~/.local/bin/nuvex"

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
        case .instalado, .otraCopia:
            // Una regla fuera del sandbox nunca debe quedar apuntando a una
            // ruta que Nuvex ya no administra.
            for destino in destinos { try revocar(destino) }
            try FileManager.default.removeItem(at: enlace)
        default: break
        }
    }

    // MARK: Autorización persistente del agente

    static func estadoAutorizacion(_ destino: Destino) -> AutorizacionAgentes.Estado {
        guard estadoComando() == .instalado else { return .noDisponible }
        switch destino.id {
        case "codex": return AutorizacionAgentes.estadoCodex(raiz: destino.raiz, comando: comandoParaAgentes)
        case "claude": return AutorizacionAgentes.estadoClaude(raiz: destino.raiz, comando: comandoParaAgentes)
        default: return .noDisponible
        }
    }

    static func autorizar(_ destino: Destino) throws {
        guard estadoComando() == .instalado else { throw CocoaError(.fileNoSuchFile) }
        switch destino.id {
        case "codex": try AutorizacionAgentes.instalarCodex(raiz: destino.raiz, comando: comandoParaAgentes)
        case "claude": try AutorizacionAgentes.instalarClaude(raiz: destino.raiz, comando: comandoParaAgentes)
        default: throw CocoaError(.featureUnsupported)
        }
    }

    static func revocar(_ destino: Destino) throws {
        switch destino.id {
        case "codex": try AutorizacionAgentes.quitarCodex(raiz: destino.raiz)
        case "claude": try AutorizacionAgentes.quitarClaude(raiz: destino.raiz, comando: comandoParaAgentes)
        default: break
        }
    }

    /// Prepara de una vez el comando y las habilidades de los asistentes que
    /// ya estén instalados. Conserva archivos ajenos y no cambia la política
    /// de autorización elegida por la persona.
    static func preparar() throws {
        try instalarComando()
        for destino in destinos {
            switch estado(destino) {
            case .ausente, .desactualizada:
                try instalar(destino)
            case .sinHerramienta, .instalada, .ajena:
                // Una habilidad ajena se conserva y no impide preparar el
                // resto de herramientas detectadas.
                continue
            }
        }
    }

    /// Ejecuta el comando instalado contra el socket real de esta app. Así el
    /// diagnóstico cubre enlace, ejecutable, autorización y versión del
    /// protocolo, no solo la existencia de archivos.
    static func comprobarComando() async -> Comprobacion {
        let estado = estadoComando()
        guard estado == .instalado else {
            return Comprobacion(nombre: "Comando nuvex", ok: false, detalle: descripcionComando(estado))
        }
        return await Task.detached(priority: .utility) {
            do {
                let resultado = try Proceso.ejecutar(enlace.path, args: ["estado", "--json"],
                                                     entorno: Paths.environment, limite: 15)
                let mensajes = resultado.salida.split(separator: "\n").compactMap { linea in
                    try? Linea.decodificar(Mensaje.self, de: Data(linea.utf8))
                }
                guard resultado.codigo == CodigoSalida.ok.rawValue,
                      mensajes.last?.tipo == .resultado, mensajes.last?.salida == .ok else {
                    let detalle = resultado.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    return Comprobacion(nombre: "Comando nuvex", ok: false,
                                        detalle: detalle.isEmpty ? "Se ejecutó, pero no respondió correctamente" : detalle)
                }
                return Comprobacion(nombre: "Comando nuvex", ok: true,
                                    detalle: "Instalado y comunicado con esta copia de Nuvex")
            } catch {
                return Comprobacion(nombre: "Comando nuvex", ok: false,
                                    detalle: "No respondió: \(error.localizedDescription)")
            }
        }.value
    }

    private static func descripcionComando(_ estado: EstadoComando) -> String {
        switch estado {
        case .noIncluido: return "Esta compilación no incluye el comando"
        case .ausente: return "No instalado"
        case .instalado: return "Instalado"
        case .otraCopia: return "Apunta a otra copia de Nuvex"
        case .ajeno: return "Ya existe un comando ajeno que Nuvex no modifica"
        }
    }
}

// MARK: - Página de Ajustes

struct AjustesAutomatizacion: View {
    @ObservedObject var modelo: VPNModel
    @ObservedObject private var preferencias = Preferencias.shared
    @State private var estadoComando = IntegracionAsistentes.estadoComando()
    @State private var estados: [String: IntegracionAsistentes.Estado] = [:]
    @State private var autorizaciones: [String: AutorizacionAgentes.Estado] = [:]
    @State private var comprobaciones: [Comprobacion]?
    @State private var error: String?
    @State private var errorPreferencias: String?
    @State private var comprobando = false

    private var politica: Binding<PoliticaAsistentes> {
        Binding(get: { preferencias.ajustes.politicaAsistentes },
                set: { nueva in modificarPreferencias { $0.politicaAsistentes = nueva } })
    }

    private func refrescar() {
        estadoComando = IntegracionAsistentes.estadoComando()
        estados = Dictionary(uniqueKeysWithValues: IntegracionAsistentes.destinos.map { ($0.id, IntegracionAsistentes.estado($0)) })
        autorizaciones = Dictionary(uniqueKeysWithValues: IntegracionAsistentes.destinos.map {
            ($0.id, IntegracionAsistentes.estadoAutorizacion($0))
        })
    }

    private func intentar(_ accion: () throws -> Void) {
        do { try accion(); error = nil } catch { self.error = "No se pudo completar: \(error.localizedDescription)" }
        refrescar()
    }

    private func modificarPreferencias(_ cambio: (inout AjustesApp) -> Void) {
        errorPreferencias = preferencias.modificar(cambio)
            ? nil
            : "No se pudo guardar el cambio. Revisa los permisos del archivo de ajustes e inténtalo de nuevo."
    }

    private func comprobarPreparacion() async {
        comprobando = true
        defer { comprobando = false }
        refrescar()
        var resultado = modelo.control?.diagnostico() ?? [
            Comprobacion(nombre: "Control remoto", ok: false,
                         detalle: "El servicio de automatización todavía no está disponible."),
        ]
        resultado.append(await IntegracionAsistentes.comprobarComando())
        resultado.append(contentsOf: IntegracionAsistentes.destinos.compactMap(comprobacionHabilidad))
        resultado.append(contentsOf: IntegracionAsistentes.destinos.compactMap(comprobacionAutorizacion))
        comprobaciones = resultado
    }

    private func prepararIntegracion() {
        intentar(IntegracionAsistentes.preparar)
        guard error == nil else { return }
        Task { await comprobarPreparacion() }
    }

    var body: some View {
        Form {
            if let aviso = preferencias.soloLectura {
                Section { Label(aviso, systemImage: "lock.fill").foregroundStyle(Paleta.avisoTexto) }
            }
            Section {
                HStack(spacing: Espacio.l) {
                    IconoCuadrado(simbolo: "wand.and.stars", color: Paleta.acento,
                                  lado: Tamano.iconoCabecera)
                    VStack(alignment: .leading, spacing: Espacio.xxs) {
                        Text("Preparar automatización").font(Tipo.encabezado)
                        Text("Instala o actualiza el comando y las habilidades detectadas; después comprueba la comunicación real.")
                            .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Preparar") { prepararIntegracion() }
                        .estiloBoton(.principal)
                        .disabled(comprobando || estadoComando == .noIncluido || estadoComando == .ajeno)
                }
                .padding(.vertical, Espacio.xs)
            } footer: {
                Text("No concede permisos de macOS ni modifica «Conectar sin preguntar». Los archivos que Nuvex no creó nunca se reemplazan.")
                    .foregroundStyle(Paleta.textoSecundario)
            }
            Section {
                Picker("Terminal y asistentes", selection: politica) {
                    Text("No permitir").tag(PoliticaAsistentes.noPermitir)
                    Text("Pedir confirmación en la Mac").tag(PoliticaAsistentes.preguntar)
                    Text("Conectar sin preguntar").tag(PoliticaAsistentes.permitir)
                }
                Toggle("Avisar cuando un asistente conecte o desconecte", isOn: Binding(
                    get: { preferencias.ajustes.avisarAccionesAsistentes },
                    set: { valor in modificarPreferencias { $0.avisarAccionesAsistentes = valor } }))
                if let errorPreferencias {
                    Label(errorPreferencias, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Paleta.errorTexto)
                }
            } header: {
                Text("Permisos")
            } footer: {
                Text("Con «Conectar sin preguntar», Claude Code o Codex pueden conectar tus VPN aunque no estés frente a la Mac. Consultar el estado siempre está permitido y no muestra servidores, usuarios ni contraseñas.")
                    .foregroundStyle(Paleta.textoSecundario)
            }
            .disabled(preferencias.soloLectura != nil)

            if !modelo.profiles.isEmpty {
                Section {
                    ForEach(modelo.profiles) { perfil in
                        Toggle(isOn: Binding(
                            get: { !preferencias.ajustes.bloqueadasParaAsistentes.contains(perfil.id) },
                            set: { permitida in
                                modificarPreferencias {
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
                    VStack(alignment: .leading, spacing: Espacio.xxs) {
                        Text("Comando nuvex")
                        Text(descripcion(estadoComando)).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                    }
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("Crea ~/.local/bin/nuvex. Si tu Terminal no lo encuentra, añade ~/.local/bin a tu PATH.")
                    .foregroundStyle(Paleta.textoSecundario)
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
                        VStack(alignment: .leading, spacing: Espacio.xxs) {
                            Text(destino.nombre)
                            Text(descripcion(estados[destino.id] ?? .ausente, destino)).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                        }
                    }
                }
                if let error {
                    Text(error).foregroundStyle(Paleta.errorTexto).textSelection(.enabled)
                }
            } header: {
                Text("Habilidad para asistentes")
            } footer: {
                Text("Enseña a Claude Code y a Codex cuándo y cómo usar nuvex, por ejemplo al pedirles «conéctame a la VPN de la oficina». Si la VPN pide un código, te lo preguntarán en el chat o Nuvex lo leerá del correo.")
                    .foregroundStyle(Paleta.textoSecundario)
            }

            Section {
                ForEach(IntegracionAsistentes.destinos) { destino in
                    LabeledContent {
                        switch autorizaciones[destino.id] ?? .noDisponible {
                        case .ausente, .parcial:
                            Button("Autorizar") { intentar { try IntegracionAsistentes.autorizar(destino) } }
                        case .instalada:
                            Button("Revocar") { intentar { try IntegracionAsistentes.revocar(destino) } }
                        case .noDisponible, .ajena:
                            EmptyView()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: Espacio.xxs) {
                            Text(destino.nombre)
                            Text(descripcion(autorizaciones[destino.id] ?? .noDisponible, destino))
                                .font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                        }
                    }
                }
            } header: {
                Text("Acceso persistente de agentes")
            } footer: {
                Text("Autorizar crea una regla revocable limitada a ~/.local/bin/nuvex. Las operaciones rutinarias ejecutan únicamente ese CLI fuera del sandbox sin volver a preguntar; el resto de comandos conserva su aislamiento y Nuvex sigue aplicando la política y las conexiones permitidas de arriba. Reinicia el agente después de cambiarla.")
                    .foregroundStyle(Paleta.textoSecundario)
            }

            Section {
                Button { Task { await comprobarPreparacion() } } label: {
                    if comprobando { ProgressView().controlSize(.small) }
                    else { Text("Comprobar preparación") }
                }
                .disabled(comprobando)
                if let comprobaciones {
                    ForEach(Array(comprobaciones.enumerated()), id: \.offset) { _, comprobacion in
                        Label {
                            VStack(alignment: .leading, spacing: Espacio.xxs) {
                                Text(comprobacion.nombre)
                                Text(comprobacion.detalle).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                            }
                        } icon: {
                            Image(systemName: comprobacion.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(comprobacion.ok ? Paleta.exito : Paleta.aviso)
                        }
                    }
                }
            } header: {
                Text("Diagnóstico")
            } footer: {
                Text("Comprueba localmente permisos, ayudante, Llavero, conexiones, comando y habilidades. No intenta conectar ninguna VPN.")
                    .foregroundStyle(Paleta.textoSecundario)
            }

            Section("Ejemplos") {
                ForEach(["~/.local/bin/nuvex estado", "~/.local/bin/nuvex conectar oficina", "~/.local/bin/nuvex desconectar --todas", "~/.local/bin/nuvex diagnostico"], id: \.self) { ejemplo in
                    HStack {
                        Text(ejemplo).font(Tipo.mono).textSelection(.enabled)
                        Spacer()
                        BotonCopiar(texto: ejemplo, etiqueta: "Copiar \(ejemplo)")
                    }
                }
            }
        }
        .formularioNuvex()
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

    private func descripcion(_ estado: AutorizacionAgentes.Estado,
                             _ destino: IntegracionAsistentes.Destino) -> String {
        switch estado {
        case .noDisponible: return "Instala primero el comando y \(destino.nombre)."
        case .ausente: return "Pedirá autorización del agente al salir de su sandbox."
        case .parcial: return "La regla está incompleta o pertenece a otra versión; puedes repararla."
        case .instalada: return "Autorizado para las operaciones rutinarias del CLI de Nuvex."
        case .ajena: return "La configuración existente no tiene una estructura segura para modificarla."
        }
    }

    private func comprobacionHabilidad(_ destino: IntegracionAsistentes.Destino) -> Comprobacion? {
        let estado = IntegracionAsistentes.estado(destino)
        guard estado != .sinHerramienta else { return nil }
        return Comprobacion(nombre: "Habilidad para \(destino.nombre)", ok: estado == .instalada,
                            detalle: descripcion(estado, destino))
    }

    private func comprobacionAutorizacion(_ destino: IntegracionAsistentes.Destino) -> Comprobacion? {
        let estado = IntegracionAsistentes.estadoAutorizacion(destino)
        guard estado != .noDisponible else { return nil }
        return Comprobacion(nombre: "Acceso persistente para \(destino.nombre)", ok: estado == .instalada,
                            detalle: descripcion(estado, destino))
    }
}
