import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fputs("Uso: rasterize_svg.swift IMAGEN.svg ICONSET\n", stderr)
    exit(1)
}

let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func bitmap(width: Int, height: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: width * 4,
        bitsPerPixel: 32
    )
}

func draw(_ source: NSImage, pixels: Int) -> NSBitmapImageRep? {
    guard let bitmap = bitmap(width: pixels, height: pixels),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        return nil
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.imageInterpolation = .high
    source.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: NSRect(origin: .zero, size: source.size),
        operation: .copy,
        fraction: 1
    )
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

// AppKit puede producir bandas corruptas al rasterizar un SVG directamente a
// 16 o 32 px. Se crea una representación maestra y todas las variantes se
// reducen desde píxeles ya rasterizados, como recomienda el flujo de iconos de
// macOS para conservar el mismo dibujo en cada escala.
let masterPixels = 1024
guard let masterBitmap = draw(image, pixels: masterPixels) else {
    fputs("No se pudo rasterizar el icono maestro.\n", stderr)
    exit(1)
}
let masterImage = NSImage(size: NSSize(width: masterPixels, height: masterPixels))
masterImage.addRepresentation(masterBitmap)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = draw(masterImage, pixels: pixels) else {
            fputs("No se pudo crear el icono de \(pixels) píxeles.\n", stderr)
            exit(1)
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fputs("No se pudo guardar el icono.\n", stderr)
            exit(1)
        }
        let suffix = scale == 2 ? "@2x" : ""
        let target = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try data.write(to: target)
    }
}
