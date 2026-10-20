import Foundation

/// Comprobaciones de los datos que deben sobrevivir a las actualizaciones:
/// ajustes.json, copias de seguridad y migraciones.
@main
struct NucleoChecks {
    @MainActor
    static func main() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuvex-nucleo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // ajustes.json: valores de serie, ida y vuelta y claves desconocidas.
        let vacio = try ArchivoAjustes.leer(nil)
        precondition(vacio.ajustes == AjustesApp())
        precondition(vacio.ajustes.politicaAsistentes == .preguntar)

        let futuro = #"{"version":1,"politicaAsistentes":"preguntar","clavesDelFuturo":{"x":1},"correo":{"vpn-a":{"remitente":"noreply@empresa.com","espera":60,"campoNuevo":true}}}"#
        let lectura = try ArchivoAjustes.leer(Data(futuro.utf8))
        precondition(lectura.ajustes.politicaAsistentes == .preguntar)
        precondition(lectura.ajustes.correo["vpn-a"]?.espera == 60)
        precondition(lectura.ajustes.correo["vpn-a"]?.asunto == "")
        var cambiados = lectura.ajustes
        cambiados.avisarAccionesAsistentes = false
        let escrito = try ArchivoAjustes.escribir(cambiados, sobre: lectura.crudo)
        let texto = String(decoding: escrito, as: UTF8.self)
        precondition(texto.contains("clavesDelFuturo"), "una versión anterior no debe borrar claves que no conoce")
        let releido = try ArchivoAjustes.leer(escrito)
        precondition(releido.ajustes == cambiados)

        let raro = try ArchivoAjustes.leer(Data(#"{"politicaAsistentes":"desconocida"}"#.utf8))
        precondition(raro.ajustes.politicaAsistentes == .preguntar, "un valor desconocido falla de forma segura")
        let v3 = try ArchivoAjustes.leer(Data(#"{"version":3}"#.utf8))
        let v2 = try ArchivoAjustes.leer(Data(#"{"version":2}"#.utf8))
        precondition(v3.esMasNuevo && !v2.esMasNuevo)

        // Permisos: una instalación nueva pide confirmación y las exclusiones
        // por conexión prevalecen sobre la política global.
        var permisosAsistentes = AjustesApp()
        precondition(permisosAsistentes.decisionParaAsistente(conexion: "vpn-a") == .confirmar)
        permisosAsistentes.politicaAsistentes = .permitir
        precondition(permisosAsistentes.decisionParaAsistente(conexion: "vpn-a") == .permitir)
        permisosAsistentes.bloqueadasParaAsistentes.insert("vpn-a")
        precondition(permisosAsistentes.decisionParaAsistente(conexion: "vpn-a") == .rechazarConexion)
        permisosAsistentes.politicaAsistentes = .noPermitir
        precondition(permisosAsistentes.decisionParaAsistente(conexion: "vpn-b") == .rechazarGlobal)

        // Un archivo gestionado se retira sin borrar archivos vecinos. Los
        // enlaces simbólicos y el contenido sin marca nunca se modifican.
        let marca = "<!-- gestionado -->"
        let habilidad = base.appendingPathComponent("habilidad", isDirectory: true)
        let skill = habilidad.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: habilidad, withIntermediateDirectories: true)
        try Data((marca + "\n").utf8).write(to: skill)
        let vecino = habilidad.appendingPathComponent("notas.txt")
        try Data("conservar".utf8).write(to: vecino)
        precondition(ArchivoGestionado.estado(carpeta: habilidad, archivo: skill, marca: marca)
                     == .gestionado(marca + "\n"))
        try ArchivoGestionado.quitar(carpeta: habilidad, archivo: skill, marca: marca)
        precondition(!FileManager.default.fileExists(atPath: skill.path))
        precondition(FileManager.default.fileExists(atPath: vecino.path))
        precondition(FileManager.default.fileExists(atPath: habilidad.path))

        let vaciable = base.appendingPathComponent("vaciable", isDirectory: true)
        let vaciableSkill = vaciable.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: vaciable, withIntermediateDirectories: true)
        try Data((marca + "\n").utf8).write(to: vaciableSkill)
        try ArchivoGestionado.quitar(carpeta: vaciable, archivo: vaciableSkill, marca: marca)
        precondition(!FileManager.default.fileExists(atPath: vaciable.path))

        let ajena = base.appendingPathComponent("ajena", isDirectory: true)
        let ajenaSkill = ajena.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: ajena, withIntermediateDirectories: true)
        try Data("contenido ajeno".utf8).write(to: ajenaSkill)
        try ArchivoGestionado.quitar(carpeta: ajena, archivo: ajenaSkill, marca: marca)
        precondition(FileManager.default.fileExists(atPath: ajenaSkill.path))

        let enlace = base.appendingPathComponent("enlace", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: enlace, withDestinationURL: habilidad)
        precondition(ArchivoGestionado.estado(carpeta: enlace,
                                              archivo: enlace.appendingPathComponent("SKILL.md"), marca: marca) == .ajeno)

        // Almacén: permisos privados y solo lectura ante datos más nuevos.
        let url = base.appendingPathComponent("ajustes.json")
        let preferencias = Preferencias(url: url)
        precondition(preferencias.modificar { $0.politicaAsistentes = .noPermitir })
        let permisos = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        precondition(permisos == 0o600)
        precondition(Preferencias(url: url).ajustes.politicaAsistentes == .noPermitir)
        preferencias.modificar { $0.correo["vpn-b"] = ConfigCorreo(remitente: "a@b.c") }
        preferencias.olvidarConexion("vpn-b")
        precondition(Preferencias(url: url).ajustes.correo["vpn-b"] == nil)
        try Data(#"{"version":99,"politicaAsistentes":"permitir"}"#.utf8).write(to: url)
        let nueva = Preferencias(url: url)
        precondition(nueva.soloLectura != nil)
        precondition(!nueva.modificar { $0.politicaAsistentes = .noPermitir }, "no se escribe sobre datos más nuevos")
        let intacto = try Data(contentsOf: url)
        precondition(String(decoding: intacto, as: UTF8.self).contains("99"))

        // El registro conserva una sola generación y no crece sin límite.
        let registro = base.appendingPathComponent("Nuvex.log").path
        try Data(repeating: 0x61, count: 32).write(to: URL(fileURLWithPath: registro))
        Log.rotarSiNecesario(registro, maximo: 16)
        precondition(!FileManager.default.fileExists(atPath: registro))
        precondition(FileManager.default.fileExists(atPath: registro + ".1"))

        // Migraciones: la primera instalación no es una actualización; una
        // versión nueva copia la configuración; repetir no hace nada.
        let defaults = UserDefaults(suiteName: "NuvexNucleo.\(UUID().uuidString)")!
        let perfiles = base.appendingPathComponent("profiles.json")
        let perfilesJSON = #"{"version":2,"profiles":[{"id":"vpn-a","name":"Oficina","server":"vpn.empresa.com:443","username":"ana","trust":"system","realm":"","manageRoutes":true,"manageDNS":true,"enabled":true}]}"#
        var perfilEtiqueta = VPNProfile.nuevo()
        perfilEtiqueta.name = "Oficina"
        precondition(perfilEtiqueta.etiquetaLlavero == "Nuvex: Oficina")
        let v30 = InfoVersion(corta: "3.0.0", compilacion: 3)
        let v31 = InfoVersion(corta: "3.1.0", compilacion: 9)
        precondition(v31.canalLegible == "Estable")
        precondition(InfoVersion(corta: "3.2.0", compilacion: 10, canal: "beta").canalLegible == "Beta")
        precondition(InfoVersion(corta: "3.2.0", compilacion: 11, canal: "desarrollo").canalLegible == "Desarrollo")

        // Actualizaciones: se rechazan metadatos inseguros antes de descargar
        // y el siguiente proceso confirma la compilación realmente instalada.
        let actual = InfoVersion(corta: "3.1.2", compilacion: 130)
        let candidato = CandidatoActualizacion(
            version: "3.2.0", compilacion: "131", canal: nil,
            direccion: URL(string: "https://example.invalid/Nuvex-3.2.0.zip"),
            tipoInstalacion: "application", tamano: 20 * 1_024 * 1_024)
        try PreparacionActualizacion.validar(candidato, actual: actual, permiteBeta: false,
                                             capacidadDisponible: 500 * 1_024 * 1_024)
        precondition(PreparacionActualizacion.espacioNecesario(tamano: candidato.tamano) == 250 * 1_024 * 1_024)
        let inseguro = CandidatoActualizacion(version: candidato.version, compilacion: candidato.compilacion,
            canal: candidato.canal, direccion: URL(string: "http://example.invalid/Nuvex.zip"),
            tipoInstalacion: candidato.tipoInstalacion, tamano: candidato.tamano)
        do {
            try PreparacionActualizacion.validar(inseguro, actual: actual, permiteBeta: false,
                                                 capacidadDisponible: nil)
            preconditionFailure("una actualización por HTTP debe rechazarse")
        } catch ErrorPreparacionActualizacion.direccionInsegura {}
        let beta = CandidatoActualizacion(version: "3.2.0-beta.1", compilacion: "132", canal: "beta",
            direccion: candidato.direccion, tipoInstalacion: "application", tamano: candidato.tamano)
        do {
            try PreparacionActualizacion.validar(beta, actual: actual, permiteBeta: false,
                                                 capacidadDisponible: nil)
            preconditionFailure("el canal beta necesita consentimiento")
        } catch ErrorPreparacionActualizacion.canalNoPermitido {}
        try PreparacionActualizacion.validar(beta, actual: actual, permiteBeta: true,
                                             capacidadDisponible: 500 * 1_024 * 1_024)
        let regresiva = CandidatoActualizacion(
            version: "3.1.1", compilacion: "131", canal: nil, direccion: candidato.direccion,
            tipoInstalacion: "application", tamano: candidato.tamano)
        do {
            try PreparacionActualizacion.validar(regresiva, actual: actual, permiteBeta: false,
                                                 capacidadDisponible: nil)
            preconditionFailure("una compilación mayor no debe permitir regresar la versión pública")
        } catch ErrorPreparacionActualizacion.versionAnterior {}
        precondition(VersionSemantica("1.0.0-alpha")! < VersionSemantica("1.0.0-alpha.1")!)
        precondition(VersionSemantica("1.0.0-beta.11")! < VersionSemantica("1.0.0-rc.1")!)
        precondition(VersionSemantica("1.0.0-rc.1")! < VersionSemantica("1.0.0")!)
        precondition(VersionSemantica("1.0.0+compilacion.7") == VersionSemantica("1.0.0+otra"))
        precondition(VersionSemantica("99999999999999999999.0.0")!
                     > VersionSemantica("10000000000000000000.0.0")!)
        precondition(VersionSemantica("01.0.0") == nil)
        precondition(VersionSemantica("1.0.0-01") == nil)
        do {
            try PreparacionActualizacion.validar(candidato, actual: actual, permiteBeta: false,
                                                 capacidadDisponible: 100 * 1_024 * 1_024)
            preconditionFailure("una actualización sin espacio debe rechazarse")
        } catch ErrorPreparacionActualizacion.espacioInsuficiente {}

        precondition(PoliticaPresentacionActualizacion.accion(
            etapa: .sinDescargar, iniciadaPorUsuario: true, instalarAhora: true) == .iniciarDescarga)
        precondition(PoliticaPresentacionActualizacion.accion(
            etapa: .descargada, iniciadaPorUsuario: true, instalarAhora: true) == .iniciarDescarga)
        precondition(PoliticaPresentacionActualizacion.accion(
            etapa: .instalando, iniciadaPorUsuario: false, instalarAhora: true) == .mantenerProgramada)
        precondition(PoliticaPresentacionActualizacion.accion(
            etapa: .instalando, iniciadaPorUsuario: true, instalarAhora: false) == .mantenerProgramada)
        precondition(PoliticaPresentacionActualizacion.accion(
            etapa: .descargada, iniciadaPorUsuario: false, instalarAhora: false) == .mostrarDisponible)

        let defaultsActualizacion = UserDefaults(suiteName: "NuvexActualizacion.\(UUID().uuidString)")!
        precondition(RegistroInstalacionActualizacion.comenzar(
            version: "3.2.0", compilacion: "131", actual: actual,
            defaults: defaultsActualizacion, ahora: Date(timeIntervalSince1970: 1)))
        let verificada = RegistroInstalacionActualizacion.resolver(
            actual: InfoVersion(corta: "3.2.0", compilacion: 131), defaults: defaultsActualizacion)
        if case .verificada(let registro)? = verificada {
            precondition(registro.compilacionOrigen == 130 && registro.compilacionEsperada == 131)
        } else { preconditionFailure("el siguiente proceso debe confirmar la compilación esperada") }
        precondition(RegistroInstalacionActualizacion.resolver(actual: actual, defaults: defaultsActualizacion) == nil)
        RegistroInstalacionActualizacion.comenzar(version: "3.2.0", compilacion: "131", actual: actual,
                                                  defaults: defaultsActualizacion)
        let incompleta = RegistroInstalacionActualizacion.resolver(actual: actual, defaults: defaultsActualizacion)
        if case .incompleta(_, let instalada)? = incompleta {
            precondition(instalada == actual)
        } else { preconditionFailure("volver a abrir la versión anterior debe informar el fallo") }
        precondition(RegistroInstalacionActualizacion.resolver(
            actual: actual, defaults: defaultsActualizacion) == incompleta,
            "el diagnóstico incompleto debe persistir hasta que el usuario lo vea")
        RegistroInstalacionActualizacion.confirmarLectura(defaults: defaultsActualizacion)
        precondition(!RegistroInstalacionActualizacion.comenzar(
            version: "3.1.2", compilacion: "130", actual: actual,
            defaults: defaultsActualizacion))
        precondition(RegistroInstalacionActualizacion.resolver(
            actual: actual, defaults: defaultsActualizacion) == nil)
        RegistroInstalacionActualizacion.comenzar(version: "3.2.0", compilacion: "131", actual: actual,
                                                  defaults: defaultsActualizacion)
        let versionDistinta = RegistroInstalacionActualizacion.resolver(
            actual: InfoVersion(corta: "3.3.0", compilacion: 132), defaults: defaultsActualizacion)
        if case .incompleta? = versionDistinta {} else {
            preconditionFailure("solo la versión y compilación exactas deben confirmar la instalación")
        }
        RegistroInstalacionActualizacion.confirmarLectura(defaults: defaultsActualizacion)

        let notasHTML = TextoHTMLSeguro.convertir("""
        <head><link href="https://example.invalid/estilo.css"></head>
        <h2>Novedades</h2><p>Cambio &amp; mejora &#x1F680;.</p>
        <img src="https://example.invalid/seguimiento.png">
        <script>contenidoPeligroso()</script><ul><li>Más estable</li></ul>
        """)
        precondition(notasHTML.contains("Novedades"))
        precondition(notasHTML.contains("Cambio & mejora 🚀."))
        precondition(notasHTML.contains("• Más estable"))
        precondition(!notasHTML.contains("https://") && !notasHTML.contains("contenidoPeligroso"),
                     "las notas HTML no deben conservar recursos ni contenido ejecutable")

        // Instalación nueva, sin conexiones: no es una actualización.
        let limpia = UserDefaults(suiteName: "NuvexNucleo.\(UUID().uuidString)")!
        let instalacion = Migraciones.ejecutar(defaults: limpia, version: v31, base: base, perfiles: perfiles)
        precondition(!instalacion.versionNueva && instalacion.anterior == nil)
        // Con conexiones y sin registro, se viene de Nuvex 3.0.
        try Data(perfilesJSON.utf8).write(to: perfiles)
        let legada = UserDefaults(suiteName: "NuvexNucleo.\(UUID().uuidString)")!
        let desde30 = Migraciones.ejecutar(defaults: legada, version: v31, base: base, perfiles: perfiles)
        precondition(desde30.versionNueva && desde30.anterior == "3.0" && desde30.copia != nil)
        precondition(Migraciones.perfiles(en: desde30.copia!)?.count == 1)
        for copia in Migraciones.copias(base: base) { try FileManager.default.removeItem(at: copia.url) }

        let primera = Migraciones.ejecutar(defaults: defaults, version: v30, base: base, perfiles: perfiles)
        precondition(primera.versionNueva && primera.anterior == "3.0")
        let repetida = Migraciones.ejecutar(defaults: defaults, version: v30, base: base, perfiles: perfiles)
        precondition(!repetida.versionNueva && repetida.copia == nil, "la misma versión no repite la migración")
        let actualizacion = Migraciones.ejecutar(defaults: defaults, version: v31, base: base, perfiles: perfiles)
        precondition(actualizacion.versionNueva && actualizacion.anterior == "3.0.0")
        guard let copia = actualizacion.copia else { preconditionFailure("debe haber copia antes de actualizar") }
        precondition(Migraciones.perfiles(en: copia)?.first?.name == "Oficina")
        precondition(FileManager.default.fileExists(atPath: copia.appendingPathComponent("ajustes.json").path))
        let copiaPermisos = try FileManager.default.attributesOfItem(
            atPath: copia.appendingPathComponent("profiles.json").path)[.posixPermissions] as? Int
        precondition(copiaPermisos == 0o600)
        precondition(Migraciones.copias(base: base).first?.etiqueta == "v3.0.0")
        precondition(Migraciones.copias(base: base).count == 2)

        // Rotación: se conservan las más recientes.
        for n in 0..<12 {
            _ = try Migraciones.crearCopia(etiqueta: "manual", base: base, perfiles: perfiles,
                                           ahora: Date(timeIntervalSince1970: Double(n) * 60))
        }
        Migraciones.rotar(base: base, conservar: 10)
        precondition(Migraciones.copias(base: base).count == 10)

        // Notas de versión desde el CHANGELOG.
        let changelog = "# Cambios\n\n## [3.1.0] - 2026-10-20\n\n### Añadido\n- Algo nuevo.\n\n## [3.0.0] - 2026-10-16\n- Viejo.\n"
        precondition(NotasCambios.seccion(de: "3.1.0", en: changelog) == "### Añadido\n- Algo nuevo.")
        precondition(NotasCambios.seccion(de: "9.9.9", en: changelog) == nil)

        // Resumen del guardado: qué se hizo y qué quedó pendiente.
        let todoBien = ResumenGuardado(conexiones: .hecho, contrasenas: .hecho, ayudante: .hecho)
        precondition(!todoBien.hayProblemas && todoBien.resumen == "Cambios guardados y aplicados.")
        let sinAyudante = ResumenGuardado(conexiones: .hecho, ayudante: .pendiente("al conectar"))
        precondition(sinAyudante.hayProblemas && sinAyudante.pasos.count == 2)
        precondition(sinAyudante.resumen.contains("al volver a conectar"))
        let sinLlavero = ResumenGuardado(conexiones: .hecho, contrasenas: .fallo("x"), ayudante: .enCurso)
        precondition(sinLlavero.hayProblemas && sinLlavero.enCurso && sinLlavero.resumen.contains("Llavero"))
        precondition(ResumenGuardado(conexiones: .fallo("x")).resumen == "No se guardaron los cambios")

        // Procesos: mucha salida de error no bloquea la lectura de la normal.
        let mucho = try Proceso.ejecutar("/bin/sh", args: ["-c", "head -c 300000 /dev/zero | tr '\\0' e >&2; echo listo"],
                                         limite: 10)
        precondition(mucho.codigo == 0 && mucho.salida == "listo\n" && mucho.error.utf8.count == 300_000,
                     "la salida y los errores deben leerse a la vez")
        // Un proceso que no termina se detiene al agotarse el tiempo.
        let inicio = Date()
        do {
            _ = try Proceso.ejecutar("/bin/sleep", args: ["30"], limite: 1)
            preconditionFailure("debió agotarse el tiempo")
        } catch let error as ErrorVPN {
            precondition(error.fallo?.titulo == "El motor no respondió")
        }
        precondition(Date().timeIntervalSince(inicio) < 6, "el tiempo límite debe cortar la espera")

        print("Núcleo: comprobaciones superadas")
    }
}
