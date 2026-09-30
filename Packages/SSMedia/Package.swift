// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSMedia",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSMedia", targets: ["SSMedia"])],
    dependencies: [.package(path: "../SSCore")],
    targets: [
        .target(name: "SSMedia", dependencies: ["SSCore"]),
        .testTarget(name: "SSMediaTests", dependencies: ["SSMedia"]),
    ]
)
