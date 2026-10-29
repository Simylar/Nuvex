import Foundation

struct PendienteCapacidad: Identifiable, Equatable {
    enum Destino: Equatable {
        case conexion(String), ayudante, cuentaGoogle, automatizacion, contrasenas(String), confirmacionInicial
    }
    let id: String
    let funcion: String
    let detalle: String
    let accion: String
    let destino: Destino
}

/// Solo las funciones configuradas generan pendientes. Una función opcional
/// desactivada por la persona no es un permiso faltante.
struct EstadoCapacidades {
    var perfiles: [VPNProfile] = []
    var ayudanteListo: Bool?
    var contrasenas: [String: PasswordStatus] = [:]
    var accesos: [String: AccesoLlavero] = [:]
    var correo: [String: ConfigCorreo] = [:]
    var problemaCuenta: ProblemaGmail?
    var confirmacionPendiente = false
    var automatizacionSolicitada = false
    var comandoListo: Bool?
    var agentes: [String: Bool] = [:]

    var pendientes: [PendienteCapacidad] {
        let visibles = perfiles.filter(\.enabled)
        var lista: [PendienteCapacidad] = []
        for perfil in visibles {
            if let motivo = Validacion.motivo(perfil) {
                lista.append(.init(id: "perfil.\(perfil.id)", funcion: "Conectar \(perfil.name)",
                    detalle: motivo, accion: "Completar conexión…", destino: .conexion(perfil.id)))
                continue
            }
            let acceso = accesos[perfil.id]
            if acceso == .ausente || (acceso == nil && contrasenas[perfil.id] == .missing) {
                lista.append(.init(id: "password.\(perfil.id)", funcion: "Conectar \(perfil.name)",
                    detalle: "No hay contraseña guardada.", accion: "Añadir contraseña…", destino: .conexion(perfil.id)))
            } else if let acceso, acceso != .disponible {
                lista.append(.init(id: "llavero.\(perfil.id)", funcion: "Usar la contraseña de \(perfil.name)",
                    detalle: acceso.descripcion, accion: "Comprobar acceso…", destino: .contrasenas(perfil.id)))
            }
        }
        if !visibles.isEmpty, ayudanteListo != true {
            lista.append(.init(id: "ayudante", funcion: "Crear los túneles VPN",
                detalle: ayudanteListo == false ? "El ayudante no está vigente; revisa su instalación o configuración."
                    : "El estado del ayudante aún no pudo comprobarse.",
                accion: "Revisar ayudante…", destino: .ayudante))
        }
        if !visibles.isEmpty, confirmacionPendiente {
            lista.append(.init(id: "confirmacion", funcion: "Usar contraseñas guardadas",
                detalle: "Falta la confirmación inicial de Nuvex.", accion: "Confirmar uso…", destino: .confirmacionInicial))
        }
        let lectores = visibles.filter { correo[$0.id] != nil }
        for perfil in lectores where correo[perfil.id]?.remitente.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lista.append(.init(id: "remitente.\(perfil.id)", funcion: "Leer el código de \(perfil.name)",
                detalle: ProblemaGmail.remitenteNoConfigurado.detalle, accion: "Añadir remitente…", destino: .conexion(perfil.id)))
        }
        if !lectores.isEmpty, let problemaCuenta {
            lista.append(.init(id: "gmail", funcion: "Leer códigos desde Gmail",
                detalle: problemaCuenta.titulo, accion: "Revisar cuenta…", destino: .cuentaGoogle))
        }
        if automatizacionSolicitada {
            if comandoListo != true {
                lista.append(.init(id: "comando", funcion: "Usar la Terminal y los asistentes",
                    detalle: "El comando de esta copia de Nuvex no está preparado o no pudo comprobarse.",
                    accion: "Revisar automatización…", destino: .automatizacion))
            }
            for agente in agentes.keys.sorted() where agentes[agente] == false {
                lista.append(.init(id: "agente.\(agente)", funcion: "Usar \(agente == "codex" ? "Codex" : "Claude Code")",
                    detalle: "La integración necesita revisarse; las demás funciones pueden seguir disponibles.",
                    accion: "Revisar integración…", destino: .automatizacion))
            }
        }
        return lista
    }
}
