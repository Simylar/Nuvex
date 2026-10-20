import AppKit
import Darwin

// MARK: - Ejecucion del motor

extension VPNModel {
    typealias Resultado = Proceso.Resultado

    /// Tiempo máximo de cada orden del motor. `install-helper` no tiene límite:
    /// espera al diálogo de administrador de macOS, que controla la persona.
    nonisolated static func limite(para args: [String]) -> TimeInterval? {
        switch args.first {
        case "list": return 20
        case "stop": return 30
        case "config": return args.dropFirst().first == "set-all" ? 45 : 15
        case "install-helper": return nil
        default: return 30
        }
    }

    /// Ejecuta una orden del motor con su tiempo límite.
    nonisolated static func ejecutar(args: [String]) throws -> Resultado {
        try ejecutar(args: args, limite: limite(para: args))
    }

    nonisolated static func ejecutar(args: [String], limite: TimeInterval?) throws -> Resultado {
        try Proceso.ejecutar(Paths.nuvexctl, args: args, entorno: Paths.environment, limite: limite)
    }

    /// Conecta vigilando la salida del ayudante. Cuando el servidor pide el
    /// código por correo, lo solicita y lo entrega por entrada estándar.
    nonisolated static func conectarProceso(id: String, name: String) async -> Result<Void, ErrorVPN> {
        // Los correos con el código se buscan a partir de este momento.
        let inicioIntento = Date()
        let acumulado = Acumulador()
        // Registrado desde ya: se puede cancelar mientras se lee el Llavero.
        IntentosConexion.registrar(id, proceso: nil, acumulado: acumulado)
        let password: String
        do { password = try await leerDelLlavero(id: id, name: name) }
        catch let error as ErrorVPN { IntentosConexion.retirar(id, acumulado: acumulado); return .failure(error) }
        catch {
            IntentosConexion.retirar(id, acumulado: acumulado)
            return .failure(ErrorVPN(mensaje: error.localizedDescription))
        }
        if acumulado.detenidoPorPersona {
            IntentosConexion.retirar(id, acumulado: acumulado)
            return .failure(ErrorVPN(mensaje: "Conexión cancelada.", fallo: .canceladaPorPersona))
        }
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Paths.nuvexctl)
            p.arguments = ["connect", id, "--password-stdin"]
            p.environment = Paths.environment

            // La salida normal va a la misma tubería que los errores: así se
            // lee entera y no puede llenarse sin que nadie la vacíe.
            let entrada = Pipe(), errores = Pipe()
            p.standardInput = entrada
            p.standardOutput = errores
            p.standardError = errores

            errores.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                // EOF también dispara el manejador. Dejarlo registrado provoca
                // un bucle de lecturas vacías e impide cerrar el intento.
                guard !d.isEmpty else {
                    fh.readabilityHandler = nil
                    return
                }
                let texto = String(data: d, encoding: .utf8) ?? ""
                let necesitaCodigo = acumulado.anadir(texto)
                guard necesitaCodigo else { return }
                Task { @MainActor in
                    if let codigo = await SolicitudCodigo.obtener(perfilID: id, nombre: name, inicio: inicioIntento) {
                        // Si el motor ya terminó, escribir falla sin cerrar la app.
                        try? entrada.fileHandleForWriting.write(contentsOf: Data((codigo + "\n").utf8))
                        // Cerrar es imprescindible, no cortesia: al otro lado
                        // hay un lector alimentando al motor VPN, y sin EOF se
                        // queda bloqueado para siempre esperando mas entrada.
                        try? entrada.fileHandleForWriting.close()
                    } else {
                        acumulado.marcarCancelado()
                        try? entrada.fileHandleForWriting.close()
                    }
                }
            }

            do {
                try p.run()
                try? entrada.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
            } catch {
                IntentosConexion.retirar(id, acumulado: acumulado)
                cont.resume(returning: .failure(ErrorVPN(mensaje: "no se pudo ejecutar nuvexctl.sh: \(error.localizedDescription)")))
                return
            }
            IntentosConexion.registrar(id, proceso: p, acumulado: acumulado)
            // Cancelado justo mientras arrancaba.
            if acumulado.detenidoPorPersona {
                DispatchQueue.global(qos: .userInitiated).async { IntentosConexion.detener(id, proceso: p) }
            }

            // El ayudante abandona el intento a los 300 s. Si por lo que sea el
            // proceso sigue vivo después, se detiene para no quedar «conectando».
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + IntentosConexion.limite) {
                guard p.isRunning else { return }
                Log.escribir("el intento de conectar \(id) superó \(Int(IntentosConexion.limite)) s; se detiene")
                acumulado.marcarAgotado()
                IntentosConexion.detener(id, proceso: p)
            }

            DispatchQueue.global(qos: .userInitiated).async {
                p.waitUntilExit()
                IntentosConexion.retirar(id, acumulado: acumulado)
                errores.fileHandleForReading.readabilityHandler = nil
                // Si el motor terminó con la ventana del código abierta, se cierra.
                Task { @MainActor in SolicitudCodigo.abiertas[id]?.cancelar() }
                try? entrada.fileHandleForWriting.close()
                // Primero la cancelación: si el túnel subió justo al cancelar,
                // `stop` ya lo detuvo y no debe darse por conectado.
                if acumulado.detenidoPorPersona {
                    Log.escribir("intento de conectar \(id) cancelado")
                    cont.resume(returning: .failure(ErrorVPN(mensaje: "Conexión cancelada.", fallo: .canceladaPorPersona)))
                } else if p.terminationStatus == 0 {
                    cont.resume(returning: .success(()))
                } else if acumulado.agotado {
                    cont.resume(returning: .failure(ErrorVPN(mensaje: "La conexión tardó demasiado.", fallo: Fallo(
                        titulo: "La conexión tardó demasiado",
                        detalle: "El servidor no completó la conexión en \(Int(IntentosConexion.limite / 60)) minutos y Nuvex detuvo el intento.",
                        accion: .reintentar("Reintentar"), codigo: .agotado))))
                } else {
                    let output = acumulado.texto
                    Log.escribir("fallo al conectar \(id) (código \(p.terminationStatus)): \(output.split(separator: "\n").suffix(8).joined(separator: " | "))")
                    let fallo = Fallo.interpretar(output, codigoCancelado: acumulado.cancelado)
                    cont.resume(returning: .failure(ErrorVPN(mensaje: fallo.detalle, fallo: fallo)))
                }
            }
        }
    }
}

/// Acumula la salida de error del proceso y detecta el prompt del codigo.
/// Es una clase con cerrojo porque el manejador de lectura se ejecuta en una
/// cola distinta de la principal.
final class Acumulador: @unchecked Sendable {
    private let cerrojo = NSLock()
    private var buffer = ""
    private var yaPedido = false
    private var codigoCancelado = false
    private var porPersona = false
    private var porTiempo = false

    var texto: String {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return buffer
    }

    var cancelado: Bool {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return codigoCancelado
    }

    func marcarCancelado() {
        cerrojo.lock(); defer { cerrojo.unlock() }
        codigoCancelado = true
    }

    /// La persona pulsó «Cancelar» mientras se conectaba.
    var detenidoPorPersona: Bool {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return porPersona
    }

    func marcarDetenidoPorPersona() {
        cerrojo.lock(); defer { cerrojo.unlock() }
        porPersona = true
    }

    var agotado: Bool {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return porTiempo
    }

    func marcarAgotado() {
        cerrojo.lock(); defer { cerrojo.unlock() }
        porTiempo = true
    }

    /// Devuelve true la primera vez que aparece el prompt del codigo.
    func anadir(_ s: String) -> Bool {
        cerrojo.lock(); defer { cerrojo.unlock() }
        buffer += s
        guard !yaPedido else { return false }
        // el motor señala que necesita el código para el codigo del correo.
        if buffer.contains("NUVEX_OTP_REQUIRED") {
            yaPedido = true
            return true
        }
        return false
    }
}

/// Intentos de conexión en marcha, para poder cancelarlos. Cancelar es
/// seguro: `stop` detiene el motor del túnel a medio establecer y el proceso
/// que lo vigila termina solo.
enum IntentosConexion {
    /// Algo más que los 300 s del ayudante, que es quien decide primero.
    static let limite: TimeInterval = 330

    private static let cerrojo = NSLock()
    nonisolated(unsafe) private static var enCurso: [String: (proceso: Process?, acumulado: Acumulador)] = [:]

    /// Cancelaciones pedidas antes de que el intento llegara a registrarse.
    nonisolated(unsafe) private static var pendientes: Set<String> = []

    /// Se llama justo antes de lanzar un intento nuevo.
    static func preparar(_ id: String) {
        cerrojo.lock(); defer { cerrojo.unlock() }
        pendientes.remove(id)
    }

    static func registrar(_ id: String, proceso: Process?, acumulado: Acumulador) {
        cerrojo.lock(); defer { cerrojo.unlock() }
        enCurso[id] = (proceso, acumulado)
        if pendientes.remove(id) != nil { acumulado.marcarDetenidoPorPersona() }
    }

    static func retirar(_ id: String, acumulado: Acumulador) {
        cerrojo.lock(); defer { cerrojo.unlock() }
        if enCurso[id]?.acumulado === acumulado { enCurso[id] = nil }
    }

    /// Cancela el intento de una conexión.
    @discardableResult
    static func cancelar(_ id: String) -> Bool {
        cerrojo.lock()
        let intento = enCurso[id]
        if intento == nil { pendientes.insert(id) }
        cerrojo.unlock()
        guard let intento else { return false }
        intento.acumulado.marcarDetenidoPorPersona()
        // Si aún no arrancó el proceso, el intento se detiene antes de lanzarlo.
        if let proceso = intento.proceso {
            DispatchQueue.global(qos: .userInitiated).async { detener(id, proceso: proceso) }
        }
        return true
    }

    /// Detiene el túnel a medio establecer y, si hace falta, el proceso que lo vigila.
    static func detener(_ id: String, proceso: Process) {
        _ = try? VPNModel.ejecutar(args: ["stop", id])
        // Sin el motor, el vigilante termina en un segundo; si no, se le ayuda.
        for _ in 0..<5 where proceso.isRunning { Thread.sleep(forTimeInterval: 1) }
        if proceso.isRunning { proceso.terminate() }
    }
}

// MARK: - Detalles del túnel

/// Completa IP, interfaz, rutas y hora de inicio de las VPN conectadas a
/// partir de información pública del sistema (ps, ifconfig, netstat). No
/// necesita el ayudante ni permisos de administrador.
enum DetallesTunel {
    static func completar(_ lista: [VPNStatus]) -> [VPNStatus] {
        let conectadas = lista.filter { $0.connected && $0.pid > 0 }
        guard !conectadas.isEmpty else { return lista }

        let procesos = ejecutar("/bin/ps", ["-A", "-o", "pid=,ppid=,comm="])
            .split(separator: "\n").compactMap { linea -> (pid: Int, ppid: Int, comando: String)? in
                let partes = linea.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard partes.count == 3, let pid = Int(partes[0]), let ppid = Int(partes[1]) else { return nil }
                return (pid, ppid, String(partes[2]))
            }
        // pppd escribe /var/run/pppN.pid con su PID; así se asocia cada túnel
        // con su interfaz aunque haya varias VPN a la vez.
        var interfazDePPPD: [Int: String] = [:]
        let archivos = (try? FileManager.default.contentsOfDirectory(atPath: "/var/run")) ?? []
        for archivo in archivos where archivo.hasPrefix("ppp") && archivo.hasSuffix(".pid") {
            guard let contenido = try? String(contentsOfFile: "/var/run/" + archivo, encoding: .utf8),
                  let pid = Int(contenido.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) ?? "")
            else { continue }
            interfazDePPPD[pid] = String(archivo.dropLast(4))
        }
        let interfacesPPP = ejecutar("/sbin/ifconfig", ["-l"])
            .split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.hasPrefix("ppp") }
        let rutas = ejecutar("/usr/sbin/netstat", ["-rn", "-f", "inet"]).split(separator: "\n")
            .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }

        return lista.map { vpn in
            guard vpn.connected, vpn.pid > 0 else { return vpn }
            var completa = vpn
            completa.inicio = inicioDeProceso(vpn.pid)
            let hijos = procesos.filter { $0.ppid == vpn.pid && $0.comando.hasSuffix("pppd") }
            var interfaz = hijos.compactMap { interfazDePPPD[$0.pid] }.first
            if interfaz == nil, conectadas.count == 1, interfacesPPP.count == 1 {
                interfaz = interfacesPPP.first
            }
            guard let interfaz else { return completa }
            completa.iface = interfaz
            let config = ejecutar("/sbin/ifconfig", [interfaz])
            if let linea = config.split(separator: "\n").first(where: { $0.contains("inet ") }) {
                let partes = linea.split(whereSeparator: \.isWhitespace)
                if let i = partes.firstIndex(of: "inet"), i + 1 < partes.count {
                    completa.ip = String(partes[i + 1])
                }
            }
            completa.networks = rutas.filter { $0.count >= 4 && $0[3] == interfaz }.map { $0[0] }
            return completa
        }
    }

    private static func inicioDeProceso(_ pid: Int) -> Date? {
        var info = kinfo_proc()
        var tamano = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &tamano, nil, 0) == 0, tamano > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    private static func ejecutar(_ ruta: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ruta)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let datos = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: datos, encoding: .utf8) ?? ""
    }
}
