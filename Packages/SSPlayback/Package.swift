// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSPlayback",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSPlayback", targets: ["SSPlayback"])],
    dependencies: [.package(path: "../SSCore"),.package(path: "../SSMedia"),.package(path: "../SSRender")],
    targets: [
        .target(name: "SSPlayback", dependencies: ["SSCore","SSMedia","SSRender"]),
        .testTarget(name: "SSPlaybackTests", dependencies: ["SSPlayback"]),
    ]
)
