// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SQTranscribe",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQTranscribe", targets: ["SQTranscribe"])],
    dependencies: [.package(path: "../SQCore")],
    targets: [
        .target(name: "SQTranscribe", dependencies: ["SQCore"]),
        .testTarget(name: "SQTranscribeTests", dependencies: ["SQTranscribe"]),
    ]
)
