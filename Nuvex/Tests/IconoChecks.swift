import AppKit
import Foundation

guard (2...3).contains(CommandLine.arguments.count) else {
    fputs("Uso: icono-checks ICONSET [--completo]\n", stderr)
    exit(1)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let requiereIconsetCompleto = CommandLine.arguments.dropFirst(2).contains("--completo")
let archivos = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

var validados = 0
for (nombre, pixels) in archivos {
    let url = folder.appendingPathComponent(nombre)
    guard FileManager.default.fileExists(atPath: url.path) else {
        if requiereIconsetCompleto {
            fputs("Falta una representación del icono: \(nombre)\n", stderr)
            exit(1)
        }
        continue
    }
    guard let data = try? Data(contentsOf: url),
          let bitmap = NSBitmapImageRep(data: data),
          bitmap.pixelsWide == pixels,
          bitmap.pixelsHigh == pixels else {
        fputs("Dimensiones o PNG inválido: \(nombre)\n", stderr)
        exit(1)
    }

    let puntosTransparentes = [(0, 0), (pixels - 1, 0), (0, pixels - 1),
                                (pixels - 1, pixels - 1), (pixels / 2, pixels / 2)]
    guard puntosTransparentes.allSatisfy({ punto in
        (bitmap.colorAt(x: punto.0, y: punto.1)?.alphaComponent ?? 1) < 0.1
    }) else {
        fputs("El fondo o centro del logotipo está corrupto: \(nombre)\n", stderr)
        exit(1)
    }

    var visibles = 0
    var coloresMarca = 0
    for y in 0..<pixels {
        for x in 0..<pixels {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  color.alphaComponent > 0.1 else { continue }
            visibles += 1
            if color.blueComponent > color.redComponent + 0.08 {
                coloresMarca += 1
            }
        }
    }

    let total = pixels * pixels
    let proporcionVisible = Double(visibles) / Double(total)
    let proporcionMarca = visibles == 0 ? 0 : Double(coloresMarca) / Double(visibles)
    guard (0.15...0.65).contains(proporcionVisible), proporcionMarca > 0.8 else {
        fputs("Los píxeles del logotipo no corresponden a la marca: \(nombre)\n", stderr)
        exit(1)
    }
    validados += 1
}

guard validados >= 4 else {
    fputs("El icono no contiene suficientes representaciones.\n", stderr)
    exit(1)
}

print("Icono de aplicación válido en todas las escalas")
