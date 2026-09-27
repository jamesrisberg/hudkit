// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "__PRODUCT__",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "__PRODUCT__Kit", targets: ["__PRODUCT__Kit"]),
        .executable(name: "__PRODUCT__", targets: ["__PRODUCT__"]),
        // Installed as Contents/Helpers/__REPO__: a distinct product name because __PRODUCT__ and
        // __REPO__ would collide on a case-insensitive volume.
        .executable(name: "__PRODUCT__CLI", targets: ["__PRODUCT__CLI"]),
    ],
    dependencies: [
        // Sibling checkout: ~/dev/hudkit next to ~/dev/__REPO__.
        .package(path: "../hudkit"),
    ],
    targets: [
        // Pure core: models, parsing, persistence. No AppKit UI; everything here is unit-tested.
        .target(
            name: "__PRODUCT__Kit",
            path: "Sources/__PRODUCT__Kit"
        ),
        .executableTarget(
            name: "__PRODUCT__",
            dependencies: ["__PRODUCT__Kit", .product(name: "HUDKit", package: "hudkit")],
            path: "Sources/__PRODUCT__",
            // Bundle files, assembled into the .app by hudkit/scripts/hud-build.sh.
            exclude: ["Resources"]
        ),
        // `__REPO__ <command> [key=value ...]`: a thin client for the MacHUD control socket.
        .executableTarget(
            name: "__PRODUCT__CLI",
            dependencies: [.product(name: "HUDKit", package: "hudkit")],
            path: "Sources/__PRODUCT__CLI"
        ),
        .testTarget(
            name: "__PRODUCT__KitTests",
            dependencies: ["__PRODUCT__Kit"],
            path: "Tests/__PRODUCT__KitTests"
        ),
        // Host logic in the app target and the shipped manifest/settings schema.
        .testTarget(
            name: "__PRODUCT__Tests",
            dependencies: ["__PRODUCT__", "__PRODUCT__Kit", .product(name: "HUDKit", package: "hudkit")],
            path: "Tests/__PRODUCT__Tests"
        ),
    ]
)
