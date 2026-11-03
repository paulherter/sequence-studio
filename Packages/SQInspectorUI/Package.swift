// swift-tools-version: 6.2
import PackageDescription

// DECISIONS "SQEditorUI split": the inspector view layer above SQEditorSession, and SQTimelineUI. Effect
// Controls, keyframe lanes and graph editor, Color inspector, text, graphics, captions, keystones. Knows no shell code.

var targets: [Target] = [
    .target(name: "SQInspectorUI", dependencies: [
        "SQUIKit", "SQEditorSession", "SQTimelineUI", "SQCore", "SQText", "SQAudioFX",
        "SQTranscribe", "SQLibrary", "SQMedia", "SQPlayback", "SQAnalysis",
        .product(name: "SQRender", package: "SQRender"), .product(name: "SQDrawKit", package: "SQDrawKit"),
    ]),
]
#if !os(Windows)
// The tests import Apple frameworks; Windows builds the portable sources only.
targets.append(.testTarget(name: "SQInspectorUITests", dependencies: [
    "SQCore", "SQAudioFX", "SQLibrary", "SQMedia", "SQPlayback", "SQText", "SQTranscribe", "SQAnalysis",
    "SQInspectorUI", "SQEditorSession", "SQTimelineUI", "SQUIKit",
    .product(name: "SQRender", package: "SQRender"), .product(name: "SQDrawKit", package: "SQDrawKit"),
]))
#endif

let package = Package(
    name: "SQInspectorUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQInspectorUI", targets: ["SQInspectorUI"])],
    dependencies: [
        .package(path: "../SQUIKit"), .package(path: "../SQEditorSession"), .package(path: "../SQTimelineUI"),
        .package(path: "../SQCore"), .package(path: "../SQRender"),
        .package(path: "../SQText"), .package(path: "../SQAudioFX"), .package(path: "../SQTranscribe"),
        .package(path: "../SQLibrary"), .package(path: "../SQMedia"), .package(path: "../SQPlayback"),
        .package(path: "../SQAnalysis"), .package(path: "../SQDrawKit"),
    ],
    targets: targets
)
