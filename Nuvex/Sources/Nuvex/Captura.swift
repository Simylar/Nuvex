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
        borradores.seleccion = .ayudante
        guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 820, height: 640),
                nombre: "ajustes-ayudante-claro", en: carpeta, oscuro: false)
        guardar(BienvenidaView(modelo: modelo, cerrar: {}).background(.background),
                nombre: "bienvenida-claro", en: carpeta, oscuro: false)
        for estado in [IconoBarra.Estado.desconectado, .conectando, .conectado, .atencion] {
            guardar(Image(nsImage: IconoBarra.imagen(estado)).padding(4).background(.background),
                    nombre: "icono-\(estado)", en: carpeta, oscuro: false)
        }
    }

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
