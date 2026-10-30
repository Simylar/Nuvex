import AppKit
import SwiftUI

extension AutorizacionCapacidades {
    static let shared = AutorizacionCapacidades(
        preferencias: .shared,
        confirmar: { try await VPNModel.confirmarUsoInicial(razon: "Autorizar las capacidades habituales de Nuvex") },
        preparar: { try IntegracionAsistentes.configurar() },
        revocarConfirmacion: { ConfirmacionInicial.shared.revocar() },
        retirarReglas: {
            var pendientes: [String] = []
            for destino in IntegracionAsistentes.destinos {
                do { try IntegracionAsistentes.revocar(destino) }
                catch { pendientes.append(destino.nombre) }
            }
            return pendientes
        })
}

/// Resumen en General; los editores existentes conservan las acciones de cada
/// servicio. Consultar el estado no solicita autorizaciones ni conecta VPN.
struct SeccionPermisosNuvex: View {
    @ObservedObject var modelo: VPNModel
    let abrir: (PaginaAjustes) -> Void
    @ObservedObject private var preferencias = Preferencias.shared
    @ObservedObject private var cuenta = CuentaGoogle.shared
    @ObservedObject private var autorizacion = AutorizacionCapacidades.shared
    @AppStorage(SecurityPreferences.authorizedKey) private var usoAutorizado = false
    @AppStorage(SecurityPreferences.confirmationKey) private var confirmar = true
    @State private var confirmarAutorizacion = false
    @State private var confirmarRevocacion = false
    @State private var comprobandoContrasenas = false
    @State private var mensaje: String?
    @State private var accesos: [String: AccesoLlavero] = [:]
    @State private var agentes: [String: Bool] = [:]
    @State private var comandoListo = false
    @State private var integracionesComprobadas = false
    @State private var detalleExpandido: Bool
    @State private var revisionComprobacion = UUID()
    @State private var comprobandoEstado = true

    init(modelo: VPNModel, detalleExpandido: Bool = false, abrir: @escaping (PaginaAjustes) -> Void) {
        self.modelo = modelo
        self.abrir = abrir
        _detalleExpandido = State(initialValue: detalleExpandido)
    }

    private var completa: Bool {
        preferencias.ajustes.autorizacionGlobalCompleta && (!confirmar || usoAutorizado)
            && integracionesComprobadas && comandoListo
            && agentes.values.allSatisfy { $0 }
    }

    private var trabajando: Bool { comprobandoContrasenas || autorizacion.trabajando }

    private var pendientes: [PendienteCapacidad] {
        EstadoCapacidades(perfiles: modelo.profiles, ayudanteListo: modelo.ayudanteListo,
            contrasenas: modelo.passwordStatuses, accesos: accesos, correo: preferencias.ajustes.correo,
            problemaCuenta: cuenta.problemaParaLeerCorreo, confirmacionPendiente: confirmar && !usoAutorizado,
            automatizacionSolicitada: preferencias.ajustes.politicaAsistentes != .noPermitir
                && (preferencias.ajustes.politicaAsistentes == .permitir || comandoListo),
            comandoListo: integracionesComprobadas ? comandoListo : nil, agentes: agentes).pendientes
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Espacio.xs) {
                if comprobandoEstado {
                    HStack(spacing: Espacio.s) { ProgressView().controlSize(.small); Text("Comprobando capacidades…") }
                } else {
                    Text(pendientes.isEmpty ? "Sin acciones pendientes detectadas"
                         : pendientes.count == 1 ? "Una acción pendiente" : "\(pendientes.count) acciones pendientes")
                        .font(Tipo.cuerpoEnfasis)
                    Text(modelo.profiles.isEmpty ? "Añade una conexión para revisar las funciones que utilizarás."
                         : pendientes.isEmpty ? "Los permisos y servicios externos se vuelven a comprobar al usarlos."
                         : "Cada acción indica qué función necesita tu atención.")
                        .font(Tipo.apoyo).foregroundStyle(Paleta.textoSecundario)
                }
            }
            if trabajando {
                HStack(spacing: Espacio.s) {
                    ProgressView().controlSize(.small)
                    Text(comprobandoContrasenas ? "Comprobando acceso…" : "Actualizando autorizaciones…")
                }
            }
            if let mensaje {
                Text(mensaje).foregroundStyle(Paleta.avisoTexto).textSelection(.enabled)
            }
            if !comprobandoEstado {
                ForEach(pendientes.prefix(detalleExpandido ? pendientes.count : 3)) { pendiente in
                    LabeledContent {
                        Button(pendiente.accion) { resolver(pendiente.destino) }
                            .disabled(trabajando)
                            .accessibilityLabel("\(pendiente.accion) \(pendiente.funcion)")
                    } label: {
                        VStack(alignment: .leading, spacing: Espacio.xxs) {
                            Text(pendiente.funcion).font(Tipo.cuerpoEnfasis)
                            Text(pendiente.detalle).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if pendientes.count > 3 && !detalleExpandido {
                    Button("Ver todas las capacidades y las demás acciones…") { detalleExpandido = true }
                        .buttonStyle(.link)
                }
            }
            DisclosureGroup("Todas las capacidades y autorización conjunta", isExpanded: $detalleExpandido) {
                VStack(alignment: .leading, spacing: Espacio.m) {
                    Text(estadoGlobal).font(Tipo.cuerpoEnfasis)
                    Text("Autoriza el uso habitual de contraseñas y permite conectar y desconectar desde la Terminal y los asistentes sin confirmar cada operación. Configura el comando y los agentes detectados; conserva las conexiones excluidas en Automatización.")
                        .foregroundStyle(Paleta.textoSecundario)
                    HStack {
                        Button("Autorizar todas las capacidades de Nuvex…") { confirmarAutorizacion = true }
                            .estiloBoton(.secundario)
                            .disabled(autorizacion.trabajando)
                        Button("Revocar…", role: .destructive) { confirmarRevocacion = true }
                            .estiloBoton(.destructivo)
                    }
                    .disabled(comprobandoContrasenas || preferencias.soloLectura != nil)
                    if let aviso = preferencias.soloLectura {
                        Text(aviso).foregroundStyle(Paleta.avisoTexto)
                    }
                    if let resultado = autorizacion.mensaje {
                        Text(resultado).foregroundStyle(Paleta.avisoTexto).textSelection(.enabled)
                    }
                }
                LabeledContent("Confirmación inicial", value: confirmar ? (usoAutorizado ? "Sin confirmación pendiente" : "Pendiente") : "Desactivada por ti")
                Toggle("Confirmar con Touch ID la primera vez", isOn: $confirmar)
                LabeledContent {
                    Button("Revisar…") { abrir(.automatizacion) }
                } label: {
                    VStack(alignment: .leading, spacing: Espacio.xxs) {
                        Text("Terminal y asistentes")
                        Text(estadoAsistentes).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                    }
                }
                ForEach(IntegracionAsistentes.destinos) { destino in
                    if let listo = agentes[destino.id] {
                        LabeledContent(destino.nombre, value: listo ? "Integración configurada" : "Revisar en Automatización")
                    }
                }
                LabeledContent {
                    Button("Revisar…") { abrir(.ayudante) }
                } label: {
                    VStack(alignment: .leading, spacing: Espacio.xxs) {
                        Text("Ayudante de red")
                        Text(estadoAyudante).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                    }
                }
                LabeledContent {
                    Button("Revisar cuenta…") { abrir(.cuentaGoogle) }
                } label: {
                    VStack(alignment: .leading, spacing: Espacio.xxs) {
                        Text("Códigos desde Gmail")
                        Text(estadoGoogle).font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                    }
                }
                ForEach(modelo.profiles) { perfil in
                    LabeledContent {
                        Button("Revisar…") { abrir(.conexion(perfil.id)) }
                    } label: {
                        VStack(alignment: .leading, spacing: Espacio.xxs) {
                            Text("Contraseña de \(perfil.name)")
                            Text(accesos[perfil.id]?.descripcion ?? "Sin comprobar")
                                .font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
                        }
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { accionesComprobacion }.fixedSize()
                    VStack(alignment: .leading, spacing: Espacio.s) { accionesComprobacion }
                }
                .disabled(trabajando)
                Text("El acceso al Llavero se comprueba por contraseña y puede cambiar al bloquearlo. «Comprobar acceso» puede mostrar diálogos de macOS. Si ofrece «Permitir siempre», elige esa opción para conservar el acceso de esta copia firmada de Nuvex.")
                    .font(Tipo.nota).foregroundStyle(Paleta.textoSecundario)
            }
        } header: {
            Text("Permisos y capacidades")
        } footer: {
            Text("La decisión se conserva al volver a abrir, reiniciar y actualizar. Las capacidades nuevas requieren otra decisión. macOS administra el Llavero, el ayudante, los avisos y el inicio de sesión; Google administra Gmail. Revocar aquí bloquea la automatización y restablece la confirmación inicial; los permisos externos se revocan en su servicio.")
                .foregroundStyle(Paleta.textoSecundario)
        }
        .confirmationDialog("¿Autorizar las capacidades actuales de Nuvex?", isPresented: $confirmarAutorizacion) {
            Button("Autorizar") { autorizar() }
        } message: {
            Text("La Terminal y los asistentes podrán conectar y desconectar las VPN permitidas sin volver a preguntar. Se prepararán sus integraciones acotadas. No se exportan contraseñas ni se conceden permisos de macOS o Google. Las capacidades futuras no quedan autorizadas.")
        }
        .confirmationDialog("¿Revocar las capacidades de Nuvex?", isPresented: $confirmarRevocacion) {
            Button("Revocar", role: .destructive) { revocar() }
        } message: {
            Text("Se bloquearán las operaciones de la Terminal y asistentes, se retirarán las reglas de agentes gestionadas y volverá a pedirse la confirmación inicial. Las VPN activas seguirán conectadas. Las contraseñas y los permisos de macOS y Google se conservan.")
        }
        .task { await refrescar() }
        .onChange(of: autorizacion.trabajando) { _, trabajando in
            if !trabajando { Task { await refrescar() } }
        }
        .onChange(of: modelo.profiles) { _, _ in
            accesos = [:]
            Task { await refrescar() }
        }
        .onChange(of: modelo.passwordStatuses) { _, _ in
            accesos = [:]
            Task { await refrescar() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refrescar() }
        }
    }

    @ViewBuilder
    private var accionesComprobacion: some View {
        Button("Comprobar sin solicitar permisos") { Task { await refrescar() } }
            .fixedSize()
        Button("Comprobar acceso a contraseñas…") { comprobarContrasenas() }
            .fixedSize()
            .disabled(modelo.profiles.isEmpty)
    }

    private var estadoGlobal: String {
        if preferencias.ajustes.autorizacionRevocada {
            return preferencias.ajustes.politicaAsistentes == .noPermitir
                ? "Autorización conjunta revocada · automatización bloqueada"
                : "Autorización conjunta revocada · revisa los permisos individuales de automatización"
        }
        if completa { return "Capacidades internas autorizadas · revisa los permisos externos debajo" }
        if !preferencias.ajustes.capacidadesAutorizadas.isEmpty { return "Autorización interna parcial · revisa el estado" }
        return "Sin autorización conjunta · se conservan tus decisiones individuales"
    }

    private var estadoAsistentes: String {
        switch preferencias.ajustes.politicaAsistentes {
        case .noPermitir: return "No permitido"
        case .preguntar: return "Pide confirmación por operación"
        case .permitir: return "Sin preguntar · \(preferencias.ajustes.bloqueadasParaAsistentes.count) conexiones excluidas"
        }
    }

    private var estadoAyudante: String {
        if modelo.profiles.isEmpty { return "No se necesita hasta añadir una conexión" }
        switch modelo.ayudanteListo {
        case true?: return "Instalado y vigente"
        case false?: return "No está vigente; revisa la instalación o configuración"
        case nil: return "Sin comprobar; un fallo de estado no demuestra falta de autorización"
        }
    }

    private var estadoGoogle: String {
        switch cuenta.estado {
        case .sinCliente: return "Opcional · falta configurar el cliente OAuth"
        case .llaveroNoDisponible: return "No se pudo leer la cuenta guardada; recupera el acceso al Llavero"
        case .desconectada: return "Sin sesión; inicia sesión con Google"
        case .esperandoNavegador: return "Completa el inicio de sesión en el navegador"
        case .caducada: return "Sesión vencida o revocada; vuelve a iniciar sesión"
        case .conectada: return "Sesión guardada; el permiso y el servicio se verifican al leer Gmail"
        }
    }

    private func refrescar() async {
        #if DEBUG
        if modelo.esMuestra {
            accesos = Dictionary(uniqueKeysWithValues: modelo.profiles.map { ($0.id, .disponible) })
            comandoListo = true
            agentes = ["codex": true, "claude": true]
            integracionesComprobadas = true
            comprobandoEstado = false
            return
        }
        #endif
        let revision = UUID()
        revisionComprobacion = revision
        comprobandoEstado = true
        comandoListo = IntegracionAsistentes.estadoComando() == .instalado
        agentes = Dictionary(uniqueKeysWithValues: IntegracionAsistentes.destinos.compactMap { destino in
            guard IntegracionAsistentes.estado(destino) != .sinHerramienta else { return nil }
            return (destino.id, IntegracionAsistentes.estado(destino) == .instalada
                && IntegracionAsistentes.estadoAutorizacion(destino) == .instalada)
        })
        integracionesComprobadas = true
        let perfiles = modelo.profiles
        let contrasenas = modelo.passwordStatuses
        let comprobados = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: perfiles.map { perfil in
                (perfil.id, AccesoLlavero.comprobar(servicio: "nuvex.\(perfil.id)", cuenta: perfil.username))
            })
        }.value
        guard revisionComprobacion == revision, perfiles == modelo.profiles,
              contrasenas == modelo.passwordStatuses else { return }
        accesos = comprobados
        modelo.chequeo?.confirmarAccesosLlavero(perfiles: perfiles,
            accesos: comprobados, configuracionCargada: modelo.configuracionCargada)
        comprobandoEstado = false
    }

    private func autorizar() {
        mensaje = nil
        Task {
            await autorizacion.autorizar()
            await refrescar()
        }
    }

    private func revocar() {
        mensaje = nil
        autorizacion.revocar()
        Task { await refrescar() }
    }

    private func comprobarContrasenas(id: String? = nil) {
        comprobandoContrasenas = true
        mensaje = nil
        let perfiles = modelo.profiles.filter {
            (id == nil || $0.id == id) && !$0.username.isEmpty && modelo.passwordStatuses[$0.id] != .missing
        }
        Task {
            defer { comprobandoContrasenas = false }
            do {
                for perfil in perfiles {
                    _ = try await VPNModel.leerDelLlavero(id: perfil.id, name: perfil.name,
                        reason: "Comprobar el acceso de Nuvex a las contraseñas guardadas")
                }
                mensaje = perfiles.isEmpty ? "No hay contraseñas guardadas comprobables en los perfiles actuales."
                    : id == nil ? "Se pudieron leer todas las contraseñas guardadas ahora." : "Se pudo leer la contraseña ahora."
            } catch { mensaje = error.localizedDescription }
            await refrescar()
        }
    }

    private func resolver(_ destino: PendienteCapacidad.Destino) {
        switch destino {
        case .conexion(let id): abrir(.conexion(id))
        case .ayudante: abrir(.ayudante)
        case .cuentaGoogle: abrir(.cuentaGoogle)
        case .automatizacion: abrir(.automatizacion)
        case .contrasenas(let id): comprobarContrasenas(id: id)
        case .confirmacionInicial:
            comprobandoContrasenas = true
            mensaje = nil
            Task {
                defer { comprobandoContrasenas = false }
                do { try await VPNModel.confirmarUsoInicial(razon: "Confirmar el uso de las contraseñas guardadas en Nuvex") }
                catch { mensaje = error.localizedDescription; detalleExpandido = true }
                await refrescar()
            }
        }
    }
}
