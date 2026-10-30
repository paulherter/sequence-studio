import Foundation
import SQCore

/// Menu structure (real NSMenus). Key equivalents come from `CommandMap.binding(for:)`.
/// Names and order follow Premiere Pro: File, Edit, Clip, Sequence, Markers, View, Window (Help and the app menu are
/// built by the app). Only commands that exist are listed; the app hides the ones that are not wired yet.
public struct MenuSpec: Sendable, Equatable {
    public indirect enum Item: Sendable, Equatable {
        case command(EditorCommand)
        case separator
        case submenu(String, [Item])
    }
    public var title: String
    public var items: [Item]

    /// Every command in the menu, submenus included.
    public var commands: [EditorCommand] { Self.flatten(items) }

    static func flatten(_ items: [Item]) -> [EditorCommand] {
        items.flatMap { item -> [EditorCommand] in
            switch item {
            case .command(let c): [c]
            case .separator: []
            case .submenu(_, let sub): flatten(sub)
            }
        }
    }
}

public enum EditorMenus {
    /// The complete command catalog by menu area: the audit, the key ownership checks and Quick Apply (the command palette) read
    /// it. It is NOT what the menu bar shows: `visible` is (one entry per action, no scrolling, see `MenuLayout` below).
    public static let all: [MenuSpec] = [file, edit, clip, sequence, markers, view, window]
    /// What the menu bar builds, in order. Every command here is in `all`; the others stay reachable through their key,
    /// Quick Apply (Window > Quick Apply) and, for the import and export variants, the Import and Export dialogs.
    public static let visible: [MenuSpec] = [visibleFile, visibleEdit, visibleClip, visibleSequence, visibleMarkers, visibleView, visibleWindow]

    private static func cmds(_ c: [EditorCommand?]) -> [MenuSpec.Item] {
        c.map { $0.map(MenuSpec.Item.command) ?? .separator }
    }

    /// File. The app inserts "Open Recent" after Open Project.
    public static let file = MenuSpec(title: "File", items: cmds([
        .newProject, .newSequence, .newBin, nil, .openProject, nil, .save, .saveAs, .saveCopy, .revert, nil, .closeProject, nil, .projectNotes, nil, .importMedia, .importProject, .importTimeline, .importPremiereProject, .importPremierePresets, .importMotionGraphicsTemplate, .importLottie, nil,
        .export, .quickExport, .exportFrame, .exportMarkersCSV, .exportEDL, .exportFCPXML, .exportFinalCutXML, .exportOpenTimelineIO,
    ]))
    public static let edit = MenuSpec(title: "Edit", items: cmds([
        .undo, .redo, nil, .cut, .copy, .paste, .pasteInsert, .pasteToTargets, .pasteAttached, .pasteAttributes, nil, .duplicate, nil,
        .selectAll, .deselectAll, .selectClipAtPlayhead, .selectNextClip, .selectPreviousClip, .selectLeftEdge, .selectRightEdge, .selectLayerAbove, .selectLayerBelow, nil,
        .delete, .rippleDelete, nil,
        .find,
    ]))
    public static let clip = MenuSpec(title: "Clip", items: cmds([
        .insert, .overwrite, .fitToFill, .replaceClipFromSource, .replaceClipFromProject, nil, .setPosterFrame, .clearPosterFrame, nil, .speedDuration, .reverseClip, .toggleTimeRemapping, .addSpeedPoint, .removeTimeRemapping, nil, .enableClip, .link, .unlink, .detachAudio, .syncAudioToReference, .solo, .muteTracks, .trimToRange, nil, .group, .ungroup, .bundle, .unbundle, nil, .extendToSequenceEnd, .saveAsTemplate, .toggleAnimationZones, nil,
        .makeSubclip, .editOriginal, nil, .setToFrameSize, .setToFillFrame, nil,
    ]) + [
        .submenu("Replace Modes", cmds(ReplaceMode.allCases.map { EditorCommand.replaceMode($0) })),
        .submenu("Audio Options", cmds([
            .audioGain, .audioGainDown, .audioGainUp, .audioGainDown6, .audioGainUp6, nil,
            .matchLoudness, .autoDuck, .projectLiveDucking,
            nil, .removeSilences, .removeFillerWords, nil, .reviewProposedCuts, .acceptProposedCuts, .rejectProposedCuts, .acceptProposedCutAtPlayhead, .rejectProposedCutAtPlayhead,
            nil, .voiceover, .recordVoiceOver, .voiceChain, .disguiseVoice, .tagDialogue, .tagMusic, .tagSFX,
        ])),
        .submenu("Video Options", cmds([.addFrameHold, .insertFrameHold, nil, .videoFadeIn, .videoFadeOut, nil, .fitBlurredFill, .fitCard, .removeBlurredFill, nil, .togglePunchIn, nil, .autoReframe, .dynamicZoomIn, .dynamicZoomOut, .editDynamicZoom, .stabilize, .matchColorToClip, .addSubjectMask, .anonymize, nil, .findSceneChanges])),
        .submenu("Speed Ramp Presets", cmds(SpeedRampPreset.allCases.map { EditorCommand.speedRampPreset($0, onBeat: false) } + [nil]
                                            + SpeedRampPreset.allCases.map { EditorCommand.speedRampPreset($0, onBeat: true) })),
        .submenu("Beat Edits", cmds([.cutToBeats, .snapToBeats, nil, .fitMusicToLength])),
        .submenu("Angles", cmds([.createAnglesClip, nil] + (1...9).map { EditorCommand.switchAngle($0) })),
        .submenu("Split Screen", cmds(SplitLayoutPreset.allCases.map { EditorCommand.splitScreen($0, animated: false) } + [nil]
                                      + SplitLayoutPreset.allCases.map { EditorCommand.splitScreen($0, animated: true) })),
        .separator,
    ] + cmds([
        .easyEase, .easeIn, .easeOut, .toggleHoldInterpolation,
    ]))
    public static let sequence = MenuSpec(title: "Sequence", items: cmds([
        .sequenceSettings, nil,
        .lift, .extract, .bleep, nil,
        .newTone, .toneSettings, nil,
        .addEdit, .addEditAllTracks, .joinCuts, .jumpCutAlternate, .splitEditAudio, .splitEditVideo, .cutOut, .placeOnTop, .attachBacktimed, .closeGapAtPlayhead, .jCut, .lCut, .jCutByOffset, .lCutByOffset, .nudgeAudioEditLeft, .nudgeAudioEditRight, .nudgeVideoEditLeft, .nudgeVideoEditRight, .rippleTrimPrevious, .rippleTrimNext, .trimPrevious, .trimNext,
        .rollTrimPrevious, .rollTrimNext, .extendEdit, .toggleTrimType, .toggleTrimMode, nil,
        .appendToMainTrack, .insertSpacer, .liftOffMainTrack, .putOnMainTrack, .setAttachPoint, .createStoryline, .storylineRippleDelete, .moveClipLeft, .moveClipRight, .deleteSelectionOnly, nil,
    ]) + [
        .submenu("Nudge", cmds([.nudgeLeft, .nudgeRight, .nudgeLeft10, .nudgeRight10, nil, .slideLeft, .slideRight, .slideLeft5, .slideRight5, nil, .slipLeft, .slipRight, .slipLeft5, .slipRight5, nil, .moveSelectionUp, .moveSelectionDown])),
        .submenu("Trim Selected Edit", cmds([.trimBackward, .trimForward, .trimBackward5, .trimForward5])),
        .submenu("Track Targets", cmds([.toggleLockOfTargets, nil]
                                       + (1...9).map { EditorCommand.toggleTrackTarget(.video, $0) } + [nil]
                                       + (1...9).map { EditorCommand.toggleTrackTarget(.audio, $0) })),
        .separator,
    ] + cmds([
        .applyVideoTransition, .applyAudioTransition, .applyDefaultTransitions, nil,
        .addVideoTrack, .addAudioTrack, .removeEmptyTracks, .deleteTrack, nil,
        .toggleSnapping, .toggleLinkedSelection, .toggleAllTargets, .toggleVideoTargets, .toggleAudioTargets, .toggleSelectionFollowsPlayhead, .toggleMagnetic, nil,
        .matchFrame, .reverseMatchFrame, nil,
        .checkCuts, .whooshAtCuts, .punchInCuts, .fillReel, nil,
        .addTitle, .autoCaptions, nil,
        .zoomIn, .zoomOut, .zoomFit, nil,
        .previousEditPoint, .nextEditPoint, .previousEditPointAnyTrack, .nextEditPointAnyTrack, .goToStart, .goToEnd, .goToSelectedClipStart, .goToSelectedClipEnd, .nextSplitPoint, .previousSplitPoint, .goToTimecode,
    ]))
    /// Premiere's Markers menu: In/Out marking and sequence markers.
    public static let markers = MenuSpec(title: "Markers", items: cmds([
        .markIn, .markOut, .markClip, nil,
        .goToIn, .goToOut, nil,
        .clearIn, .clearOut, .clearInOut, nil,
        .addMarker, .addAndEditMarker, .editMarker, .nextMarker, .previousMarker, .clearMarker, .clearAllMarkers, nil,
        .addBeatMarkers, .addMarkersOnDownbeats, nil,
        .nextWeakTracking, nil,
        .markSelection, .markOverhang, nil,
        .keywordAtPlayhead,
    ]))
    public static let view = MenuSpec(title: "View", items: [
        .submenu("Playback", cmds([
            .playPause, .playFromStart, .playInToOut, .playToOut, .playInToOutRoll, .playAround, .toggleLoop, nil, .shuttleReverse, .shuttleStop, .shuttleForward, .shuttleSlowReverse, .shuttleSlowForward, nil,
            .stepBackward, .stepForward, .stepBackward5, .stepForward5, nil, .addKeyframe, .previousKeyframe, .nextKeyframe,
        ])),
        .separator,
        .command(.toggleAudioScrubbing), .command(.toggleHoverScrub),
        .command(.toggleCaptionsInMonitor), .command(.toggleSafeAreas), .command(.toggleOverlays), .command(.toggleGraphEditor),
        .submenu("View Gamma", cmds(ViewGammaChoice.allCases.map { EditorCommand.viewGamma($0) })),
        .separator,
        .submenu("Timeline Thumbnails", cmds(ThumbnailModeChoice.allCases.map { EditorCommand.thumbnailMode($0) })),
        .submenu("Project Panel", cmds([.projectListView, .projectIconView, nil, .projectThumbnailSmaller, .projectThumbnailLarger])),
        .separator,
        .submenu("Track Height", cmds([
            .allTracksTaller, .allTracksShorter, .toggleFitTracks, nil,
            .videoTracksTaller, .videoTracksShorter, .audioTracksTaller, .audioTracksShorter, nil,
            .minimizeAllTracks, .expandAllTracks, nil,
            .trackHeightSmall, .trackHeightMedium, .trackHeightLarge, .trackHeightAuto,
        ])),
        .separator,
        .command(.uiScaleLarger), .command(.uiScaleSmaller), .command(.uiScaleReset),
        .separator,
        .submenu("Tools", cmds([
            .tool(.selection), .tool(.trackForward), .tool(.trackBackward), .tool(.ripple), .tool(.rolling),
            .tool(.slip), .slipKeyframesStayTool, .tool(.slide), .tool(.rateStretch), .tool(.razor), .tool(.hand), .tool(.zoom), .tool(.type),
            .tool(.rectangle), .tool(.ellipse), .tool(.line), .tool(.draw), .tool(.mask), .tool(.position),
        ])),
    ])
    /// Panels in the Window menu, in menu order: one checkable item each (check = visible in the workspace).
    public static let windowPanels: [PanelID] = [
        .effectControls, .text, .graphics, .programMonitor, .sourceMonitor, .library, .effects, .keystones, .markerList, .project, .timeline, .audioMeter,
        .colorClips, .steps, .colorInspector, .scopes,
    ]

    /// The panel items and the workspace list are added by the app (they carry state); the spec keeps the plain commands.
    public static let window = MenuSpec(title: "Window", items: cmds([.maximizePanel, .maximizeActivePanel, .selectNextPanel, .selectPreviousPanel, .quickApply]))

    /// Commands that stay visible in their menu even when not wired (the standard text editing commands: a text field
    /// handles them) and commands that are menu-only (no default key in Premiere).
    /// Keyed commands without an item of their own: the Project panel's Delete is the Edit menu's Delete in that scope
    /// (same key, so a second item would be dead).
    public static let scopeAliases: Set<EditorCommand> = [.deleteProjectItems]

    public static let alwaysShown: Set<EditorCommand> = [.undo, .redo, .cut, .copy, .paste, .delete]
    public static let menuOnly: Set<EditorCommand> = baseMenuOnly.union(splitScreenCommands).union(speedPresetCommands).union(thumbnailCommands).union(gammaCommands).union(replaceModeCommands)
    private static let replaceModeCommands: [EditorCommand] = ReplaceMode.allCases.map { EditorCommand.replaceMode($0) }
    private static let gammaCommands: [EditorCommand] = ViewGammaChoice.allCases.map { EditorCommand.viewGamma($0) }
    private static let thumbnailCommands: [EditorCommand] = ThumbnailModeChoice.allCases.map { EditorCommand.thumbnailMode($0) }
    private static let speedPresetCommands: [EditorCommand] = SpeedRampPreset.allCases.flatMap { p in [false, true].map { EditorCommand.speedRampPreset(p, onBeat: $0) } }
    private static let splitScreenCommands: [EditorCommand] = SplitLayoutPreset.allCases.flatMap { p in [false, true].map { EditorCommand.splitScreen(p, animated: $0) } }
    private static let baseMenuOnly: Set<EditorCommand> = [.removeEmptyTracks, .markOverhang, .nextSplitPoint, .previousSplitPoint, .fillReel, .toggleAllTargets, .fitToFill, .selectLeftEdge, .selectRightEdge, .editMarker, .addAndEditMarker, .playToOut, .unlink, .trimToRange, .createAnglesClip, .syncAudioToReference, .bleep, .newTone, .toneSettings, .setAttachPoint, .keywordAtPlayhead, .slipKeyframesStayTool, .pasteToTargets, .extendToSequenceEnd, .toggleAnimationZones, .revert, .projectNotes, .sequenceSettings, .setToFrameSize, .setToFillFrame, .checkCuts, .whooshAtCuts, .punchInCuts, .toggleSelectionFollowsPlayhead, .toggleAudioScrubbing, .toggleCaptionsInMonitor, .toggleSafeAreas, .toggleOverlays,
                                                       .exportMarkersCSV, .toggleGraphEditor, .importTimeline, .exportEDL, .exportFCPXML, .exportFinalCutXML, .exportOpenTimelineIO,
                                                       .importLottie, .importMotionGraphicsTemplate, .importPremiereProject, .importPremierePresets, .importProject,
                                                       .videoFadeIn, .videoFadeOut, .addFrameHold, .insertFrameHold, .autoReframe, .anonymize, .dynamicZoomIn, .dynamicZoomOut, .editDynamicZoom, .stabilize, .findSceneChanges, .matchColorToClip, .addSubjectMask, .fitBlurredFill, .fitCard, .removeBlurredFill,
                                                       .joinCuts, .toggleTimeRemapping, .removeTimeRemapping, .addSpeedPoint, .toggleHoldInterpolation,
                                                       .matchLoudness, .autoDuck, .addBeatMarkers, .addMarkersOnDownbeats, .cutToBeats, .snapToBeats, .fitMusicToLength, .projectLiveDucking, .removeSilences, .removeFillerWords, .voiceover, .recordVoiceOver, .voiceChain, .disguiseVoice, .reviewProposedCuts, .acceptProposedCuts, .rejectProposedCuts, .acceptProposedCutAtPlayhead, .rejectProposedCutAtPlayhead, .tagDialogue, .tagMusic, .tagSFX,
                                                       .trackHeightSmall, .trackHeightMedium, .trackHeightLarge, .trackHeightAuto]
}

/// The trimmed menus (feedback 2026-10-17): one entry per action, at most about 15 entries per menu, no submenu over 8 entries.
/// Everything left out stays reachable through its key and Quick Apply (Window > Quick Apply); the import and export
/// variants live in the Import and Export dialogs. The app adds its stateful items (Open Recent, Style Kit, panels).
extension EditorMenus {
    typealias Items = [MenuSpec.Item]
    private static func c(_ list: [EditorCommand?]) -> Items { cmds(list) }
    private static func sub(_ title: String, _ parts: [Items]) -> Items { [.submenu(title, Array(parts.joined()))] }
    private static func sub(_ title: String, _ list: [EditorCommand?]) -> Items { [.submenu(title, cmds(list))] }
    private static var sep: Items { [.separator] }
    private static func menu(_ title: String, _ parts: [Items]) -> MenuSpec { MenuSpec(title: title, items: Array(parts.joined())) }

    /// Title of the File submenu the app fills (Open Recent sits next to it).
    public static let projectSubmenuTitle = "Project"

    static let visibleFile = menu("File", [
        c([.newProject, .newSequence, .newBin, nil, .openProject, nil, .save, .saveAs, nil, .closeProject, nil, .importMedia, .export, .quickExport, nil]),
        sub(projectSubmenuTitle, [.saveCopy, .revert, .projectNotes]),
    ])

    static let visibleEdit = menu("Edit", [
        c([.undo, .redo, nil, .cut, .copy, .paste]),
        sub("Paste Special", [.pasteInsert, .pasteToTargets, .pasteAttached, .pasteAttributes]),
        sep,
        c([.duplicate, .delete, .rippleDelete, nil, .selectAll, .deselectAll]),
        sub("Select", [.selectClipAtPlayhead, .selectNextClip, .selectPreviousClip, .selectLeftEdge, .selectRightEdge]),
        sep,
        c([.find]),
    ])

    private static var speedPresets: Items {
        let plain: [EditorCommand?] = SpeedRampPreset.allCases.map { EditorCommand.speedRampPreset($0, onBeat: false) }
        let beat: [EditorCommand?] = SpeedRampPreset.allCases.map { EditorCommand.speedRampPreset($0, onBeat: true) }
        return sub("Speed Ramp Presets", [c(plain), sub("On Beat", beat)])
    }
    private static var splitScreens: Items {
        let plain: [EditorCommand?] = SplitLayoutPreset.allCases.map { EditorCommand.splitScreen($0, animated: false) }
        let anim: [EditorCommand?] = SplitLayoutPreset.allCases.map { EditorCommand.splitScreen($0, animated: true) }
        return sub("Split Screen", [c(plain), sub("Animated", anim)])
    }
    private static var angles: Items {
        let list: [EditorCommand?] = [.createAnglesClip, nil] + (1...6).map { EditorCommand.switchAngle($0) }
        return sub("Angles", list)
    }

    static let visibleClip = menu("Clip", [
        c([.insert, .overwrite, nil, .speedDuration, .reverseClip, .enableClip, nil]),
        sub("Link and Group", [.link, .unlink, nil, .group, .ungroup, .bundle, .unbundle]),
        sub("Replace and Fit", [
            c([.fitToFill, .replaceClipFromSource, .replaceClipFromProject, .setToFrameSize, .setToFillFrame]),
            sub("Replace Modes", ReplaceMode.allCases.map { Optional(EditorCommand.replaceMode($0)) }),
        ]),
        sub("Source", [.setPosterFrame, .clearPosterFrame, .makeSubclip, .editOriginal]),
        sub("Arrange", [.detachAudio, .syncAudioToReference, .solo, .muteTracks, .trimToRange, .extendToSequenceEnd, .saveAsTemplate, .toggleAnimationZones]),
        sep,
        sub("Timing", [
            c([.toggleTimeRemapping, .addSpeedPoint, .removeTimeRemapping]),
            speedPresets,
            sub("Beat Edits", [.cutToBeats, .snapToBeats, nil, .fitMusicToLength]),
        ]),
        sub("Audio Options", [
            c([.audioGain]),
            sub("Gain Steps", [.audioGainDown, .audioGainUp, .audioGainDown6, .audioGainUp6]),
            sub("Loudness and Ducking", [.matchLoudness, .autoDuck, .projectLiveDucking]),
            sub("Clean Up", [
                c([.removeSilences, .removeFillerWords]),
                sub("Proposed Cuts", [.reviewProposedCuts, .acceptProposedCuts, .rejectProposedCuts, .acceptProposedCutAtPlayhead, .rejectProposedCutAtPlayhead]),
            ]),
            sub("Voice", [.voiceover, .recordVoiceOver, .voiceChain, .disguiseVoice]),
            sub("Tag Role", [.tagDialogue, .tagMusic, .tagSFX]),
        ]),
        sub("Video Options", [
            sub("Holds and Fades", [.addFrameHold, .insertFrameHold, .videoFadeIn, .videoFadeOut, .togglePunchIn]),
            sub("Fit Frame", [.fitBlurredFill, .fitCard, .removeBlurredFill, .autoReframe]),
            sub("Dynamic Zoom", [.dynamicZoomIn, .dynamicZoomOut, .editDynamicZoom]),
            c([.stabilize, .matchColorToClip, .addSubjectMask, .anonymize, .findSceneChanges]),
        ]),
        sub("Multi-Clip", [angles, splitScreens]),
        sub("Ease Keyframes", [.easyEase, .easeIn, .easeOut, .toggleHoldInterpolation]),
    ])

    static let visibleSequence = menu("Sequence", [
        c([.sequenceSettings, nil]),
        sub("New", [.newTone, .toneSettings, .addTitle, .autoCaptions, .bleep]),
        sep,
        c([.addEdit, .addEditAllTracks, .lift, .extract, nil]),
        sub("Edit", [
            sub("Split and Join", [.joinCuts, .jumpCutAlternate, .splitEditAudio, .splitEditVideo, .cutOut, .closeGapAtPlayhead, .attachBacktimed, .placeOnTop]),
            sub("Split Edits", [.jCut, .lCut, .jCutByOffset, .lCutByOffset, .nudgeAudioEditLeft, .nudgeAudioEditRight, .nudgeVideoEditLeft, .nudgeVideoEditRight]),
            sub("Trim", [.rippleTrimPrevious, .rippleTrimNext, .trimPrevious, .trimNext, .rollTrimPrevious, .rollTrimNext, .extendEdit]),
            sub("Trim Selected Edit", [.trimBackward, .trimForward, .trimBackward5, .trimForward5, .toggleTrimType, .toggleTrimMode]),
            sub("Nudge", [.nudgeLeft, .nudgeRight, .nudgeLeft10, .nudgeRight10, .moveSelectionUp, .moveSelectionDown]),
            sub("Slip and Slide", [.slideLeft, .slideRight, .slideLeft5, .slideRight5, .slipLeft, .slipRight, .slipLeft5, .slipRight5]),
            sub("Cut Tools", [.checkCuts, .whooshAtCuts, .punchInCuts, .fillReel]),
        ]),
        sub("Storyline", [.appendToMainTrack, .insertSpacer, .liftOffMainTrack, .putOnMainTrack, .setAttachPoint, .createStoryline, .storylineRippleDelete]),
        sub("Fast Cut", [.moveClipLeft, .moveClipRight, .deleteSelectionOnly]),
        sub("Tracks and Transitions", [
            c([.applyVideoTransition, .applyAudioTransition, .applyDefaultTransitions, nil, .addVideoTrack, .addAudioTrack, .removeEmptyTracks, .deleteTrack]),
            sub("Track Targets", [.toggleLockOfTargets, .toggleAllTargets, .toggleVideoTargets, .toggleAudioTargets, .toggleSelectionFollowsPlayhead]),
        ]),
        sep,
        c([.toggleSnapping, .toggleLinkedSelection, .toggleMagnetic, nil]),
        sub("Go To", [
            c([.goToStart, .goToEnd, .goToSelectedClipStart, .goToSelectedClipEnd, .goToTimecode, .matchFrame, .reverseMatchFrame]),
            sub("Edit Points", [.previousEditPoint, .nextEditPoint, .previousEditPointAnyTrack, .nextEditPointAnyTrack, .nextSplitPoint, .previousSplitPoint]),
        ]),
        sub("Zoom", [.zoomIn, .zoomOut, .zoomFit]),
    ])

    static let visibleMarkers = menu("Markers", [
        c([.markIn, .markOut, .markClip, .markSelection, nil, .goToIn, .goToOut, nil]),
        sub("Clear In and Out", [.clearIn, .clearOut, .clearInOut]),
        sep,
        c([.addMarker, .nextMarker, .previousMarker]),
        sub("Marker", [.addAndEditMarker, .editMarker, .clearMarker, .clearAllMarkers, .addBeatMarkers, .addMarkersOnDownbeats, .keywordAtPlayhead, .markOverhang]),
        c([.nextWeakTracking]),
    ])

    static let visibleView = menu("View", [
        sub("Playback", [
            c([.playPause, .playFromStart, .playInToOut, .playAround, .toggleLoop]),
            sub("Shuttle", [.shuttleReverse, .shuttleStop, .shuttleForward, .shuttleSlowReverse, .shuttleSlowForward]),
            sub("Step and Keyframes", [.stepBackward, .stepForward, .stepBackward5, .stepForward5, nil, .addKeyframe, .previousKeyframe, .nextKeyframe]),
        ]),
        sep,
        c([.toggleAudioScrubbing, .toggleHoverScrub]),
        sub("Show", [.toggleCaptionsInMonitor, .toggleSafeAreas, .toggleOverlays, .toggleGraphEditor]),
        sub("View Gamma", ViewGammaChoice.allCases.map { Optional(EditorCommand.viewGamma($0)) }),
        sep,
        sub("Timeline Thumbnails", ThumbnailModeChoice.allCases.map { Optional(EditorCommand.thumbnailMode($0)) }),
        sub("Project Panel", [.projectListView, .projectIconView, nil, .projectThumbnailSmaller, .projectThumbnailLarger]),
        sub("Track Height", [.allTracksTaller, .allTracksShorter, .toggleFitTracks, .minimizeAllTracks, .expandAllTracks, .trackHeightSmall, .trackHeightMedium, .trackHeightLarge]),
        sub("Interface Scale", [.uiScaleLarger, .uiScaleSmaller, .uiScaleReset]),
        sep,
        sub("Tools", [.tool(.selection), .tool(.ripple), .tool(.rolling), .tool(.slip), .tool(.slide), .tool(.razor), .tool(.hand), .tool(.zoom)]),
    ])

    /// Panels the Window menu lists directly; the rest sit in "More Panels" (added by the app).
    public static let primaryWindowPanels: [PanelID] = [.effectControls, .programMonitor, .sourceMonitor, .project, .timeline, .library, .effects, .audioMeter]
    public static var secondaryWindowPanels: [PanelID] { windowPanels.filter { !primaryWindowPanels.contains($0) } }

    static let visibleWindow = menu("Window", [c([.maximizePanel, .quickApply])])
}
