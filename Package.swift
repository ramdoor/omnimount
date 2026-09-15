// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Omnimount",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OmnimountKit", targets: ["OmnimountKit"]),
        .executable(name: "omnimount", targets: ["OmnimountCLI"]),
        .executable(name: "OmnimountApp", targets: ["OmnimountApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "OmnimountKit"),
        .executableTarget(
            name: "OmnimountCLI",
            dependencies: [
                "OmnimountKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "OmnimountApp",
            dependencies: [
                "OmnimountKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(
            name: "OmnimountHelper",
            dependencies: ["OmnimountKit"]
        ),
        .testTarget(
            name: "OmnimountKitTests",
            dependencies: ["OmnimountKit"]
        ),
    ]
)
