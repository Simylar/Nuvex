import Foundation
import Security

private actor AutenticacionSimulada {
    private(set) var llamadas = 0
    private var pendiente: CheckedContinuation<Void, Error>?

    func autenticar() async throws {
        llamadas += 1
        try await withCheckedThrowingContinuation { pendiente = $0 }
    }

    func resolver() { pendiente?.resume(); pendiente = nil }
}

@MainActor
private final class RenovacionSimulada {
    private(set) var llamadas = 0
    private var pendiente: CheckedContinuation<[String: Any], Error>?

    func pedir() async throws -> [String: Any] {
        llamadas += 1
        return try await withCheckedThrowingContinuation { pendiente = $0 }
    }

    func resolver(_ respuesta: Result<[String: Any], Error>) {
        pendiente?.resume(with: respuesta)
        pendiente = nil
    }
}

@main
struct SecurityPreferencesChecks {
    private static func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "NuvexTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @MainActor
    static func main() async throws {
        withDefaults { defaults in
            defaults.set(false, forKey: "confirmarConexion.sicert")
            defaults.set(false, forKey: "confirmarConexion.prepa")
            SecurityPreferences.migrate(defaults: defaults, existingHelper: false)
            precondition(defaults.bool(forKey: SecurityPreferences.confirmationKey) == false)
            precondition(defaults.object(forKey: "confirmarConexion.sicert") == nil)
            precondition(defaults.object(forKey: "confirmarConexion.prepa") == nil)
        }
        withDefaults { defaults in
            defaults.set(false, forKey: "confirmarConexion.sicert")
            defaults.set(true, forKey: "confirmarConexion.prepa")
            SecurityPreferences.migrate(defaults: defaults, existingHelper: false)
            precondition(defaults.bool(forKey: SecurityPreferences.confirmationKey))
        }
        withDefaults { defaults in
            defaults.set(false, forKey: SecurityPreferences.confirmationKey)
            defaults.set(true, forKey: "confirmarConexion.sicert")
            SecurityPreferences.migrate(defaults: defaults, existingHelper: false)
            precondition(defaults.bool(forKey: SecurityPreferences.confirmationKey) == false)
            precondition(defaults.object(forKey: "confirmarConexion.sicert") == nil)
        }
        withDefaults { defaults in
            SecurityPreferences.migrate(defaults: defaults, existingHelper: true)
            precondition(SecurityPreferences.needsInitialConfirmation(defaults: defaults) == false)
        }
        withDefaults { defaults in
            SecurityPreferences.migrate(defaults: defaults, existingHelper: false)
            precondition(SecurityPreferences.needsInitialConfirmation(defaults: defaults))
            SecurityPreferences.markInitialUseAuthorized(defaults: defaults)
            precondition(SecurityPreferences.needsInitialConfirmation(defaults: defaults) == false)
        }
        let nombre = "NuvexTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: nombre)!
        defer { defaults.removePersistentDomain(forName: nombre) }
        let confirmacion = ConfirmacionInicial(defaults: defaults)
        let autenticacion = AutenticacionSimulada()
        let primera = Task { try await confirmacion.confirmar { try await autenticacion.autenticar() } }
        while await autenticacion.llamadas == 0 { await Task.yield() }
        let segunda = Task { try await confirmacion.confirmar { try await autenticacion.autenticar() } }
        for _ in 0..<20 { await Task.yield() }
        await autenticacion.resolver()
        try await primera.value
        try await segunda.value
        let llamadas = await autenticacion.llamadas
        precondition(llamadas == 1, "dos conexiones comparten una sola confirmación")
        precondition(!SecurityPreferences.needsInitialConfirmation(defaults: defaults))

        let reabierta = ConfirmacionInicial(defaults: UserDefaults(suiteName: nombre)!)
        try await reabierta.confirmar { preconditionFailure("no debe autenticar al reabrir") }

        confirmacion.revocar()
        precondition(SecurityPreferences.needsInitialConfirmation(defaults: defaults))
        SecurityPreferences.migrate(defaults: defaults, existingHelper: true)
        precondition(SecurityPreferences.needsInitialConfirmation(defaults: defaults), "la migración no deshace una revocación")
        do {
            try await confirmacion.confirmar { throw CancellationError() }
            preconditionFailure("se esperaba cancelación")
        } catch is CancellationError {}
        precondition(SecurityPreferences.needsInitialConfirmation(defaults: defaults))

        let tardia = AutenticacionSimulada()
        let pendiente = Task { try await confirmacion.confirmar { try await tardia.autenticar() } }
        while await tardia.llamadas == 0 { await Task.yield() }
        confirmacion.revocar()
        await tardia.resolver()
        do { try await pendiente.value; preconditionFailure("no debe restaurar una decisión revocada") }
        catch is CancellationError {}
        precondition(SecurityPreferences.needsInitialConfirmation(defaults: defaults))
        try await confirmacion.confirmar { }
        precondition(!SecurityPreferences.needsInitialConfirmation(defaults: defaults))

        precondition(AccesoLlavero(codigo: errSecSuccess) == .disponible)
        precondition(AccesoLlavero(codigo: errSecItemNotFound) == .ausente)
        precondition(AccesoLlavero(codigo: errSecInteractionNotAllowed) == .requiereInteraccion)
        precondition(AccesoLlavero(codigo: errSecAuthFailed) == .requiereInteraccion)
        precondition(AccesoLlavero(codigo: errSecUserCanceled) == .cancelado)
        precondition(AccesoLlavero(codigo: errSecNotAvailable) == .fallo(errSecNotAvailable))
        var lecturas: [Bool] = []
        let cuenta = CuentaGoogle(lectorLlavero: { interactivo in
            lecturas.append(interactivo)
            if !interactivo { return (nil, errSecInteractionNotAllowed) }
            return (Data(#"{"clienteID":"prueba.apps.googleusercontent.com","secreto":"ficticio","tokenRenovacion":"ficticio","correo":"prueba@example.invalid"}"#.utf8), errSecSuccess)
        }, escritorLlavero: { _ in false }, borradorLlavero: { false })
        precondition(lecturas == [false], "el arranque no solicita interacción")
        precondition(cuenta.estado == .llaveroNoDisponible(errSecInteractionNotAllowed))
        precondition(cuenta.problemaParaLeerCorreo == .llaveroNoDisponible)
        precondition(!cuenta.guardarCliente(id: "otro.apps.googleusercontent.com", secreto: "ficticio"),
                     "una lectura bloqueada no permite reemplazar la cuenta guardada")
        do { _ = try await cuenta.tokenAcceso(); preconditionFailure("no debe contactar a Google") }
        catch let fallo as ProblemaGmail { precondition(fallo == .llaveroNoDisponible) }
        cuenta.recuperarDelLlavero()
        precondition(lecturas == [false, true])
        precondition(cuenta.estado == .conectada("prueba@example.invalid"))
        precondition(cuenta.problemaParaLeerCorreo == nil)
        let cerrada = await cuenta.cerrarSesion()
        precondition(!cerrada && cuenta.estado == .conectada("prueba@example.invalid"),
                     "una escritura fallida no debe mostrar una sesión cerrada que reaparecería al reiniciar")
        let ausente = CuentaGoogle(lectorLlavero: { _ in (nil, errSecItemNotFound) })
        precondition(ausente.estado == .sinCliente)
        precondition(ausente.problemaParaLeerCorreo == .sinCuenta)
        let corrupta = CuentaGoogle(lectorLlavero: { _ in (Data("invalido".utf8), errSecSuccess) })
        precondition(corrupta.estado == .llaveroNoDisponible(errSecDecode))
        let clienteConservado = CuentaGoogle(lectorLlavero: { _ in
            (Data(#"{"clienteID":"prueba.apps.googleusercontent.com","secreto":"ficticio"}"#.utf8), errSecSuccess)
        }, escritorLlavero: { _ in true }, borradorLlavero: { false })
        await clienteConservado.olvidarCliente()
        precondition(clienteConservado.estado == .desconectada && clienteConservado.clienteID != nil
                     && clienteConservado.error != nil, "un borrado denegado conserva el estado real del cliente")
        var alRevocar: (() -> Void)?
        var borrados = 0
        let cambioDuranteCierre = CuentaGoogle(lectorLlavero: { _ in
            (Data(#"{"clienteID":"prueba.apps.googleusercontent.com","secreto":"ficticio","tokenRenovacion":"ficticio","correo":"prueba@example.invalid"}"#.utf8), errSecSuccess)
        }, escritorLlavero: { _ in true }, borradorLlavero: { borrados += 1; return true },
            abrirNavegador: { _ in preconditionFailure("la prueba no debe abrir el navegador") },
            revocarToken: { _ in alRevocar?(); return "aviso de la sesión anterior" })
        alRevocar = { cambioDuranteCierre.iniciarSesion() }
        await cambioDuranteCierre.olvidarCliente()
        let conservaInicio = cambioDuranteCierre.clienteID != nil && cambioDuranteCierre.estado == .esperandoNavegador
        cambioDuranteCierre.cancelarInicio()
        alRevocar = nil
        precondition(conservaInicio && borrados == 0, "una respuesta de cierre anterior no debe borrar un cliente con un inicio nuevo en curso")
        precondition(cambioDuranteCierre.error != "aviso de la sesión anterior", "una revocación anterior no debe sobrescribir el error de un inicio nuevo")
        cambioDuranteCierre.recuperarDelLlavero(interactivo: false)
        alRevocar = { cambioDuranteCierre.iniciarSesion() }
        let cierreLocal = await cambioDuranteCierre.cerrarSesion()
        let respetaInicio = cambioDuranteCierre.estado == .esperandoNavegador && cambioDuranteCierre.error == nil
        cambioDuranteCierre.cancelarInicio()
        alRevocar = nil
        precondition(cierreLocal && respetaInicio, "el aviso de una revocación obsoleta no debe publicarse durante el inicio nuevo")
        try await comprobarOperacionGlobal()
        try await comprobarRespuestasGoogle()
        try await comprobarLecturaLlaveroEnSegundoPlano()
        try await comprobarRenovacionCompartidaCaducada()
        try await comprobarCorreoUsado()
        try await comprobarCierrePermisosCorreo()
        if ProcessInfo.processInfo.environment["NUVEX_VALIDAR_LLAVERO"] == "1" {
            let resultado = AccesoLlavero.comprobar(servicio: "nuvex.prueba.\(UUID().uuidString)", cuenta: "inexistente")
            precondition(resultado == .ausente, "la consulta real sin diálogos debe distinguir una entrada inexistente: \(resultado)")
            print("Llavero de macOS: consulta real sin interacción sobre servicio inexistente verificada")
        }
        print("SecurityPreferences: migración, concurrencia, reapertura, revocación, recuperación y clasificación verificadas")
    }

    @MainActor
    private static func comprobarLecturaLlaveroEnSegundoPlano() async throws {
        let datos = Data(#"{"clienteID":"prueba.apps.googleusercontent.com","secreto":"ficticio","tokenRenovacion":"ficticio","correo":"muestra@example.invalid"}"#.utf8)
        for caso in ["exito", "cancelada", "denegada"] {
            let comenzo = DispatchSemaphore(value: 0)
            let continuar = DispatchSemaphore(value: 0)
            var renovaciones = 0
            let cuenta = CuentaGoogle(lectorSegundoPlano: { interactivo in
                precondition(!Thread.isMainThread && !interactivo)
                comenzo.signal()
                continuar.wait()
                return caso == "denegada" ? (nil, errSecInteractionNotAllowed) : (datos, errSecSuccess)
            }, escritorLlavero: { _ in preconditionFailure("no se modifica una cuenta pendiente de lectura") },
                borradorLlavero: { preconditionFailure("no se borra una cuenta pendiente de lectura") },
                pedirTokens: { _ in
                    renovaciones += 1
                    return ["access_token": "ficticio", "expires_in": 3600]
                }, abrirNavegador: { _ in preconditionFailure("no se inicia OAuth durante la lectura") })
            let esperarInicio: @Sendable () -> Void = { comenzo.wait() }
            await Task.detached(operation: esperarInicio).value
            precondition(cuenta.comprobandoLlavero && cuenta.correo == nil)
            precondition(!cuenta.guardarCliente(id: "otro.apps.googleusercontent.com", secreto: "ficticio"))
            let cerrada = await cuenta.cerrarSesion()
            precondition(!cerrada)
            await cuenta.olvidarCliente()
            cuenta.iniciarSesion()
            cuenta.recuperarDelLlavero() // No duplica una comprobación ya pendiente.
            let token = Task { try await cuenta.tokenAcceso() }
            for _ in 0..<20 { await Task.yield() }
            precondition(renovaciones == 0, "la renovación espera a que termine la lectura")
            if caso == "cancelada" {
                token.cancel()
                guard case .failure(is CancellationError) = await token.result else {
                    preconditionFailure("cancelar no espera a que el sistema termine de leer el Llavero")
                }
                precondition(cuenta.comprobandoLlavero && renovaciones == 0)
            }
            continuar.signal()
            while cuenta.comprobandoLlavero { await Task.yield() }
            switch await token.result {
            case .success(let valor) where caso == "exito":
                precondition(valor == "ficticio" && renovaciones == 1 && cuenta.correo != nil)
            case .failure(is CancellationError) where caso == "cancelada":
                precondition(renovaciones == 0 && cuenta.correo != nil)
            case .failure(let error as ProblemaGmail) where caso == "denegada":
                precondition(error == .llaveroNoDisponible && renovaciones == 0)
            default: preconditionFailure("la lectura asíncrona debe respetar su resultado y la cancelación del consumidor")
            }
            precondition(!cuenta.comprobandoLlavero)
        }
    }

    @MainActor
    private static func comprobarOperacionGlobal() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nuvex-autorizacion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let preferencias = Preferencias(url: base.appendingPathComponent("ajustes.json"))
        let espera = AutenticacionSimulada()
        var preparaciones = 0
        var revocaciones = 0
        let gestor = AutorizacionCapacidades(preferencias: preferencias,
            confirmar: { try await espera.autenticar() }, preparar: { preparaciones += 1 },
            revocarConfirmacion: { revocaciones += 1 }, retirarReglas: { ["Agente de prueba"] })
        let pendiente = Task { await gestor.autorizar() }
        while await espera.llamadas == 0 { await Task.yield() }
        await gestor.autorizar()
        let llamadas = await espera.llamadas
        precondition(llamadas == 1 && gestor.trabajando, "la operación compartida no se duplica al recrear una vista")
        gestor.revocar()
        precondition(!gestor.trabajando && preferencias.ajustes.autorizacionRevocada && revocaciones == 1)
        precondition(gestor.mensaje?.contains("Agente de prueba") == true, "debe informar la limpieza parcial")
        await espera.resolver()
        await pendiente.value
        precondition(preparaciones == 0 && preferencias.ajustes.politicaAsistentes == .noPermitir,
                     "una confirmación tardía no debe preparar reglas ni deshacer la revocación")
        precondition(Preferencias(url: base.appendingPathComponent("ajustes.json")).ajustes.autorizacionRevocada)

        let recuperada = Task { await gestor.autorizar() }
        while await espera.llamadas < 2 { await Task.yield() }
        await espera.resolver()
        await recuperada.value
        precondition(preparaciones == 1 && preferencias.ajustes.autorizacionGlobalCompleta && !gestor.trabajando)

        let fallo = AutorizacionCapacidades(preferencias: preferencias, confirmar: {},
            preparar: { throw CocoaError(.fileWriteNoPermission) }, revocarConfirmacion: {}, retirarReglas: { [] })
        fallo.revocar()
        await fallo.autorizar()
        precondition(preferencias.ajustes.autorizacionRevocada && !fallo.trabajando && fallo.mensaje != nil)
        let futuro = base.appendingPathComponent("futuro.json")
        try Data("{\"version\":99}".utf8).write(to: futuro)
        let soloLectura = AutorizacionCapacidades(preferencias: Preferencias(url: futuro),
            confirmar: { preconditionFailure("no debe autenticar con ajustes de solo lectura") },
            preparar: { preconditionFailure("no debe preparar reglas con ajustes de solo lectura") },
            revocarConfirmacion: {}, retirarReglas: { [] })
        await soloLectura.autorizar()
        precondition(soloLectura.mensaje != nil && !soloLectura.trabajando)
    }

    @MainActor
    private static func comprobarRespuestasGoogle() async throws {
        var datos = Data(#"{"clienteID":"prueba.apps.googleusercontent.com","secreto":"ficticio","tokenRenovacion":"ficticio","correo":"primera@example.invalid"}"#.utf8)
        let renovacion = RenovacionSimulada()
        var navegadores = 0
        let cuenta = CuentaGoogle(lectorLlavero: { _ in (datos, errSecSuccess) },
            escritorLlavero: { _ in true }, borradorLlavero: { true },
            pedirTokens: { _ in try await renovacion.pedir() },
            abrirNavegador: { _ in navegadores += 1; return true })
        let primera = Task { try await cuenta.tokenAcceso() }
        while renovacion.llamadas == 0 { await Task.yield() }
        let segunda = Task { try await cuenta.tokenAcceso() }
        for _ in 0..<20 { await Task.yield() }
        renovacion.resolver(.success(["access_token": "acceso-ficticio", "expires_in": 3600]))
        let tokens = try await (primera.value, segunda.value)
        precondition(tokens.0 == "acceso-ficticio" && tokens.1 == tokens.0 && renovacion.llamadas == 1)

        cuenta.invalidarAcceso()
        let obsoleta = Task { try await cuenta.tokenAcceso() }
        while renovacion.llamadas < 2 { await Task.yield() }
        datos = Data(#"{"clienteID":"otra.apps.googleusercontent.com","secreto":"ficticio","tokenRenovacion":"otro-ficticio","correo":"segunda@example.invalid"}"#.utf8)
        cuenta.recuperarDelLlavero(interactivo: false)
        renovacion.resolver(.failure(ErrorGoogle.respuesta("invalid_grant")))
        do { _ = try await obsoleta.value; preconditionFailure("se esperaba sesión invalidada") }
        catch ErrorGoogle.sinSesion {}
        precondition(cuenta.estado == .conectada("segunda@example.invalid"), "un error tardío no caduca la cuenta nueva")

        let vigente = Task { try await cuenta.tokenAcceso() }
        while renovacion.llamadas < 3 { await Task.yield() }
        renovacion.resolver(.failure(ErrorGoogle.respuesta("invalid_grant")))
        do { _ = try await vigente.value; preconditionFailure("se esperaba sesión caducada") }
        catch ErrorGoogle.caducada {}
        precondition(cuenta.estado == .caducada("segunda@example.invalid"))
        precondition(cuenta.problemaParaLeerCorreo == .sesionCaducada)
        cuenta.recuperarDelLlavero(interactivo: false)
        let sinRed = Task { try await cuenta.tokenAcceso() }
        while renovacion.llamadas < 4 { await Task.yield() }
        renovacion.resolver(.failure(URLError(.notConnectedToInternet)))
        do { _ = try await sinRed.value; preconditionFailure("se esperaba error de red") }
        catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
        precondition(cuenta.estado == .conectada("segunda@example.invalid"), "un fallo de red no revoca la sesión")

        cuenta.iniciarSesion()
        precondition(cuenta.estado == .esperandoNavegador)
        precondition(cuenta.problemaParaLeerCorreo == .inicioPendiente)
        precondition(cuenta.guardarCliente(id: "nueva.apps.googleusercontent.com", secreto: "ficticio"))
        for _ in 0..<20 { await Task.yield() }
        precondition(navegadores == 0 && cuenta.estado == .desconectada && cuenta.error == nil,
                     "cambiar de cliente cancela el inicio anterior antes de abrir navegador o sobrescribir el estado")
    }

    @MainActor
    private static func comprobarRenovacionCompartidaCaducada() async throws {
        let datos = Data(#"{"clienteID":"prueba.apps.googleusercontent.com","secreto":"ficticio","tokenRenovacion":"ficticio","correo":"cuenta@example.invalid"}"#.utf8)
        let renovacion = RenovacionSimulada()
        let cuenta = CuentaGoogle(lectorLlavero: { _ in (datos, errSecSuccess) },
            pedirTokens: { _ in try await renovacion.pedir() })
        let primera = Task { try await cuenta.tokenAcceso() }
        while renovacion.llamadas == 0 { await Task.yield() }
        let otras = (0..<4).map { _ in Task { try await cuenta.tokenAcceso() } }
        for _ in 0..<40 { await Task.yield() }
        renovacion.resolver(.failure(ErrorGoogle.respuesta("invalid_grant")))
        for tarea in [primera] + otras {
            switch await tarea.result {
            case .failure(ErrorGoogle.caducada): break
            default: preconditionFailure("todos los consumidores de la renovación deben recibir sesión caducada")
            }
        }
        precondition(renovacion.llamadas == 1 && cuenta.problemaParaLeerCorreo == .sesionCaducada)
        for caso in ["exito", "red", "sesion-cambiada", "error-obsoleto"] {
            let compartida = RenovacionSimulada()
            let actual = CuentaGoogle(lectorLlavero: { _ in (datos, errSecSuccess) },
                pedirTokens: { _ in try await compartida.pedir() })
            let inicio = Task { try await actual.tokenAcceso() }
            while compartida.llamadas == 0 { await Task.yield() }
            let consumidores = [inicio] + (0..<6).map { _ in Task { try await actual.tokenAcceso() } }
            for _ in 0..<40 { await Task.yield() }
            if caso == "sesion-cambiada" || caso == "error-obsoleto" {
                actual.recuperarDelLlavero(interactivo: false)
            }
            if caso == "red" { compartida.resolver(.failure(URLError(.notConnectedToInternet))) }
            else if caso == "error-obsoleto" { compartida.resolver(.failure(ErrorGoogle.respuesta("invalid_grant"))) }
            else { compartida.resolver(.success(["access_token": "ficticio", "expires_in": 3600])) }
            for tarea in consumidores {
                let resultado = await tarea.result
                switch (caso, resultado) {
                case ("exito", .success(let token)): precondition(token == "ficticio")
                case ("red", .failure(let error as URLError)): precondition(error.code == .notConnectedToInternet)
                case ("sesion-cambiada", .failure(ErrorGoogle.sinSesion)),
                     ("error-obsoleto", .failure(ErrorGoogle.sinSesion)): break
                default: preconditionFailure("la limpieza normal y la invalidación de sesión son hechos distintos")
                }
            }
            precondition(compartida.llamadas == 1 && actual.correo != nil)
        }
    }

    @MainActor
    private static func comprobarCorreoUsado() async throws {
        let carpeta = FileManager.default.temporaryDirectory.appendingPathComponent("nuvex-papelera-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: carpeta) }
        let preferencias = Preferencias(url: carpeta.appendingPathComponent("ajustes.json"))
        func datos(modificar: Bool) -> Data {
            let permisos = modificar ? #", "permisos":["https://www.googleapis.com/auth/gmail.modify"]"# : ""
            return Data((#"{"clienteID":"prueba.apps.googleusercontent.com","secreto":"ficticio","tokenRenovacion":"ficticio","correo":"cuenta@example.invalid""#
                + permisos + "}").utf8)
        }
        var renovaciones = 0
        var traslados = 0
        let antigua = CuentaGoogle(lectorLlavero: { _ in (datos(modificar: false), errSecSuccess) },
            pedirTokens: { _ in preconditionFailure("no debe renovar sin permiso") })
        precondition(!antigua.puedeModificarCorreo)
        precondition(preferencias.modificar { $0.enviarCorreoPapelera = true })
        await antigua.moverCorreoUsado(.init(id: "abc123", sesion: antigua.idSesion), preferencias: preferencias,
            mover: { _, _ in preconditionFailure("una sesión anterior conserva solo lectura") })

        let cuenta = CuentaGoogle(lectorLlavero: { _ in (datos(modificar: true), errSecSuccess) },
            pedirTokens: { _ in renovaciones += 1; return ["access_token": "ficticio", "expires_in": 3600] })
        precondition(cuenta.puedeModificarCorreo)
        precondition(antigua.mensajePapeleraPendiente.contains("Falta autorizar"))
        let mensaje = MensajeCodigoGmail(id: "abc123", sesion: cuenta.idSesion)
        precondition(preferencias.modificar { $0.enviarCorreoPapelera = false })
        await cuenta.moverCorreoUsado(mensaje, preferencias: preferencias,
            mover: { _, _ in preconditionFailure("desactivado no toca Gmail") })
        precondition(renovaciones == 0)
        precondition(preferencias.modificar { $0.enviarCorreoPapelera = true })
        await cuenta.moverCorreoUsado(mensaje, preferencias: preferencias, mover: { id, token in
            precondition(id == "abc123" && token == "ficticio")
            traslados += 1
        })
        precondition(renovaciones == 1 && traslados == 1 && cuenta.avisoPapelera == nil)
        await cuenta.moverCorreoUsado(mensaje, preferencias: preferencias, mover: { _, _ in
            throw URLError(.notConnectedToInternet)
        })
        precondition(cuenta.avisoPapelera != nil && cuenta.correo != nil, "un fallo secundario no cierra la sesión")
        await cuenta.moverCorreoUsado(mensaje, preferencias: preferencias, mover: { _, _ in })
        precondition(cuenta.avisoPapelera != nil, "un éxito posterior no oculta un traslado anterior sin confirmar")
        cuenta.descartarAvisoPapelera()
        precondition(cuenta.avisoPapelera == nil)
        await cuenta.moverCorreoUsado(mensaje, preferencias: preferencias, mover: { _, _ in throw ProblemaGmail.sinPermiso })
        precondition(!cuenta.puedeModificarCorreo && cuenta.avisoPapelera != nil && cuenta.problemaParaLeerCorreo == nil)

        let renovacion = RenovacionSimulada()
        let concurrente = CuentaGoogle(lectorLlavero: { _ in (datos(modificar: true), errSecSuccess) },
            pedirTokens: { _ in try await renovacion.pedir() })
        let pendiente = Task {
            await concurrente.moverCorreoUsado(.init(id: "abc123", sesion: concurrente.idSesion), preferencias: preferencias,
                mover: { _, _ in preconditionFailure("desactivar durante la renovación impide el traslado") })
        }
        while renovacion.llamadas == 0 { await Task.yield() }
        precondition(preferencias.modificar { $0.enviarCorreoPapelera = false })
        renovacion.resolver(.success(["access_token": "ficticio", "expires_in": 3600]))
        await pendiente.value
        precondition(preferencias.modificar { $0.enviarCorreoPapelera = true })
        let anterior = MensajeCodigoGmail(id: "abc123", sesion: concurrente.idSesion)
        concurrente.recuperarDelLlavero(interactivo: false)
        await concurrente.moverCorreoUsado(anterior, preferencias: preferencias,
            mover: { _, _ in preconditionFailure("otra sesión no puede usar el ID anterior") })
        precondition(renovacion.llamadas == 1)

        let tardia = Task {
            await concurrente.moverCorreoUsado(.init(id: "abc123", sesion: concurrente.idSesion), preferencias: preferencias,
                mover: { _, _ in preconditionFailure("un cambio de cuenta invalida una renovación pendiente") })
        }
        while renovacion.llamadas < 2 { await Task.yield() }
        concurrente.recuperarDelLlavero(interactivo: false)
        renovacion.resolver(.success(["access_token": "obsoleto", "expires_in": 3600]))
        await tardia.value
        precondition(concurrente.avisoPapelera == nil)

        let soloLectura = CuentaGoogle.permisosOAuth(modificar: false)
        let modificar = CuentaGoogle.permisosOAuth(modificar: true)
        precondition(soloLectura == CuentaGoogle.permisos && !soloLectura.contains("gmail.modify"))
        precondition(modificar.contains(CuentaGoogle.permisoModificar) && !modificar.contains("mail.google.com/"))
        let completa = try CuentaGoogle.permisosConcedidos(nil, solicitados: modificar)
        precondition(completa.contains(CuentaGoogle.permisoModificar), "scope omitido equivale al solicitado según OAuth")
        let parcial = try CuentaGoogle.permisosConcedidos(soloLectura, solicitados: modificar)
        precondition(!parcial.contains(CuentaGoogle.permisoModificar), "una concesión parcial nunca hereda la modificación solicitada")
        do {
            _ = try CuentaGoogle.permisosConcedidos("openid email", solicitados: modificar)
            preconditionFailure("una concesión sin acceso a Gmail no debe reemplazar la sesión anterior")
        } catch is ErrorGoogle {}
    }

    @MainActor
    private static func comprobarCierrePermisosCorreo() async throws {
        let original = Data(#"{"clienteID":"prueba.apps.googleusercontent.com","secreto":"ficticio","tokenRenovacion":"ficticio","correo":"cuenta@example.invalid","permisos":["https://www.googleapis.com/auth/gmail.modify"]}"#.utf8)
        var persistido = original
        var borrados = 0
        let cuenta = CuentaGoogle(lectorLlavero: { _ in (persistido, errSecSuccess) },
            escritorLlavero: { persistido = $0; return true },
            borradorLlavero: { borrados += 1; return true }, revocarToken: { _ in nil })
        let cerrada = await cuenta.cerrarSesion()
        let contenido = try JSONSerialization.jsonObject(with: persistido) as! [String: Any]
        precondition(cerrada && cuenta.estado == .desconectada && !cuenta.puedeModificarCorreo)
        precondition(contenido["permisos"] == nil && contenido["tokenRenovacion"] == nil && contenido["correo"] == nil)
        precondition(contenido["clienteID"] != nil && contenido["secreto"] != nil, "cerrar conserva el cliente")
        cuenta.recuperarDelLlavero(interactivo: false)
        precondition(cuenta.estado == .desconectada && !cuenta.puedeModificarCorreo)

        persistido = original
        cuenta.recuperarDelLlavero(interactivo: false)
        await cuenta.olvidarCliente()
        precondition(borrados == 1 && cuenta.estado == .sinCliente, "olvidar debe comparar también los permisos limpiados")

        let denegada = CuentaGoogle(lectorLlavero: { _ in (original, errSecSuccess) },
            escritorLlavero: { _ in false }, revocarToken: { _ in preconditionFailure("no revoca si no pudo cerrar localmente") })
        let rechazo = await denegada.cerrarSesion()
        precondition(!rechazo && denegada.correo != nil && denegada.puedeModificarCorreo,
                     "un guardado fallido conserva la sesión y sus metadatos reales")

        let caducada = CuentaGoogle(lectorLlavero: { _ in (original, errSecSuccess) },
            pedirTokens: { _ in throw ErrorGoogle.respuesta("invalid_grant") })
        do { _ = try await caducada.tokenAcceso(); preconditionFailure("se esperaba caducidad") }
        catch ErrorGoogle.caducada {}
        precondition(!caducada.puedeModificarCorreo && caducada.mensajePapeleraPendiente.contains("caducó")
                     && caducada.mensajePapeleraPendiente.contains("iniciar sesión"))
        precondition(!caducada.mensajePapeleraPendiente.contains("Falta autorizar"))
    }
}
