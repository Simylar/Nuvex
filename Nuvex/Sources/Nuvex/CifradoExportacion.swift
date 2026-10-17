import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Archivo .nuvexvpn: conexiones exportadas, siempre cifradas con una frase.
/// La cabecera (formato, versión, parámetros de la clave) va en claro y se
/// autentica como datos asociados de AES-GCM: alterarla invalida el archivo.
struct ArchivoExportado: Codable, Equatable {
    struct Derivacion: Codable, Equatable {
        var algoritmo = "pbkdf2-sha256"
        var iteraciones: Int
        var sal: String
    }

    var formato = "nuvex-exportacion"
    var version = 1
    var kdf: Derivacion
    var cifrado = "aes-256-gcm"
    /// Nonce, texto cifrado y etiqueta (AES.GCM combined), en base64.
    var datos: String

    /// Cabecera sin los datos, con claves ordenadas: lo que se autentica.
    var cabecera: Data {
        get throws {
            var sinDatos = self
            sinDatos.datos = ""
            let codificador = JSONEncoder()
            codificador.outputFormatting = [.sortedKeys]
            return try codificador.encode(sinDatos)
        }
    }
}

/// Lo que viaja cifrado.
struct ContenidoExportado: Codable, Equatable {
    var creado: Date
    var app: String
    var conexiones: [VPNProfile]
    /// Contraseñas por id de conexión; solo si se eligió incluirlas.
    var contrasenas: [String: String]?
    /// Configuración del código por correo, por id de conexión.
    var correo: [String: ConfigCorreo]?
}

enum ErrorExportacion: LocalizedError, Equatable {
    case fraseCorta
    case fraseIncorrecta
    case noEsArchivoNuvex
    case versionNoCompatible
    case demasiadoGrande
    case parametrosNoValidos
    case contenidoNoValido(String)

    var errorDescription: String? {
        switch self {
        case .fraseCorta: return "La frase debe tener al menos \(CifradoExportacion.longitudMinima) caracteres."
        case .fraseIncorrecta: return "La frase no es correcta o el archivo está dañado."
        case .noEsArchivoNuvex: return "Este archivo no es una exportación de Nuvex."
        case .versionNoCompatible: return "El archivo lo creó una versión más nueva de Nuvex. Actualiza Nuvex para importarlo."
        case .demasiadoGrande: return "El archivo es demasiado grande para ser una exportación de Nuvex."
        case .parametrosNoValidos: return "El archivo tiene parámetros de cifrado no válidos."
        case .contenidoNoValido(let detalle): return "El contenido del archivo no es válido: \(detalle)"
        }
    }
}

enum CifradoExportacion {
    static let longitudMinima = 12
    static let iteraciones = 600_000
    static let tamanoMaximo = 1_048_576
    static let iteracionesPermitidas = 100_000...5_000_000

    static func cifrar(_ contenido: ContenidoExportado, frase: String, iteraciones: Int = iteraciones) throws -> Data {
        guard frase.count >= longitudMinima else { throw ErrorExportacion.fraseCorta }
        var sal = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, sal.count, &sal) == errSecSuccess else {
            throw ErrorExportacion.parametrosNoValidos
        }
        var archivo = ArchivoExportado(kdf: .init(iteraciones: iteraciones, sal: Data(sal).base64EncodedString()), datos: "")
        let clave = try derivar(frase, sal: Data(sal), iteraciones: iteraciones)
        let codificador = JSONEncoder()
        codificador.dateEncodingStrategy = .iso8601
        let caja = try AES.GCM.seal(try codificador.encode(contenido), using: clave, authenticating: try archivo.cabecera)
        guard let combinado = caja.combined else { throw ErrorExportacion.parametrosNoValidos }
        archivo.datos = combinado.base64EncodedString()
        let salida = JSONEncoder()
        salida.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try salida.encode(archivo)
    }

    static func descifrar(_ datos: Data, frase: String) throws -> ContenidoExportado {
        guard datos.count <= tamanoMaximo else { throw ErrorExportacion.demasiadoGrande }
        guard let archivo = try? JSONDecoder().decode(ArchivoExportado.self, from: datos),
              archivo.formato == "nuvex-exportacion" else { throw ErrorExportacion.noEsArchivoNuvex }
        guard archivo.version == 1 else { throw ErrorExportacion.versionNoCompatible }
        guard archivo.cifrado == "aes-256-gcm", archivo.kdf.algoritmo == "pbkdf2-sha256",
              iteracionesPermitidas.contains(archivo.kdf.iteraciones),
              let sal = Data(base64Encoded: archivo.kdf.sal), sal.count >= 16,
              let combinado = Data(base64Encoded: archivo.datos) else { throw ErrorExportacion.parametrosNoValidos }
        let clave = try derivar(frase, sal: sal, iteraciones: archivo.kdf.iteraciones)
        let claro: Data
        do {
            claro = try AES.GCM.open(try AES.GCM.SealedBox(combined: combinado), using: clave,
                                     authenticating: try archivo.cabecera)
        } catch {
            throw ErrorExportacion.fraseIncorrecta
        }
        let decodificador = JSONDecoder()
        decodificador.dateDecodingStrategy = .iso8601
        guard let contenido = try? decodificador.decode(ContenidoExportado.self, from: claro) else {
            throw ErrorExportacion.contenidoNoValido("no se pudieron leer las conexiones")
        }
        guard contenido.conexiones.count <= 64 else { throw ErrorExportacion.contenidoNoValido("más de 64 conexiones") }
        guard Set(contenido.conexiones.map(\.id)).count == contenido.conexiones.count else {
            throw ErrorExportacion.contenidoNoValido("hay conexiones repetidas")
        }
        let idValido = try NSRegularExpression(pattern: "^[a-z][a-z0-9-]{0,47}$")
        for conexion in contenido.conexiones
        where idValido.firstMatch(in: conexion.id, range: NSRange(conexion.id.startIndex..., in: conexion.id)) == nil {
            throw ErrorExportacion.contenidoNoValido("identificador de conexión no válido")
        }
        return contenido
    }

    private static func derivar(_ frase: String, sal: Data, iteraciones: Int) throws -> SymmetricKey {
        let bytesFrase = Array(frase.utf8)
        var clave = [UInt8](repeating: 0, count: 32)
        let resultado = sal.withUnsafeBytes { puntero in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), frase, bytesFrase.count,
                                 puntero.bindMemory(to: UInt8.self).baseAddress, sal.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iteraciones),
                                 &clave, clave.count)
        }
        guard resultado == kCCSuccess else { throw ErrorExportacion.parametrosNoValidos }
        defer { clave.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return SymmetricKey(data: clave)
    }

    /// Fuerza orientativa de la frase: 0 débil … 3 muy buena.
    static func fuerza(_ frase: String) -> Int {
        guard frase.count >= longitudMinima else { return 0 }
        var clases = 0
        if frase.rangeOfCharacter(from: .lowercaseLetters) != nil { clases += 1 }
        if frase.rangeOfCharacter(from: .uppercaseLetters) != nil { clases += 1 }
        if frase.rangeOfCharacter(from: .decimalDigits) != nil { clases += 1 }
        if frase.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { clases += 1 }
        let palabras = frase.split(separator: " ").count
        if frase.count >= 20 || palabras >= 4 { return clases >= 2 ? 3 : 2 }
        return clases >= 3 ? 2 : 1
    }
}
