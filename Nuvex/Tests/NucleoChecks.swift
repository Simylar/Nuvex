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
        precondition(vacio.ajustes.politicaAsistentes == .permitir)

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
        precondition(raro.ajustes.politicaAsistentes == .permitir, "un valor desconocido usa el de serie")
        let v2 = try ArchivoAjustes.leer(Data(#"{"version":2}"#.utf8))
        let v1 = try ArchivoAjustes.leer(Data(#"{"version":1}"#.utf8))
        precondition(v2.esMasNuevo && !v1.esMasNuevo)

        // Permisos: se conserva «Conectar sin preguntar» como valor inicial y
        // las exclusiones por conexión prevalecen sobre la política global.
        var permisosAsistentes = AjustesApp()
        precondition(permisosAsistentes.decisionParaAsistente(conexion: "vpn-a") == .permitir)
        permisosAsistentes.politicaAsistentes = .preguntar
        precondition(permisosAsistentes.decisionParaAsistente(conexion: "vpn-a") == .confirmar)
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

        // Migraciones: la primera instalación no es una actualización; una
        // versión nueva copia la configuración; repetir no hace nada.
        let defaults = UserDefaults(suiteName: "NuvexNucleo.\(UUID().uuidString)")!
        let perfiles = base.appendingPathComponent("profiles.json")
        let perfilesJSON = #"{"version":2,"profiles":[{"id":"vpn-a","name":"Oficina","server":"vpn.empresa.com:443","username":"ana","trust":"system","realm":"","manageRoutes":true,"manageDNS":true,"enabled":true}]}"#
        let v30 = InfoVersion(corta: "3.0.0", compilacion: 3)
        let v31 = InfoVersion(corta: "3.1.0", compilacion: 9)
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
