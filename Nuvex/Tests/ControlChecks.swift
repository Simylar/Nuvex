import Darwin
import Foundation

/// Comprobaciones del protocolo y del socket de control con un servidor real.
@main
struct ControlChecks {
    static func main() async throws {
        let conexiones = [
            ConexionInfo(id: "vpn-1", nombre: "Oficina central", estado: "desconectada", permitida: true, codigoPorCorreo: false),
            ConexionInfo(id: "vpn-2", nombre: "Prepa · Sedes", estado: "conectada", ip: "10.0.0.2", permitida: true, codigoPorCorreo: true),
            ConexionInfo(id: "vpn-3", nombre: "Cliente Norte", estado: "desconectada", permitida: false, codigoPorCorreo: false),
            ConexionInfo(id: "vpn-4", nombre: "Cliente Sur", estado: "desconectada", permitida: true, codigoPorCorreo: false),
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

        // Codificación de ida y vuelta, con fechas.
        let mensaje = Mensaje.resultado(.ok, vpn: "vpn-2", estado: "conectada", conexiones: [conexiones[1]])
        let decodificado = try Linea.decodificar(Mensaje.self, de: Linea.codificar(mensaje).dropLast())
        precondition(decodificado == mensaje)

        // Servidor real en un socket temporal.
        let carpeta = NSTemporaryDirectory() + "nvx-\(getpid())"
        let ruta = carpeta + "/control.sock"
        defer { try? FileManager.default.removeItem(atPath: carpeta) }
        let servidor = ServidorSocket(ruta: ruta) { peticion, cliente, emisor in
            switch peticion.comando {
            case .estado:
                return .resultado(.ok, conexiones: conexiones)
            case .conectar:
                emisor.enviar(.evento("estado", vpn: peticion.vpn, titulo: "Conectando…"))
                emisor.enviar(.evento("codigo_requerido", vpn: peticion.vpn))
                return .resultado(.ok, vpn: peticion.vpn, estado: "conectada", detalle: cliente.origen)
            default:
                return .resultado(.uso)
            }
        }
        try servidor.iniciar()
        var atributos = stat()
        precondition(stat(ruta, &atributos) == 0)
        precondition(atributos.st_mode & 0o777 == 0o600, "el socket debe ser privado")
        precondition(ClienteControl.hayServidor(ruta: ruta))

        let segundo = ServidorSocket(ruta: ruta) { _, _, _ in .resultado(.ok) }
        do { try segundo.iniciar(); preconditionFailure("una segunda Nuvex no debe quitarle el socket a la primera") }
        catch ErrorControl.yaEnUso {}

        let estado = try ClienteControl.enviar(Peticion(comando: .estado), ruta: ruta)
        precondition(estado.ok && estado.conexiones?.count == 4)

        var eventos: [String] = []
        let conectar = try ClienteControl.enviar(Peticion(comando: .conectar, vpn: "vpn-1", esperar: true), ruta: ruta) {
            eventos.append($0.evento ?? "")
        }
        precondition(conectar.ok && conectar.estado == "conectada")
        precondition(eventos == ["estado", "codigo_requerido"])
        precondition(!(conectar.detalle ?? "").isEmpty, "se identifica el origen del cliente")

        let invalida = try ClienteControl.enviar(Peticion(comando: .codigo), ruta: ruta)
        precondition(invalida.salida == .uso)

        servidor.detener()
        precondition(!FileManager.default.fileExists(atPath: ruta))
        precondition(!ClienteControl.hayServidor(ruta: ruta))
        do { _ = try ClienteControl.enviar(Peticion(comando: .estado), ruta: ruta); preconditionFailure("sin servidor") }
        catch ErrorControl.sinServidor {}

        print("Control: comprobaciones superadas")
    }
}
