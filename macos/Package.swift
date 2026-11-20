// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EdgeGlow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EdgeGlow",
            path: "Sources/EdgeGlow",
            // Compiled into Contents/Resources/default.metallib by build.sh.
            exclude: ["Lyrics/Shaders/Shaders.metal"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
