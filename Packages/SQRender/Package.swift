// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SQRender",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQRender", targets: ["SQRender"])],
    dependencies: [.package(path: "../SQCore")],
    targets: [
        .target(name: "SQRender", dependencies: ["SQCore"]),
        .testTarget(name: "SQRenderTests", dependencies: ["SQRender"]),
    ]
)
