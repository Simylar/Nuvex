import Foundation

/// Opera únicamente sobre un archivo que contiene una marca conocida. Nunca
/// sigue enlaces simbólicos ni elimina otros archivos de la misma carpeta.
enum ArchivoGestionado {
    enum Estado: Equatable {
        case ausente
        case gestionado(String)
        case ajeno
    }

    static func estado(carpeta: URL, archivo: URL, marca: String,
                       archivos: FileManager = .default) -> Estado {
        guard archivos.fileExists(atPath: carpeta.path) else { return .ausente }
        guard !esEnlaceSimbolico(carpeta), !esEnlaceSimbolico(archivo),
              let contenido = try? String(contentsOf: archivo, encoding: .utf8),
              contenido.contains(marca) else { return .ajeno }
        return .gestionado(contenido)
    }

    static func quitar(carpeta: URL, archivo: URL, marca: String,
                       archivos: FileManager = .default) throws {
        guard case .gestionado = estado(carpeta: carpeta, archivo: archivo, marca: marca, archivos: archivos) else {
            return
        }
        try archivos.removeItem(at: archivo)
        if try archivos.contentsOfDirectory(atPath: carpeta.path).isEmpty {
            try archivos.removeItem(at: carpeta)
        }
    }

    private static func esEnlaceSimbolico(_ url: URL) -> Bool {
        let valores = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return valores?.isSymbolicLink == true
    }
}
