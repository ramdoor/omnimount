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
            dependencies: ["OmnimountKit"]
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
