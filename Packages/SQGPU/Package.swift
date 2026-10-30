// swift-tools-version: 6.2
import PackageDescription

// SQGPU: thin GPU backend protocol under the renderer (the Windows port plan, Phase 1 seam 4).
// `SQGPU` (protocol) and `SQGPUKernels` (Slang-generated MSL + HLSL, passes written once) are portable and build on
// Windows; `SQGPUMetal` is the Mac backend and compiles to an empty module where Metal does not exist. The D3D12 backend
// is its own package (SQGPUD3D12, Windows only).
let package = Package(
    name: "SQGPU",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SQGPU", targets: ["SQGPU"]),
        .library(name: "SQGPUKernels", targets: ["SQGPUKernels"]),
        .library(name: "SQGPUMetal", targets: ["SQGPUMetal"]),
    ],
    targets: [
        .target(name: "SQGPU"),
        .target(name: "SQGPUKernels", dependencies: ["SQGPU"]),
        .target(name: "SQGPUMetal", dependencies: ["SQGPU"]),
        .testTarget(name: "SQGPUTests", dependencies: ["SQGPU", "SQGPUKernels", "SQGPUMetal"]),
    ]
)
