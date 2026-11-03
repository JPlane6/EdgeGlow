// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EdgeGlow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EdgeGlow",
            path: "Sources/EdgeGlow"
        )
    ],
    swiftLanguageVersions: [.v5]
)
