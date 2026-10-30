import Foundation

/// Referencia efímera al mensaje y a la sesión que lo leyó. No contiene el OTP.
struct MensajeCodigoGmail: Equatable, Sendable {
    let id: String
    let sesion: UUID
}

struct EntregaCodigo: Sendable {
    let codigo: String
    var mensaje: MensajeCodigoGmail? = nil
}

/// Una instancia por intento. Solo una consulta iniciada después de entregar
/// el código y confirmar el proceso puede autorizar el traslado del correo.
@MainActor
final class UsoCorreoGmail {
    static let esperaConfirmacion: Duration = .seconds(30)
    private var mensaje: MensajeCodigoGmail?
    private var procesoConfirmado = false
    private var revisionEntrega = UUID()
    private var terminado = false
    private var limiteConfirmacion: ContinuousClock.Instant?
    private let ahora: @MainActor () -> ContinuousClock.Instant
    private let alConsumir: @MainActor (MensajeCodigoGmail) -> Void

    init(ahora: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         alConsumir: @escaping @MainActor (MensajeCodigoGmail) -> Void) {
        self.ahora = ahora
        self.alConsumir = alConsumir
    }

    /// Se captura al iniciar `list`, no al recibir su respuesta. Una consulta
    /// previa o de otro intento nunca acredita el uso de este mensaje.
    var consultaPendiente: UUID? {
        if let limiteConfirmacion, ahora() >= limiteConfirmacion { cancelar() }
        return !terminado && procesoConfirmado && mensaje != nil ? revisionEntrega : nil
    }

    func registrarEntrega(_ mensaje: MensajeCodigoGmail?) {
        guard !terminado else { return }
        self.mensaje = mensaje
        revisionEntrega = UUID()
    }

    func confirmarProceso() {
        guard !terminado else { return }
        procesoConfirmado = true
        // `list` puede haber retirado inicioConexion antes del resultado del
        // proceso. El plazo del correo debe existir también en esa secuencia.
        if limiteConfirmacion == nil {
            limiteConfirmacion = ahora().advanced(by: Self.esperaConfirmacion)
        }
    }

    func confirmarTunel(consulta: UUID?) {
        guard let consulta, consulta == consultaPendiente, let mensaje else { return }
        terminado = true
        self.mensaje = nil
        alConsumir(mensaje)
    }

    func cancelar() {
        terminado = true
        mensaje = nil
    }
}
