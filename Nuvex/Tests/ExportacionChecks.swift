import Foundation

/// Comprobaciones del archivo .nuvexvpn cifrado.
@main
struct ExportacionChecks {
    static func esperarError(_ esperado: ErrorExportacion, _ bloque: () throws -> Void) {
        do { try bloque(); preconditionFailure("se esperaba \(esperado)") }
        catch let error as ErrorExportacion { precondition(error == esperado, "se obtuvo \(error), se esperaba \(esperado)") }
        catch { preconditionFailure("error inesperado \(error)") }
    }

    static func main() throws {
        let perfil = VPNProfile(id: "vpn-a", name: "Oficina", server: "vpn.empresa.com:443", username: "ana",
                                trust: "system", realm: "", manageRoutes: true, manageDNS: false, enabled: true)
        let contenido = ContenidoExportado(creado: Date(timeIntervalSince1970: 1_800_000_000), app: "3.1.0",
                                           conexiones: [perfil], contrasenas: ["vpn-a": "s3creta ñ"],
                                           correo: ["vpn-a": ConfigCorreo.fortinet])
        let frase = "caballo correcto batería grapa"

        // Ida y vuelta con los parámetros de serie (600 000 iteraciones).
        let inicio = Date()
        let archivo = try CifradoExportacion.cifrar(contenido, frase: frase)
        let recuperado = try CifradoExportacion.descifrar(archivo, frase: frase)
        precondition(recuperado == contenido)
        precondition(Date().timeIntervalSince(inicio) < 10, "derivar la clave no debe tardar demasiado")
        let texto = String(decoding: archivo, as: UTF8.self)
        precondition(!texto.contains("s3creta") && !texto.contains("vpn.empresa.com") && !texto.contains("ana"),
                     "nada del contenido viaja en claro")
        precondition(texto.contains("\"iteraciones\" : 600000"))

        // Dos exportaciones iguales no producen el mismo archivo (sal y nonce aleatorios).
        let rapido = try CifradoExportacion.cifrar(contenido, frase: frase, iteraciones: 100_000)
        let otro = try CifradoExportacion.cifrar(contenido, frase: frase, iteraciones: 100_000)
        precondition(rapido != otro)

        esperarError(.fraseIncorrecta) { _ = try CifradoExportacion.descifrar(rapido, frase: frase + "x") }
        esperarError(.fraseCorta) { _ = try CifradoExportacion.cifrar(contenido, frase: "corta") }

        // Alterar la cabecera o los datos invalida el archivo.
        func modificar(_ cambio: (inout [String: Any]) -> Void) throws -> Data {
            var json = try JSONSerialization.jsonObject(with: rapido) as! [String: Any]
            cambio(&json)
            return try JSONSerialization.data(withJSONObject: json)
        }
        let otraSal = try modificar { json in
            var kdf = json["kdf"] as! [String: Any]
            kdf["sal"] = Data(repeating: 7, count: 16).base64EncodedString()
            json["kdf"] = kdf
        }
        esperarError(.fraseIncorrecta) { _ = try CifradoExportacion.descifrar(otraSal, frase: frase) }
        let otrosDatos = try modificar { json in
            var bytes = Data(base64Encoded: json["datos"] as! String)!
            bytes[bytes.count / 2] ^= 0x01
            json["datos"] = bytes.base64EncodedString()
        }
        esperarError(.fraseIncorrecta) { _ = try CifradoExportacion.descifrar(otrosDatos, frase: frase) }

        // Archivos ajenos, futuros o con parámetros peligrosos.
        esperarError(.noEsArchivoNuvex) { _ = try CifradoExportacion.descifrar(Data("hola".utf8), frase: frase) }
        esperarError(.noEsArchivoNuvex) { _ = try CifradoExportacion.descifrar(try modificar { $0["formato"] = "otro" }, frase: frase) }
        esperarError(.versionNoCompatible) { _ = try CifradoExportacion.descifrar(try modificar { $0["version"] = 2 }, frase: frase) }
        let pocas = try modificar { json in
            var kdf = json["kdf"] as! [String: Any]; kdf["iteraciones"] = 50; json["kdf"] = kdf
        }
        esperarError(.parametrosNoValidos) { _ = try CifradoExportacion.descifrar(pocas, frase: frase) }
        let demasiadas = try modificar { json in
            var kdf = json["kdf"] as! [String: Any]; kdf["iteraciones"] = 2_000_000_000; json["kdf"] = kdf
        }
        esperarError(.parametrosNoValidos) { _ = try CifradoExportacion.descifrar(demasiadas, frase: frase) }
        esperarError(.demasiadoGrande) {
            _ = try CifradoExportacion.descifrar(Data(repeating: 0x20, count: 2_000_000), frase: frase)
        }

        // Fuerza de la frase.
        precondition(CifradoExportacion.fuerza("corta") == 0)
        precondition(CifradoExportacion.fuerza("aaaaaaaaaaaa") == 1)
        precondition(CifradoExportacion.fuerza("Abcdefgh1234") == 2)
        precondition(CifradoExportacion.fuerza(frase) == 3)

        print("Exportación: comprobaciones superadas")
    }
}
