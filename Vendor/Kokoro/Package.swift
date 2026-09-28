// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Kokoro",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Kokoro", targets: ["Kokoro"])],
    dependencies: [
        .package(path: "Packages/Misaki"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.3")
    ],
    targets: [.target(name: "Kokoro", dependencies: [
        .product(name: "Misaki", package: "Misaki"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXFast", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift")
    ])],
    swiftLanguageModes: [.v5]
)
