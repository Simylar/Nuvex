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
        Diseno.vidrioDelSistema = false
        let modelo = VPNModel(muestra: ())
        let borradores = BorradoresAjustes()
        borradores.sincronizar(con: modelo.profiles)

        for oscuro in [false, true] {
            let sufijo = oscuro ? "oscuro" : "claro"
            guardar(PanelVPN(modelo: modelo).background(.background), nombre: "panel-\(sufijo)", en: carpeta, oscuro: oscuro)

            borradores.seleccion = .general
            guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 780, height: 580),
                    nombre: "ajustes-permisos-minimo-\(sufijo)", en: carpeta, oscuro: oscuro)
            guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 1180, height: 820),
                    nombre: "ajustes-permisos-amplio-\(sufijo)", en: carpeta, oscuro: oscuro)
            guardar(Form { SeccionPermisosNuvex(modelo: modelo, detalleExpandido: true, abrir: { _ in }) }
                .formularioNuvex().frame(width: 540, height: 1250),
                    nombre: "ajustes-permisos-detalle-\(sufijo)", en: carpeta, oscuro: oscuro)

            borradores.seleccion = .conexion("oficina")
            guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 820, height: 640),
                    nombre: "ajustes-conexion-\(sufijo)", en: carpeta, oscuro: oscuro)
            // Tamaño mínimo y ventana amplia: la composición debe sostenerse en ambos.
            guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 780, height: 580),
                    nombre: "ajustes-conexion-minimo-\(sufijo)", en: carpeta, oscuro: oscuro)
            guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 1180, height: 820),
                    nombre: "ajustes-conexion-amplio-\(sufijo)", en: carpeta, oscuro: oscuro)
            guardar(BienvenidaView(modelo: modelo, borrador: BorradorBienvenida(), cerrar: {}).background(.background),
                    nombre: "bienvenida-\(sufijo)", en: carpeta, oscuro: oscuro)
        }
        for oscuro in [false, true] {
            let sufijo = oscuro ? "oscuro" : "claro"
            let borrador = BorradorBienvenida()
            borrador.perfil.server = "vpn.empresa.example"
            borrador.perfil.username = "persona"
            borrador.password = "ficticia"
            borrador.perfil.trust = "sha256:" + String(repeating: "a", count: 64)
            guardar(BienvenidaView(modelo: modelo, borrador: borrador, cerrar: {})
                .frame(width: 520, height: 760),
                    nombre: "alta-avanzada-\(sufijo)", en: carpeta, oscuro: oscuro)
            borrador.error = "No se pudo guardar la contraseña. Desbloquea el Llavero y vuelve a guardar."
            guardar(BienvenidaView(modelo: modelo, borrador: borrador, cerrar: {})
                .frame(width: 520, height: 620),
                    nombre: "alta-error-\(sufijo)", en: carpeta, oscuro: oscuro)
            borrador.perfil = borrador.perfil.conNombreSugerido
            let modeloAlta = VPNModel(muestra: ())
            modeloAlta.profiles = [borrador.perfil]
            func estadoAlta(conectada: Bool, ayudante: Bool = true) -> VPNStatus {
                VPNStatus(id: borrador.perfil.id, name: "Oficina", connected: conectada, pid: conectada ? 1 : 0,
                          ip: "", iface: "", networks: [], enabled: true, configured: true, helperReady: ayudante)
            }
            modeloAlta.vpns = [estadoAlta(conectada: true)]
            borrador.paso = .guardada
            borrador.resumen = .init(conexiones: .hecho, contrasenas: .hecho, ayudante: .hecho)
            guardar(BienvenidaView(modelo: modeloAlta, borrador: borrador, cerrar: {}),
                    nombre: "alta-preparada-\(sufijo)", en: carpeta, oscuro: oscuro)
            modeloAlta.vpns = [estadoAlta(conectada: false, ayudante: false)]
            borrador.resumen?.ayudante = .fallo("Autorización cancelada")
            guardar(BienvenidaView(modelo: modeloAlta, borrador: borrador, cerrar: {}),
                    nombre: "alta-permiso-pendiente-\(sufijo)", en: carpeta, oscuro: oscuro)
            modeloAlta.vpns = [estadoAlta(conectada: false)]
            modeloAlta.estados[borrador.perfil.id] = .conectando
            guardar(BienvenidaView(modelo: modeloAlta, borrador: borrador, cerrar: {}),
                    nombre: "alta-conectando-\(sufijo)", en: carpeta, oscuro: oscuro)
            modeloAlta.estados[borrador.perfil.id] = .error(Fallo.interpretar("Could not authenticate to gateway"))
            guardar(BienvenidaView(modelo: modeloAlta, borrador: borrador, cerrar: {}),
                    nombre: "alta-autenticacion-\(sufijo)", en: carpeta, oscuro: oscuro)
            let sinEstado = VPNModel(muestra: ())
            sinEstado.errorConsulta = "Fallo simulado"
            guardar(PanelVPN(modelo: sinEstado).background(.background),
                    nombre: "panel-estado-desconocido-\(sufijo)", en: carpeta, oscuro: oscuro)
            guardar(FilaVPN(vpn: modelo.vpns[1], estado: .conectando, passwordStatus: .saved, caidaEn: nil,
                            esperandoCodigo: true, atajo: 1, bloqueada: false,
                            alAlternar: {}, alConfigurar: {}, alDescartar: {})
                .frame(width: Tamano.panel).background(.background),
                    nombre: "fila-codigo-\(sufijo)", en: carpeta, oscuro: oscuro)
            guardar(AjustesCuentaGoogle().frame(width: 540, height: 640),
                    nombre: "google-primer-uso-\(sufijo)", en: carpeta, oscuro: oscuro)
        }
        let modeloAtencion = VPNModel(muestra: ())
        modeloAtencion.usarActualizacionesDeMuestra(Actualizaciones(
            muestra: .error("La última actualización no se completó."),
            puedeBuscar: true, requiereAtencion: true))
        guardar(PanelVPN(modelo: modeloAtencion).background(.background),
                nombre: "panel-actualizacion-atencion", en: carpeta, oscuro: false)
        borradores.seleccion = .general
        guardar(ConfigurationView(modelo: modeloAtencion, borradores: borradores)
            .frame(width: 820, height: 640),
                nombre: "ajustes-actualizacion-atencion", en: carpeta, oscuro: false)
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
        for oscuro in [false, true] {
            guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 900, height: 1080),
                    nombre: "ajustes-automatizacion-completo-\(oscuro ? "oscuro" : "claro")",
                    en: carpeta, oscuro: oscuro)
        }
        borradores.seleccion = .cuentaGoogle
        guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 820, height: 640),
                nombre: "ajustes-cuenta-google-claro", en: carpeta, oscuro: false)
        for oscuro in [false, true] {
            for (ancho, alto) in [(CGFloat(780), CGFloat(580)), (CGFloat(1180), CGFloat(820))] {
                guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: ancho, height: alto),
                        nombre: "ajustes-cuenta-google-\(Int(ancho))-\(oscuro ? "oscuro" : "claro")",
                        en: carpeta, oscuro: oscuro)
            }
        }
        capturarPapelera(en: carpeta)
        capturarEditorCorreo(en: carpeta)
        borradores.seleccion = .ayudante
        guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 820, height: 640),
                nombre: "ajustes-ayudante-claro", en: carpeta, oscuro: false)
        let notas = """
        ### Mejoras
        - Instalación más clara y confiable.
        - Diagnósticos útiles sin mostrar información sensible.

        ### Seguridad
        - Verificación obligatoria de la firma antes de instalar.
        """
        let instalada = InfoVersion(corta: "3.1.2", compilacion: 130,
                                    canal: "publicada", commit: "90c7bca")
        let version = VersionDisponible(version: "3.2.0", compilacion: "140", tamano: 12_400_000,
                                        fecha: Date(), notas: notas)
        let estados: [(String, EstadoActualizacion)] = [
            ("aldia", .alDia),
            ("buscando", .buscando),
            ("disponible", .disponible(version)),
            ("descargando", .descargando(version, recibido: 5_100_000, total: 12_400_000)),
            ("preparando", .preparando(version, progreso: 0.72)),
            ("lista", .lista(version)),
            ("programada", .programada(version)),
            ("esperando", .esperando(version, detalle: "Esperando a que termine de guardarse la configuración…")),
            ("instalando", .instalando(version)),
            ("error", .error("La actualización no superó la verificación de seguridad y no se instaló. Inténtalo de nuevo más tarde.")),
        ]
        for (nombre, estado) in estados {
            guardar(ActualizacionSoftwareView(actualizaciones: Actualizaciones(muestra: estado),
                                              instalada: instalada).frame(width: 520, height: 640),
                    nombre: "actualizacion-\(nombre)", en: carpeta, oscuro: false)
        }
        let instaladaActualizada = InfoVersion(corta: version.version, compilacion: 140,
                                               canal: "publicada", commit: "d4e5f6a")
        let registroInstalacion = InstalacionActualizacionPendiente(
            versionOrigen: instalada.corta, compilacionOrigen: instalada.compilacion,
            versionEsperada: version.version,
            compilacionEsperada: instaladaActualizada.compilacion, iniciada: Date())
        let verificada = ResultadoInstalacionActualizacion.verificada(registroInstalacion)
        guardar(ActualizacionSoftwareView(
            actualizaciones: Actualizaciones(muestra: .alDia, verificacionInicial: verificada),
            instalada: instaladaActualizada).frame(width: 520, height: 640),
                nombre: "actualizacion-instalacion-verificada", en: carpeta, oscuro: false)
        let incompleta = ResultadoInstalacionActualizacion.incompleta(
            registroInstalacion, instalada: instalada)
        guardar(ActualizacionSoftwareView(
            actualizaciones: Actualizaciones(muestra: .error(incompleta.mensaje),
                                              verificacionInicial: incompleta),
            instalada: instalada).frame(width: 520, height: 640),
                nombre: "actualizacion-instalacion-incompleta", en: carpeta, oscuro: false)
        guardar(ActualizacionSoftwareView(
            actualizaciones: Actualizaciones(muestra: .disponible(version),
                                              verificacionInicial: incompleta),
            instalada: instalada).frame(width: 520, height: 640),
                nombre: "actualizacion-incompleta-con-version", en: carpeta, oscuro: false)
        let errorConfiguracion = "La configuración de actualizaciones no es válida. Instala nuevamente la versión publicada de Nuvex."
        guardar(ActualizacionSoftwareView(
            actualizaciones: Actualizaciones(muestra: .error(errorConfiguracion),
                                              puedeBuscar: false),
            instalada: instalada).frame(width: 520, height: 640),
                nombre: "actualizacion-error-sin-busqueda", en: carpeta, oscuro: false)
        guardar(ActualizacionSoftwareView(actualizaciones: Actualizaciones(muestra: .disponible(version)),
                                          instalada: instalada).frame(width: 520, height: 640),
                nombre: "actualizacion-disponible-oscuro", en: carpeta, oscuro: true)
        guardar(NovedadesView(version: "3.2.0", notas: notas, cerrar: {}), nombre: "novedades", en: carpeta, oscuro: false)
        guardar(PanelCodigoView(solicitud: .muestra(nombre: "Oficina central",
                                                    correo: .buscando(desde: Date().addingTimeInterval(-12), cuenta: "persona@example.com"))),
                nombre: "codigo-buscando", en: carpeta, oscuro: false)
        guardar(PanelCodigoView(solicitud: .muestra(nombre: "Oficina central", codigo: "482913",
                                                    correo: .encontrado(remitente: "noreply@empresa.com"), automatico: true)),
                nombre: "codigo-recibido-oscuro", en: carpeta, oscuro: true)
        guardar(PanelCodigoView(solicitud: .muestra(nombre: "Oficina central",
                                                    correo: .buscando(desde: Date().addingTimeInterval(-40), cuenta: "persona@example.com",
                                                                      aviso: .sinRed))),
                nombre: "codigo-sin-red", en: carpeta, oscuro: false)
        guardar(PanelCodigoView(solicitud: .muestra(nombre: "Oficina central", correo: .problema(.apiDesactivada))),
                nombre: "codigo-api-desactivada", en: carpeta, oscuro: false)
        guardar(PanelCodigoView(solicitud: .muestra(nombre: "Oficina central", correo: .problema(.sesionCaducada))),
                nombre: "codigo-sesion-caducada-oscuro", en: carpeta, oscuro: true)
        modelo.resumenGuardado = ResumenGuardado(conexiones: .hecho, contrasenas: .hecho,
                                                 ayudante: .fallo("No se pudo instalar el ayudante: se canceló la autorización de macOS. Nuvex volverá a pedirlo al conectar."))
        guardar(ListaResumenGuardado(modelo: modelo, resumen: modelo.resumenGuardado!).padding(16).frame(width: 380).background(.background),
                nombre: "guardado-resumen", en: carpeta, oscuro: false)
        borradores.seleccion = .conexion("oficina")
        guardar(ConfigurationView(modelo: modelo, borradores: borradores).frame(width: 820, height: 640),
                nombre: "ajustes-guardado-pendiente", en: carpeta, oscuro: false)
        modelo.resumenGuardado = nil
        guardar(VistaExportar(modelo: modelo, cerrar: {}, seleccion: Set(modelo.profiles.prefix(3).map(\.id))),
                nombre: "exportar-claro", en: carpeta, oscuro: false)
        for oscuro in [false, true] {
            guardar(HojaIconos(), nombre: "iconos-barra-\(oscuro ? "oscuro" : "claro")", en: carpeta, oscuro: oscuro)
            guardar(GuiaEstiloView(desplazable: false), nombre: "guia-estilo-\(oscuro ? "oscuro" : "claro")",
                    en: carpeta, oscuro: oscuro)
        }
    }

    private static func capturarPapelera(en carpeta: String) {
        let temporal = FileManager.default.temporaryDirectory.appendingPathComponent("nuvex-papelera-muestra-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporal) }
        let preferencias = Preferencias(url: temporal.appendingPathComponent("ajustes.json"))
        let datos = Data(#"{"clienteID":"muestra.apps.googleusercontent.com","secreto":"ficticio","tokenRenovacion":"ficticio","correo":"persona@example.com","permisos":["https://www.googleapis.com/auth/gmail.modify"]}"#.utf8)
        let cuenta = CuentaGoogle(lectorLlavero: { _ in (datos, 0) },
            escritorLlavero: { _ in false }, borradorLlavero: { false },
            pedirTokens: { _ in throw ErrorGoogle.respuesta("invalid_grant") })
        for activar in [false, true] {
            preferencias.modificar { $0.enviarCorreoPapelera = activar }
            for oscuro in [false, true] {
                for (ancho, alto) in [(CGFloat(540), CGFloat(580)), (CGFloat(880), CGFloat(820))] {
                    guardar(AjustesCuentaGoogle(cuenta: cuenta, preferencias: preferencias)
                        .frame(width: ancho, height: alto),
                        nombre: "google-papelera-\(activar ? "activa" : "inactiva")-\(Int(ancho))-\(oscuro ? "oscuro" : "claro")",
                        en: carpeta, oscuro: oscuro)
                }
            }
        }
        let soloLectura = CuentaGoogle(lectorLlavero: { _ in
            (Data(#"{"clienteID":"muestra.apps.googleusercontent.com","secreto":"ficticio","tokenRenovacion":"ficticio","correo":"persona@example.com"}"#.utf8), 0)
        }, escritorLlavero: { _ in false }, borradorLlavero: { false })
        for oscuro in [false, true] {
            guardar(AjustesCuentaGoogle(cuenta: soloLectura, preferencias: preferencias)
                .frame(width: 540, height: 580),
                nombre: "google-papelera-permiso-pendiente-\(oscuro ? "oscuro" : "claro")", en: carpeta, oscuro: oscuro)
        }
        var caducidadComprobada = false
        Task {
            _ = try? await cuenta.tokenAcceso() // Renovación ficticia: no contacta Google.
            caducidadComprobada = true
        }
        let limite = Date().addingTimeInterval(5)
        while !caducidadComprobada && Date() < limite {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(caducidadComprobada)
        for oscuro in [false, true] {
            guardar(AjustesCuentaGoogle(cuenta: cuenta, preferencias: preferencias)
                .frame(width: 540, height: 580),
                nombre: "google-papelera-sesion-caducada-\(oscuro ? "oscuro" : "claro")", en: carpeta, oscuro: oscuro)
        }
    }

    private static func capturarEditorCorreo(en carpeta: String) {
        let temporal = FileManager.default.temporaryDirectory.appendingPathComponent("nuvex-editor-correo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporal) }
        let datos = Data(#"{"clienteID":"muestra.apps.googleusercontent.com","secreto":"ficticio","tokenRenovacion":"ficticio","correo":"persona@example.com"}"#.utf8)
        let cuenta = CuentaGoogle(lectorLlavero: { _ in (datos, 0) },
            escritorLlavero: { _ in false }, borradorLlavero: { false },
            pedirTokens: { _ in throw ErrorGoogle.sinSesion })
        for caso in ["guardada", "nueva", "solo-lectura"] {
            let url = temporal.appendingPathComponent("\(caso)/ajustes.json")
            let preferencias = Preferencias(url: url)
            if caso != "nueva" { preferencias.modificar { $0.correo["muestra"] = .fortinet } }
            if caso == "solo-lectura" {
                guard let datos = try? Data(contentsOf: url),
                      var json = try? JSONSerialization.jsonObject(with: datos) as? [String: Any] else {
                    preconditionFailure("no se prepararon los ajustes ficticios")
                }
                json["version"] = 999
                try! JSONSerialization.data(withJSONObject: json).write(to: url)
                preferencias.cargar()
            }
            for oscuro in [false, true] {
                guardar(Form {
                    SeccionCodigoCorreo(perfilID: "muestra", perfilGuardado: caso != "nueva",
                        preferencias: preferencias, cuenta: cuenta)
                }.formularioNuvex().frame(width: 540, height: 580),
                    nombre: "editor-correo-\(caso)-\(oscuro ? "oscuro" : "claro")", en: carpeta, oscuro: oscuro)
            }
        }
    }

    private static func guardar<V: View>(_ vista: V, nombre: String, en carpeta: String, oscuro: Bool) {
        // Como una ventana activa: los controles con tinte, las barras de
        // progreso y la selección se dibujan como en uso, no atenuados. No se
        // activa la app de verdad para no quitar el foco a quien la ejecuta.
        let host = NSHostingView(rootView: vista.environment(\.controlActiveState, .key).id(nombre))
        host.appearance = NSAppearance(named: oscuro ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let ventana = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        ventana.appearance = host.appearance
        ventana.contentView = host
        ventana.orderFrontRegardless()
        ventana.makeFirstResponder(nil)
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
        confirmarConfiguracionDeMuestra()
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
        estados = ["norte": .error(Fallo.interpretar("Could not authenticate to gateway")), "prepa": .conectando]
        inicioConexion = ["prepa": Date().addingTimeInterval(-14)]
        desconexiones = ["lab": Calendar.current.date(bySettingHour: 10, minute: 31, second: 0, of: Date()) ?? Date()]
    }
}
#endif
