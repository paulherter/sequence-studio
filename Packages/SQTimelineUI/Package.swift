// swift-tools-version: 6.2
import PackageDescription

// DECISIONS "SQEditorUI split": the timeline view layer above SQEditorSession. TimelineView and its extensions, clip
// drawing, ruler, track headers, drags, waveform tiles. Knows no monitor or inspector view code. SQEditorUI re-exports it.
#if os(Windows)
// Windows (the Windows port plan, "Panel status: Timeline"): the portable gesture and layout logic only (TimelineInteraction,
// TimelineGeometry, TrackSizing, drags, zoom, transitions layout) for the shared draw-list timeline (SQDrawKit
// SQDrawTimeline). The AppKit views stay Mac-only. A new source file that imports an Apple framework goes on this list.
let appleOnly = [
    "CaptionSearchPopup.swift", "CaptionWordDrawing.swift", "ClipDrawing+AnalysisProgress.swift",
    "ClipDrawing+GradeOutline.swift", "ClipDrawing+MagneticHint.swift", "ClipDrawing+Zones.swift",
    "ClipDrawing.swift", "ClipThumbnailSource.swift", "TimelineWaveforms.swift", "FastCutStrip.swift",
    "KeystoneSupport.swift", "LabelColor+ClipFill.swift", "MarkerIndexView.swift",
    "PlayheadLineView.swift", "RulerView.swift", "TimelineAccessibility.swift", "TimelineContentCache.swift",
    "TimelineContextMenu.swift", "TimelineCursors.swift", "TimelineHeaderBar.swift", "TimelineModeChip.swift",
    "TimelineToolSlotButton.swift", "TimelineView+AttachDrag.swift",
    "TimelineView+CaptionWords.swift", "TimelineView+DuckCurve.swift", "TimelineView+ItemLaneMove.swift",
    "TimelineView+ItemLanes.swift", "TimelineView+KeyLaneClick.swift", "TimelineView+Keystones.swift",
    "TimelineView+OpacityLine.swift", "TimelineView+PresetDrop.swift", "TimelineView+SilencePreview.swift",
    "TimelineView+Skimmer.swift", "TimelineView+SourcePatch.swift", "TimelineView+SpeedBand.swift",
    "TimelineView+Thumbnails.swift", "TimelineView+TrackConfidence.swift", "TimelineView+TransitionLayer.swift",
    "TimelineView+Transitions.swift", "TimelineView+VolumeLine.swift", "TimelineView+ZoomMotion.swift",
    "TimelineView.swift", "ToolStripView.swift", "TrackConfidenceStrip.swift", "TrackHeaderView.swift",
    "WaveformMask.swift", "WaveformTileCache.swift",
]
// Tests of the portable logic (the AppKit view tests stay Mac-only).
let portableTests = [
    "CaptionPositionOverrideTests.swift", "DefaultsMigrationTests.swift", "DropPreviewTests.swift",
    "EffectDropRulesTests.swift", "MarkerRangeTests.swift", "MirroredMoveTests.swift",
    "PanelSyncThrottleTests.swift", "PlayheadLogicTests.swift", "ScrollGestureLogicTests.swift",
    "SnapPointCacheTests.swift", "SplitRollTests.swift", "TimelineCursorMapTests.swift",
    "TimelineEdgeGapTests.swift", "TimelineFeelTests.swift", "TimelineGeometryTests.swift",
    "TimelineInteractionTests.swift", "TimelineZoomAnimationTests.swift", "TimingSupport.swift", "ToolStripLayoutTests.swift",
    "TrackHeightModeTests.swift", "TrackHeightToggleTests.swift", "TrackStretchTests.swift",
    "TransitionUITests.swift", "UnlinkedSelectionTests.swift",
]
let package = Package(
    name: "SQTimelineUI",
    products: [.library(name: "SQTimelineUI", targets: ["SQTimelineUI"])],
    dependencies: [
        .package(path: "../SQUIKit"), .package(path: "../SQEditorSession"), .package(path: "../SQCore"),
        .package(path: "../SQText"), .package(path: "../SQLibrary"), .package(path: "../SQMedia"), .package(path: "../SQPlayback"),
    ],
    targets: [
        .target(name: "SQTimelineUI", dependencies: [
            "SQUIKit", "SQEditorSession", "SQCore", "SQText", "SQLibrary", "SQMedia", "SQPlayback",
        ], exclude: appleOnly),
        .testTarget(name: "SQTimelineUITests", dependencies: [
            "SQCore", "SQLibrary", "SQMedia", "SQPlayback", "SQText", "SQTimelineUI", "SQEditorSession", "SQUIKit",
        ], sources: portableTests),
    ]
)
#else
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
        ]),
    ]
)
#endif
