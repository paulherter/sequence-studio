// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSExport",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSExport", targets: ["SSExport"])],
    dependencies: [.package(path: "../SSCore"), .package(path: "../SSRender"), .package(path: "../SSPlayback"),
                   .package(path: "../SSTranscribe"), .package(path: "../SSText"), .package(path: "../SSAudioFX"),
                   .package(path: "../SSMedia")],
    targets: [
        .target(name: "SSExport", dependencies: ["SSCore", "SSRender", "SSPlayback", "SSTranscribe", "SSText", "SSAudioFX", "SSMedia"]),
        .testTarget(name: "SSExportTests", dependencies: ["SSExport", "SSMedia", .product(name: "SSMediaTestSupport", package: "SSMedia")]),
    ]
)
