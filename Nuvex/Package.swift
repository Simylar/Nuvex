// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Nuvex",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Nuvex", path: "Sources/Nuvex")
    ]
)
