import Foundation

enum PapeleraGmail {
    /// Solo messages.trash: un mensaje concreto, sin cuerpo y sin borrado
    /// definitivo. La sesión sustituible permite probar HTTP sin una cuenta.
    static func mover(_ id: String, token: String, sesion: URLSession = .shared) async throws {
        let caracteresID = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ caracteresID.contains($0) }),
              let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)/trash") else {
            throw ProblemaGmail.servidor(0)
        }
        var peticion = URLRequest(url: url, timeoutInterval: 15)
        peticion.httpMethod = "POST"
        peticion.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (datos, respuesta) = try await sesion.data(for: peticion)
        let estado = (respuesta as? HTTPURLResponse)?.statusCode ?? 0
        guard estado == 200 else { throw ProblemaGmail.clasificar(estado: estado, cuerpo: datos) }
        guard let json = try JSONSerialization.jsonObject(with: datos) as? [String: Any],
              json["id"] as? String == id,
              (json["labelIds"] as? [String])?.contains("TRASH") == true else {
            throw ProblemaGmail.servidor(0)
        }
    }

    static func mover(_ id: String, _ token: String) async throws {
        try await mover(id, token: token)
    }
}
