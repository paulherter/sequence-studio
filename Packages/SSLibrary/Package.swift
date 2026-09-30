// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSLibrary",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSLibrary", targets: ["SSLibrary"])],
    targets: [
        .target(name: "SSLibrary"),
        .testTarget(name: "SSLibraryTests", dependencies: ["SSLibrary"]),
    ]
)
