import Darwin
import Foundation

public enum ErrorControl: Error, Equatable, CustomStringConvertible {
    case rutaDemasiadoLarga
    case sistema(String, Int32)
    case yaEnUso
    case sinServidor
    /// El sistema negó el acceso al socket: el proceso corre dentro de un
    /// sandbox, como el de Codex, que no permite comunicarse con otras apps.
    case bloqueado
    case tiempoAgotado
    case protocolo(String)

    public var description: String {
        switch self {
        case .rutaDemasiadoLarga: return "la ruta del socket es demasiado larga"
        case .sistema(let llamada, let codigo): return "\(llamada): \(String(cString: strerror(codigo)))"
        case .yaEnUso: return "otra Nuvex ya atiende el socket de control"
        case .sinServidor: return "Nuvex no está abierta"
        case .bloqueado: return "el aislamiento del proceso impide comunicarse con Nuvex"
        case .tiempoAgotado: return "Nuvex dejó de responder durante la operación"
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

    /// Después de un diálogo en la Mac, evita ejecutar una orden cuyo cliente
    /// ya agotó la espera o cerró la Terminal.
    public func clienteConectado() -> Bool {
        cerrojo.lock(); defer { cerrojo.unlock() }
        guard abierto else { return false }
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if n == 0 { abierto = false; return false }
        if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            abierto = false
            return false
        }
        return true
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
    private let alInterrumpirse: @Sendable () -> Void
    private let cerrojo = NSLock()
    private var fd: Int32 = -1
    private var activo = false
    private var escucha: DispatchSourceRead?

    public init(ruta: String, registro: @escaping @Sendable (String) -> Void = { _ in },
                autorizarCliente: @escaping AutorizarCliente = { _ in true },
                alInterrumpirse: @escaping @Sendable () -> Void = {},
                manejador: @escaping Manejador) {
        self.ruta = ruta
        self.registro = registro
        self.autorizarCliente = autorizarCliente
        self.alInterrumpirse = alInterrumpirse
        self.manejador = manejador
    }

    /// Estado operativo real, no solo el resultado del arranque. El archivo
    /// puede desaparecer mientras el descriptor sigue abierto, dejando un
    /// servidor imposible de alcanzar si no se comprueba explícitamente.
    public var estaDisponible: Bool {
        cerrojo.lock()
        let escuchando = activo && fd >= 0
        cerrojo.unlock()
        return escuchando && FileManager.default.fileExists(atPath: ruta)
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
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let e = errno; close(fd); unlink(ruta); throw ErrorControl.sistema("fcntl", e)
        }

        let escucha = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        escucha.setEventHandler { [weak self] in self?.aceptar(fd) }
        // El descriptor se cierra cuando ya no hay un manejador usándolo.
        // Cerrar desde otro hilo mientras accept espera puede bloquear macOS.
        escucha.setCancelHandler { close(fd) }
        cerrojo.lock(); self.fd = fd; activo = true; self.escucha = escucha; cerrojo.unlock()
        escucha.resume()
    }

    public func detener() {
        cerrojo.lock()
        let escucha = self.escucha
        activo = false
        self.fd = -1
        self.escucha = nil
        cerrojo.unlock()
        guard let escucha else { return }
        escucha.cancel()
        unlink(ruta)
    }

    private func sigueActivo(_ servidor: Int32) -> Bool {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return activo && fd == servidor
    }

    private func aceptar(_ servidor: Int32) {
        while sigueActivo(servidor) {
            let cliente = accept(servidor, nil, nil)
            guard cliente >= 0 else {
                if errno == EINTR { continue }
                if errno == ECONNABORTED { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                interrumpir(servidor, error: errno)
                return
            }
            // Los clientes siguen usando lectura bloqueante con sus límites;
            // no deben heredar O_NONBLOCK del descriptor de escucha.
            let flags = fcntl(cliente, F_GETFL, 0)
            guard flags >= 0, fcntl(cliente, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
                close(cliente)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in atender(cliente) }
        }
    }

    private func interrumpir(_ servidor: Int32, error: Int32) {
        cerrojo.lock()
        guard activo, fd == servidor else { cerrojo.unlock(); return }
        let escucha = self.escucha
        activo = false
        fd = -1
        self.escucha = nil
        cerrojo.unlock()
        escucha?.cancel()
        unlink(ruta)
        registro("servidor de control interrumpido en accept: \(String(cString: strerror(error)))")
        alInterrumpirse()
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
            emisor.enviar(.resultado(.noPermitido, motivo: .clienteNoAutorizado,
                                     titulo: "Cliente de control no autorizado",
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
            emisor.enviar(.resultado(.uso, motivo: .protocoloIncompatible,
                                     titulo: "Versión de protocolo no compatible",
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
    public enum Disponibilidad: Sendable, Equatable {
        case abierta
        case cerrada
        case bloqueada
    }

    /// true si hay una Nuvex escuchando en la ruta.
    public static func hayServidor(ruta: String) -> Bool {
        disponibilidad(ruta: ruta) == .abierta
    }

    /// Distingue una Nuvex cerrada de un socket al que el sistema niega el acceso.
    public static func disponibilidad(ruta: String) -> Disponibilidad {
        do {
            close(try conectar(ruta: ruta))
            return .abierta
        } catch ErrorControl.bloqueado {
            return .bloqueada
        } catch {
            return .cerrada
        }
    }

    static func conectar(ruta: String) throws -> Int32 {
        Socket.ignorarSIGPIPE()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let e = errno
            throw e == EPERM ? ErrorControl.bloqueado : ErrorControl.sistema("socket", e)
        }
        var direccion = try Socket.direccion(ruta)
        let resultado = withUnsafePointer(to: &direccion) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard resultado == 0 else {
            // El socket es 0600 y del mismo usuario: un EPERM o EACCES solo
            // puede venir de un sandbox que prohíbe la conexión.
            let e = errno
            close(fd)
            throw e == EPERM || e == EACCES ? ErrorControl.bloqueado : ErrorControl.sinServidor
        }
        var uno: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &uno, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Envía la petición, entrega cada evento y devuelve el resultado final.
    public static func enviar(_ peticion: Peticion, ruta: String, limiteRespuesta: TimeInterval = 30,
                              alEvento: (Mensaje) -> Void = { _ in }) throws -> Mensaje {
        let fd = try conectar(ruta: ruta)
        defer { close(fd) }
        let limite = max(0.1, limiteRespuesta)
        var espera = timeval(tv_sec: Int(limite), tv_usec: Int32((limite.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &espera, socklen_t(MemoryLayout<timeval>.size))
        guard Socket.escribirTodo(fd, try Linea.codificar(peticion)) else {
            throw ErrorControl.sistema("write", errno)
        }
        while true {
            guard let linea = Socket.leerLinea(fd) else {
                if errno == EAGAIN || errno == EWOULDBLOCK { throw ErrorControl.tiempoAgotado }
                throw ErrorControl.protocolo("Nuvex cerró la conexión sin responder")
            }
            let mensaje = try Linea.decodificar(Mensaje.self, de: linea)
            if mensaje.tipo == .resultado { return mensaje }
            alEvento(mensaje)
        }
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
            errno = 0
            let n = read(fd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            guard n == 1 else { return linea.isEmpty ? nil : linea }
            if byte == 0x0A { return linea }
            linea.append(byte)
        }
        return nil
    }

    static func pidRemoto(_ fd: Int32) -> pid_t {
        // LOCAL_PEERTOKEN contiene la identidad autenticada por el kernel y
        // evita aceptar un PID aportado por el cliente. En conexiones reales
        // LOCAL_PEERPID puede informar éxito pero entregar cero.
        var token = audit_token_t()
        var tamano = socklen_t(MemoryLayout<audit_token_t>.size)
        // SOL_LOCAL = 0, LOCAL_PEERTOKEN = 6 (sys/un.h).
        if getsockopt(fd, 0, 6, &token, &tamano) == 0 {
            let pidAuditado = audit_token_to_pid(token)
            if pidAuditado > 0 { return pidAuditado }
        }

        var pid: pid_t = 0
        tamano = socklen_t(MemoryLayout<pid_t>.size)
        // Compatibilidad defensiva si una versión futura no ofrece el token.
        // SOL_LOCAL = 0, LOCAL_PEERPID = 2 (sys/un.h).
        guard getsockopt(fd, 0, 2, &pid, &tamano) == 0 else { return 0 }
        return pid > 0 ? pid : 0
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
