import Foundation

/// Comprobaciones de la lectura de códigos de correo y del PKCE de OAuth.
@main
struct CorreoChecks {
    @MainActor
    static func main() async throws {
        try comprobarPreferenciaPapelera()
        comprobarUsoCorreo()
        try await comprobarPapeleraHTTP()
        // Importación del archivo de escritorio sin red ni secretos reales.
        let cliente = #"{"installed":{"client_id":"prueba.apps.googleusercontent.com","client_secret":"secreto-ficticio"}}"#
        let importado = try! JSONDecoder().decode(ClienteGoogleImportado.self, from: Data(cliente.utf8))
        precondition(importado.id == "prueba.apps.googleusercontent.com")
        precondition(importado.secreto == "secreto-ficticio")
        for invalido in ["{}", "{", cliente.replacingOccurrences(of: "installed", with: "web"),
                         cliente.replacingOccurrences(of: "secreto-ficticio", with: ""),
                         cliente.replacingOccurrences(of: "prueba.apps.googleusercontent.com", with: "cliente.example"),
                         cliente.replacingOccurrences(of: "secreto-ficticio", with: "secreto\\npartido")] {
            precondition((try? JSONDecoder().decode(ClienteGoogleImportado.self, from: Data(invalido.utf8))) == nil)
        }

        // Formatos habituales de códigos por correo.
        let casos: [(String, String?)] = [
            ("AuthCode: 123456", "123456"),
            // Correo real de FortiToken: el asunto y el cuerpo, con un cero inicial.
            ("AuthCode: 043051\nYour authentication token code is 043051.", "043051"),
            ("Your authentication token code is 043051.", "043051"),
            ("Tu código de verificación es 654321. Caduca en 5 minutos.", "654321"),
            ("Your FortiToken code is: 482913", "482913"),
            ("Su clave temporal: 4821", "4821"),
            ("Token valid for 10 minutes: 112233", "112233"),
            ("Acceso del 2026-10-17 a las 10:31. Use 135790 para continuar.", "135790"),
            ("Pedido 123456 y referencia 654321", nil),
            ("Hola, no hay ningún número aquí.", nil),
        ]
        for (texto, esperado) in casos {
            let obtenido = ExtractorCodigo.extraer(de: texto)
            precondition(obtenido == esperado, "«\(texto)» → \(obtenido ?? "nil"), se esperaba \(esperado ?? "nil")")
        }
        let html = "<html><style>p{color:red}</style><body><p>C&oacute;digo de acceso:</p><p><b>778899</b></p><p>Ref. 2026</p></body></html>"
        let texto = ExtractorCodigo.textoDesdeHTML(html)
        precondition(!texto.contains("<") && !texto.contains("color"))
        precondition(ExtractorCodigo.extraer(de: texto) == "778899")
        precondition(ExtractorCodigo.extraer(de: "PIN 9988, ref 112233", patron: #"PIN (\d+)"#) == "9988")
        precondition(ExtractorCodigo.codigoValido("A9-42"))
        for (entrada, esperado) in [("A9-42", "A9-42"), ("  A9-42  ", "A9-42"),
                                    ("000123", "000123"), ("482 913", "482913"),
                                    ("482-913", "482913"), ("12\n34", "12\n34")] {
            precondition(ExtractorCodigo.normalizar(entrada) == esperado)
        }
        precondition(ExtractorCodigo.extraer(de: "Token: A9-42", patron: #"Token: ([A-Z0-9-]+)"#) == "A9-42")
        precondition(ExtractorCodigo.extraer(de: "Código: 482-913", patron: #"Código: ([0-9-]+)"#) == "482913")
        precondition(!ExtractorCodigo.codigoValido(""))
        precondition(!ExtractorCodigo.codigoValido(String(repeating: "1", count: 65)))
        precondition(!ExtractorCodigo.codigoValido("123\n456"))
        precondition(ExtractorCodigo.extraer(de: String(repeating: "A", count: 65),
                                             patron: #"(A+)"#) == nil)
        precondition(ExtractorCodigo.patronValido(#"codigo (\d{6})"#))
        precondition(!ExtractorCodigo.patronValido("("))
        precondition(ExtractorCodigo.patronValido(""))
        precondition(ExtractorCodigo.enmascarar("482913") == "48••13")
        precondition(ExtractorCodigo.enmascarar("1234") == "••••")

        // La configuración de Fortinet que se propone por defecto encuentra ese correo.
        precondition(ConfigCorreo.fortinet.remitente == "DoNotReply@notification.fortinet.net")
        precondition(ExtractorCodigo.consultaGmail(remitente: ConfigCorreo.fortinet.remitente,
                                                   asunto: ConfigCorreo.fortinet.asunto, desde: Date(timeIntervalSince1970: 100))
                     == "from:(DoNotReply@notification.fortinet.net) after:70 subject:(AuthCode)")

        // Búsqueda de Gmail.
        let desde = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(ExtractorCodigo.consultaGmail(remitente: " noreply@empresa.com ", asunto: "", desde: desde)
                     == "from:(noreply@empresa.com) after:1799999970")
        precondition(ExtractorCodigo.consultaGmail(remitente: "a@b.c", asunto: "AuthCode", desde: desde)
                     .hasSuffix("subject:(AuthCode)"))

        // PKCE: vector de ejemplo del RFC 7636, apéndice B.
        precondition(ExtractorCodigo.desafioPKCE("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                     == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verificador = ExtractorCodigo.verificadorPKCE()
        precondition(verificador.count == 43 && verificador != ExtractorCodigo.verificadorPKCE())
        precondition(!verificador.contains("+") && !verificador.contains("/") && !verificador.contains("="))

        // Base64 url y correo del id_token.
        let carga = ExtractorCodigo.codificarBase64URL(Data(#"{"email":"samuel@gmail.com","sub":"1"}"#.utf8))
        precondition(ExtractorCodigo.correoDeIDToken("e30.\(carga).firma") == "samuel@gmail.com")
        precondition(ExtractorCodigo.correoDeIDToken("no-es-un-token") == nil)
        precondition(String(decoding: ExtractorCodigo.decodificarBase64URL("SG9sYQ")!, as: UTF8.self) == "Hola")

        // Gmail puede entregar una parte de texto inline o mediante
        // attachmentId, incluso sin que sea un archivo adjunto visible.
        let mime: [String: Any] = [
            "mimeType": "multipart/alternative",
            "parts": [
                ["mimeType": "text/plain", "body": ["attachmentId": "texto-1", "size": 42]],
                ["mimeType": "text/html", "body": ["data": ExtractorCodigo.codificarBase64URL(Data("<b>123456</b>".utf8)), "size": 13]],
                ["mimeType": "image/png", "body": ["attachmentId": "imagen", "size": 2_000]],
            ],
        ]
        let partes = SoporteGmail.partesTexto(en: mime)
        precondition(partes.count == 2)
        precondition(partes[0] == ParteTextoGmail(formato: .plano, datos: nil, adjuntoID: "texto-1", tamano: 42))
        precondition(SoporteGmail.texto(datosBase64URL: [
            ExtractorCodigo.codificarBase64URL(Data("AuthCode: 246810".utf8)),
        ], formato: .plano) == "AuthCode: 246810")
        precondition(SoporteGmail.extraerCodigo(asunto: "AuthCode", cuerpo: "Este cuerpo no incluye cifras",
                                                patron: "") == nil)
        precondition(SoporteGmail.extraerCodigo(asunto: "AuthCode", cuerpo: "<b>975310</b>",
                                                patron: "") == "975310",
                     "si la parte plana no tiene código se debe poder probar la variante HTML")
        let fragmentoGrande = ExtractorCodigo.codificarBase64URL(
            Data(String(repeating: "a", count: SoporteGmail.maximoBytesTexto / 2 + 1).utf8))
        let textoAcotado = SoporteGmail.texto(datosBase64URL: [fragmentoGrande, fragmentoGrande], formato: .plano)
        precondition(textoAcotado.utf8.count <= SoporteGmail.maximoBytesTexto,
                     "el límite se aplica al cuerpo completo, no a cada fragmento por separado")
        let demasiadoGrande: [String: Any] = [
            "mimeType": "text/plain",
            "body": ["attachmentId": "enorme", "size": SoporteGmail.maximoBytesTexto + 1],
        ]
        precondition(SoporteGmail.partesTexto(en: demasiadoGrande).isEmpty)
        let configFortinet = ConfigCorreo.fortinet
        precondition(SoporteGmail.coincide(
            remitenteCabecera: "Fortinet <donotreply@notification.fortinet.net>",
            asuntoCabecera: "AuthCode: acceso", config: configFortinet
        ))
        precondition(!SoporteGmail.coincide(
            remitenteCabecera: "otro@example.com", asuntoCabecera: "AuthCode: acceso",
            config: configFortinet
        ))
        precondition(!SoporteGmail.coincide(
            remitenteCabecera: "DoNotReply@notification.fortinet.net", asuntoCabecera: "Aviso general",
            config: configFortinet
        ))

        // La consulta exacta ya incorpora `after:` y no vuelve a comparar
        // internalDate. Solo los mensajes del fallback sin `q` necesitan el
        // límite local; IDs usados o repetidos quedan fuera desde el inicio.
        let limiteFallback = Date(timeIntervalSince1970: 1_800_000_000)
        let candidatos = SoporteGmail.candidatos(
            filtrados: ["exacto", "usado"],
            recientes: ["exacto", "reciente", "usado"],
            excluidos: ["usado"], desdeMinimaRecientes: limiteFallback
        )
        precondition(candidatos == [
            CandidatoMensajeGmail(id: "exacto", desdeMinima: nil),
            CandidatoMensajeGmail(id: "reciente", desdeMinima: limiteFallback),
        ])

        // Un mensaje nuevo sin código se relee de forma acotada: Gmail puede
        // haber listado su ID antes de terminar de propagar las partes MIME.
        var inspeccion = RegistroInspeccionGmail()
        precondition(!inspeccion.excluidos(usados: []).contains("nuevo"))
        inspeccion.registrarSinCodigo(["nuevo"])
        inspeccion.registrarSinCodigo(["nuevo"])
        precondition(!inspeccion.excluidos(usados: []).contains("nuevo"))
        inspeccion.registrarSinCodigo(["nuevo"])
        precondition(inspeccion.excluidos(usados: []).contains("nuevo"),
                     "un mensaje sin código no debe releerse indefinidamente")
        inspeccion.descartar(["antiguo"])
        precondition(inspeccion.excluidos(usados: []).contains("antiguo"))
        precondition(inspeccion.excluidos(usados: ["usado"]).contains("usado"))

        // Sondeo normal y backoff truncado, con jitter y Retry-After.
        precondition(SoporteGmail.pausaSinCorreo(segundosTranscurridos: 0) == 3)
        precondition(SoporteGmail.pausaSinCorreo(segundosTranscurridos: 45) == 5)
        precondition(SoporteGmail.pausaSinCorreo(segundosTranscurridos: 120) == 8)
        precondition(SoporteGmail.pausaTrasError(fallosConsecutivos: 1, problema: .sinRed, jitter: 0) == 1)
        precondition(SoporteGmail.pausaTrasError(fallosConsecutivos: 4, problema: .sinRed, jitter: 0.5) == 8.5)
        precondition(SoporteGmail.pausaTrasError(fallosConsecutivos: 1, problema: .limite, jitter: 0) == 5)
        precondition(SoporteGmail.pausaTrasError(fallosConsecutivos: 8, problema: .limite, jitter: 1) == 30)
        precondition(SoporteGmail.pausaTrasError(fallosConsecutivos: 1, problema: .sinRed,
                                                retryAfter: 17, jitter: 0) == 17)
        precondition(SoporteGmail.pausaTrasError(fallosConsecutivos: 1, problema: .limite,
                                                retryAfter: 120, jitter: 0) == 120,
                     "Retry-After no se acorta; el límite global se aplica al dormir")
        precondition(SoporteGmail.retryAfter("12") == 12)
        let fechaHTTP = Date(timeIntervalSince1970: 1_800_000_030)
        precondition(SoporteGmail.retryAfter("Fri, 15 Jan 2027 08:00:30 GMT",
                                             ahora: Date(timeIntervalSince1970: 1_800_000_000)) == fechaHTTP.timeIntervalSince1970 - 1_800_000_000)

        // Errores de Gmail: cada uno con su explicación y su salida.
        func cuerpo(_ json: String) -> Data { Data(json.utf8) }
        precondition(ProblemaGmail.clasificar(estado: 403, cuerpo: cuerpo(#"{"error":{"code":403,"message":"Gmail API has not been used in project 123 before or it is disabled.","status":"PERMISSION_DENIED","details":[{"reason":"SERVICE_DISABLED"}]}}"#)) == .apiDesactivada)
        precondition(ProblemaGmail.clasificar(estado: 403, cuerpo: cuerpo(#"{"error":{"code":403,"errors":[{"reason":"accessNotConfigured"}]}}"#)) == .apiDesactivada)
        precondition(ProblemaGmail.clasificar(estado: 403, cuerpo: cuerpo(#"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#)) == .sinPermiso)
        precondition(ProblemaGmail.clasificar(estado: 429, cuerpo: cuerpo("{}")) == .limite)
        precondition(ProblemaGmail.clasificar(estado: 403, cuerpo: cuerpo(#"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#)) == .limite)
        precondition(ProblemaGmail.clasificar(estado: 403, cuerpo: cuerpo(#"{"error":{"code":403}}"#)) == .servidor(403),
                     "un 403 sin causa no demuestra que falte el permiso de lectura")
        precondition(ProblemaGmail.llaveroNoDisponible.definitivo)
        precondition(ProblemaGmail.llaveroNoDisponible.accion == .cuentaGoogle)
        precondition(ProblemaGmail.clasificar(estado: 500, cuerpo: cuerpo("no es json")) == .servidor(500))
        precondition(ProblemaGmail.clasificarToken("invalid_grant") == .sesionCaducada)
        precondition(ProblemaGmail.clasificarToken("invalid_client") == .clienteNoValido)
        precondition(ProblemaGmail.clasificar(URLError(.notConnectedToInternet)) == .sinRed)
        precondition(ProblemaGmail.sinRed.codigoDiagnostico == "sin_red")
        precondition(ProblemaGmail.apiDesactivada.definitivo && ProblemaGmail.sesionCaducada.definitivo)
        precondition(!ProblemaGmail.sinRed.definitivo && !ProblemaGmail.limite.definitivo)
        precondition(ProblemaGmail.servidor(0).detalle.hasPrefix("Google devolvió un error inesperado."))

        print("Correo: comprobaciones superadas")
    }

    private static func comprobarPreferenciaPapelera() throws {
        precondition(!AjustesApp().enviarCorreoPapelera)
        let anterior = try ArchivoAjustes.leer(Data(#"{"version":3,"correo":{},"ajusteFuturo":42}"#.utf8))
        precondition(!anterior.ajustes.enviarCorreoPapelera)
        var ajustes = anterior.ajustes
        ajustes.enviarCorreoPapelera = true
        let datos = try ArchivoAjustes.escribir(ajustes, sobre: anterior.crudo)
        let recuperada = try ArchivoAjustes.leer(datos)
        precondition(recuperada.ajustes.enviarCorreoPapelera && recuperada.crudo["ajusteFuturo"] as? Int == 42)
        ajustes.enviarCorreoPapelera = false
        let desactivada = try ArchivoAjustes.leer(ArchivoAjustes.escribir(ajustes, sobre: recuperada.crudo))
        precondition(!desactivada.ajustes.enviarCorreoPapelera)
    }

    @MainActor
    private static func comprobarUsoCorreo() {
        let mensaje = MensajeCodigoGmail(id: "abc123", sesion: UUID())
        var movidos: [MensajeCodigoGmail] = []
        let uso = UsoCorreoGmail { movidos.append($0) }
        let antesDeEntregar = uso.consultaPendiente
        uso.registrarEntrega(mensaje)
        let antesDeConfirmarProceso = uso.consultaPendiente
        precondition(movidos.isEmpty, "encontrar y entregar no equivale a usar con éxito")
        uso.confirmarProceso()
        let consultaVigente = uso.consultaPendiente
        precondition(consultaVigente != nil && movidos.isEmpty, "código cero habilita la consulta, sin confirmar el túnel")
        uso.confirmarTunel(consulta: antesDeEntregar)
        uso.confirmarTunel(consulta: antesDeConfirmarProceso)
        precondition(movidos.isEmpty, "una consulta iniciada antes de entregar el código o de confirmar el proceso no mueve el correo")
        uso.confirmarTunel(consulta: consultaVigente)
        uso.confirmarTunel(consulta: consultaVigente)
        uso.confirmarProceso()
        precondition(movidos == [mensaje], "solo un traslado por intento")
        precondition(uso.consultaPendiente == nil)

        let invertido = UsoCorreoGmail { movidos.append($0) }
        invertido.confirmarProceso()
        let antesDeEntregaTardia = invertido.consultaPendiente
        invertido.registrarEntrega(mensaje)
        invertido.confirmarTunel(consulta: antesDeEntregaTardia)
        precondition(movidos.count == 1, "la entrega tardía también requiere una consulta nueva")
        invertido.confirmarTunel(consulta: invertido.consultaPendiente)
        precondition(movidos.count == 2)

        for confirmarProceso in [false, true] {
            let cancelado = UsoCorreoGmail { _ in preconditionFailure("un intento cancelado no mueve correo") }
            cancelado.registrarEntrega(mensaje)
            if confirmarProceso { cancelado.confirmarProceso() }
            let consultaAnterior = cancelado.consultaPendiente
            cancelado.cancelar()
            cancelado.confirmarTunel(consulta: consultaAnterior)
            cancelado.confirmarProceso()
            cancelado.registrarEntrega(mensaje)
            precondition(cancelado.consultaPendiente == nil)
        }
        let manual = UsoCorreoGmail { _ in preconditionFailure("un código sin origen Gmail no mueve correo") }
        manual.registrarEntrega(nil)
        manual.confirmarProceso()
        precondition(manual.consultaPendiente == nil)
        manual.confirmarTunel(consulta: consultaVigente)
        let otro = UsoCorreoGmail { movidos.append($0) }
        otro.registrarEntrega(MensajeCodigoGmail(id: "def456", sesion: mensaje.sesion))
        otro.confirmarProceso()
        otro.confirmarTunel(consulta: consultaVigente)
        precondition(movidos.count == 2, "una consulta de otra VPN o intento no confirma este uso")
        let consultaAntesDeReemplazar = otro.consultaPendiente
        otro.registrarEntrega(mensaje)
        otro.confirmarTunel(consulta: consultaAntesDeReemplazar)
        precondition(movidos.count == 2, "una entrega distinta invalida la consulta anterior")
        otro.confirmarTunel(consulta: otro.consultaPendiente)
        precondition(movidos == [mensaje, mensaje, mensaje])

        var ahora = ContinuousClock.now
        let vencido = UsoCorreoGmail(ahora: { ahora }) { _ in
            preconditionFailure("un uso vencido no puede mover el correo")
        }
        vencido.registrarEntrega(mensaje)
        vencido.confirmarProceso()
        let consultaAntesDeVencer = vencido.consultaPendiente
        ahora = ahora.advanced(by: .seconds(29))
        precondition(vencido.consultaPendiente != nil)
        vencido.confirmarProceso() // Una respuesta duplicada no renueva el plazo.
        ahora = ahora.advanced(by: .seconds(1))
        vencido.confirmarTunel(consulta: consultaAntesDeVencer)
        precondition(vencido.consultaPendiente == nil)
        vencido.registrarEntrega(mensaje)
        vencido.confirmarProceso()
        precondition(vencido.consultaPendiente == nil, "el vencimiento es definitivo para ese intento")
    }

    private static func comprobarPapeleraHTTP() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProtocoloPapeleraSimulado.self]
        let sesion = URLSession(configuration: config)
        defer { sesion.invalidateAndCancel() }
        try await PapeleraGmail.mover("abc123", token: "ficticio", sesion: sesion)
        for (id, esperado) in [("permiso", ProblemaGmail.sinPermiso), ("caducado", .sesionCaducada),
                               ("limite", .limite), ("servidor", .servidor(503)),
                               ("sinconfirmar", .servidor(0)), ("otromensaje", .servidor(0))] {
            do {
                try await PapeleraGmail.mover(id, token: "ficticio", sesion: sesion)
                preconditionFailure("debía rechazar \(id)")
            } catch let problema as ProblemaGmail { precondition(problema == esperado) }
        }
        do {
            try await PapeleraGmail.mover("../threads/otro", token: "ficticio", sesion: sesion)
            preconditionFailure("no debe permitir cambiar el recurso")
        } catch let problema as ProblemaGmail { precondition(problema == .servidor(0)) }
    }
}

private final class ProtocoloPapeleraSimulado: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.httpMethod == "POST" && request.httpBody == nil)
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer ficticio")
        precondition(request.url?.host == "gmail.googleapis.com")
        let path = request.url!.path
        precondition(path.hasPrefix("/gmail/v1/users/me/messages/") && path.hasSuffix("/trash"))
        let id = path.split(separator: "/").dropLast().last!
        let estado: Int
        let cuerpo: String
        switch id {
        case "permiso": estado = 403; cuerpo = #"{"error":{"errors":[{"reason":"insufficientPermissions"}]}}"#
        case "caducado": estado = 401; cuerpo = "{}"
        case "limite": estado = 429; cuerpo = "{}"
        case "servidor": estado = 503; cuerpo = "{}"
        case "sinconfirmar": estado = 200; cuerpo = #"{"id":"sinconfirmar","labelIds":["INBOX"]}"#
        case "otromensaje": estado = 200; cuerpo = #"{"id":"equivocado","labelIds":["TRASH"]}"#
        default: estado = 200; cuerpo = #"{"id":"abc123","labelIds":["TRASH"]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: estado,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(cuerpo.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
