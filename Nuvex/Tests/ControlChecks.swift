import Darwin
import Foundation

/// Comprobaciones del protocolo y del socket de control con un servidor real.
@main
struct ControlChecks {
    static func main() async throws {
        // Modo auxiliar: informa la disponibilidad que ve un proceso aislado.
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--sondear" {
            print(ClienteControl.disponibilidad(ruta: CommandLine.arguments[2]))
            return
        }

        let conexiones = [
            ConexionInfo(id: "vpn-1", nombre: "Oficina central", estado: .desconectada, permitida: true, codigoPorCorreo: false),
            ConexionInfo(id: "vpn-2", nombre: "Prepa · Sedes", estado: .conectada, ip: "10.0.0.2", permitida: true, codigoPorCorreo: true),
            ConexionInfo(id: "vpn-3", nombre: "Cliente Norte", estado: .desconectada, permitida: false, codigoPorCorreo: false),
            ConexionInfo(id: "vpn-4", nombre: "Cliente Sur", estado: .desconectada, permitida: true, codigoPorCorreo: false),
        ]

        // Búsqueda por id, nombre sin acentos ni mayúsculas y prefijo único.
        precondition(Busqueda.buscar("vpn-2", en: conexiones) == .una(conexiones[1]))
        precondition(Busqueda.buscar("oficina central", en: conexiones) == .una(conexiones[0]))
        precondition(Busqueda.buscar("OFICINA", en: conexiones) == .una(conexiones[0]))
        precondition(Busqueda.buscar("prepa sedes", en: conexiones) == .una(conexiones[1]))
        precondition(Busqueda.buscar("prepa", en: conexiones) == .una(conexiones[1]))
        precondition(Busqueda.buscar("norte", en: conexiones) == .una(conexiones[2]))
        if case .varias(let opciones) = Busqueda.buscar("cliente", en: conexiones) {
            precondition(opciones.count == 2)
        } else { preconditionFailure("«cliente» es ambiguo") }
        precondition(Busqueda.buscar("casa", en: conexiones) == .ninguna)
        precondition(Busqueda.buscar("  ", en: conexiones) == .ninguna)

        // Una conexión no puede recibir dos operaciones remotas simultáneas;
        // reservar varias para --todas es atómico.
        var operaciones = CoordinadorOperacionesRemotas()
        precondition(operaciones.reservar(["vpn-1"]))
        precondition(operaciones.estaOcupada("vpn-1"))
        precondition(!operaciones.reservar(["vpn-1", "vpn-2"]))
        precondition(!operaciones.estaOcupada("vpn-2"))
        operaciones.liberar(["vpn-1"])
        precondition(operaciones.reservar(["vpn-1", "vpn-2"]))
        operaciones.liberar(["vpn-1", "vpn-2"])

        // Codificación de ida y vuelta, con fechas.
        let mensaje = Mensaje.resultado(.ok, vpn: "vpn-2", estado: .conectada, motivo: .conectada,
                                        conexiones: [conexiones[1]])
        let decodificado = try Linea.decodificar(Mensaje.self, de: Linea.codificar(mensaje).dropLast())
        precondition(decodificado == mensaje)
        let peticionConID = Peticion(comando: .estado)
        precondition(!(peticionConID.operacion ?? "").isEmpty)
        let peticionAntigua = try Linea.decodificar(Peticion.self,
            de: Data(#"{"version":2,"comando":"estado"}"#.utf8))
        precondition(peticionAntigua.operacion == nil, "clientes de protocolo 2 anteriores siguen siendo válidos")
        precondition(CodigoSalida.paraDiagnostico([
            Comprobacion(nombre: "A", ok: true, detalle: "Bien"),
        ]) == .ok)
        precondition(CodigoSalida.paraDiagnostico([
            Comprobacion(nombre: "A", ok: true, detalle: "Bien"),
            Comprobacion(nombre: "B", ok: false, detalle: "Pendiente"),
        ]) == .requierePersona, "un diagnóstico incompleto no puede salir con cero")

        // Una confirmación tardía no puede iniciar una operación después de
        // que el comando haya cerrado el socket.
        var par = [Int32](repeating: -1, count: 2)
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &par) == 0)
        let emisor = Emisor(fd: par[0])
        precondition(emisor.clienteConectado())
        close(par[1])
        precondition(!emisor.clienteConectado())
        close(par[0])

        // Servidor real en un socket temporal.
        let carpeta = NSTemporaryDirectory() + "nvx-\(getpid())"
        let ruta = carpeta + "/control.sock"
        defer { try? FileManager.default.removeItem(atPath: carpeta) }
        let servidor = ServidorSocket(ruta: ruta, autorizarCliente: { !$0.ejecutable.isEmpty }) { peticion, cliente, emisor in
            switch peticion.comando {
            case .estado:
                return .resultado(.ok, conexiones: conexiones)
            case .conectar:
                emisor.enviar(.evento(.estado, vpn: peticion.vpn, titulo: "Conectando…"))
                emisor.enviar(.evento(.codigoRequerido, vpn: peticion.vpn))
                return .resultado(.ok, vpn: peticion.vpn, estado: .conectada, motivo: .conectada,
                                  detalle: cliente.origen)
            case .diagnostico:
                try? await Task.sleep(for: .milliseconds(300))
                return .resultado(.ok)
            default:
                return .resultado(.uso)
            }
        }
        try servidor.iniciar()
        var atributos = stat()
        precondition(stat(ruta, &atributos) == 0)
        precondition(atributos.st_mode & 0o777 == 0o600, "el socket debe ser privado")
        precondition(ClienteControl.hayServidor(ruta: ruta))
        precondition(ClienteControl.disponibilidad(ruta: ruta) == .abierta)

        // Un sandbox sin red, como el de Codex, no se confunde con una Nuvex cerrada.
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
            let aislado = Process()
            aislado.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            aislado.arguments = ["-p", "(version 1)(allow default)(deny network*)",
                                 CommandLine.arguments[0], "--sondear", ruta]
            let salida = Pipe()
            aislado.standardOutput = salida
            try aislado.run()
            aislado.waitUntilExit()
            let visto = String(decoding: salida.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            precondition(visto == "bloqueada", "desde un sandbox se esperaba «bloqueada» y llegó «\(visto)»")
        }

        let segundo = ServidorSocket(ruta: ruta) { _, _, _ in .resultado(.ok) }
        do { try segundo.iniciar(); preconditionFailure("una segunda Nuvex no debe quitarle el socket a la primera") }
        catch ErrorControl.yaEnUso {}

        let estado = try ClienteControl.enviar(Peticion(comando: .estado), ruta: ruta)
        precondition(estado.ok && estado.conexiones?.count == 4)

        var eventos: [EventoControl] = []
        let conectar = try ClienteControl.enviar(Peticion(comando: .conectar, vpn: "vpn-1", esperar: true), ruta: ruta) {
            if let evento = $0.evento { eventos.append(evento) }
        }
        precondition(conectar.ok && conectar.estado == .conectada && conectar.motivo == .conectada)
        precondition(eventos == [.estado, .codigoRequerido])
        precondition(!(conectar.detalle ?? "").isEmpty, "se identifica el origen del cliente")

        let invalida = try ClienteControl.enviar(Peticion(comando: .codigo), ruta: ruta)
        precondition(invalida.salida == .uso)

        do {
            _ = try ClienteControl.enviar(Peticion(comando: .diagnostico), ruta: ruta, limiteRespuesta: 0.05)
            preconditionFailure("el cliente no debe esperar indefinidamente")
        } catch ErrorControl.tiempoAgotado {}
        try? await Task.sleep(for: .milliseconds(350))

        var incompatible = Peticion(comando: .estado)
        incompatible.version = Peticion.versionActual + 1
        let version = try ClienteControl.enviar(incompatible, ruta: ruta)
        precondition(version.salida == .uso && version.titulo == "Versión de protocolo no compatible")

        servidor.detener()
        precondition(!FileManager.default.fileExists(atPath: ruta))
        precondition(!ClienteControl.hayServidor(ruta: ruta))
        precondition(ClienteControl.disponibilidad(ruta: ruta) == .cerrada, "una Nuvex cerrada no es un sandbox")
        do { _ = try ClienteControl.enviar(Peticion(comando: .estado), ruta: ruta); preconditionFailure("sin servidor") }
        catch ErrorControl.sinServidor {}

        // El servidor puede restringirse al cliente oficial antes de atender
        // cualquier comando, aun cuando el proceso pertenezca al mismo usuario.
        let restringido = ServidorSocket(ruta: ruta, autorizarCliente: { _ in false }) { _, _, _ in
            preconditionFailure("un cliente rechazado no debe llegar al manejador")
        }
        try restringido.iniciar()
        let rechazado = try ClienteControl.enviar(Peticion(comando: .estado), ruta: ruta)
        precondition(rechazado.salida == .noPermitido)
        restringido.detener()

        // Un descriptor puede seguir abierto aunque el nodo del socket haya
        // desaparecido. Debe detectarse para que ControlRemoto pueda recrearlo.
        let recuperable = ServidorSocket(ruta: ruta) { _, _, _ in .resultado(.ok) }
        try recuperable.iniciar()
        precondition(recuperable.estaDisponible)
        unlink(ruta)
        precondition(!recuperable.estaDisponible, "un socket sin ruta ya no está disponible para clientes")
        recuperable.detener()

        print("Control: comprobaciones superadas")
    }
}
