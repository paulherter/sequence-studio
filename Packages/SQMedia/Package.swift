// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SQMedia",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SQMedia", targets: ["SQMedia"]),
        .library(name: "SQMediaTestSupport", targets: ["SQMediaTestSupport"]),
    ],
    dependencies: [.package(path: "../SQCore")],
    targets: [
        .target(name: "SQMedia", dependencies: ["SQCore"]),
        .target(name: "SQMediaTestSupport", path: "Sources/SQMediaTestSupport"),
        .testTarget(name: "SQMediaTests", dependencies: ["SQMedia", "SQMediaTestSupport"]),
    ]
)
