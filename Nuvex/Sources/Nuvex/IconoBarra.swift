import AppKit
import SwiftUI

/// Icono monocromo de la barra de menús. Es una imagen de plantilla para que
/// macOS lo tiña según la barra; el estado se distingue por la forma.
@MainActor
enum IconoBarra {
    enum Estado { case desconectado, conectando, conectado, atencion }

    private static var cache: [Estado: NSImage] = [:]

    static func imagen(_ estado: Estado) -> NSImage {
        if let imagen = cache[estado] { return imagen }
        let imagen = dibujar(estado)
        cache[estado] = imagen
        return imagen
    }

    private static func dibujar(_ estado: Estado) -> NSImage {
        let lado: CGFloat = 18
        let imagen = NSImage(size: NSSize(width: lado, height: lado), flipped: true) { _ in
            // Hexágono del logotipo (coordenadas 0–100) reducido a 18 pt.
            let escala: CGFloat = 0.15, margen: CGFloat = 1.5
            func punto(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: margen + x * escala, y: margen + y * escala)
            }
            let vertices = [punto(50, 10), punto(84, 30), punto(84, 70), punto(50, 90), punto(16, 70), punto(16, 30)]
            let hexagono = NSBezierPath()
            hexagono.move(to: vertices[0])
            vertices.dropFirst().forEach { hexagono.line(to: $0) }
            hexagono.close()
            hexagono.lineJoinStyle = .round
            hexagono.lineWidth = 1.8

            let tinta = estado == .atencion ? NSColor.labelColor : NSColor.black
            tinta.set()
            if estado == .conectado {
                hexagono.fill()
                hexagono.stroke()
            } else {
                hexagono.stroke()
                for v in [vertices[0], vertices[2], vertices[4]] {
                    NSBezierPath(ovalIn: NSRect(x: v.x - 1.7, y: v.y - 1.7, width: 3.4, height: 3.4)).fill()
                }
                if estado == .conectando {
                    let centro = punto(50, 50)
                    NSBezierPath(ovalIn: NSRect(x: centro.x - 2, y: centro.y - 2, width: 4, height: 4)).fill()
                }
            }
            if estado == .atencion {
                // Insignia de aviso: se recorta el fondo para que se lea sobre el contorno.
                let insignia = NSRect(x: 9.5, y: 9.5, width: 8.5, height: 8.5)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: insignia.insetBy(dx: -1.2, dy: -1.2)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.systemOrange.set()
                NSBezierPath(ovalIn: insignia).fill()
                NSColor.white.set()
                NSBezierPath(roundedRect: NSRect(x: 13.15, y: 11.3, width: 1.2, height: 3.3), xRadius: 0.6, yRadius: 0.6).fill()
                NSBezierPath(ovalIn: NSRect(x: 13.1, y: 15.1, width: 1.3, height: 1.3)).fill()
            }
            return true
        }
        // La variante de aviso lleva color; las demás se tiñen como plantilla.
        imagen.isTemplate = estado != .atencion
        return imagen
    }
}

struct EtiquetaBarra: View {
    @ObservedObject var modelo: VPNModel

    private var estado: IconoBarra.Estado {
        if modelo.requiereAtencion { return .atencion }
        if modelo.hayConectando { return .conectando }
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
                .renderingMode(estado == .atencion ? .original : .template)
            if modelo.conectadas > 1 {
                Text("\(modelo.conectadas)").monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(descripcion + (modelo.requiereAtencion ? ", requiere atención" : ""))
    }
}
