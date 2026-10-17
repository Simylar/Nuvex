import AppKit
import SwiftUI

/// Icono monocromo de la barra de menús. Es una imagen de plantilla para que
/// macOS lo tiña según la barra; el estado se distingue por la forma: contorno
/// sin conexión, relleno conectado, un vértice que gira mientras conecta y una
/// insignia naranja cuando algo requiere atención.
@MainActor
enum IconoBarra {
    enum Estado: Hashable {
        case desconectado
        /// Fotograma de la animación (0–5): el vértice resaltado.
        case conectando(Int)
        case conectado
        case atencion

        var tieneColor: Bool { self == .conectado || self == .atencion }
    }

    static let fotogramas = 6
    private static var cache: [Estado: NSImage] = [:]

    static func imagen(_ estado: Estado) -> NSImage {
        if let imagen = cache[estado] { return imagen }
        let imagen = dibujar(estado)
        cache[estado] = imagen
        return imagen
    }

    /// Vértices del hexágono del logotipo (lienzo 0–100) en un icono de 18 pt,
    /// alineados al medio punto para que el trazo caiga en píxeles enteros en
    /// pantallas Retina.
    private static let vertices: [NSPoint] = {
        let escala: CGFloat = 0.16   // 80 unidades de alto → 12,8 pt; margen para los puntos
        let desplazamiento = NSPoint(x: (18 - 68 * escala) / 2 - 16 * escala, y: (18 - 80 * escala) / 2 - 10 * escala)
        let logo: [(CGFloat, CGFloat)] = [(50, 10), (84, 30), (84, 70), (50, 90), (16, 70), (16, 30)]
        return logo.map { x, y in
            NSPoint(x: ((desplazamiento.x + x * escala) * 2).rounded() / 2,
                    y: ((desplazamiento.y + y * escala) * 2).rounded() / 2)
        }
    }()

    private static func punto(_ centro: NSPoint, radio: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: centro.x - radio, y: centro.y - radio, width: radio * 2, height: radio * 2))
    }

    private static func dibujar(_ estado: Estado) -> NSImage {
        let imagen = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let hexagono = NSBezierPath()
            hexagono.move(to: vertices[0])
            vertices.dropFirst().forEach { hexagono.line(to: $0) }
            hexagono.close()
            hexagono.lineJoinStyle = .round
            hexagono.lineWidth = 1.5

            (estado == .atencion ? NSColor.labelColor : NSColor.black).set()
            switch estado {
            case .conectado:
                // Verde con una marca blanca: conectada se reconoce de un vistazo.
                NSColor.systemGreen.set()
                hexagono.fill()
                hexagono.stroke()
                let centro = NSPoint(x: (vertices[1].x + vertices[4].x) / 2, y: (vertices[0].y + vertices[3].y) / 2)
                let marca = NSBezierPath()
                marca.move(to: NSPoint(x: centro.x - 2.6, y: centro.y + 0.1))
                marca.line(to: NSPoint(x: centro.x - 0.7, y: centro.y + 2.0))
                marca.line(to: NSPoint(x: centro.x + 2.7, y: centro.y - 1.8))
                marca.lineWidth = 1.6
                marca.lineCapStyle = .round
                marca.lineJoinStyle = .round
                NSColor.white.set()
                marca.stroke()
            case .conectando(let fotograma):
                hexagono.stroke()
                // Un vértice destacado recorre el hexágono.
                for (indice, vertice) in vertices.enumerated() {
                    let activo = indice == fotograma % fotogramas
                    punto(vertice, radio: activo ? 2.1 : 0.9).fill()
                }
            case .desconectado, .atencion:
                hexagono.stroke()
                // Los tres puntos del logotipo.
                for indice in [0, 2, 4] { punto(vertices[indice], radio: 1.5).fill() }
            }
            if estado == .atencion {
                // Insignia de aviso: se recorta el fondo para que se lea sobre el contorno.
                let insignia = NSRect(x: 10.5, y: 10.5, width: 7.5, height: 7.5)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: insignia.insetBy(dx: -1, dy: -1)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.systemOrange.set()
                NSBezierPath(ovalIn: insignia).fill()
                NSColor.white.set()
                NSBezierPath(roundedRect: NSRect(x: 13.7, y: 11.9, width: 1.1, height: 2.9), xRadius: 0.55, yRadius: 0.55).fill()
                NSBezierPath(ovalIn: NSRect(x: 13.65, y: 15.25, width: 1.2, height: 1.2)).fill()
            }
            return true
        }
        // Conectada y aviso llevan color propio; las demás se tiñen como plantilla.
        imagen.isTemplate = !estado.tieneColor
        return imagen
    }
}

struct EtiquetaBarra: View {
    @ObservedObject var modelo: VPNModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reducirMovimiento
    @State private var fotograma = 0

    private var estado: IconoBarra.Estado {
        if modelo.requiereAtencion { return .atencion }
        if modelo.hayConectando { return .conectando(reducirMovimiento ? 0 : fotograma) }
        return modelo.conectadas > 0 ? .conectado : .desconectado
    }

    private var descripcion: String {
        switch modelo.conectadas {
        case 0: return "Nuvex, sin VPN conectadas"
        case 1: return "Nuvex, 1 VPN conectada"
        case let n: return "Nuvex, \(n) VPN conectadas"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: IconoBarra.imagen(estado))
                .renderingMode(estado.tieneColor ? .original : .template)
            if modelo.conectadas > 1 {
                Text("\(modelo.conectadas)").monospacedDigit()
            }
        }
        .onAppear { AperturaAjustes.accion = openSettings }
        // La animación solo corre mientras hay una conexión en curso.
        .task(id: modelo.hayConectando && !reducirMovimiento) {
            guard modelo.hayConectando && !reducirMovimiento else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                fotograma = (fotograma + 1) % IconoBarra.fotogramas
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(descripcion + (modelo.requiereAtencion ? ", requiere atención" : ""))
    }
}

/// Abre la ventana de Ajustes desde código AppKit (avisos, enlaces). SwiftUI
/// solo ofrece openSettings dentro de las vistas; la etiqueta de la barra, que
/// siempre está activa, la deja aquí al aparecer.
@MainActor
enum AperturaAjustes {
    static var accion: OpenSettingsAction?

    static func abrir(_ modelo: VPNModel, conexion id: String? = nil) {
        if let id { modelo.settingsTargetID = id }
        NSApp.activate(ignoringOtherApps: true)
        accion?()
    }
}
