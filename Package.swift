// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LunarLanderMetal",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LunarLanderMetal",
            path: "Sources/LunarLanderMetal",
            linkerSettings: [.linkedFramework("AVFoundation")]
        )
    ]
)
