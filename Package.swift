// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Critique",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Critique", path: "Sources/Critique")
    ],
    swiftLanguageModes: [.v5]
)
