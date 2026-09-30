// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSText",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSText", targets: ["SSText"])],
    dependencies: [.package(path: "../SSCore")],
    targets: [
        .target(name: "SSText", dependencies: ["SSCore"]),
        .testTarget(name: "SSTextTests", dependencies: ["SSText"]),
    ]
)
