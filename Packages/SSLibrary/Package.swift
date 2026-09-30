// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSLibrary",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SSLibrary", targets: ["SSLibrary"])],
    dependencies: [.package(path: "../SSCore"), .package(path: "../SSMedia")],
    targets: [
        .target(name: "SSLibrary", dependencies: ["SSCore", .product(name: "SSMedia", package: "SSMedia")]),
        .testTarget(name: "SSLibraryTests", dependencies: [
            "SSLibrary",
            .product(name: "SSMedia", package: "SSMedia"),
            .product(name: "SSMediaTestSupport", package: "SSMedia"),
        ]),
    ]
)
