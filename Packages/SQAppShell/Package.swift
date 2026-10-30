// swift-tools-version: 6.2
import PackageDescription

// SQAppShell: the panel hosts of the shared draw-list UI (the Windows port plan, "Panel status: Mac on shared UI"), moved
// out of the Windows app (Windows/SQWinApp) so the Windows app and the Mac shared UI (`SQ_SHARED_UI=1`) run the same
// host code. Portable: no AppKit, AVFoundation, Metal or WinSDK; the platform parts sit behind the protocols in
// AppPlatform.swift (file choosers, the Program engine's picture and monitoring).
let package = Package(
    name: "SQAppShell",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQAppShell", targets: ["SQAppShell"])],
    dependencies: [
        .package(path: "../SQCore"), .package(path: "../SQUIKit"), .package(path: "../SQDrawKit"),
        .package(path: "../SQEditorSession"), .package(path: "../SQExport"), .package(path: "../SQDrawShell"),
        .package(path: "../SQDrawMonitor"), .package(path: "../SQDrawTimeline"), .package(path: "../SQInspectorUI"),
        .package(path: "../SQTimelineUI"), .package(path: "../SQAudioFX"), .package(path: "../SQPlayback"),
        .package(path: "../SQMedia"), .package(path: "../SQText"), .package(path: "../SQDrawLibrary"),
        .package(path: "../SQLibrary"), .package(path: "../SQTranscribe"),
    ],
    targets: [
        .target(name: "SQAppShell", dependencies: [
            "SQCore", "SQUIKit", .product(name: "SQDrawKit", package: "SQDrawKit"), "SQEditorSession", "SQExport",
            "SQDrawShell", "SQDrawMonitor", "SQDrawTimeline", "SQInspectorUI", "SQTimelineUI", "SQAudioFX", "SQPlayback",
            "SQText", "SQDrawLibrary", "SQLibrary", "SQTranscribe",
        ]),
        .testTarget(name: "SQAppShellTests", dependencies: [
            "SQAppShell", "SQCore", "SQUIKit", .product(name: "SQDrawKit", package: "SQDrawKit"), "SQEditorSession",
            "SQDrawShell", "SQDrawMonitor", "SQAudioFX", "SQMedia", "SQDrawTimeline", "SQInspectorUI", "SQDrawLibrary", "SQLibrary", "SQTimelineUI", "SQTranscribe",
        ]),
    ]
)
