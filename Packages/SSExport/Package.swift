// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSExport",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSExport", targets: ["SSExport"])],
    dependencies: [.package(path: "../SSCore"), .package(path: "../SSRender"), .package(path: "../SSPlayback")],
    targets: [
        .target(name: "SSExport", dependencies: ["SSCore", "SSRender", "SSPlayback"]),
        .testTarget(name: "SSExportTests", dependencies: ["SSExport"]),
    ]
)
