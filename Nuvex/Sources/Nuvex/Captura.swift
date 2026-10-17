#if DEBUG
import AppKit
import SwiftUI

/// Solo en compilaciones de depuración: `Nuvex --captura <carpeta>` dibuja las
/// vistas principales con datos de ejemplo y guarda PNG en claro y oscuro.
/// No ejecuta el motor ni lee el Llavero.
@MainActor
enum Captura {
    static func ejecutar(en carpeta: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let modelo = VPNModel(muestra: ())
        let borradores = BorradoresAjustes()
        borradores.sincronizar(con: modelo.profiles)

        for oscuro in [false, true] {
            let sufijo = oscuro ? "oscuro" : "claro"
            guardar(PanelVPN(modelo: modelo).background(.background), nombre: "panel-\(sufijo)", en: carpeta, oscuro: oscuro)

            borradores.seleccion = .conexion("oficina")
            guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 820, height: 640),
                    nombre: "ajustes-conexion-\(sufijo)", en: carpeta, oscuro: oscuro)
        }
        borradores.seleccion = .conexion("norte")
        if let i = borradores.drafts.firstIndex(where: { $0.id == "norte" }) {
            borradores.drafts[i].server = "remote.norte.example:443"
        }
        guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 820, height: 640),
                nombre: "ajustes-cambios-claro", en: carpeta, oscuro: false)
        borradores.seleccion = .general
        guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 820, height: 640),
                nombre: "ajustes-general-claro", en: carpeta, oscuro: false)
        borradores.seleccion = .automatizacion
        guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 820, height: 720),
                nombre: "ajustes-automatizacion-claro", en: carpeta, oscuro: false)
        borradores.seleccion = .cuentaGoogle
        guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 820, height: 640),
                nombre: "ajustes-cuenta-google-claro", en: carpeta, oscuro: false)
        borradores.seleccion = .ayudante
        guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 820, height: 640),
                nombre: "ajustes-ayudante-claro", en: carpeta, oscuro: false)
        guardar(BienvenidaView(modelo: modelo, cerrar: {}).background(.background),
                nombre: "bienvenida-claro", en: carpeta, oscuro: false)
        let notas = ChequeoActualizacion.notas(de: "3.1.0", en: (try? String(contentsOfFile: carpetaProyecto + "/CHANGELOG.md", encoding: .utf8))) ?? ""
        let version = VersionDisponible(version: "3.1.0", compilacion: "42", tamano: 12_400_000,
                                        fecha: Date(), notas: notas)
        let estados: [(String, EstadoActualizacion)] = [
            ("aldia", .alDia),
            ("disponible", .disponible(version)),
            ("descargando", .descargando(version, recibido: 5_100_000, total: 12_400_000)),
            ("lista", .lista(version)),
        ]
        for (nombre, estado) in estados {
            guardar(ActualizacionSoftwareView(actualizaciones: Actualizaciones(muestra: estado)).frame(width: 520, height: 640),
                    nombre: "actualizacion-\(nombre)", en: carpeta, oscuro: false)
        }
        guardar(ActualizacionSoftwareView(actualizaciones: Actualizaciones(muestra: .disponible(version))).frame(width: 520, height: 640),
                nombre: "actualizacion-disponible-oscuro", en: carpeta, oscuro: true)
        guardar(NovedadesView(version: "3.1.0", notas: notas, cerrar: {}), nombre: "novedades", en: carpeta, oscuro: false)
        guardar(PanelCodigoView(solicitud: .muestra(nombre: "Oficina central",
                                                    correo: .buscando(desde: Date().addingTimeInterval(-12), cuenta: "samuel@gmail.com"))),
                nombre: "codigo-buscando", en: carpeta, oscuro: false)
        guardar(PanelCodigoView(solicitud: .muestra(nombre: "Oficina central", codigo: "482913",
                                                    correo: .encontrado(remitente: "noreply@empresa.com"), automatico: true)),
                nombre: "codigo-recibido-oscuro", en: carpeta, oscuro: true)
        for oscuro in [false, true] {
            guardar(HojaIconos(), nombre: "iconos-barra-\(oscuro ? "oscuro" : "claro")", en: carpeta, oscuro: oscuro)
        }
    }

    /// Raíz del repositorio a partir de este archivo fuente.
    private static let carpetaProyecto = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().path

    private static func guardar<V: View>(_ vista: V, nombre: String, en carpeta: String, oscuro: Bool) {
        let host = NSHostingView(rootView: vista)
        host.appearance = NSAppearance(named: oscuro ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let ventana = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        ventana.appearance = host.appearance
        ventana.contentView = host
        ventana.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = URL(fileURLWithPath: carpeta).appendingPathComponent(nombre + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        ventana.orderOut(nil)
    }
}

/// Estados del icono sobre una barra de menús, a 1x y ampliados.
private struct HojaIconos: View {
    private let estados: [(String, IconoBarra.Estado)] = [
        ("Sin conexión", .desconectado), ("Conectando", .conectando(0)), ("", .conectando(2)),
        ("", .conectando(4)), ("Conectada", .conectado), ("Atención", .atencion),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                ForEach(Array(estados.enumerated()), id: \.offset) { _, par in icono(par.1) }
                HStack(spacing: 3) { icono(.conectado); Text("2").monospacedDigit() }
            }
            .padding(.horizontal, 12).frame(height: 24)
            .background(.bar)
            HStack(alignment: .top, spacing: 20) {
                ForEach(Array(estados.enumerated()), id: \.offset) { _, par in
                    VStack(spacing: 6) {
                        icono(par.1).scaleEffect(4).frame(width: 72, height: 72)
                        Text(par.0).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .background(.background)
    }

    private func icono(_ estado: IconoBarra.Estado) -> some View {
        Image(nsImage: IconoBarra.imagen(estado))
            .renderingMode(estado.tieneColor ? .original : .template)
            .foregroundStyle(.primary)
    }
}

extension VPNModel {
    convenience init(muestra: Void) {
        self.init(sinArrancar: ())
        esMuestra = true
        func estado(_ id: String, _ nombre: String, conectada: Bool = false, ip: String = "", iface: String = "",
                    rutas: Int = 0, inicio: Date? = nil, configurada: Bool = true) -> VPNStatus {
            VPNStatus(id: id, name: nombre, connected: conectada, pid: conectada ? 1 : 0, ip: ip, iface: iface,
                      networks: Array(repeating: "10.0.0.0/8", count: rutas), enabled: true,
                      configured: configurada, helperReady: true, inicio: inicio)
        }
        vpns = [
            estado("oficina", "Oficina central", conectada: true, ip: "10.0.0.7", iface: "ppp0", rutas: 14,
                   inicio: Date().addingTimeInterval(-72 * 60)),
            estado("prepa", "Prepa · Sedes"),
            estado("norte", "Cliente Norte"),
            estado("lab", "Laboratorio"),
            estado("sur", "Sucursal Sur"),
        ]
        func perfil(_ id: String, _ nombre: String, _ servidor: String, _ usuario: String) -> VPNProfile {
            VPNProfile(id: id, name: nombre, server: servidor, username: usuario, trust: "system", realm: "",
                       manageRoutes: true, manageDNS: true, enabled: true)
        }
        profiles = [
            perfil("oficina", "Oficina central", "vpn.empresa.com:443", "usuario.demo"),
            perfil("prepa", "Prepa · Sedes", "acceso.prepa.example:10443", "cuenta.demo"),
            perfil("norte", "Cliente Norte", "remote.norte.example", "consultor02"),
            perfil("lab", "Laboratorio", "lab.example:8443", "invitado"),
            perfil("sur", "Sucursal Sur", "sur.example:443", "usuario.demo"),
        ]
        passwordStatuses = ["oficina": .saved, "prepa": .saved, "norte": .saved, "lab": .saved, "sur": .missing]
        estados = ["norte": .error(Fallo.interpretar("Could not authenticate to gateway"))]
        desconexiones = ["lab": Calendar.current.date(bySettingHour: 10, minute: 31, second: 0, of: Date()) ?? Date()]
    }
}
#endif
