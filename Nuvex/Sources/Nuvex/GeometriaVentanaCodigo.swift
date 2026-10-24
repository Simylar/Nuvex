import AppKit

/// Calcula una posición completamente visible en la pantalla donde se originó
/// la interacción. Es pura para poder probar pantallas pequeñas y cascadas.
enum GeometriaVentanaCodigo {
    static func marco(areaVisible: NSRect, tamanoIdeal: NSSize, indice: Int,
                      margen: CGFloat = Espacio.xxxl) -> NSRect {
        let margenX = min(max(0, margen), max(0, (areaVisible.width - 1) / 2))
        let margenY = min(max(0, margen), max(0, (areaVisible.height - 1) / 2))
        let anchoDisponible = max(1, areaVisible.width - margenX * 2)
        let altoDisponible = max(1, areaVisible.height - margenY * 2)
        let ancho = min(tamanoIdeal.width, anchoDisponible)
        let alto = min(tamanoIdeal.height, altoDisponible)
        let desplazamiento = CGFloat(max(0, indice)) * Espacio.xxl
        var x = areaVisible.midX - ancho / 2 + desplazamiento
        var y = areaVisible.midY - alto / 2 - desplazamiento
        x = min(max(x, areaVisible.minX + margenX), areaVisible.maxX - margenX - ancho)
        y = min(max(y, areaVisible.minY + margenY), areaVisible.maxY - margenY - alto)
        return NSRect(x: x, y: y, width: ancho, height: alto)
    }
}
