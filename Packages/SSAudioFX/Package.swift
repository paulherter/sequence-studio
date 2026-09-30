// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSAudioFX",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSAudioFX", targets: ["SSAudioFX"])],
    dependencies: [.package(path: "../SSCore")],
    targets: [
        .target(
            name: "CRNNoise",
            exclude: ["COPYING"],
            cSettings: [.headerSearchPath(".")]
        ),
        .target(name: "SSAudioFX", dependencies: ["SSCore", "CRNNoise"]),
        .testTarget(name: "SSAudioFXTests", dependencies: ["SSAudioFX"]),
    ]
)
