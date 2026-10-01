// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SQLibrary",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQLibrary", targets: ["SQLibrary"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQMedia")],
    targets: [
        .target(name: "SQLibrary", dependencies: ["SQCore", .product(name: "SQMedia", package: "SQMedia")]),
        .testTarget(name: "SQLibraryTests", dependencies: [
            "SQLibrary",
            .product(name: "SQMedia", package: "SQMedia"),
            .product(name: "SQMediaTestSupport", package: "SQMedia"),
        ]),
    ]
)
