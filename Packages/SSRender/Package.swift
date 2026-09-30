// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSRender",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSRender", targets: ["SSRender"])],
    dependencies: [.package(path: "../SSCore")],
    targets: [
        .target(name: "SSRender", dependencies: ["SSCore"]),
        .testTarget(name: "SSRenderTests", dependencies: ["SSRender"]),
    ]
)
