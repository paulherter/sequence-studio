// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSProxy",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SSProxy", targets: ["SSProxy"]),
    ],
    dependencies: [.package(path: "../SSCore")],
    targets: [
        .target(name: "SSProxy", dependencies: ["SSCore"]),
        .testTarget(name: "SSProxyTests", dependencies: ["SSProxy"]),
    ]
)
