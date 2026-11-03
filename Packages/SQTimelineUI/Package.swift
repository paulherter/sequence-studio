// swift-tools-version: 6.2
import PackageDescription

// DECISIONS "SQEditorUI split": the timeline view layer above SQEditorSession. TimelineView and its extensions, clip
// drawing, ruler, track headers, drags, waveform tiles. Knows no monitor or inspector view code.

#if os(Windows)
// Windows runs only the tests of portable logic (the rest import Apple frameworks).
let testSources: [String]? = [
    "CaptionPositionOverrideTests.swift",
    "DefaultsMigrationTests.swift",
    "DropPreviewTests.swift",
    "EffectDropRulesTests.swift",
    "MarkerRangeTests.swift",
    "MirroredMoveTests.swift",
    "PanelSyncThrottleTests.swift",
    "PlayheadLogicTests.swift",
    "ScrollGestureLogicTests.swift",
    "SnapPointCacheTests.swift",
    "SplitRollTests.swift",
    "TimelineCursorMapTests.swift",
    "TimelineEdgeGapTests.swift",
    "TimelineFeelTests.swift",
    "TimelineGeometryTests.swift",
    "TimelineInteractionTests.swift",
    "TimelineZoomAnimationTests.swift",
    "TimingSupport.swift",
    "ToolStripLayoutTests.swift",
    "TrackHeightModeTests.swift",
    "TrackHeightToggleTests.swift",
    "TrackStretchTests.swift",
    "TransitionUITests.swift",
    "UnlinkedSelectionTests.swift",
]
#else
let testSources: [String]? = nil
#endif
let package = Package(
    name: "SQTimelineUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQTimelineUI", targets: ["SQTimelineUI"])],
    dependencies: [
        .package(path: "../SQUIKit"), .package(path: "../SQEditorSession"), .package(path: "../SQCore"),
        .package(path: "../SQText"), .package(path: "../SQLibrary"), .package(path: "../SQMedia"), .package(path: "../SQPlayback"),
    ],
    targets: [
        .target(name: "SQTimelineUI", dependencies: [
            "SQUIKit", "SQEditorSession", "SQCore", "SQText", "SQLibrary", "SQMedia", "SQPlayback",
        ]),
        .testTarget(name: "SQTimelineUITests", dependencies: [
            "SQCore", "SQLibrary", "SQMedia", "SQPlayback", "SQText", "SQTimelineUI", "SQEditorSession", "SQUIKit",
        ], sources: testSources),
    ]
)
