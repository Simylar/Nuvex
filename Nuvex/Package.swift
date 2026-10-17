// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Nuvex",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Versión exacta: una actualización de Sparkle se revisa antes de adoptarla.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        // Protocolo y socket de control, compartidos por la app y el comando nuvex.
        .target(name: "NuvexControl", path: "Sources/NuvexControl"),
        .executableTarget(
            name: "Nuvex",
            dependencies: ["NuvexControl", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Nuvex"
        ),
        .executableTarget(
            name: "nuvex-cli",
            dependencies: ["NuvexControl"],
            path: "Sources/nuvex-cli"
        )
    ]
)
