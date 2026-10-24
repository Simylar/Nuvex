import Foundation

// Protocolo entre Nuvex y el comando `nuvex`: una petición JSON por línea y
// respuestas JSON por línea (eventos y un resultado final) por un socket Unix
// que solo puede usar el mismo usuario.

public enum Comando: String, Codable, Sendable {
    case estado
    case conectar
    case desconectar
    case codigo
    case diagnostico
}

public struct Peticion: Codable, Sendable, Equatable {
    public static let versionActual = 2

    public var version = Peticion.versionActual
    /// Correlación opaca para diagnóstico. Es opcional para conservar
    /// compatibilidad con clientes de protocolo 2 anteriores.
    public var operacion: String?
    public var comando: Comando
    /// Nombre, id o prefijo único de la conexión.
    public var vpn: String?
    /// Desconectar todas.
    public var todas: Bool?
    /// Esperar a que termine la conexión.
    public var esperar: Bool?
    /// Segundos máximos de espera.
    public var limite: Int?
    /// Código de verificación (solo para `codigo`).
    public var codigo: String?
    /// En `diagnostico`, comprueba que las contraseñas se puedan leer. Puede
    /// requerir la presencia de la persona delante de la Mac.
    public var profundo: Bool?

    public init(comando: Comando, vpn: String? = nil, todas: Bool? = nil, esperar: Bool? = nil,
                limite: Int? = nil, codigo: String? = nil, profundo: Bool? = nil,
                operacion: String? = UUID().uuidString.lowercased()) {
        self.operacion = operacion
        self.comando = comando
        self.vpn = vpn
        self.todas = todas
        self.esperar = esperar
        self.limite = limite
        self.codigo = codigo
        self.profundo = profundo
    }
}

/// Evita que dos peticiones remotas modifiquen la misma conexión al mismo
/// tiempo. La reserva de varias conexiones es atómica para `--todas`.
public struct CoordinadorOperacionesRemotas: Sendable {
    private var ocupadas: Set<String> = []

    public init() {}

    public mutating func reservar(_ ids: Set<String>) -> Bool {
        guard !ids.isEmpty, ocupadas.isDisjoint(with: ids) else { return false }
        ocupadas.formUnion(ids)
        return true
    }

    public mutating func liberar(_ ids: Set<String>) {
        ocupadas.subtract(ids)
    }

    public func estaOcupada(_ id: String) -> Bool {
        ocupadas.contains(id)
    }
}

/// Códigos de salida del comando `nuvex`, documentados para los asistentes.
public enum CodigoSalida: Int32, Codable, Sendable {
    case ok = 0
    case error = 1
    case uso = 2
    case noPermitido = 3
    /// Hace falta la persona: un código sin lector de correo, autorizar el
    /// ayudante o permitir el acceso al Llavero.
    case requierePersona = 4
    case tiempoAgotado = 5
    case sinApp = 6
    /// El comando corre dentro del sandbox de un asistente que no le deja
    /// abrir Nuvex ni hablar con ella. Hay que repetirlo fuera del sandbox.
    case aislado = 7

    /// Un diagnóstico incompleto nunca debe parecer satisfactorio a scripts o
    /// asistentes, aunque sus comprobaciones se sigan mostrando una por una.
    public static func paraDiagnostico(_ comprobaciones: [Comprobacion]) -> CodigoSalida {
        comprobaciones.allSatisfy(\.ok) ? .ok : .requierePersona
    }
}

public enum EstadoConexionRemota: String, Codable, Sendable, Equatable, Hashable {
    case conectada
    case desconectada
    case conectando
    case esperandoCodigo = "esperando_codigo"
    case error
    case caida
}

public enum EventoControl: String, Codable, Sendable, Equatable {
    case estado
    case codigoRequerido = "codigo_requerido"
    case codigoCorreo = "codigo_correo"
}

/// Motivo estable y apto para automatización. Los títulos y detalles pueden
/// mejorar o traducirse sin obligar a los clientes a compararlos literalmente.
public enum MotivoResultado: String, Codable, Sendable, Equatable {
    case yaConectada = "ya_conectada"
    case conectada
    case desconectada
    case conectando
    case cancelada
    case servidorNoResponde = "servidor_no_responde"
    case servidorNoEncontrado = "servidor_no_encontrado"
    case autenticacionRechazada = "autenticacion_rechazada"
    case certificadoNoVerificado = "certificado_no_verificado"
    case tunelRechazado = "tunel_rechazado"
    case tunelActivo = "tunel_activo"
    case configuracionIncompleta = "configuracion_incompleta"
    case llaveroNoDisponible = "llavero_no_disponible"
    case ayudanteNoDisponible = "ayudante_no_disponible"
    case confirmacionRequerida = "confirmacion_requerida"
    case codigoNoEsperado = "codigo_no_esperado"
    case codigoInvalido = "codigo_invalido"
    case clienteNoAutorizado = "cliente_no_autorizado"
    case protocoloIncompatible = "protocolo_incompatible"
    case operacionEnCurso = "operacion_en_curso"
    case tiempoAgotado = "tiempo_agotado"
    case noPermitido = "no_permitido"
    case noEncontrada = "no_encontrada"
    case ambigua
    case diagnosticoIncompleto = "diagnostico_incompleto"
    case estadoNoConfirmado = "estado_no_confirmado"
    case errorConexion = "error_conexion"
    case aislamiento
}

public struct ConexionInfo: Codable, Sendable, Equatable {
    public var id: String
    public var nombre: String
    public var estado: EstadoConexionRemota
    public var ip: String?
    public var desde: Date?
    public var error: String?
    /// Si los asistentes pueden conectarla o desconectarla.
    public var permitida: Bool
    /// Si su código de verificación se lee del correo.
    public var codigoPorCorreo: Bool

    public init(id: String, nombre: String, estado: EstadoConexionRemota, ip: String? = nil, desde: Date? = nil,
                error: String? = nil, permitida: Bool, codigoPorCorreo: Bool) {
        self.id = id
        self.nombre = nombre
        self.estado = estado
        self.ip = ip
        self.desde = desde
        self.error = error
        self.permitida = permitida
        self.codigoPorCorreo = codigoPorCorreo
    }
}

public struct Comprobacion: Codable, Sendable, Equatable {
    public var nombre: String
    public var ok: Bool
    public var detalle: String

    public init(nombre: String, ok: Bool, detalle: String) {
        self.nombre = nombre
        self.ok = ok
        self.detalle = detalle
    }
}

public struct Mensaje: Codable, Sendable, Equatable {
    public enum Tipo: String, Codable, Sendable { case evento, resultado }

    public var tipo: Tipo
    public var evento: EventoControl?
    public var salida: CodigoSalida?
    public var vpn: String?
    public var estado: EstadoConexionRemota?
    public var motivo: MotivoResultado?
    public var titulo: String?
    public var detalle: String?
    public var conexiones: [ConexionInfo]?
    public var comprobaciones: [Comprobacion]?

    public var ok: Bool { salida == .ok }

    public static func evento(_ nombre: EventoControl, vpn: String? = nil, titulo: String? = nil, detalle: String? = nil) -> Mensaje {
        Mensaje(tipo: .evento, evento: nombre, vpn: vpn, titulo: titulo, detalle: detalle)
    }

    public static func resultado(_ salida: CodigoSalida, vpn: String? = nil, estado: EstadoConexionRemota? = nil,
                                 motivo: MotivoResultado? = nil,
                                 titulo: String? = nil, detalle: String? = nil,
                                 conexiones: [ConexionInfo]? = nil, comprobaciones: [Comprobacion]? = nil) -> Mensaje {
        Mensaje(tipo: .resultado, salida: salida, vpn: vpn, estado: estado, motivo: motivo, titulo: titulo, detalle: detalle,
                conexiones: conexiones, comprobaciones: comprobaciones)
    }

    public init(tipo: Tipo, evento: EventoControl? = nil, salida: CodigoSalida? = nil, vpn: String? = nil,
                estado: EstadoConexionRemota? = nil, motivo: MotivoResultado? = nil,
                titulo: String? = nil, detalle: String? = nil,
                conexiones: [ConexionInfo]? = nil, comprobaciones: [Comprobacion]? = nil) {
        self.tipo = tipo
        self.evento = evento
        self.salida = salida
        self.vpn = vpn
        self.estado = estado
        self.motivo = motivo
        self.titulo = titulo
        self.detalle = detalle
        self.conexiones = conexiones
        self.comprobaciones = comprobaciones
    }
}

// MARK: - Codificación por líneas

public enum Linea {
    public static func codificar<T: Encodable>(_ valor: T) throws -> Data {
        let codificador = JSONEncoder()
        codificador.dateEncodingStrategy = .iso8601
        codificador.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var datos = try codificador.encode(valor)
        datos.append(0x0A)
        return datos
    }

    public static func decodificar<T: Decodable>(_ tipo: T.Type, de datos: Data) throws -> T {
        let decodificador = JSONDecoder()
        decodificador.dateDecodingStrategy = .iso8601
        return try decodificador.decode(tipo, from: datos)
    }
}

// MARK: - Rutas

public enum RutaControl {
    /// Socket de control: carpeta privada del usuario, permisos 0600.
    public static func socket(home: String) -> String {
        home + "/Library/Application Support/Nuvex/control.sock"
    }
}

// MARK: - Búsqueda de conexiones por nombre

public enum Busqueda: Equatable, Sendable {
    case una(ConexionInfo)
    case ninguna
    case varias([ConexionInfo])

    /// Por id exacto; luego por nombre sin distinguir mayúsculas ni acentos;
    /// luego por palabras o prefijo, si solo una coincide.
    public static func buscar(_ consulta: String, en conexiones: [ConexionInfo]) -> Busqueda {
        let buscado = normalizar(consulta)
        guard !buscado.isEmpty else { return .ninguna }
        if let exacta = conexiones.first(where: { $0.id == consulta }) { return .una(exacta) }
        let porNombre = conexiones.filter { normalizar($0.nombre) == buscado }
        if porNombre.count == 1 { return .una(porNombre[0]) }
        if porNombre.count > 1 { return .varias(porNombre) }
        let parciales = conexiones.filter { conexion in
            let nombre = normalizar(conexion.nombre)
            return nombre.hasPrefix(buscado) || nombre.contains(buscado)
                || buscado.split(separator: " ").allSatisfy { nombre.contains($0) }
        }
        switch parciales.count {
        case 0: return .ninguna
        case 1: return .una(parciales[0])
        default: return .varias(parciales)
        }
    }

    static func normalizar(_ texto: String) -> String {
        texto.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
