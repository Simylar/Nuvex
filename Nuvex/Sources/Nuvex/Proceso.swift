import Foundation

/// Ejecuta un proceso con tiempo límite y devuelve su salida.
enum Proceso {
    struct Resultado { let salida: String; let error: String; let codigo: Int32 }

    /// Lee la salida y los errores a la vez: si se leyeran por turnos y el
    /// proceso llenara la tubería de errores mientras se espera el fin de la
    /// salida, ambos quedarían bloqueados. Si se supera `limite`, se detiene el
    /// proceso (SIGTERM y, si no basta, SIGKILL) y se lanza un error.
    nonisolated static func ejecutar(_ ruta: String, args: [String], entorno: [String: String]? = nil,
                                     limite: TimeInterval?) throws -> Resultado {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ruta)
        p.arguments = args
        if let entorno { p.environment = entorno }
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let terminado = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in terminado.signal() }
        try p.run()

        let lecturas = DispatchGroup()
        let salida = Lectura(out.fileHandleForReading, grupo: lecturas)
        let errores = Lectura(err.fileHandleForReading, grupo: lecturas)

        let espera: DispatchTime = limite.map { .now() + $0 } ?? .distantFuture
        if terminado.wait(timeout: espera) == .timedOut {
            p.terminate()
            if terminado.wait(timeout: .now() + 3) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                terminado.wait()
            }
            let segundos = Int(limite ?? 0)
            Log.escribir("«\(URL(fileURLWithPath: ruta).lastPathComponent) \(args.first ?? "")» no respondió en \(segundos) s; se detuvo")
            throw ErrorVPN(mensaje: "El motor de Nuvex no respondió en \(segundos) segundos y se detuvo la operación. Vuelve a intentarlo; si se repite, revisa el registro.",
                           fallo: Fallo(titulo: "El motor no respondió",
                                        detalle: "La operación tardó más de \(segundos) segundos y se detuvo.",
                                        accion: .reintentar("Reintentar")))
        }
        // Un proceso hijo que siga vivo puede mantener abiertas las tuberías:
        // no se espera por él más de unos segundos.
        _ = lecturas.wait(timeout: .now() + 5)
        return Resultado(salida: String(data: salida.datos, encoding: .utf8) ?? "",
                         error: String(data: errores.datos, encoding: .utf8) ?? "",
                         codigo: p.terminationStatus)
    }

    /// Lee una tubería hasta el final en otra cola.
    private final class Lectura: @unchecked Sendable {
        private let cerrojo = NSLock()
        private var leido = Data()

        var datos: Data {
            cerrojo.lock(); defer { cerrojo.unlock() }
            return leido
        }

        init(_ fh: FileHandle, grupo: DispatchGroup) {
            grupo.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                let d = fh.readDataToEndOfFile()
                cerrojo.lock()
                leido = d
                cerrojo.unlock()
                grupo.leave()
            }
        }
    }
}
