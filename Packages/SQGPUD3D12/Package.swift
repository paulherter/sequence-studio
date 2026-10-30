// swift-tools-version: 6.2
import PackageDescription

// SQGPUD3D12: the D3D12 backend of the SQGPU protocol (the Windows port plan, Phase 1 seam 4). Windows only: on the Mac
// both targets compile to empty modules, so the package resolves and its tests pass without doing anything.
// CSQGPUD3D12 is a small C++ shim (device, compute pipelines from the Slang-generated HLSL, textures, one command list);
// SQGPUD3D12 wraps it in the protocol types.
let package = Package(
    name: "SQGPUD3D12",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQGPUD3D12", targets: ["SQGPUD3D12"])],
    dependencies: [.package(path: "../SQGPU"), .package(path: "../SQRender")],
    targets: [
        .target(
            name: "CSQGPUD3D12",
            linkerSettings: [
                .linkedLibrary("d3d12", .when(platforms: [.windows])),
                .linkedLibrary("dxgi", .when(platforms: [.windows])),
                .linkedLibrary("d3dcompiler", .when(platforms: [.windows])),
            ]
        ),
        .target(name: "SQGPUD3D12", dependencies: ["CSQGPUD3D12", .product(name: "SQGPU", package: "SQGPU")]),
        .testTarget(
            name: "SQGPUD3D12Tests",
            dependencies: ["SQGPUD3D12", .product(name: "SQGPU", package: "SQGPU"),
                           .product(name: "SQGPUKernels", package: "SQGPU"), .product(name: "SQRender", package: "SQRender")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
