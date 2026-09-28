// swift-tools-version:5.9
import PackageDescription

// BrainKit: a local agent brain (Codex, Claude Code, Hermes) behind a bundled Node companion.
// Its own package in the HUDKit repo: depend on it with `.package(path: "../hudkit/Kits/BrainKit")`.
let package = Package(
    name: "BrainKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BrainKit", targets: ["BrainKit"]),
    ],
    targets: [
        // The Node companion ships as a resource (BrainKit_BrainKit.bundle/Companion), with its tests.
        .target(name: "BrainKit", path: "Sources/BrainKit", resources: [.copy("Companion")]),
        .testTarget(name: "BrainKitTests", dependencies: ["BrainKit"], path: "Tests/BrainKitTests"),
    ]
)
