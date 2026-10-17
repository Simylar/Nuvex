import SwiftUI

/// Logotipo de Nuvex dibujado con la geometría y los degradados de
/// Resources/nuvex_mark.svg (lienzo de 100 × 100). Es vectorial: se ve nítido
/// a cualquier tamaño y no depende de archivos del paquete.
struct LogoNuvex: View {
    var lado: CGFloat = 64

    private struct Trazo {
        let puntos: [CGPoint]
        let desde: Color
        let hasta: Color
        /// Dirección del degradado en la caja del trazo, como x1/y1/x2/y2 del SVG.
        let inicio: UnitPoint
        let fin: UnitPoint
    }

    private static let trazos = [
        Trazo(puntos: [CGPoint(x: 50, y: 10), CGPoint(x: 84, y: 30), CGPoint(x: 84, y: 70)],
              desde: Color(hex: 0x35C5FA), hasta: Color(hex: 0x5278F7), inicio: .topLeading, fin: .bottomTrailing),
        Trazo(puntos: [CGPoint(x: 84, y: 70), CGPoint(x: 50, y: 90), CGPoint(x: 16, y: 70)],
              desde: Color(hex: 0x668CFF), hasta: Color(hex: 0x7650EC), inicio: .topTrailing, fin: .bottomLeading),
        Trazo(puntos: [CGPoint(x: 16, y: 70), CGPoint(x: 16, y: 30), CGPoint(x: 50, y: 10)],
              desde: Color(hex: 0x297EF4), hasta: Color(hex: 0x40B8F5), inicio: .bottomLeading, fin: .topTrailing),
    ]

    private static let puntos: [(CGPoint, Color)] = [
        (CGPoint(x: 50, y: 10), Color(hex: 0x38BDF8)),
        (CGPoint(x: 84, y: 70), Color(hex: 0x7551EF)),
        (CGPoint(x: 16, y: 70), Color(hex: 0x2C88F5)),
    ]

    var body: some View {
        Canvas { contexto, tamano in
            let escala = min(tamano.width, tamano.height) / 100
            func p(_ punto: CGPoint) -> CGPoint { CGPoint(x: punto.x * escala, y: punto.y * escala) }
            let estilo = StrokeStyle(lineWidth: 13 * escala, lineCap: .round, lineJoin: .round)
            for trazo in Self.trazos {
                var camino = Path()
                camino.addLines(trazo.puntos.map(p))
                let caja = camino.boundingRect
                func enCaja(_ u: UnitPoint) -> CGPoint {
                    CGPoint(x: caja.minX + caja.width * u.x, y: caja.minY + caja.height * u.y)
                }
                contexto.stroke(camino, with: .linearGradient(Gradient(colors: [trazo.desde, trazo.hasta]),
                                                             startPoint: enCaja(trazo.inicio), endPoint: enCaja(trazo.fin)),
                                style: estilo)
            }
            for (centro, color) in Self.puntos {
                let c = p(centro), r = 8 * escala
                contexto.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color))
            }
        }
        .frame(width: lado, height: lado)
        .accessibilityLabel("Nuvex")
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
