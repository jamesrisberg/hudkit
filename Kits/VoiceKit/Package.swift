// swift-tools-version:5.9
import PackageDescription

// VoiceKit is its own package so that apps depending on HUDKit resolve none of its
// dependencies (ONNX Runtime, MLX). Depend on it with `.package(path: "../hudkit/Kits/VoiceKit")`.
let package = Package(
    name: "VoiceKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoiceKit", targets: ["VoiceKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
        .package(path: "Vendor/Kokoro"),
    ],
    targets: [
        .target(
            name: "VoiceKit",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Kokoro", package: "Kokoro"),
            ]
        ),
        .testTarget(
            name: "VoiceKitTests",
            dependencies: ["VoiceKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
