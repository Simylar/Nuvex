import Darwin
import Foundation
import NuvexControl

// Comando `nuvex`: controla Nuvex desde la Terminal, Claude Code o Codex.
// Habla con la app por un socket privado; si la app no está abierta, la abre.

let ayuda = """
Uso: nuvex <comando> [opciones]

Comandos:
  estado                      Muestra las VPN y su estado (por defecto).
  conectar <vpn>              Conecta y espera el resultado.
      --no-esperar            Inicia la conexión y vuelve sin esperar.
      --limite <segundos>     Espera máxima (180 por defecto).
  desconectar <vpn>           Desconecta una VPN.
  desconectar --todas         Desconecta todas.
  codigo <vpn>                Envía el código de verificación leído de la
                              entrada estándar: printf '%s' 123456 | nuvex codigo oficina
  diagnostico                 Comprueba si todo está listo para conectar sin la persona.
      --profundo              Prueba la lectura del Llavero; puede pedir autorización.

Opciones generales:
  --json                      Una línea JSON por evento y por resultado.

<vpn> es el nombre de la conexión, una parte única de él o su id.
También se aceptan status, connect, disconnect, code y doctor.

Códigos de salida: 0 bien · 1 error · 2 uso incorrecto · 3 no permitido ·
4 hace falta la persona o hay pendientes · 5 tiempo agotado · 6 Nuvex no responde ·
7 el sandbox del asistente bloquea Nuvex: autoriza solo este CLI desde Nuvex.
"""

struct Opciones {
    var comando: Comando = .estado
    var vpn: String?
    var todas = false
    var esperar = true
    var limite: Int?
    var json = false
    var profundo = false
}

func salir(_ codigo: CodigoSalida, _ mensaje: String? = nil) -> Never {
    if let mensaje { FileHandle.standardError.write(Data((mensaje + "\n").utf8)) }
    exit(codigo.rawValue)
}

func leerOpciones() -> Opciones {
    var opciones = Opciones()
    var argumentos = Array(CommandLine.arguments.dropFirst())
    let comandos: [String: Comando] = [
        "estado": .estado, "status": .estado, "lista": .estado, "list": .estado,
        "conectar": .conectar, "connect": .conectar, "up": .conectar,
        "desconectar": .desconectar, "disconnect": .desconectar, "down": .desconectar,
        "codigo": .codigo, "código": .codigo, "code": .codigo,
        "diagnostico": .diagnostico, "diagnóstico": .diagnostico, "doctor": .diagnostico,
    ]
    if let primero = argumentos.first, !primero.hasPrefix("-") {
        if ["ayuda", "help"].contains(primero) { print(ayuda); exit(0) }
        guard let comando = comandos[primero.lowercased()] else { salir(.uso, "nuvex: comando desconocido «\(primero)»\n\n" + ayuda) }
        opciones.comando = comando
        argumentos.removeFirst()
    }
    var libres: [String] = []
    while !argumentos.isEmpty {
        let argumento = argumentos.removeFirst()
        switch argumento {
        case "-h", "--help", "--ayuda": print(ayuda); exit(0)
        case "--json": opciones.json = true
        case "--todas", "--all": opciones.todas = true
        case "--no-esperar", "--no-wait": opciones.esperar = false
        case "--esperar", "--wait": opciones.esperar = true
        case "--profundo", "--deep": opciones.profundo = true
        case "--limite", "--timeout":
            guard let valor = argumentos.first, let segundos = Int(valor) else { salir(.uso, "nuvex: --limite necesita segundos") }
            argumentos.removeFirst()
            opciones.limite = segundos
        default:
            if argumento.hasPrefix("-") { salir(.uso, "nuvex: opción desconocida «\(argumento)»") }
            libres.append(argumento)
        }
    }
    if !libres.isEmpty { opciones.vpn = libres.joined(separator: " ") }
    switch opciones.comando {
    case .conectar, .codigo:
        if opciones.vpn == nil { salir(.uso, "nuvex: indica qué VPN. Consulta las disponibles con: nuvex estado") }
    case .desconectar:
        if opciones.vpn == nil && !opciones.todas { salir(.uso, "nuvex: indica qué VPN o usa --todas") }
    default:
        break
    }
    if opciones.comando != .desconectar, opciones.todas {
        salir(.uso, "nuvex: --todas solo se puede usar con desconectar")
    }
    if opciones.comando != .conectar, (!opciones.esperar || opciones.limite != nil) {
        salir(.uso, "nuvex: --esperar, --no-esperar y --limite solo se pueden usar con conectar")
    }
    if opciones.comando != .diagnostico, opciones.profundo {
        salir(.uso, "nuvex: --profundo solo se puede usar con diagnostico")
    }
    if let limite = opciones.limite, !(10...600).contains(limite) {
        salir(.uso, "nuvex: --limite debe estar entre 10 y 600 segundos")
    }
    if !libres.isEmpty, ![Comando.conectar, .desconectar, .codigo].contains(opciones.comando) {
        salir(.uso, "nuvex: \(opciones.comando.rawValue) no acepta una conexión")
    }
    return opciones
}

/// La app que contiene este comando, o la de Aplicaciones.
func rutaApp() -> String {
    let ejecutable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        .resolvingSymlinksInPath().path
    if let rango = ejecutable.range(of: ".app/Contents/") {
        return String(ejecutable[..<rango.lowerBound]) + ".app"
    }
    return "/Applications/Nuvex.app"
}

/// true si este proceso corre dentro de un sandbox de macOS, como el que usan
/// Codex o Claude Code para ejecutar comandos.
func procesoAislado() -> Bool {
    typealias Comprobar = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
    // RTLD_DEFAULT; sandbox_check no está en los encabezados públicos.
    if let simbolo = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check"),
       unsafeBitCast(simbolo, to: Comprobar.self)(getpid(), nil, 0) > 0 {
        return true
    }
    return ProcessInfo.processInfo.environment["CODEX_SANDBOX"] != nil
}

/// Dentro de un sandbox, macOS no deja abrir apps (`open` responde
/// kLSNoExecutableErr aunque la app exista) ni conectar con su socket. Lanzar el
/// ejecutable desde aquí tampoco sirve: Nuvex heredaría el aislamiento.
func salirAislado(json: Bool) -> Never {
    let titulo = "El sandbox del asistente bloquea Nuvex"
    let detalle = "Este comando corre en un entorno aislado que no permite abrir Nuvex ni comunicarse con ella. "
        + "Autoriza de forma persistente solo ~/.local/bin/nuvex desde Ajustes de Nuvex › Automatización, "
        + "o aprueba únicamente este comando una vez. No desactives globalmente el sandbox. "
        + "No abras el ejecutable de Nuvex directamente."
    if json, let datos = try? Linea.codificar(Mensaje.resultado(.aislado, motivo: .aislamiento, titulo: titulo, detalle: detalle)) {
        FileHandle.standardOutput.write(datos)
        exit(CodigoSalida.aislado.rawValue)
    }
    salir(.aislado, "nuvex: \(titulo).\n\(detalle)")
}

func asegurarApp(ruta: String, json: Bool) {
    switch ClienteControl.disponibilidad(ruta: ruta) {
    case .abierta: return
    case .bloqueada: salirAislado(json: json)
    case .cerrada: break
    }
    let aislado = procesoAislado()
    let app = rutaApp()
    guard FileManager.default.fileExists(atPath: app) else { salir(.sinApp, "nuvex: no se encontró Nuvex en \(app)") }
    if !json { FileHandle.standardError.write(Data("Abriendo Nuvex…\n".utf8)) }
    let abrir = Process()
    abrir.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    abrir.arguments = ["-g", app]
    if aislado { abrir.standardError = FileHandle.nullDevice }
    var abierta = false
    if (try? abrir.run()) != nil {
        abrir.waitUntilExit()
        abierta = abrir.terminationStatus == 0
    }
    if !abierta, aislado { salirAislado(json: json) }
    let limite = Date().addingTimeInterval(15)
    while Date() < limite {
        switch ClienteControl.disponibilidad(ruta: ruta) {
        case .abierta: return
        case .bloqueada: salirAislado(json: json)
        case .cerrada: usleep(250_000)
        }
    }
    if aislado { salirAislado(json: json) }
    salir(.sinApp, "nuvex: Nuvex no respondió. Ábrela desde Aplicaciones y vuelve a intentarlo.")
}

// MARK: - Salida legible

let horas: DateFormatter = {
    let formato = DateFormatter()
    formato.dateStyle = .none
    formato.timeStyle = .short
    return formato
}()

func describir(_ conexion: ConexionInfo) -> String {
    let simbolos: [EstadoConexionRemota: String] = [.conectada: "●", .conectando: "◐", .esperandoCodigo: "◐", .error: "✕", .caida: "!"]
    let estados: [EstadoConexionRemota: String] = [.conectada: "conectada", .conectando: "conectando…",
        .esperandoCodigo: "esperando el código", .error: "error", .caida: "se desconectó", .desconectada: "desconectada"]
    var partes = [estados[conexion.estado] ?? conexion.estado.rawValue]
    if let ip = conexion.ip { partes.append(ip) }
    if let desde = conexion.desde { partes.append("desde " + horas.string(from: desde)) }
    if let error = conexion.error { partes.append(error) }
    if conexion.codigoPorCorreo { partes.append("código por correo") }
    if !conexion.permitida { partes.append("no disponible para asistentes") }
    return "\(simbolos[conexion.estado] ?? "○") \(conexion.nombre)  —  \(partes.joined(separator: " · "))"
}

func mostrar(_ mensaje: Mensaje, json: Bool) {
    if json {
        if let datos = try? Linea.codificar(mensaje) { FileHandle.standardOutput.write(datos) }
        return
    }
    if mensaje.tipo == .evento {
        let texto = [mensaje.titulo, mensaje.detalle].compactMap { $0 }.joined(separator: ". ")
        FileHandle.standardError.write(Data(("… " + texto + "\n").utf8))
        return
    }
    if let titulo = mensaje.titulo { print(titulo) }
    if let detalle = mensaje.detalle, !detalle.isEmpty { print(detalle) }
    if let comprobaciones = mensaje.comprobaciones {
        for comprobacion in comprobaciones {
            print("\(comprobacion.ok ? "✓" : "✗") \(comprobacion.nombre): \(comprobacion.detalle)")
        }
    } else if let conexiones = mensaje.conexiones, mensaje.titulo == nil || mensaje.ok {
        if conexiones.isEmpty { print("No hay VPN configuradas. Añádelas desde el menú de Nuvex.") }
        conexiones.forEach { print(describir($0)) }
    }
}

// MARK: - Principal

signal(SIGPIPE, SIG_IGN)
let opciones = leerOpciones()
let ruta = RutaControl.socket(home: RutaControl.homeUsuarioActual)

var peticion = Peticion(comando: opciones.comando, vpn: opciones.vpn, todas: opciones.todas ? true : nil,
                        esperar: opciones.esperar, limite: opciones.limite,
                        profundo: opciones.profundo ? true : nil)
if opciones.comando == .codigo {
    // El código llega por la entrada estándar: no queda en el historial ni en ps.
    if isatty(STDIN_FILENO) != 0 { FileHandle.standardError.write(Data("Código: ".utf8)) }
    let leido = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !leido.isEmpty else { salir(.uso, "nuvex: no llegó ningún código por la entrada estándar") }
    peticion.codigo = leido
}

asegurarApp(ruta: ruta, json: opciones.json)
do {
    let esperaOperacion: TimeInterval
    if opciones.comando == .conectar, opciones.esperar {
        esperaOperacion = TimeInterval(opciones.limite ?? 180) + 30
    } else if opciones.comando == .diagnostico, opciones.profundo {
        esperaOperacion = 300
    } else if opciones.comando == .conectar || opciones.comando == .desconectar {
        // Desconectar puede esperar hasta 20 s y consultar de nuevo el motor
        // durante otros 20 s. La confirmación en la Mac tiene su propia espera.
        esperaOperacion = 75
    } else {
        esperaOperacion = 30
    }
    let resultado = try ClienteControl.enviar(peticion, ruta: ruta, limiteRespuesta: esperaOperacion) {
        mostrar($0, json: opciones.json)
    }
    mostrar(resultado, json: opciones.json)
    exit((resultado.salida ?? .error).rawValue)
} catch ErrorControl.sinServidor {
    salir(.sinApp, "nuvex: Nuvex no está abierta.")
} catch ErrorControl.bloqueado {
    salirAislado(json: opciones.json)
} catch ErrorControl.tiempoAgotado {
    salir(.sinApp, "nuvex: Nuvex dejó de responder durante la operación.")
} catch {
    salir(.error, "nuvex: \(error)")
}
