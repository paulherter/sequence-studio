// swift-tools-version: 6.2
import PackageDescription

// SQDrawKit: the portable UI toolkit of the Windows app (the Windows port plan, phase 2/3). Views emit a draw list of
// quads (rounded rects, glyphs from a CPU-rasterized atlas, the video picture, an icon triangle); each platform only has
// to draw quads. No AppKit, no WinSDK. `SoftwareRenderer` is the reference rasterizer of the same quads: the Mac (and the
// PC) render screenshots with it to compare against the D3D12 renderer pixel by pixel.
// SQDrawEditor holds the editor views (timeline, monitor, bars) fed by the SQCore model; they turn input into
// `EditorIntent`s that the host applies through the session.
let package = Package(
    name: "SQDrawKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SQDrawKit", targets: ["SQDrawKit"]),
        .library(name: "SQDrawEditor", targets: ["SQDrawEditor"]),
    ],
    dependencies: [.package(path: "../SQCore"), .package(path: "../SQText"), .package(path: "../SQUIKit"),
                   .package(path: "../SQGPU")],
    targets: [
        .target(name: "SQDrawKit", dependencies: ["SQCore", "SQText", "SQUIKit", .product(name: "SQGPUKernels", package: "SQGPU")]),
        .target(name: "SQDrawEditor", dependencies: ["SQDrawKit", "SQCore"]),
        .testTarget(name: "SQDrawKitTests", dependencies: ["SQDrawKit", "SQDrawEditor", "SQCore", "SQText", "SQUIKit",
                                                          .product(name: "SQGPUKernels", package: "SQGPU")]),
    ]
)
