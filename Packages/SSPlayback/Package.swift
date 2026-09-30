// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSPlayback",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSPlayback", targets: ["SSPlayback"])],
    dependencies: [.package(path: "../SSCore"),.package(path: "../SSMedia"),.package(path: "../SSRender"),.package(path: "../SSAudioFX")],
    targets: [
        .target(name: "SSPlayback", dependencies: ["SSCore","SSMedia","SSRender","SSAudioFX"]),
        .testTarget(name: "SSPlaybackTests", dependencies: ["SSPlayback","SSAudioFX","SSMedia",.product(name: "SSMediaTestSupport", package: "SSMedia")]),
    ]
)
