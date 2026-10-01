// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SQProxy",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SQProxy", targets: ["SQProxy"]),
    ],
    dependencies: [.package(path: "../SQCore")],
    targets: [
        .target(name: "SQProxy", dependencies: ["SQCore"]),
        .testTarget(name: "SQProxyTests", dependencies: ["SQProxy"]),
    ]
)
