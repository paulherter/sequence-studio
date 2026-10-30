// swift-tools-version: 6.2
import PackageDescription

// DECISIONS "SQEditorUI split": the inspector view layer above SQEditorSession, SQTimelineUI and SQMonitorUI. Effect
// Controls, keyframe lanes and graph editor, Color inspector, text, graphics, captions, keystones. Knows no shell code.
// SQEditorUI re-exports it.
#if os(Windows)
// Windows (the Windows port plan, "Panel status: Inspector"): the portable models and logic of the inspector
// (EffectControlsModel and its extensions, track audio, captions list, color math, graphics editor logic) for the
// shared draw-list inspector (SQDrawKit SQDrawInspector). The AppKit views stay Mac-only. A new portable file that the
// draw-list panels need goes on this list.
let portableSources = [
    "ClipSectionLogic.swift", "ColorBlockText.swift", "ControlsMetrics.swift", "Exports.swift",
    "EffectControlsFX.swift", "EffectControlsGraphEditor.swift", "EffectControlsModel.swift",
    "EffectControlsModel+Animation.swift", "EffectControlsModel+ColorMatch.swift",
    "EffectControlsModel+ColorRangeMask.swift", "EffectControlsModel+GradeRange.swift",
    "EffectControlsModel+KeyLane.swift", "EffectControlsModel+KeyLoopBake.swift", "EffectControlsModel+KeyNudge.swift",
    "EffectControlsModel+KeyTools.swift", "EffectControlsModel+MaskPathKeys.swift", "EffectControlsModel+MaskTool.swift",
    "EffectControlsModel+Masks.swift", "EffectControlsModel+Multi.swift", "EffectControlsModel+PictureMask.swift",
    "EffectControlsModel+SpeedGraph.swift", "EffectControlsModel+SpeedKeys.swift", "EffectControlsModel+Stabilize.swift",
    "EffectControlsModel+TrackMask.swift", "EffectControlsModel+TransformCrop.swift", "EffectControlsPremiere.swift", "GraphEditorGeometry.swift",
    "InspectorTextFormats.swift", "MagicTrackControl.swift", "MagicTrackedFrames.swift", "MaskTrackActivity.swift", "PropertyTrackGlyphs.swift",
    "SpeedRampEaseSource.swift", "TrackAudioInspectorModel.swift", "TransitionEaseSource.swift",
    "Color/CurveEditing.swift", "EQCurve.swift", "SubjectMaskQualityMenu.swift",
    "Draw/EffectControlsDrawPanel.swift", "Draw/EffectControlsDrawRows.swift", "Draw/EffectControlsDrawSurfaces.swift",
    "Draw/EffectKeyframeLanesDraw.swift", "Draw/EffectControlsDrawView.swift",
    "KeyframeRuler.swift", "KeyframeZoomInput.swift", "EasingMenuSpec.swift", "KeyToolsInput.swift",
    "SpeedGraphGeometry.swift", "EaseHandleDragMath.swift", "Draw/InlineSpeedGraphDraw.swift",
    "Draw/KeyframeGraphDraw.swift", "Draw/GraphEditorDraw.swift", "GraphEditorShortcuts.swift",
    "CompressorBandsGeometry.swift", "Draw/TrackAudioDraw.swift", "Draw/ClipSectionsDraw.swift", "Draw/TextBlockDraw.swift", "Draw/EasingPopoverDraw.swift", "EffectControlsMotionCurve.swift",
    "KeyLanes.swift", "TextInspectorModel.swift", "TextStyleLibrary.swift", "EffectControlsModel+TextAlign.swift",
    "TextAnimatorChoices.swift", "CaptionListModel.swift", "CaptionsPanelModel.swift", "CaptionsPanelModel+AutoCaptions.swift", "GeneratedCaptionPresets.swift", "NamedLookPreset.swift", "Draw/CaptionListDraw.swift", "Draw/CaptionsTabDraw.swift", "Draw/TranscriptTabDraw.swift", "CaptionSearch.swift", "Draw/TemplateSlotsDraw.swift",
    "EffectControlsMultibandModel.swift", "Draw/MultibandEditorDraw.swift",
    "Graphics/GraphicsEditor.swift", "Graphics/GraphicsEditor+CreateTools.swift", "Graphics/GraphicsEditor+EffectPresets.swift",
    "Graphics/GraphicsEditor+Follow.swift", "Graphics/GraphicsEditor+Monitor.swift", "Graphics/GraphicsEditor+TextResize.swift",
    "Graphics/GraphicsKeyEase.swift", "Graphics/TemplateFieldsLogic.swift", "Graphics/KeyTickMath.swift",
    "Graphics/CreateToolShape.swift", "Graphics/CreateToolMenuShape.swift",
    "Graphics/GraphicsPanelLogic.swift", "Graphics/GraphicsMonitorLogic.swift", "Draw/GraphicsFormDraw.swift", "Draw/GraphicsLayerListDraw.swift", "Draw/GraphicsPanelDraw.swift",
    "Draw/GraphicItemRowsDraw.swift", "TransitionControlsModel.swift", "Draw/TransitionControlsDraw.swift",
    "TextTemplateTiles.swift", "Draw/TextTemplatesTabDraw.swift", "Draw/TextTemplateTileAtlas.swift", "Draw/TextPanelDraw.swift", "Draw/CaptionStyleTabDraw.swift",
    "Draw/LookGalleryDraw.swift",
    "Color/ColorGradeTarget.swift", "Color/ColorInspectorModel.swift", "Color/ColorInspectorModel+Graph.swift",
    "Color/ColorInspectorModel+GraphDetail.swift", "Color/ColorRangeModel.swift", "Color/ColorSharpen.swift",
    "Color/ColorWheelMath.swift", "Color/ColorZoneBoardModel.swift", "Color/StepsCanvas.swift", "Color/ColorClipRow.swift",
    "Color/ColorPageModels.swift", "Color/ColorInputChoices.swift", "Color/ColorGradeController.swift", "Draw/ColorGradeDraw.swift", "Draw/ColorGradeDraw+Input.swift",
    "Color/ColorGraphMenus.swift", "Color/StepRangeLogic.swift", "Draw/ColorGradeDraw+Pro.swift", "Draw/ColorGradeDraw+ProTabs.swift", "Draw/ColorStepsDraw.swift", "Draw/ColorSourcesDraw.swift", "Draw/ColorViewerHeaderDraw.swift",
]
let package = Package(
    name: "SQInspectorUI",
    products: [.library(name: "SQInspectorUI", targets: ["SQInspectorUI"])],
    dependencies: [
        .package(path: "../SQUIKit"), .package(path: "../SQEditorSession"), .package(path: "../SQCore"),
        .package(path: "../SQText"), .package(path: "../SQAudioFX"), .package(path: "../SQTranscribe"),
        .package(path: "../SQAnalysis"), .package(path: "../SQDrawKit"), .package(path: "../SQLibrary"),
        .package(path: "../SQTimelineUI"), .package(path: "../SQRender"),
    ],
    targets: [
        .target(name: "SQInspectorUI", dependencies: [
            "SQUIKit", "SQEditorSession", "SQCore", "SQText", "SQAudioFX", "SQTranscribe", "SQAnalysis", "SQLibrary",
            "SQTimelineUI", .product(name: "SQDrawKit", package: "SQDrawKit"), .product(name: "SQRender", package: "SQRender"),
        ], sources: portableSources),
    ]
)
#else
let package = Package(
    name: "SQInspectorUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQInspectorUI", targets: ["SQInspectorUI"])],
    dependencies: [
        .package(path: "../SQUIKit"), .package(path: "../SQEditorSession"), .package(path: "../SQTimelineUI"),
        .package(path: "../SQMonitorUI"), .package(path: "../SQCore"), .package(path: "../SQRender"),
        .package(path: "../SQText"), .package(path: "../SQAudioFX"), .package(path: "../SQTranscribe"),
        .package(path: "../SQLibrary"), .package(path: "../SQMedia"), .package(path: "../SQPlayback"),
        .package(path: "../SQAnalysis"), .package(path: "../SQDrawKit"),
    ],
    targets: [
        .target(name: "SQInspectorUI", dependencies: [
            "SQUIKit", "SQEditorSession", "SQTimelineUI", "SQMonitorUI", "SQCore", "SQText", "SQAudioFX",
            "SQTranscribe", "SQLibrary", "SQMedia", "SQPlayback", "SQAnalysis",
            .product(name: "SQRender", package: "SQRender"), .product(name: "SQDrawKit", package: "SQDrawKit"),
        ]),
        .testTarget(name: "SQInspectorUITests", dependencies: [
            "SQCore", "SQAudioFX", "SQLibrary", "SQMedia", "SQPlayback", "SQText", "SQTranscribe", "SQAnalysis",
            "SQInspectorUI", "SQEditorSession", "SQTimelineUI", "SQMonitorUI", "SQUIKit",
            .product(name: "SQRender", package: "SQRender"), .product(name: "SQDrawKit", package: "SQDrawKit"),
        ]),
    ]
)
#endif
