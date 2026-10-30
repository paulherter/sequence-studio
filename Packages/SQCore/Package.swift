// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SQCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQCore", targets: ["SQCore"])],
    dependencies: [],
    targets: [
        .target(name: "SQCore", dependencies: []),
        .testTarget(name: "SQCoreTests", dependencies: ["SQCore"]),
    ]
)
