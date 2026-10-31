// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Critique",
    platforms: [.macOS(.v15)],
    dependencies: [
        // A real terminal for the agents Critique runs (Agent tab).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .executableTarget(name: "Critique",
                          dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
                          path: "Sources/Critique")
    ],
    swiftLanguageModes: [.v5]
)
