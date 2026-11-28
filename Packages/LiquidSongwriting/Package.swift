// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LiquidSongwriting",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "LiquidSongwriting", targets: ["LiquidSongwriting"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.33.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.33.0")),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.4.0")
    ],
    targets: [
        .target(name: "LiquidSongwriting", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ])
    ]
)
