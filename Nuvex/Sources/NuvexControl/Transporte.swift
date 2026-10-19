import Darwin
import Foundation

public enum ErrorControl: Error, Equatable, CustomStringConvertible {
    case rutaDemasiadoLarga
    case sistema(String, Int32)
    case yaEnUso
    case sinServidor
    case protocolo(String)

    public var description: String {
        switch self {
        case .rutaDemasiadoLarga: return "la ruta del socket es demasiado larga"
        case .sistema(let llamada, let codigo): return "\(llamada): \(String(cString: strerror(codigo)))"
        case .yaEnUso: return "otra Nuvex ya atiende el socket de control"
        case .sinServidor: return "Nuvex no está abierta"
        case .protocolo(let detalle): return "respuesta inesperada de Nuvex: \(detalle)"
        }
    }
}

/// Quién envía una petición: el proceso y la herramienta que lo lanzó.
public struct InfoCliente: Sendable, Equatable {
    public let pid: pid_t
    /// «Claude Code», «Codex» o «Terminal».
    public let origen: String
    /// Ruta que el kernel reporta para el ejecutable conectado.
    public let ejecutable: String
}

/// Envía mensajes a un cliente. Varias tareas pueden escribir a la vez.
public final class Emisor: @unchecked Sendable {
    private let fd: Int32
    private let cerrojo = NSLock()
    private var abierto = true

    init(fd: Int32) { self.fd = fd }

    public func enviar(_ mensaje: Mensaje) {
        guard let datos = try? Linea.codificar(mensaje) else { return }
        cerrojo.lock(); defer { cerrojo.unlock() }
        guard abierto else { return }
        if !Socket.escribirTodo(fd, datos) { abierto = false }
    }
}

// MARK: - Servidor

/// Servidor de control en un socket Unix con permisos 0600 en una carpeta
/// 0700. Solo atiende a procesos del mismo usuario.
public final class ServidorSocket: @unchecked Sendable {
    public typealias Manejador = @Sendable (Peticion, InfoCliente, Emisor) async -> Mensaje
    public typealias AutorizarCliente = @Sendable (InfoCliente) -> Bool

    private let ruta: String
    private let manejador: Manejador
    private let registro: @Sendable (String) -> Void
    private let autorizarCliente: AutorizarCliente
    private let cerrojo = NSLock()
    private var fd: Int32 = -1
    private var activo = false

    public init(ruta: String, registro: @escaping @Sendable (String) -> Void = { _ in },
                autorizarCliente: @escaping AutorizarCliente = { _ in true },
                manejador: @escaping Manejador) {
        self.ruta = ruta
        self.registro = registro
        self.autorizarCliente = autorizarCliente
        self.manejador = manejador
    }

    public func iniciar() throws {
        Socket.ignorarSIGPIPE()
        if ClienteControl.hayServidor(ruta: ruta) { throw ErrorControl.yaEnUso }
        let carpeta = (ruta as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: carpeta, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(carpeta, 0o700)
        unlink(ruta)  // Socket abandonado por una ejecución anterior.

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ErrorControl.sistema("socket", errno) }
        var direccion = try Socket.direccion(ruta)
        // El socket nace con 0600: nunca hay un instante con permisos abiertos.
        let mascara = umask(0o177)
        let enlazado = withUnsafePointer(to: &direccion) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(mascara)
        guard enlazado == 0 else { let e = errno; close(fd); throw ErrorControl.sistema("bind", e) }
        chmod(ruta, 0o600)
        guard listen(fd, 8) == 0 else { let e = errno; close(fd); unlink(ruta); throw ErrorControl.sistema("listen", e) }

        cerrojo.lock(); self.fd = fd; activo = true; cerrojo.unlock()
        let hilo = Thread { [weak self] in self?.aceptar(fd) }
        hilo.name = "nuvex.control"
        hilo.start()
    }

    public func detener() {
        cerrojo.lock()
        let fd = self.fd
        activo = false
        self.fd = -1
        cerrojo.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(ruta)
    }

    private var sigueActivo: Bool { cerrojo.lock(); defer { cerrojo.unlock() }; return activo }

    private func aceptar(_ servidor: Int32) {
        while sigueActivo {
            let cliente = accept(servidor, nil, nil)
            guard cliente >= 0 else {
                if errno == EINTR { continue }
                break
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in atender(cliente) }
        }
    }

    private func atender(_ cliente: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(cliente, &uid, &gid) == 0, uid == getuid() else {
            registro("conexión de control rechazada: otro usuario")
            close(cliente)
            return
        }
        var uno: Int32 = 1
        setsockopt(cliente, SOL_SOCKET, SO_NOSIGPIPE, &uno, socklen_t(MemoryLayout<Int32>.size))
        var espera = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(cliente, SOL_SOCKET, SO_RCVTIMEO, &espera, socklen_t(MemoryLayout<timeval>.size))

        let emisor = Emisor(fd: cliente)
        let pid = Socket.pidRemoto(cliente)
        let info = InfoCliente(pid: pid, origen: Procesos.origen(de: pid),
                               ejecutable: Procesos.rutaEjecutable(pid))
        guard autorizarCliente(info) else {
            registro("conexión de control rechazada: cliente no autorizado (pid \(pid))")
            emisor.enviar(.resultado(.noPermitido, titulo: "Cliente de control no autorizado",
                                     detalle: "Usa el comando nuvex incluido con esta copia de la app."))
            close(cliente)
            return
        }
        guard let linea = Socket.leerLinea(cliente),
              let peticion = try? Linea.decodificar(Peticion.self, de: linea) else {
            emisor.enviar(.resultado(.uso, titulo: "Petición no válida"))
            close(cliente)
            return
        }
        guard peticion.version == Peticion.versionActual else {
            registro("petición de control rechazada: protocolo \(peticion.version)")
            emisor.enviar(.resultado(.uso, titulo: "Versión de protocolo no compatible",
                                     detalle: "Instala el comando nuvex incluido con esta copia de la app."))
            close(cliente)
            return
        }
        Task.detached { [manejador] in
            let resultado = await manejador(peticion, info, emisor)
            emisor.enviar(resultado)
            close(cliente)
        }
    }
}

// MARK: - Cliente

public enum ClienteControl {
    /// true si hay una Nuvex escuchando en la ruta.
    public static func hayServidor(ruta: String) -> Bool {
        guard let fd = try? conectar(ruta: ruta) else { return false }
        close(fd)
        return true
    }

    static func conectar(ruta: String) throws -> Int32 {
        Socket.ignorarSIGPIPE()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ErrorControl.sistema("socket", errno) }
        var direccion = try Socket.direccion(ruta)
        let resultado = withUnsafePointer(to: &direccion) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard resultado == 0 else { close(fd); throw ErrorControl.sinServidor }
        var uno: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &uno, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Envía la petición, entrega cada evento y devuelve el resultado final.
    public static func enviar(_ peticion: Peticion, ruta: String,
                              alEvento: (Mensaje) -> Void = { _ in }) throws -> Mensaje {
        let fd = try conectar(ruta: ruta)
        defer { close(fd) }
        guard Socket.escribirTodo(fd, try Linea.codificar(peticion)) else {
            throw ErrorControl.sistema("write", errno)
        }
        while let linea = Socket.leerLinea(fd) {
            let mensaje = try Linea.decodificar(Mensaje.self, de: linea)
            if mensaje.tipo == .resultado { return mensaje }
            alEvento(mensaje)
        }
        throw ErrorControl.protocolo("Nuvex cerró la conexión sin responder")
    }
}

// MARK: - Utilidades de socket

enum Socket {
    /// Un cliente que se va a mitad de respuesta no debe cerrar el proceso.
    /// SO_NOSIGPIPE no cubre todos los casos, así que se ignora la señal.
    static func ignorarSIGPIPE() { signal(SIGPIPE, SIG_IGN) }

    static func direccion(_ ruta: String) throws -> sockaddr_un {
        var direccion = sockaddr_un()
        direccion.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(ruta.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: direccion.sun_path) else { throw ErrorControl.rutaDemasiadoLarga }
        withUnsafeMutableBytes(of: &direccion.sun_path) { destino in
            destino.copyBytes(from: bytes)
            destino[bytes.count] = 0
        }
        direccion.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return direccion
    }

    static func escribirTodo(_ fd: Int32, _ datos: Data) -> Bool {
        datos.withUnsafeBytes { puntero in
            var enviado = 0
            while enviado < datos.count {
                let n = write(fd, puntero.baseAddress! + enviado, datos.count - enviado)
                if n < 0 { if errno == EINTR { continue }; return false }
                enviado += n
            }
            return true
        }
    }

    /// Lee hasta un salto de línea (máximo 1 MB). nil si se cierra antes.
    static func leerLinea(_ fd: Int32) -> Data? {
        var linea = Data()
        var byte: UInt8 = 0
        while linea.count < 1_048_576 {
            let n = read(fd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            guard n == 1 else { return linea.isEmpty ? nil : linea }
            if byte == 0x0A { return linea }
            linea.append(byte)
        }
        return nil
    }

    static func pidRemoto(_ fd: Int32) -> pid_t {
        var pid: pid_t = 0
        var tamano = socklen_t(MemoryLayout<pid_t>.size)
        // SOL_LOCAL = 0, LOCAL_PEERPID = 2 (sys/un.h).
        guard getsockopt(fd, 0, 2, &pid, &tamano) == 0 else { return 0 }
        return pid
    }
}

// MARK: - Procesos

public enum Procesos {
    /// Recorre los procesos padre para reconocer a Claude Code, Codex o la Terminal.
    public static func origen(de pid: pid_t) -> String {
        var actual = pid
        for _ in 0..<12 where actual > 1 {
            let ruta = rutaEjecutable(actual).lowercased()
            let nombre = (ruta as NSString).lastPathComponent
            if nombre == "claude" || ruta.contains("/claude/") || ruta.contains("claude.app") { return "Claude Code" }
            if nombre == "codex" || ruta.contains("/codex/") || ruta.contains("codex.app") { return "Codex" }
            guard let padre = padre(de: actual), padre != actual else { break }
            actual = padre
        }
        return "Terminal"
    }

    static func rutaEjecutable(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func padre(de pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var tamano = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &tamano, nil, 0) == 0, tamano > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
