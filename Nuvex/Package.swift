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
        .executableTarget(
            name: "Nuvex",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Nuvex"
        )
    ]
)
