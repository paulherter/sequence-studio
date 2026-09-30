// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSCore", targets: ["SSCore"])],
    dependencies: [],
    targets: [
        .target(name: "SSCore", dependencies: []),
        .testTarget(name: "SSCoreTests", dependencies: ["SSCore"]),
    ]
)
