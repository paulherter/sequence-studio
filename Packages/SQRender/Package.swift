// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SQRender",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQRender", targets: ["SQRender"])],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQFrame"), .package(path: "../SQGPU")],
    targets: [
        .target(name: "SQRender", dependencies: ["SQCore", .product(name: "SQFrame", package: "SQFrame"),
                                                .product(name: "SQFrameCoreVideo", package: "SQFrame"),
                                                .product(name: "SQGPU", package: "SQGPU"), .product(name: "SQGPUKernels", package: "SQGPU"),
                                                .product(name: "SQGPUMetal", package: "SQGPU")]),
        .testTarget(name: "SQRenderTests", dependencies: ["SQCore", "SQRender", .product(name: "SQFrame", package: "SQFrame"),
                                                          .product(name: "SQFrameCoreVideo", package: "SQFrame"),
                                                          .product(name: "SQGPU", package: "SQGPU"),
                                                          .product(name: "SQGPUKernels", package: "SQGPU"),
                                                          .product(name: "SQGPUMetal", package: "SQGPU")]),
    ]
)
