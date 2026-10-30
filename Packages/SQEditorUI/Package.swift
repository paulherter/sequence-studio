// swift-tools-version: 6.2
import PackageDescription

// DECISIONS: SQEditorUI depends on SQCore, SQMedia, SQRender, SQPlayback.
// DECISIONS "SQEditorUI split": SQUIKit holds the UI kit below it, SQEditorSession the session layer, SQTimelineUI the timeline views, SQMonitorUI the monitor views, SQInspectorUI the inspector views; SQEditorUI re-exports all five (Exports.swift).
// So far SQCore, SQRender (scopes), SQExport, SQText, SQAudioFX, SQTranscribe, SQLibrary, SQAnalysis (Auto Reframe), SQProxy (W9.9 AutoProxy); add the others when a slice needs them.
let package = Package(
    name: "SQEditorUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQEditorUI", targets: ["SQEditorUI"])],
    dependencies: [
        .package(path: "../SQUIKit"), .package(path: "../SQEditorSession"), .package(path: "../SQTimelineUI"), .package(path: "../SQMonitorUI"), .package(path: "../SQInspectorUI"), .package(path: "../SQCore"), .package(path: "../SQRender"), .package(path: "../SQExport"),
        .package(path: "../SQText"), .package(path: "../SQAudioFX"), .package(path: "../SQTranscribe"),
        .package(path: "../SQLibrary"), .package(path: "../SQMedia"), .package(path: "../SQPlayback"),
        .package(path: "../SQAnalysis"), .package(path: "../SQProxy"), .package(path: "../SQDrawLibrary"),
    ],
    targets: [
        .target(name: "SQEditorUI", dependencies: [
            "SQUIKit", "SQEditorSession", "SQTimelineUI", "SQMonitorUI", "SQInspectorUI", "SQCore", "SQExport", "SQText", "SQAudioFX", "SQTranscribe", "SQLibrary", "SQMedia", "SQPlayback", "SQAnalysis", "SQProxy", "SQDrawLibrary",
            .product(name: "SQRender", package: "SQRender"),
        ]),
        .testTarget(name: "SQEditorUITests", dependencies: ["SQAudioFX", "SQCore", "SQExport", "SQLibrary", "SQMedia", "SQPlayback", "SQText", "SQTranscribe", "SQEditorUI", "SQUIKit", "SQEditorSession", "SQTimelineUI", "SQMonitorUI", "SQInspectorUI", "SQAnalysis", "SQProxy", "SQDrawLibrary", .product(name: "SQRender", package: "SQRender")]),
    ]
)
