// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSExport",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSExport", targets: ["SSExport"])],
    dependencies: [.package(path: "../SSCore"), .package(path: "../SSRender"), .package(path: "../SSPlayback"),
                   .package(path: "../SSTranscribe"), .package(path: "../SSAudioFX")],
    targets: [
        .target(name: "SSExport", dependencies: ["SSCore", "SSRender", "SSPlayback", "SSTranscribe", "SSAudioFX"]),
        .testTarget(name: "SSExportTests", dependencies: ["SSExport"]),
    ]
)
