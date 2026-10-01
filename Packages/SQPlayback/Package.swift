// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SQPlayback",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQPlayback", targets: ["SQPlayback"])],
    dependencies: [.package(path: "../SQCore"),.package(path: "../SQMedia"),.package(path: "../SQRender"),.package(path: "../SQAudioFX"),.package(path: "../SQText")],
    targets: [
        .target(name: "SQPlayback", dependencies: ["SQCore","SQMedia","SQRender","SQAudioFX","SQText"]),
        .testTarget(name: "SQPlaybackTests", dependencies: ["SQPlayback","SQText","SQAudioFX","SQMedia",.product(name: "SQMediaTestSupport", package: "SQMedia")]),
    ]
)
