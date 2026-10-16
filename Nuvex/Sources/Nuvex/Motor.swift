import AppKit
import Darwin

// MARK: - Ejecucion del motor

extension VPNModel {
    struct Resultado { let salida: String; let error: String; let codigo: Int32 }

    nonisolated static func ejecutar(args: [String]) throws -> Resultado {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Paths.nuvexctl)
        p.arguments = args
        p.environment = Paths.environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Resultado(salida: String(data: o, encoding: .utf8) ?? "",
                         error: String(data: e, encoding: .utf8) ?? "",
                         codigo: p.terminationStatus)
    }

    /// Conecta vigilando la salida del ayudante. Cuando el servidor pide el
    /// código por correo, lo solicita y lo entrega por entrada estándar.
    nonisolated static func conectarProceso(id: String, name: String) async -> Result<Void, ErrorVPN> {
        let password: String
        do { password = try await leerDelLlavero(id: id, name: name) }
        catch let error as ErrorVPN { return .failure(error) }
        catch { return .failure(ErrorVPN(mensaje: error.localizedDescription)) }
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Paths.nuvexctl)
            p.arguments = ["connect", id, "--password-stdin"]
            p.environment = Paths.environment

            let entrada = Pipe(), salida = Pipe(), errores = Pipe()
            p.standardInput = entrada
            p.standardOutput = salida
            p.standardError = errores

            let acumulado = Acumulador()

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
                    if let codigo = pedirCodigoAlUsuario(nombre: name) {
                        entrada.fileHandleForWriting.write(Data((codigo + "\n").utf8))
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
                entrada.fileHandleForWriting.write(Data((password + "\n").utf8))
            } catch {
                cont.resume(returning: .failure(ErrorVPN(mensaje: "no se pudo ejecutar nuvexctl.sh: \(error.localizedDescription)")))
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                p.waitUntilExit()
                errores.fileHandleForReading.readabilityHandler = nil
                try? entrada.fileHandleForWriting.close()
                if p.terminationStatus == 0 {
                    cont.resume(returning: .success(()))
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

/// Pide el código de verificación indicando qué VPN lo solicita. El campo es
/// visible y declara `oneTimeCode`, así macOS puede ofrecer el código recibido
/// en Mensajes o Mail.
@MainActor
func pedirCodigoAlUsuario(nombre: String) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let alerta = NSAlert()
    alerta.messageText = "Código para «\(nombre)»"
    alerta.informativeText = "El servidor pidió un código de verificación (correo, SMS o app). Nuvex no lo guarda."
    alerta.addButton(withTitle: "Conectar")
    alerta.addButton(withTitle: "Cancelar")

    let campo = NSTextField(frame: NSRect(x: 0, y: 0, width: 230, height: 34))
    campo.placeholderString = "Código"
    campo.font = .monospacedSystemFont(ofSize: 20, weight: .medium)
    campo.alignment = .center
    campo.contentType = .oneTimeCode
    campo.setAccessibilityLabel("Código de verificación para \(nombre)")
    alerta.accessoryView = campo
    alerta.window.initialFirstResponder = campo

    let respuesta = alerta.runModal()
    let valor = campo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "")
    campo.stringValue = ""
    guard respuesta == .alertFirstButtonReturn else { return nil }
    return valor.isEmpty ? nil : valor
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
