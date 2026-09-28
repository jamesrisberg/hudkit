// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HUDKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HUDKit", targets: ["HUDKit"]),
        .library(name: "VoiceKit", targets: ["VoiceKit"]),
    ],
    dependencies: [
        // VoiceKit only. SwiftPM resolves these for every consumer of the package, but only
        // an app that imports VoiceKit builds them.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
        .package(path: "Vendor/Kokoro"),
    ],
    targets: [
        .target(name: "HUDKit", path: "Sources/HUDKit"),
        .testTarget(name: "HUDKitTests", dependencies: ["HUDKit"], path: "Tests/HUDKitTests"),
        .target(
            name: "VoiceKit",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Kokoro", package: "Kokoro"),
            ],
            path: "Sources/VoiceKit"
        ),
        .testTarget(
            name: "VoiceKitTests",
            dependencies: ["VoiceKit"],
            path: "Tests/VoiceKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
