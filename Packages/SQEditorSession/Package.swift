// swift-tools-version: 6.2
import PackageDescription

// DECISIONS "SQEditorUI split": the session layer above SQUIKit. EditorSession and its extensions, ProgramEngine,
// workspace model, settings, tool state, project panel model. Knows no timeline, monitor or inspector view code.
// SQEditorUI re-exports it.
#if os(Windows)
// Windows (the Windows port plan, seam 5): the session and model layer without SQRender, AppKit and the Apple-only
// services. A new source file that imports an Apple framework or SQRender goes on this list.
let appleOnly = [
    "AudioExtraction.swift", "AutoProxy.swift", "EditorSession+VoiceRecording.swift", "CaptionLanguageGuess.swift", "CommandMenuKeys.swift", "EditorSession+CaptionTranslate.swift",
    "KeyboardLayoutView.swift", "MagicMaskSession.swift", "MediaDiskWatcher.swift", "PasteMedia.swift", "PlaybackEngine+ProgramEngine.swift",
    "PasteboardTypes.swift", "ProjectMediaResolver.swift", "ProjectThumbnails.swift", "RenderCacheController.swift",
]
// Tests that need neither an Apple framework nor a Mac-only service.
let portableTests = [
    "ProxyIntakeTests.swift", "AddTitleTests.swift", "AnalysisJobTests.swift", "AudioGainReportTests.swift", "AudioRoleDefaultsTests.swift",
    "AudioShortformReviewTests.swift", "AudioShortformSessionTests.swift", "BlurredFillSessionTests.swift",
    "BeatGridSessionTests.swift", "BundleSessionTests.swift", "CaptionLookTests.swift",
    "CaptionStyleLookSessionTests.swift", "ColorMatchToClipSessionTests.swift", "CommandRoutingTests.swift",
    "CaptionTemplateStyleTests.swift", "CaptionTrackLookSessionTests.swift", "ColorMattePreviewTests.swift",
    "DeleteKeyPolicyTests.swift", "ColorMatteSessionTests.swift", "ConstantFrameRateConformTests.swift",
    "CommandEnablementTests.swift", "CutCheckSessionTests.swift", "EdgeCaseTests.swift", "CutKeysSessionTests.swift",
    "DisguiseVoiceSessionTests.swift", "DockDragHelperTests.swift", "FloatingPanelStateTests.swift", "EditTargetRulesSessionTests.swift",
    "DuckBakeUnifiedTests.swift", "FastCutStorylineSessionTests.swift", "FastCutSessionTests.swift",
    "EffectiveTimelineToolTests.swift", "FourPointSessionTests.swift", "FormatMismatchTests.swift",
    "FrameHoldSessionTests.swift", "HistoryListTests.swift", "GrowingFileRefreshTests.swift",
    "FillerWordsSessionTests.swift", "InterpretAsManyClipsTests.swift",
    "GeneratorTrackPlacementTests.swift",
    "IdStabilitySessionTests.swift", "KeywordAtPlayheadTests.swift", "KeyRouterTests.swift",
    "JumpCutSessionTests.swift", "LiveDuckingSessionTests.swift", "MagneticDeleteTests.swift",
    "LineKeyNudgeTests.swift", "MarkersPanelModelTests.swift", "LayoutMetricsTests.swift",
    "MagicMatteSweepSessionTests.swift", "MonitorQualityAutoTests.swift", "NV12ReduceTests.swift", "PasteAttributesScaleTimesTests.swift",
    "MonitorQualityMappingTests.swift", "PasteClipboardSessionTests.swift", "PixelShapeCaptionTests.swift",
    "PlaceOnTopSessionTests.swift", "NudgeSplitEditTests.swift", "PendingScaleSessionTests.swift",
    "PremiereParityKeysTests.swift", "ProjectImportTests.swift", "MediaDiskTrackerTests.swift",
    "PlayheadTrimSessionTests.swift", "ProjectPanelGroupingTests.swift", "MusicFitSessionTests.swift",
    "ProjectPanelLabelColumnTests.swift", "ProjectNotesAndSalvageTests.swift", "PlaceSequenceSessionTests.swift",
    "RecentProjectsListingTests.swift", "ProposedCutSessionTests.swift", "ProjectPanelSmartBinTests.swift",
    "ProjectInputColorSessionTests.swift", "PunchInSessionTests.swift", "ReelFillSessionTests.swift",
    "RelinkSessionTests.swift", "RelinkOfferTests.swift", "ReplaceSequenceAndChoiceTests.swift",
    "ReplaceModesSessionTests.swift", "ResetColorGraphTests.swift", "ProjectPanelModelTests.swift",
    "SaveStatusTests.swift", "RulerScaleTests.swift", "ProxiesForExportSettingTests.swift",
    "SequenceTogglesSessionTests.swift", "SequenceTabsTests.swift", "SelectionFollowsPlayheadTests.swift",
    "ShellDailyDriverTests.swift", "SessionAutosaveRootTests.swift", "SessionTimelineAuditTests.swift",
    "SideStepSessionTests.swift", "ReframeSessionTests.swift", "SkimSessionTests.swift",
    "ShortcutRestSessionTests.swift", "SourcePatchSessionTests.swift", "ReplaceMediaSessionTests.swift",
    "SourceEditSessionTests.swift", "SpeedPresetSessionTests.swift", "ReverseClipSessionTests.swift",
    "SplitEditSessionTests.swift", "SpeedCaptionMappingTests.swift", "SequenceSettingsSessionTests.swift",
    "StopOnClickTests.swift", "SplitInSessionTests.swift",
    "TextMultiEditSessionTests.swift", "StabilizeSessionTests.swift", "ShortcutsDocTests.swift",
    "SourceFlowSessionTests.swift", "TitleTemplateSessionTests.swift",
    "TemplateStyleSessionTests.swift", "SpeedPointSessionTests.swift", "TimelineOpsSessionTests.swift",
    "TitleBlockSessionTests.swift", "TypeToolSessionTests.swift", "SplitScreenSessionTests.swift",
    "ToolHoldTests.swift", "TrackToggleSessionTests.swift", "VoiceChainSessionTests.swift",
    "SyncAudioWarningTests.swift", "VariantOverrideResetTests.swift", "UpdateCheckTests.swift", "TimingSupport.swift",
    "WorkspaceDockingTests.swift", "WorkspaceColorPairTests.swift", "ToolToggleStorageTests.swift",
    "WorkspaceStoreTests.swift", "WorkspaceLayoutPickTests.swift", "UseTakeTests.swift",
    "WorkspaceProjectChoiceTests.swift", "VoiceoverSessionTests.swift", "WorkspaceMenuFlowTests.swift",
    "WorkspaceTests.swift",
]
let package = Package(
    name: "SQEditorSession",
    products: [.library(name: "SQEditorSession", targets: ["SQEditorSession"])],
    dependencies: [
        .package(path: "../SQUIKit"), .package(path: "../SQCore"), .package(path: "../SQExport"),
        .package(path: "../SQText"), .package(path: "../SQAudioFX"), .package(path: "../SQTranscribe"),
        .package(path: "../SQLibrary"), .package(path: "../SQMedia"), .package(path: "../SQPlayback"),
        .package(path: "../SQAnalysis"), .package(path: "../SQProxy"),
    ],
    targets: [
        .target(name: "SQEditorSession", dependencies: [
            "SQUIKit", "SQCore", "SQExport", "SQText", "SQAudioFX", "SQTranscribe", "SQLibrary", "SQMedia", "SQPlayback", "SQAnalysis", "SQProxy",
        ], exclude: appleOnly),
        .testTarget(name: "SQEditorSessionTests", dependencies: [
            "SQAudioFX", "SQCore", "SQExport", "SQLibrary", "SQMedia", "SQPlayback", "SQText", "SQTranscribe", "SQEditorSession", "SQUIKit",
            "SQAnalysis", "SQProxy",
        ], sources: portableTests),
    ]
)
#else
let package = Package(
    name: "SQEditorSession",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SQEditorSession", targets: ["SQEditorSession"])],
    dependencies: [
        .package(path: "../SQUIKit"), .package(path: "../SQCore"), .package(path: "../SQRender"), .package(path: "../SQExport"),
        .package(path: "../SQText"), .package(path: "../SQAudioFX"), .package(path: "../SQTranscribe"),
        .package(path: "../SQLibrary"), .package(path: "../SQMedia"), .package(path: "../SQPlayback"),
        .package(path: "../SQAnalysis"), .package(path: "../SQProxy"),
    ],
    targets: [
        .target(name: "SQEditorSession", dependencies: [
            "SQUIKit", "SQCore", "SQExport", "SQText", "SQAudioFX", "SQTranscribe", "SQLibrary", "SQMedia", "SQPlayback", "SQAnalysis", "SQProxy",
            .product(name: "SQRender", package: "SQRender"),
        ]),
        .testTarget(name: "SQEditorSessionTests", dependencies: [
            "SQAudioFX", "SQCore", "SQExport", "SQLibrary", "SQMedia", "SQPlayback", "SQText", "SQTranscribe", "SQEditorSession", "SQUIKit",
            "SQAnalysis", "SQProxy", .product(name: "SQRender", package: "SQRender"),
        ]),
    ]
)
#endif
