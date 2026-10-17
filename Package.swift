// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "UXFlow",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "UXFlow", path: "Sources/UXFlow")
    ],
    swiftLanguageModes: [.v5]
)
