// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSMedia",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SSMedia", targets: ["SSMedia"]),
        .library(name: "SSMediaTestSupport", targets: ["SSMediaTestSupport"]),
    ],
    dependencies: [.package(path: "../SSCore")],
    targets: [
        .target(name: "SSMedia", dependencies: ["SSCore"]),
        .target(name: "SSMediaTestSupport", path: "Sources/SSMediaTestSupport"),
        .testTarget(name: "SSMediaTests", dependencies: ["SSMedia", "SSMediaTestSupport"]),
    ]
)
