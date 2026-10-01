// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SQExport",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQExport", targets: ["SQExport"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQRender"), .package(path: "../SQPlayback"),
                   .package(path: "../SQTranscribe"), .package(path: "../SQText"), .package(path: "../SQAudioFX"),
                   .package(path: "../SQMedia")],
    targets: [
        .target(name: "SQExport", dependencies: ["SQCore", "SQRender", "SQPlayback", "SQTranscribe", "SQText", "SQAudioFX", "SQMedia"]),
        .testTarget(name: "SQExportTests", dependencies: ["SQExport", "SQMedia", .product(name: "SQMediaTestSupport", package: "SQMedia")]),
    ]
)
