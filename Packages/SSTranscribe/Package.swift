// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSTranscribe",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSTranscribe", targets: ["SSTranscribe"])],
    dependencies: [.package(path: "../SSCore")],
    targets: [
        .target(name: "SSTranscribe", dependencies: ["SSCore"]),
        .testTarget(name: "SSTranscribeTests", dependencies: ["SSTranscribe"]),
    ]
)
