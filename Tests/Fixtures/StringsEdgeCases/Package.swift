// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StringsEdgeCases",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Feature", targets: ["Feature"]),
    ],
    targets: [
        .target(name: "Feature", resources: [.process("Resources")]),
    ]
)
