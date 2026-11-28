// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YuE2Kit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "YuE2Kit", targets: ["YuE2Kit"]),
        .executable(name: "yue2-bench", targets: ["YuE2Bench"]),
        .executable(name: "vibeplayer-music", targets: ["VibePlayerMusicCLI"]),
    ],
    targets: [
        .target(name: "CAudioBridge"),
        .target(name: "YuE2Kit", dependencies: ["CAudioBridge"]),
        .executableTarget(name: "YuE2Bench", dependencies: ["YuE2Kit"]),
        .executableTarget(name: "VibePlayerMusicCLI", dependencies: ["YuE2Kit"]),
    ]
)
