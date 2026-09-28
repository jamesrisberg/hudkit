// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HUDKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HUDKit", targets: ["HUDKit"]),
        .library(name: "BrainKit", targets: ["BrainKit"]),
    ],
    targets: [
        .target(name: "HUDKit", path: "Sources/HUDKit"),
        .testTarget(name: "HUDKitTests", dependencies: ["HUDKit"], path: "Tests/HUDKitTests"),
        // The Node companion ships as a resource (HUDKit_BrainKit.bundle/Companion), with its tests.
        .target(name: "BrainKit", path: "Sources/BrainKit", resources: [.copy("Companion")]),
        .testTarget(name: "BrainKitTests", dependencies: ["BrainKit"], path: "Tests/BrainKitTests"),
    ]
)
