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
    static let claveLlaveroPendiente = "llaveroPendienteTrasFirma"

    /// La firma de la app cambió y el Llavero pedirá permiso en el próximo uso.
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
        firmaEstable = !huella.hasPrefix("adhoc")
        let anterior = defaults.string(forKey: Self.claveFirma)
        if let anterior, anterior != huella {
            defaults.set(true, forKey: Self.claveLlaveroPendiente)
            Log.escribir("la firma de la app cambió; el Llavero pedirá permiso de nuevo")
        }
        defaults.set(huella, forKey: Self.claveFirma)
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
        if llaveroPendiente && !modelo.passwordStatuses.values.contains(.saved) && modelo.configuracionCargada {
            // Sin contraseñas guardadas no hay nada que el Llavero deba volver a autorizar.
            descartarLlavero()
        }
        if versionNueva, !avisoAyudanteEnviado, modelo.ayudanteListo == false, !modelo.profiles.isEmpty {
            avisoAyudanteEnviado = true
            VPNNotifications.shared.avisoAyudante()
        }
    }

    /// Provoca ahora la petición de acceso del Llavero, con la persona delante.
    func probarLlavero(_ modelo: VPNModel) {
        guard let perfil = modelo.profiles.first(where: { modelo.passwordStatuses[$0.id] == .saved }) else {
            descartarLlavero()
            return
        }
        probandoLlavero = true
        errorLlavero = nil
        Task {
            do {
                _ = try await VPNModel.leerDelLlavero(
                    id: perfil.id, name: perfil.name,
                    reason: "Comprobar que Nuvex puede usar las contraseñas guardadas tras actualizarse")
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
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                IconoNuvex(lado: 72)
                Text("Novedades de Nuvex \(version)")
                    .font(.title2).fontWeight(.bold)
                Text("Nuvex se actualizó correctamente. Tus conexiones y ajustes siguen igual.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            .padding(.bottom, 18)
            Divider()
            ScrollView {
                NotasVersion(texto: notas.isEmpty ? "Mejoras de estabilidad y rendimiento." : notas)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 18)
            }
            Divider()
            Button("Continuar", action: cerrar)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(18)
        }
        .frame(width: 480, height: 540)
    }
}
