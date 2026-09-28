// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Misaki",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "Misaki",
            targets: ["Misaki"]
        ),
    ],
    targets: [
        .testTarget(name: "MisakiTests", dependencies: ["Misaki"]),
        .target(
            name: "Misaki",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
