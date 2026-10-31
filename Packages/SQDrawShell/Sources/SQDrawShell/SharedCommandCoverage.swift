import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// Where every `EditorCommand` runs in the shared app. The audit (docs/FEATURE-PARITY.md) used to match case names in source
/// files and so counted commands as "same" that the shell silently ignored. This table is the replacement: a command is
/// either run by `ShellCommands.run` (session only, checked at run time), owned by a named source file (checked by
/// `SharedCommandCoverageTests`: the file must exist and name the case), listed as not on the shared app yet with a reason
/// (then `ShellHost.notYetShared` flashes it), or not wired in the Mac app either (`CommandSupport`, hidden everywhere).
/// A new command in the catalog, a key map or a menu without a route here fails `SharedCommandCoverageTests`.
public enum SharedCommandCoverage {
    public enum Route: Equatable, Sendable {
        /// `ShellCommands.run`: needs only the session.
        case session
        /// A panel host, dialog flow or timeline view command in the named source file.
        case owner(String)
        /// Not on the shared app yet; the reason says why. The command must be in `ShellHost.notYetShared`.
        case notYetShared(String)
        /// Not wired in the Mac app either (`CommandSupport.isSupported` is false): hidden from the menus on both.
        case unwired
    }

    /// The case name without its arguments: `tool(.razor)` is "tool".
    public static func name(_ c: EditorCommand) -> String {
        let s = "\(c)"
        return String(s.prefix { $0 != "(" })
    }

    /// Commands that are not on the shared app yet, by case name, with the reason. Empty: every wired command has a route.
    public static let notYetShared: [String: String] = [:]

    /// Owner file per case name for the commands `ShellCommands.run` does not take. Traced by hand from `ShellHost.execute`:
    /// the shell's own flows (SQDrawShell), the host `onCommand` chain (SQAppShell hosts, `TimelinePanel.runViewCommand` /
    /// `runSpeedCommand`, the app's `SharedUIController+ShellHooks` and Windows `AppController+ViewOptions`).
    public static let owners: [String: String] = [
        "acceptProposedCutAtPlayhead": "ShellAudioFlows.swift",
        "acceptProposedCuts": "ShellAudioFlows.swift",
        "addBeatMarkers": "ShellAudioFlows.swift",
        "addKeyframe": "InspectorHost.swift",
        "addMarkersOnDownbeats": "ShellAudioFlows.swift",
        "addSpeedPoint": "TimelinePanel+SpeedCommands.swift",
        "addTitle": "ShellClipDialogs.swift",
        "allTracksShorter": "TimelinePanel+ViewCommands.swift",
        "allTracksTaller": "TimelinePanel+ViewCommands.swift",
        "anonymize": "ShellClipDialogs.swift",
        "appendToMainTrack": "SourceHost.swift",
        "applyAudioTransition": "ShellClipDialogs.swift",
        "applyDefaultTransitions": "ShellClipDialogs.swift",
        "applyVideoTransition": "ShellClipDialogs.swift",
        "attachBacktimed": "SourceHost.swift",
        "audioGain": "ShellClipDialogs.swift",
        "audioGainDown": "ShellTimelineOps.swift",
        "audioGainDown6": "ShellTimelineOps.swift",
        "audioGainUp": "ShellTimelineOps.swift",
        "audioGainUp6": "ShellTimelineOps.swift",
        "audioTracksShorter": "TimelinePanel+ViewCommands.swift",
        "audioTracksTaller": "TimelinePanel+ViewCommands.swift",
        "autoCaptions": "ShellHost.swift",
        "autoDuck": "ShellClipDialogs.swift",
        "autoReframe": "ShellAnalysis.swift",
        "checkCuts": "ShellClipDialogs.swift",
        "clearPosterFrame": "MonitorCardHost.swift",
        "closeProject": "ShellHost.swift",
        "createAnglesClip": "TimelinePanel+ViewCommands.swift",
        "cutToBeats": "ShellTimelineOps.swift",
        "deleteProjectItems": "ShellFocusedEdit.swift",
        "disguiseVoice": "CaptionsHost+Audio.swift",
        "easeIn": "InspectorHost.swift",
        "easeOut": "InspectorHost.swift",
        "easyEase": "InspectorHost.swift",
        "editDynamicZoom": "MonitorCardHost.swift",
        "editMarker": "TimelinePanel+ViewCommands.swift",
        "editOriginal": "ProjectListView.swift",
        "expandAllTracks": "TimelinePanel+ViewCommands.swift",
        "export": "ShellHost.swift",
        "exportEDL": "ShellInterchange.swift",
        "exportFCPXML": "ShellInterchange.swift",
        "exportFinalCutXML": "ShellInterchange.swift",
        "exportFrame": "MonitorCardHost.swift",
        "exportMarkersCSV": "MarkerListHost.swift",
        "exportOpenTimelineIO": "ShellInterchange.swift",
        "extendEdit": "TimelinePanel+ViewCommands.swift",
        "fillReel": "ProjectListView.swift",
        "find": "ShellClipDialogs.swift",
        "findSceneChanges": "ShellAnalysis.swift",
        "fitMusicToLength": "ShellAudioFlows.swift",
        "fitToFill": "SourceHost.swift",
        "focusPanel": "ShellDock+Shell.swift",
        "goToTimecode": "ShellClipDialogs.swift",
        "importLottie": "ShellLibraryImport.swift",
        "importMedia": "ShellHost.swift",
        "importMotionGraphicsTemplate": "ShellLibraryImport.swift",
        "importPremierePresets": "ShellLibraryImport.swift",
        "importPremiereProject": "ShellImport.swift",
        "importProject": "ShellClipDialogs.swift",
        "importTimeline": "ShellClipDialogs.swift",
        "insert": "MonitorCardHost.swift",
        "keyboardShortcuts": "ShellHost.swift",
        "makeSubclip": "ShellClipDialogs.swift",
        "matchColorToClip": "ShellAnalysis.swift",
        "matchFrame": "SourceHost.swift",
        "matchLoudness": "ShellClipDialogs.swift",
        "maximizeActivePanel": "ShellDock+Shell.swift",
        "maximizePanel": "ShellDock+Shell.swift",
        "minimizeAllTracks": "TimelinePanel+ViewCommands.swift",
        "newBin": "ShellViewCommands.swift",
        "newProject": "ShellHost.swift",
        "newSequence": "ShellClipDialogs.swift",
        "newTone": "ShellClipDialogs.swift",
        "nextWeakTracking": "ShellAnalysis.swift",
        "openProject": "ShellHost.swift",
        "overwrite": "MonitorCardHost.swift",
        "pasteAttributes": "ShellClipDialogs.swift",
        "placeOnTop": "SourceHost.swift",
        "playAround": "ShellViewCommands.swift",
        "playInToOutRoll": "ShellViewCommands.swift",
        "preferences": "ShellHost.swift",
        "projectIconView": "ShellViewCommands.swift",
        "projectListView": "ShellViewCommands.swift",
        "projectLiveDucking": "ShellClipDialogs.swift",
        "projectNotes": "ShellClipDialogs.swift",
        "projectThumbnailLarger": "ShellViewCommands.swift",
        "projectThumbnailSmaller": "ShellViewCommands.swift",
        "punchInCuts": "ShellClipDialogs.swift",
        "quickApply": "ShellAnalysis.swift",
        "quickExport": "ShellClipDialogs.swift",
        "recordVoiceOver": "ShellAudioFlows.swift",
        "rejectProposedCutAtPlayhead": "ShellAudioFlows.swift",
        "rejectProposedCuts": "ShellAudioFlows.swift",
        "removeFillerWords": "CaptionsHost+Audio.swift",
        "removeSilences": "ShellClipDialogs.swift",
        "removeTimeRemapping": "TimelinePanel+SpeedCommands.swift",
        "replaceClipFromProject": "ShellViewCommands.swift",
        "replaceClipFromSource": "SourceHost.swift",
        "replaceMode": "SourceHost.swift",
        "resetLayout": "ShellDock+Shell.swift",
        "reverseMatchFrame": "SourceHost.swift",
        "revert": "ShellHost.swift",
        "reviewProposedCuts": "ShellAudioFlows.swift",
        "save": "ShellHost.swift",
        "saveAs": "ShellHost.swift",
        "saveAsTemplate": "TimelinePanel+ViewCommands.swift",
        "saveCopy": "ShellHost.swift",
        "selectLayerAbove": "GraphicsHost.swift",
        "selectLayerBelow": "GraphicsHost.swift",
        "selectLeftEdge": "TimelinePanel+ViewCommands.swift",
        "selectNextPanel": "ShellDock+Shell.swift",
        "selectPreviousPanel": "ShellDock+Shell.swift",
        "selectRightEdge": "TimelinePanel+ViewCommands.swift",
        "sequenceSettings": "ShellClipDialogs.swift",
        "setPosterFrame": "MonitorCardHost.swift",
        "shuttleForward": "ShellKeyRoute.swift",
        "shuttleReverse": "ShellKeyRoute.swift",
        "shuttleSlowForward": "ShellKeyRoute.swift",
        "shuttleSlowReverse": "ShellKeyRoute.swift",
        "shuttleStop": "ShellKeyRoute.swift",
        "slipKeyframesStayTool": "TimelinePanel+ViewCommands.swift",
        "snapToBeats": "ShellTimelineOps.swift",
        "speedDuration": "ShellClipDialogs.swift",
        "speedRampPreset": "TimelinePanel+SpeedCommands.swift",
        "stabilize": "ShellAnalysis.swift",
        "switchAngle": "ShellTimelineOps.swift",
        "syncAudioToReference": "ShellClipDialogs.swift",
        "thumbnailMode": "TimelinePanel+ViewCommands.swift",
        "toggleAnimationZones": "TimelinePanel+ViewCommands.swift",
        "toggleAudioScrubbing": "ShellViewCommands.swift",
        "toggleCaptionsInMonitor": "ShellViewCommands.swift",
        "toggleFitTracks": "TimelinePanel+ViewCommands.swift",
        "toggleGraphEditor": "InspectorHost.swift",
        "toggleHoldInterpolation": "InspectorHost.swift",
        "toggleHoverScrub": "ShellViewCommands.swift",
        "toggleLinkedSelection": "TimelinePanel+ViewCommands.swift",
        "toggleMagnetic": "TimelinePanel+ViewCommands.swift",
        "toggleOverlays": "MonitorCardHost.swift",
        "toggleSafeAreas": "MonitorCardHost.swift",
        "toggleSelectionFollowsPlayhead": "ShellViewCommands.swift",
        "toggleSnapping": "TimelinePanel+ViewCommands.swift",
        "toggleTimeRemapping": "TimelinePanel+SpeedCommands.swift",
        "toggleTrimMode": "ShellTrim.swift",
        "toggleTrimType": "ShellTrim.swift",
        "toneSettings": "ShellClipDialogs.swift",
        "tool": "TimelinePanel+ViewCommands.swift",
        "trackHeightAuto": "TimelinePanel+ViewCommands.swift",
        "trackHeightLarge": "TimelinePanel+ViewCommands.swift",
        "trackHeightMedium": "TimelinePanel+ViewCommands.swift",
        "trackHeightSmall": "TimelinePanel+ViewCommands.swift",
        "trimBackward": "TimelinePanel+ViewCommands.swift",
        "trimBackward5": "TimelinePanel+ViewCommands.swift",
        "trimForward": "TimelinePanel+ViewCommands.swift",
        "trimForward5": "TimelinePanel+ViewCommands.swift",
        "uiScaleLarger": "ShellViewCommands.swift",
        "uiScaleReset": "ShellViewCommands.swift",
        "uiScaleSmaller": "ShellViewCommands.swift",
        "videoTracksShorter": "TimelinePanel+ViewCommands.swift",
        "videoTracksTaller": "TimelinePanel+ViewCommands.swift",
        "viewGamma": "SharedUIController+ShellHooks.swift",
        "voiceChain": "ShellAudioFlows.swift",
        "voiceover": "ShellAudioFlows.swift",
        "whooshAtCuts": "ShellHost.swift",
        "zoomFit": "TimelinePanel+ViewCommands.swift",
        "zoomIn": "TimelinePanel+ViewCommands.swift",
        "zoomOut": "TimelinePanel+ViewCommands.swift",
    ]

    /// The route of `c`; nil when nobody runs it (the audit fails on that).
    @MainActor public static func route(_ c: EditorCommand) -> Route? {
        let n = name(c)
        if let why = notYetShared[n] { return .notYetShared(why) }
        if !CommandSupport.isSupported(c) { return .unwired }
        if let file = owners[n] { return .owner(file) }
        let probe = EditorSession(project: Project(name: "Probe", timelines: [
            Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [Track(kind: .video), Track(kind: .audio)])]))
        return ShellCommands.run(c, session: probe) != nil ? .session : nil
    }
}
