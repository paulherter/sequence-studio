// swift-tools-version: 6.2
import PackageDescription

// SQFrame: the neutral video frame handed across package boundaries (the Windows port plan, Phase 1 seam 1).
// `SQFrame` is portable (no Apple imports, builds on Windows); `SQFrameCoreVideo` wraps a CVPixelBuffer without copying
// and compiles to an empty module where CoreVideo does not exist.
let package = Package(
    name: "SQFrame",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SQFrame", targets: ["SQFrame"]),
        .library(name: "SQFrameCoreVideo", targets: ["SQFrameCoreVideo"]),
    ],
    dependencies: [.package(path: "../SQCore")],
    targets: [
        .target(name: "SQFrame", dependencies: ["SQCore"]),
        .target(name: "SQFrameCoreVideo", dependencies: ["SQCore", "SQFrame"]),
        .testTarget(name: "SQFrameTests", dependencies: ["SQCore", "SQFrame", "SQFrameCoreVideo"]),
    ]
)
