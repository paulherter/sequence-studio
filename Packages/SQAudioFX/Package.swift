// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SQAudioFX",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQAudioFX", targets: ["SQAudioFX"])],
    dependencies: [.package(path: "../SQCore")],
    targets: [
        .target(
            name: "CRNNoise",
            exclude: ["COPYING"],
            cSettings: [.headerSearchPath(".")]
        ),
        .target(name: "SQAudioFX", dependencies: ["SQCore", "CRNNoise"]),
        .testTarget(name: "SQAudioFXTests", dependencies: ["SQCore", "SQAudioFX"]),
    ]
)
