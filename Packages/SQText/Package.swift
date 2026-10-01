// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SQText",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQText", targets: ["SQText"])],
    dependencies: [.package(path: "../SQCore")],
    targets: [
        .target(name: "SQText", dependencies: ["SQCore"]),
        .testTarget(name: "SQTextTests", dependencies: ["SQText"]),
    ]
)
