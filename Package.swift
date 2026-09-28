// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HUDKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HUDKit", targets: ["HUDKit"]),
    ],
    targets: [
        .target(name: "HUDKit", path: "Sources/HUDKit"),
        .testTarget(name: "HUDKitTests", dependencies: ["HUDKit"], path: "Tests/HUDKitTests"),
    ]
)
