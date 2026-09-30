// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSLibrary",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSLibrary", targets: ["SSLibrary"])],
    dependencies: [.package(path: "../SSCore")],
    targets: [
        .target(name: "SSLibrary", dependencies: ["SSCore"]),
        .testTarget(name: "SSLibraryTests", dependencies: ["SSLibrary"]),
    ]
)
