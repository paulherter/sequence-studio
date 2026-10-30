// swift-tools-version: 6.2
// The first runnable Windows app (the Windows port plan, "App status"): a Win32 window with a D3D12 swap chain that opens a
// .sqproj, runs the portable EditorSession with the FFmpeg media layer and draws the SQDrawKit editor (Program monitor,
// timeline). Build and run on the PC with scripts/win-app.sh. On the Mac only `SQMacReference` builds: it renders the
// reference picture of a project frame (SQExport, the Mac pipeline) and the same editor draw list through the software
// renderer, for the pixel comparisons.
import Foundation
import PackageDescription

#if os(Windows)
let ff = (ProcessInfo.processInfo.environment["SQ_FFMPEG"] ?? (ProcessInfo.processInfo.environment["USERPROFILE"] ?? "C:").appending("/ffmpeg/ffmpeg-master-latest-win64-lgpl-shared"))
    .replacingOccurrences(of: "\\", with: "/")
let package = Package(
    name: "SQWinApp",
    dependencies: [
        .package(path: "../../Packages/SQCore"), .package(path: "../../Packages/SQDrawKit"),
        .package(path: "../../Packages/SQEditorSession"), .package(path: "../../Packages/SQMediaFFmpeg"),
        .package(path: "../../Packages/SQMedia"), .package(path: "../../Packages/SQFrame"),
        .package(path: "../../Packages/SQPlayback"), .package(path: "../../Packages/SQDrawTimeline"),
        .package(path: "../../Packages/SQDrawShell"), .package(path: "../../Packages/SQUIKit"),
        .package(path: "../../Packages/SQInspectorUI"), .package(path: "../../Packages/SQDrawMonitor"),
        .package(path: "../../Packages/SQRender"), .package(path: "../../Packages/SQGPU"),
        .package(path: "../../Packages/SQGPUD3D12"), .package(path: "../../Packages/SQTimelineUI"),
        .package(path: "../../Packages/SQExport"), .package(path: "../../Packages/SQLibrary"),
        .package(path: "../../Packages/SQLottie"), .package(path: "../../Packages/SQAppShell"),
        .package(path: "../../Packages/SQProxy"), .package(path: "../../Packages/SQEditAPI"),
        .package(path: "../../Packages/SQAnalysis"), .package(path: "../../Packages/SQOnnx"),
        .package(path: "../../Packages/SQTranscribe"),
    ],
    targets: [
        .target(
            name: "CSQWinApp",
            linkerSettings: [.linkedLibrary("d3d12"), .linkedLibrary("dxgi"), .linkedLibrary("d3dcompiler")]
        ),
        .executableTarget(
            name: "SQWinApp",
            dependencies: [
                "CSQWinApp", "SQCore", .product(name: "SQDrawKit", package: "SQDrawKit"),
                .product(name: "SQDrawEditor", package: "SQDrawKit"), "SQEditorSession", "SQMediaFFmpeg", "SQMedia",
                .product(name: "SQFrame", package: "SQFrame"), "SQPlayback", "SQDrawTimeline",
                "SQDrawShell", "SQUIKit", "SQInspectorUI", "SQDrawMonitor", "SQRender", "SQGPUD3D12", "SQTimelineUI",
                .product(name: "SQGPU", package: "SQGPU"), .product(name: "SQGPUKernels", package: "SQGPU"),
                "SQExport", "SQLibrary", "SQLottie", "SQAppShell", "SQProxy", "SQEditAPI", "SQAnalysis", "SQOnnx", "SQTranscribe",
            ],
            linkerSettings: [.unsafeFlags(["-L\(ff)/lib"]), .linkedLibrary("comdlg32"), .linkedLibrary("shell32")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
#else
let package = Package(
    name: "SQWinApp",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/SQCore"), .package(path: "../../Packages/SQDrawKit"),
        .package(path: "../../Packages/SQExport"), .package(path: "../../Packages/SQMedia"),
        .package(path: "../../Packages/SQPlayback"), .package(path: "../../Packages/SQEditorSession"),
    ],
    targets: [
        .executableTarget(
            name: "SQMacReference",
            dependencies: [
                "SQCore", .product(name: "SQDrawKit", package: "SQDrawKit"),
                .product(name: "SQDrawEditor", package: "SQDrawKit"), "SQExport", "SQMedia", "SQPlayback", "SQEditorSession",
            ]
        ),
    ]
)
#endif
