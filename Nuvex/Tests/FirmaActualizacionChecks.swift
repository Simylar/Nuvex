import CryptoKit
import Foundation

enum ErrorFirma: Error, CustomStringConvertible {
    case argumentos
    case datoBase64(String)
    case firmaInvalida

    var description: String {
        switch self {
        case .argumentos:
            return "Uso: FirmaActualizacionChecks crear-clave PRIVADA PUBLICA | verificar PUBLICA ARCHIVO FIRMA"
        case let .datoBase64(nombre):
            return "El archivo \(nombre) no contiene Base64 válido"
        case .firmaInvalida:
            return "La firma Ed25519 no corresponde al archivo"
        }
    }
}

@main
enum FirmaActualizacionChecks {
    static func main() {
        do {
            try ejecutar(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func ejecutar(_ argumentos: [String]) throws {
        guard let operacion = argumentos.first else {
            throw ErrorFirma.argumentos
        }
        switch operacion {
        case "crear-clave" where argumentos.count == 3:
            try crearClave(privada: argumentos[1], publica: argumentos[2])
        case "verificar" where argumentos.count == 4:
            try verificar(publica: argumentos[1], archivo: argumentos[2], firma: argumentos[3])
        default:
            throw ErrorFirma.argumentos
        }
    }

    private static func crearClave(privada: String, publica: String) throws {
        let clave = Curve25519.Signing.PrivateKey()
        try escribirBase64(clave.rawRepresentation, en: privada, permisos: 0o600)
        try escribirBase64(clave.publicKey.rawRepresentation, en: publica, permisos: 0o644)
    }

    private static func verificar(publica: String, archivo: String, firma: String) throws {
        let datosPublicos = try leerBase64(publica)
        guard let datosFirma = Data(base64Encoded: firma) else {
            throw ErrorFirma.datoBase64("firma")
        }
        let clave = try Curve25519.Signing.PublicKey(rawRepresentation: datosPublicos)
        let contenido = try Data(contentsOf: URL(fileURLWithPath: archivo))
        guard clave.isValidSignature(datosFirma, for: contenido) else {
            throw ErrorFirma.firmaInvalida
        }
    }

    private static func escribirBase64(_ datos: Data, en ruta: String, permisos: Int) throws {
        let url = URL(fileURLWithPath: ruta)
        try (datos.base64EncodedString() + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permisos], ofItemAtPath: ruta)
    }

    private static func leerBase64(_ ruta: String) throws -> Data {
        let texto = try String(contentsOfFile: ruta, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let datos = Data(base64Encoded: texto) else {
            throw ErrorFirma.datoBase64(ruta)
        }
        return datos
    }
}
