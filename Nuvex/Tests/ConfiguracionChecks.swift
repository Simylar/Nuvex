import Foundation

@main
struct ConfiguracionChecks {
    @MainActor
    static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nuvex-configuracion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let perfil = VPNProfile(id: "vpn-a", name: "Oficina", server: "vpn.example.invalid:443",
            username: "persona", trust: "system", realm: "", manageRoutes: true, manageDNS: true, enabled: true)
        // El primer uso conserva datos ante fallos y distingue guardar de
        // estar preparado: nunca infiere éxito de la existencia de un perfil.
        let borrador = BorradorBienvenida()
        borrador.perfil = perfil
        borrador.password = "contrasena-de-prueba"
        borrador.paso = .preparando
        borrador.completar(ResultadoGuardado(id: UUID(),
            resumen: .init(conexiones: .fallo("Sin acceso al archivo")), idsConfirmados: []))
        precondition(borrador.paso == .formulario && !borrador.password.isEmpty)
        precondition(borrador.perfil == perfil)
        borrador.completar(ResultadoGuardado(id: UUID(),
            resumen: .init(conexiones: .hecho, contrasenas: .fallo("Llavero bloqueado")),
            idsConfirmados: [perfil.id]))
        precondition(borrador.paso == .formulario && !borrador.password.isEmpty)
        borrador.completar(ResultadoGuardado(id: UUID(),
            resumen: .init(conexiones: .hecho, contrasenas: .hecho), idsConfirmados: ["otra"]))
        precondition(borrador.paso == .formulario && !borrador.password.isEmpty)
        borrador.completar(ResultadoGuardado(id: UUID(),
            resumen: .init(conexiones: .hecho, contrasenas: .hecho, ayudante: .fallo("Autorización cancelada")),
            idsConfirmados: [perfil.id]))
        precondition(borrador.paso == .guardada && borrador.password.isEmpty)
        precondition(borrador.resumen?.hayProblemas == true)

        precondition(!borrador.completar(ResultadoGuardado(id: UUID(),
            resumen: .init(conexiones: .hecho, contrasenas: .hecho, ayudante: .fallo("Cancelado")),
            idsConfirmados: [perfil.id])), "cancelar el permiso no debe generar otro diálogo automático")
        let completo = ResultadoGuardado(id: UUID(),
            resumen: .init(conexiones: .hecho, contrasenas: .hecho, ayudante: .hecho), idsConfirmados: [perfil.id])
        precondition(borrador.completar(completo), "guardar y preparar debe dar paso a conectar")
        let reutilizada = ResultadoGuardado(id: UUID(),
            resumen: .init(conexiones: .hecho, contrasenas: .noAplica, ayudante: .hecho), idsConfirmados: [perfil.id])
        precondition(!borrador.completar(reutilizada), "no se puede suponer que existe una contraseña")
        precondition(borrador.completar(reutilizada, contrasenaDisponible: true))
        precondition(borrador.tieneAvance)
        precondition(!BorradorBienvenida().tieneAvance)
        let avanzado = BorradorBienvenida()
        avanzado.perfil.manageDNS = false
        precondition(avanzado.tieneAvance, "las opciones especiales también son avance")

        let copia = base.appendingPathComponent("copia")
        try FileManager.default.createDirectory(at: copia, withIntermediateDirectories: true)
        let archivoPerfiles = copia.appendingPathComponent("profiles.json")
        let archivoAjustes = copia.appendingPathComponent("ajustes.json")
        struct Archivo: Encodable { let version = 2; let profiles: [VPNProfile] }
        try JSONEncoder().encode(Archivo(profiles: [perfil])).write(to: archivoPerfiles)
        var antiguos = AjustesApp()
        antiguos.autorizarCapacidades()
        antiguos.correo[perfil.id] = .fortinet
        try ArchivoAjustes.escribir(antiguos, sobre: [:]).write(to: archivoAjustes)
        let plan = try PreparacionRestauracion.leer(en: copia)
        precondition(plan.perfiles == [perfil])

        let preferencias = Preferencias(url: base.appendingPathComponent("actual/ajustes.json"))
        precondition(preferencias.modificar {
            $0.revocarCapacidades()
            $0.bloqueadasParaAsistentes = [perfil.id, "privada"]
            $0.avisarAccionesAsistentes = false
            $0.correo["otra"] = .fortinet
        })
        _ = try plan.ajustes.aplicar(en: preferencias, ids: [perfil.id])
        precondition(preferencias.ajustes.politicaAsistentes == .noPermitir)
        precondition(preferencias.ajustes.autorizacionRevocada && preferencias.ajustes.capacidadesAutorizadas.isEmpty)
        precondition(preferencias.ajustes.bloqueadasParaAsistentes == [perfil.id, "privada"])
        precondition(!preferencias.ajustes.avisarAccionesAsistentes)
        precondition(preferencias.ajustes.correo == [perfil.id: .fortinet])
        precondition(Preferencias(url: base.appendingPathComponent("actual/ajustes.json")).ajustes == preferencias.ajustes)

        let truncado = base.appendingPathComponent("ajustes-truncados.json")
        try Data().write(to: truncado)
        let bloqueadas = Preferencias(url: truncado)
        precondition(bloqueadas.soloLectura != nil, "un archivo vacío no debe sustituir las decisiones del usuario por valores iniciales")
        precondition(!bloqueadas.modificar { $0.autorizarCapacidades() })
        let intactos = try Data(contentsOf: truncado)
        precondition(intactos.isEmpty, "un archivo corrupto no se sobrescribe")
        for version in ["0", "-1", String(Int.min), "true", #""incorrecta""#] {
            let original = Data("{\"version\":\(version)}".utf8)
            try original.write(to: truncado)
            let malformadas = Preferencias(url: truncado)
            precondition(malformadas.soloLectura != nil, "una versión inválida se rechaza antes de migrar")
            precondition(!malformadas.modificar { $0.autorizarCapacidades() })
            let conservados = try Data(contentsOf: truncado)
            precondition(conservados == original)
        }

        // No se inicia una restauración con una copia corrupta o más nueva.
        for datos in [Data(), Data("invalido".utf8), Data(#"{"version":99}"#.utf8)] {
            try datos.write(to: archivoAjustes)
            do { _ = try PreparacionRestauracion.leer(en: copia); preconditionFailure("se esperaba rechazar la copia") }
            catch { }
        }
        try FileManager.default.removeItem(at: archivoAjustes)
        let sinAjustes = try PreparacionRestauracion.leer(en: copia)
        precondition(preferencias.modificar { $0.correo["otra"] = .fortinet })
        _ = try sinAjustes.ajustes.aplicar(en: preferencias, ids: [perfil.id])
        precondition(preferencias.ajustes.correo == [perfil.id: .fortinet])
        try JSONEncoder().encode(Archivo(profiles: [perfil, perfil])).write(to: archivoPerfiles)
        do { _ = try PreparacionRestauracion.leer(en: copia); preconditionFailure("se esperaban IDs únicos") }
        catch { }
        var invalido = perfil
        invalido.server = "host:99999"
        try JSONEncoder().encode(Archivo(profiles: [invalido])).write(to: archivoPerfiles)
        do { _ = try PreparacionRestauracion.leer(en: copia); preconditionFailure("se esperaba validar el servidor") }
        catch { }

        // El segundo archivo falla: los perfiles vuelven a sus bytes originales.
        let destino = base.appendingPathComponent("perfiles-actuales.json")
        let anterior = Data("anterior".utf8), nuevo = Data("nuevo".utf8)
        try anterior.write(to: destino)
        do {
            try await PersistenciaRestauracion.aplicar(perfiles: { try nuevo.write(to: destino) },
                ajustes: { throw CocoaError(.fileWriteNoPermission) }, revertir: { try anterior.write(to: destino) })
            preconditionFailure("se esperaba fallo de ajustes")
        } catch let error as CocoaError { precondition(error.code == .fileWriteNoPermission) }
        let recuperados = try Data(contentsOf: destino)
        precondition(recuperados == anterior)
        do {
            try await PersistenciaRestauracion.aplicar(perfiles: { try nuevo.write(to: destino) },
                ajustes: { throw CocoaError(.fileWriteNoPermission) }, revertir: { throw CocoaError(.fileWriteNoPermission) })
            preconditionFailure("se esperaba recuperación fallida")
        } catch is PersistenciaRestauracion.RecuperacionFallida { }
        let trasFalloRecuperacion = try Data(contentsOf: destino)
        precondition(trasFalloRecuperacion == nuevo)
        let noDebeEscribirse = base.appendingPathComponent("ajustes-no-aplicados")
        do {
            try await PersistenciaRestauracion.aplicar(perfiles: { throw CocoaError(.fileWriteNoPermission) },
                ajustes: { try nuevo.write(to: noDebeEscribirse) }, revertir: { preconditionFailure("no hubo perfiles guardados") })
            preconditionFailure("se esperaba fallo de perfiles")
        } catch let error as CocoaError { precondition(error.code == .fileWriteNoPermission) }
        precondition(!FileManager.default.fileExists(atPath: noDebeEscribirse.path))
        try await PersistenciaRestauracion.aplicar(perfiles: { try nuevo.write(to: destino) },
            ajustes: { _ = try await plan.ajustes.aplicar(en: preferencias, ids: [perfil.id]) },
            revertir: { preconditionFailure("no debe revertir una operación correcta") })
        let guardados = try Data(contentsOf: destino)
        precondition(guardados == nuevo)

        // Una importación rechazada no se confirma aunque el ID ya existiera.
        let rechazo = ResultadoGuardado(id: UUID(), resumen: .init(conexiones: .fallo("usuario sin contraseña")), idsConfirmados: [perfil.id])
        precondition(!rechazo.confirmaImportacion([perfil.id]) && !rechazo.completo)
        let indeterminado = ResultadoGuardado(id: UUID(), resumen: .init(conexiones: .pendiente("revisa la copia previa")), idsConfirmados: [])
        precondition(!indeterminado.completo && !indeterminado.confirmaImportacion([perfil.id]))
        precondition(indeterminado.resumen.resumen == "Revisa el estado de las conexiones antes de continuar")
        let completa = ResultadoGuardado(id: UUID(), resumen: .init(conexiones: .hecho, contrasenas: .hecho, ayudante: .hecho), idsConfirmados: [perfil.id])
        precondition(completa.confirmaImportacion([perfil.id]) && completa.completo)
        precondition(!completa.confirmaImportacion(["otra"]) && !completa.confirmaImportacion([]))
        for resumen in [ResumenGuardado(conexiones: .hecho, contrasenas: .fallo("llavero")),
                        ResumenGuardado(conexiones: .hecho, ayudante: .fallo("ayudante")),
                        ResumenGuardado(conexiones: .hecho, ajustes: .fallo("ajustes"))] {
            let parcial = ResultadoGuardado(id: UUID(), resumen: resumen, idsConfirmados: [perfil.id])
            precondition(parcial.confirmaImportacion([perfil.id]) && !parcial.completo && !parcial.avisos.isEmpty)
        }
        let futuro = base.appendingPathComponent("ajustes-futuros.json")
        try Data(#"{"version":99}"#.utf8).write(to: futuro)
        do {
            _ = try AjustesDelGuardado.importarCorreo([perfil.id: .fortinet]).aplicar(en: Preferencias(url: futuro), ids: [perfil.id])
            preconditionFailure("se esperaba informar que los ajustes no se guardaron")
        } catch { }

        // Reemplazar un archivo con metadatos antiguos conserva el modo privado.
        let privado = base.appendingPathComponent("privado.json")
        try anterior.write(to: privado)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: privado.path)
        try ArchivoAjustes.guardarAtomico(nuevo, en: privado)
        let modo = try FileManager.default.attributesOfItem(atPath: privado.path)[.posixPermissions] as? Int
        precondition(modo == 0o600)

        var estado = EstadoCapacidades(perfiles: [perfil], ayudanteListo: true,
            contrasenas: [perfil.id: .saved], accesos: [perfil.id: .disponible], problemaCuenta: .sinCuenta)
        precondition(estado.pendientes.isEmpty, "Gmail y automatización opcionales no son permisos faltantes")
        estado.correo = [perfil.id: .fortinet]
        precondition(estado.pendientes.map(\.id) == ["gmail"])
        precondition(estado.pendientes.first?.destino == .cuentaGoogle)
        estado.problemaCuenta = nil
        estado.accesos = [perfil.id: .requiereInteraccion]
        precondition(estado.pendientes.first?.destino == .contrasenas(perfil.id))
        estado.accesos = [perfil.id: .disponible]
        estado.confirmacionPendiente = true
        precondition(estado.pendientes.first?.destino == .confirmacionInicial)
        estado.confirmacionPendiente = false
        estado.ayudanteListo = nil
        precondition(estado.pendientes.first?.detalle.contains("no pudo comprobarse") == true)
        estado.ayudanteListo = true
        estado.accesos = [perfil.id: .ausente]
        precondition(estado.pendientes.first?.destino == .conexion(perfil.id), "prevalece la lectura efectiva sobre metadatos guardados")
        estado.accesos = [perfil.id: .disponible]
        var desactivado = perfil
        desactivado.enabled = false
        estado.perfiles = [desactivado]
        estado.accesos = [perfil.id: .ausente]
        precondition(estado.pendientes.isEmpty, "una conexión desactivada no requiere atención")
        estado.perfiles = [perfil]
        estado.accesos = [perfil.id: .disponible]
        estado.automatizacionSolicitada = true
        estado.comandoListo = false
        estado.agentes = ["codex": false]
        precondition(Set(estado.pendientes.map(\.id)) == ["comando", "agente.codex"])
        print("Configuración: restauración, recuperación, permisos conservados, resultados de importación y acciones pendientes comprobados")
    }
}
