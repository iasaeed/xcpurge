// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xcpurge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "xcpurge", targets: ["xcpurge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "XcpurgeKit", resources: [.copy("Resources")]),
        .executableTarget(
            name: "xcpurge",
            dependencies: [
                "XcpurgeKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "XcpurgeKitTests",
            dependencies: ["XcpurgeKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
