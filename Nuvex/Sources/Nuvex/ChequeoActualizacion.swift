import AppKit
import CryptoKit
import Security
import SwiftUI

/// Comprobaciones del primer arranque de una versión nueva. Su objetivo es que
/// cualquier permiso pendiente se pida con la persona delante, no cuando un
/// asistente intente conectar a distancia.
@MainActor
final class ChequeoActualizacion: ObservableObject {
    static let claveFirma = "huellaFirmaApp"
    static let claveRequisito = "requisitoFirmaApp"
    static let claveLlaveroPendiente = "llaveroPendienteTrasFirma"

    /// Cambió la identidad; el acceso efectivo debe comprobarse por entrada.
    @Published private(set) var llaveroPendiente: Bool
    @Published private(set) var probandoLlavero = false
    @Published private(set) var errorLlavero: String?
    /// Versión cuyas novedades aún no se han visto.
    @Published private(set) var novedades: String?
    let firmaEstable: Bool

    private let defaults: UserDefaults
    private var avisoAyudanteEnviado = false
    private let versionNueva: Bool

    init(migracion: Migraciones.Resultado, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        versionNueva = migracion.versionNueva
        let huella = Self.huellaFirma()
        firmaEstable = huella != "desconocida" && !huella.hasPrefix("adhoc")
        let anterior = defaults.string(forKey: Self.claveFirma)
        let requisito = Self.requisitoFirma()
        let requisitoAnterior = defaults.string(forKey: Self.claveRequisito)
        let cambio = requisitoAnterior != nil && requisito != nil
            ? requisitoAnterior != requisito : anterior != nil && anterior != huella && huella != "desconocida"
        if cambio {
            defaults.set(true, forKey: Self.claveLlaveroPendiente)
            Log.escribir("cambió la identidad de la app; comprobar acceso al Llavero")
        }
        if huella != "desconocida" { defaults.set(huella, forKey: Self.claveFirma) }
        if let requisito { defaults.set(requisito, forKey: Self.claveRequisito) }
        llaveroPendiente = defaults.bool(forKey: Self.claveLlaveroPendiente)
        if migracion.versionNueva, Self.notas(de: InfoVersion.actual.corta) != nil {
            let version = InfoVersion.actual.corta
            if defaults.bool(forKey: Actualizaciones.claveNovedadesAlIniciar) {
                // Actualización pedida desde Nuvex: las novedades se muestran al abrir.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    VentanaNovedades.mostrar(version: version)
                }
            } else {
                novedades = version
            }
        }
        defaults.removeObject(forKey: Actualizaciones.claveNovedadesAlIniciar)
    }

    /// Se llama cuando el modelo ya cargó perfiles y estado.
    func revisar(_ modelo: VPNModel) {
        if llaveroPendiente && modelo.configuracionCargada && modelo.profiles.allSatisfy({
            modelo.passwordStatuses[$0.id] == .missing
        }) {
            // Sin contraseñas guardadas no hay nada que el Llavero deba volver a autorizar.
            descartarLlavero()
        }
        if versionNueva, !avisoAyudanteEnviado, modelo.ayudanteListo == false, !modelo.profiles.isEmpty {
            avisoAyudanteEnviado = true
            VPNNotifications.shared.avisoAyudante()
        }
    }

    /// Reconcilia el aviso de firma con una consulta vigente de todas las entradas.
    func confirmarAccesosLlavero(perfiles: [VPNProfile], accesos: [String: AccesoLlavero],
                                configuracionCargada: Bool) {
        guard llaveroPendiente, configuracionCargada, perfiles.allSatisfy({ perfil in
            guard let acceso = accesos[perfil.id] else { return false }
            return acceso == .disponible || acceso == .ausente
        }) else { return }
        descartarLlavero()
    }

    /// Provoca ahora la petición de acceso del Llavero, con la persona delante.
    func probarLlavero(_ modelo: VPNModel) {
        guard !probandoLlavero else { return }
        let perfiles = modelo.profiles.filter {
            !$0.username.isEmpty && modelo.passwordStatuses[$0.id] != .missing
        }
        guard !perfiles.isEmpty else {
            errorLlavero = "No hay contraseñas guardadas comprobables. Revisa las conexiones."
            return
        }
        probandoLlavero = true
        errorLlavero = nil
        Task {
            do {
                for perfil in perfiles {
                    _ = try await VPNModel.leerDelLlavero(
                        id: perfil.id, name: perfil.name,
                        reason: "Comprobar que Nuvex puede usar las contraseñas guardadas tras actualizarse")
                }
                descartarLlavero()
            } catch {
                errorLlavero = error.localizedDescription
            }
            probandoLlavero = false
        }
    }

    func descartarLlavero() {
        llaveroPendiente = false
        defaults.set(false, forKey: Self.claveLlaveroPendiente)
    }

    func novedadesVistas() { novedades = nil }

    // MARK: Firma

    /// El requisito designado incluye identificador y firmante. Comparar solo
    /// el certificado omitía cambios de identidad con el mismo certificado.
    nonisolated static func requisitoFirma() -> String? {
        var codigo: SecCode?
        guard SecCodeCopySelf([], &codigo) == errSecSuccess, let codigo else { return nil }
        var estatico: SecStaticCode?
        guard SecCodeCopyStaticCode(codigo, [], &estatico) == errSecSuccess, let estatico else { return nil }
        var requisito: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(estatico, [], &requisito) == errSecSuccess,
              let requisito else { return nil }
        var texto: CFString?
        guard SecRequirementCopyString(requisito, [], &texto) == errSecSuccess,
              let texto else { return nil }
        return SHA256.hash(data: Data((texto as String).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Huella del certificado que firma la app, o "adhoc:<cdhash>" sin certificado.
    nonisolated static func huellaFirma() -> String {
        var codigo: SecCode?
        guard SecCodeCopySelf([], &codigo) == errSecSuccess, let codigo else { return "desconocida" }
        var estatico: SecStaticCode?
        guard SecCodeCopyStaticCode(codigo, [], &estatico) == errSecSuccess, let estatico else { return "desconocida" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(estatico, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let datos = info as? [String: Any] else { return "desconocida" }
        if let certificados = datos[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let hoja = certificados.first {
            return SHA256.hash(data: SecCertificateCopyData(hoja) as Data)
                .map { String(format: "%02x", $0) }.joined()
        }
        let cdhash = (datos[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined() ?? ""
        return "adhoc:" + cdhash
    }

    // MARK: Novedades

    /// Sección `## [versión]` del CHANGELOG incluido en la app.
    nonisolated static func notas(de version: String, en texto: String? = nil) -> String? {
        let contenido = texto ?? Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        guard let contenido else { return nil }
        return NotasCambios.seccion(de: version, en: contenido)
    }
}

// MARK: - Ventana de novedades

@MainActor
enum VentanaNovedades {
    private static var ventana: NSWindow?

    static func mostrar(version: String) {
        let ventana = ventana ?? {
            let v = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            v.titlebarAppearsTransparent = true
            v.titleVisibility = .hidden
            v.isMovableByWindowBackground = true
            v.isReleasedWhenClosed = false
            return v
        }()
        Self.ventana = ventana
        ventana.title = "Novedades de Nuvex \(version)"
        ventana.contentViewController = NSHostingController(rootView: NovedadesView(
            version: version, notas: ChequeoActualizacion.notas(de: version) ?? "",
            cerrar: { ventana.close() }))
        ventana.center()
        NSApp.activate(ignoringOtherApps: true)
        ventana.makeKeyAndOrderFront(nil)
    }
}

/// Pantalla de bienvenida a una versión nueva, como tras actualizar iOS.
struct NovedadesView: View {
    let version: String
    let notas: String
    let cerrar: () -> Void

    var body: some View {
        // Sin separadores: la cabecera se desplaza con las notas y el botón va
        // en la barra de acciones del sistema, sobre la que el texto se funde.
        ScrollView {
            VStack(spacing: Espacio.xxl) {
                VStack(spacing: Espacio.m) {
                    IconoNuvex(lado: Tamano.logoPantalla)
                        .padding(.bottom, Espacio.xs)
                    Text("Novedades de Nuvex \(version)")
                        .font(Tipo.pantalla)
                    Text("Nuvex se actualizó correctamente. Tus conexiones y ajustes siguen igual.")
                        .font(Tipo.entradilla)
                        .foregroundStyle(Paleta.textoSecundario)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NotasVersion(texto: notas.isEmpty ? "Mejoras de estabilidad y rendimiento." : notas)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Espacio.pantalla)
            .padding(.top, Espacio.pantalla)
            .padding(.bottom, Espacio.xxl)
        }
        .barraAcciones {
            Button("Continuar", action: cerrar)
                .estiloBoton(.principal)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 480, height: 540)
        .fondoVentana()
    }
}
