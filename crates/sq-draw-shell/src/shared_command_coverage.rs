// Swift: SharedCommandCoverage.swift
//! Where every `EditorCommand` runs in the shared app. The audit (docs/FEATURE-PARITY.md) used to match case names in source
//! files and so counted commands as "same" that the shell silently ignored. This table is the replacement: a command is
//! either run by `ShellCommands::run` (session only, checked at run time), owned by a named source file, listed as not on
//! the shared app yet with a reason, or not wired in the Mac app either (`CommandRouting::is_supported`, hidden everywhere).
//! A new command in the catalog, a key map or a menu without a route here fails `every_audited_command_has_a_route`.
//!
//! The owner names are the Swift files the rows were traced to (the Swift test also grepped that source tree for the case
//! name; that check is not ported, the tree it reads is not part of this crate).

use crate::shell_commands::ShellCommands;
use sq_core_time::SequentialIds;
use sq_editor_session::{AudioRoleDefaults, CommandRouting, EditorSession, SessionDeps};
use sq_library::library_folder_store::MemorySettings;
use sq_uikit::editor_command::EditorCommand;

/// Where a command runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Route {
    /// `ShellCommands::run`: needs only the session.
    Session,
    /// A panel host, dialog flow or timeline view command in the named source file.
    Owner(&'static str),
    /// Not on the shared app yet; the reason says why.
    NotYetShared(&'static str),
    /// Not wired in the Mac app either (`CommandRouting::is_supported` is false): hidden from the menus on both.
    Unwired,
}

/// The audit table (Swift `SharedCommandCoverage`).
pub enum SharedCommandCoverage {}

impl SharedCommandCoverage {
    /// The case name without its arguments: `Tool(Razor)` is "tool", the first letter lowercase like the Swift case.
    pub fn name(c: &EditorCommand) -> String {
        let s = format!("{c:?}");
        let case = s.split('(').next().unwrap_or("");
        let mut chars = case.chars();
        chars.next().map_or_else(String::new, |f| f.to_lowercase().chain(chars).collect())
    }

    /// Commands that are not on the shared app yet, by case name, with the reason. Empty: every wired command has a route.
    pub const NOT_YET_SHARED: [(&'static str, &'static str); 0] = [];

    /// Owner file per case name for the commands `ShellCommands::run` does not take. Traced by hand from `ShellHost.execute`:
    /// the shell's own flows (SQDrawShell), the host `onCommand` chain (SQAppShell hosts, `TimelinePanel.runViewCommand` /
    /// `runSpeedCommand`, the app's `SharedUIController+ShellHooks` and Windows `AppController+ViewOptions`). Sorted by name.
    pub const OWNERS: [(&'static str, &'static str); 168] = [
        ("acceptProposedCutAtPlayhead", "ShellAudioFlows.swift"),
        ("acceptProposedCuts", "ShellAudioFlows.swift"),
        ("addBeatMarkers", "ShellAudioFlows.swift"),
        ("addKeyframe", "InspectorHost.swift"),
        ("addMarkersOnDownbeats", "ShellAudioFlows.swift"),
        ("addSpeedPoint", "TimelinePanel+SpeedCommands.swift"),
        ("addTitle", "ShellClipDialogs.swift"),
        ("allTracksShorter", "TimelinePanel+ViewCommands.swift"),
        ("allTracksTaller", "TimelinePanel+ViewCommands.swift"),
        ("anonymize", "ShellClipDialogs.swift"),
        ("appendToMainTrack", "SourceHost.swift"),
        ("applyAudioTransition", "ShellClipDialogs.swift"),
        ("applyDefaultTransitions", "ShellClipDialogs.swift"),
        ("applyVideoTransition", "ShellClipDialogs.swift"),
        ("attachBacktimed", "SourceHost.swift"),
        ("audioGain", "ShellClipDialogs.swift"),
        ("audioGainDown", "ShellTimelineOps.swift"),
        ("audioGainDown6", "ShellTimelineOps.swift"),
        ("audioGainUp", "ShellTimelineOps.swift"),
        ("audioGainUp6", "ShellTimelineOps.swift"),
        ("audioTracksShorter", "TimelinePanel+ViewCommands.swift"),
        ("audioTracksTaller", "TimelinePanel+ViewCommands.swift"),
        ("autoCaptions", "ShellHost.swift"),
        ("autoDuck", "ShellClipDialogs.swift"),
        ("autoReframe", "ShellAnalysis.swift"),
        ("checkCuts", "ShellClipDialogs.swift"),
        ("clearPosterFrame", "MonitorCardHost.swift"),
        ("closeProject", "ShellHost.swift"),
        ("createAnglesClip", "TimelinePanel+ViewCommands.swift"),
        ("cutToBeats", "ShellTimelineOps.swift"),
        ("deleteProjectItems", "ShellFocusedEdit.swift"),
        ("disguiseVoice", "CaptionsHost+Audio.swift"),
        ("displayView", "SharedUIController+ShellHooks.swift"),
        ("easeIn", "InspectorHost.swift"),
        ("easeLinear", "InspectorHost.swift"),
        ("easeOut", "InspectorHost.swift"),
        ("easyEase", "InspectorHost.swift"),
        ("editDynamicZoom", "MonitorCardHost.swift"),
        ("editMarker", "TimelinePanel+ViewCommands.swift"),
        ("editOriginal", "ProjectListView.swift"),
        ("expandAllTracks", "TimelinePanel+ViewCommands.swift"),
        ("export", "ShellHost.swift"),
        ("exportEDL", "ShellInterchange.swift"),
        ("exportFCPXML", "ShellInterchange.swift"),
        ("exportFinalCutXML", "ShellInterchange.swift"),
        ("exportFrame", "MonitorCardHost.swift"),
        ("exportMarkersCSV", "MarkerListHost.swift"),
        ("exportOpenTimelineIO", "ShellInterchange.swift"),
        ("extendEdit", "TimelinePanel+ViewCommands.swift"),
        ("fillReel", "ProjectListView.swift"),
        ("find", "ShellClipDialogs.swift"),
        ("findSceneChanges", "ShellAnalysis.swift"),
        ("fitMusicToLength", "ShellAudioFlows.swift"),
        ("fitToFill", "SourceHost.swift"),
        ("focusPanel", "ShellDock+Shell.swift"),
        ("goToTimecode", "ShellClipDialogs.swift"),
        ("importLottie", "ShellLibraryImport.swift"),
        ("importMedia", "ShellHost.swift"),
        ("importMotionGraphicsTemplate", "ShellLibraryImport.swift"),
        ("importPremierePresets", "ShellLibraryImport.swift"),
        ("importPremiereProject", "ShellImport.swift"),
        ("importProject", "ShellClipDialogs.swift"),
        ("importTimeline", "ShellClipDialogs.swift"),
        ("insert", "MonitorCardHost.swift"),
        ("keyboardShortcuts", "ShellHost.swift"),
        ("makeSubclip", "ShellClipDialogs.swift"),
        ("matchColorToClip", "ShellAnalysis.swift"),
        ("matchFrame", "SourceHost.swift"),
        ("matchLoudness", "ShellClipDialogs.swift"),
        ("maximizeActivePanel", "ShellDock+Shell.swift"),
        ("maximizePanel", "ShellDock+Shell.swift"),
        ("minimizeAllTracks", "TimelinePanel+ViewCommands.swift"),
        ("newBin", "ShellViewCommands.swift"),
        ("newProject", "ShellHost.swift"),
        ("newSequence", "ShellClipDialogs.swift"),
        ("newTone", "ShellClipDialogs.swift"),
        ("nextWeakTracking", "ShellAnalysis.swift"),
        ("openProject", "ShellHost.swift"),
        ("overwrite", "MonitorCardHost.swift"),
        ("pasteAttributes", "ShellClipDialogs.swift"),
        ("placeOnTop", "SourceHost.swift"),
        ("playAround", "ShellViewCommands.swift"),
        ("playInToOutRoll", "ShellViewCommands.swift"),
        ("preferences", "ShellHost.swift"),
        ("projectIconView", "ShellViewCommands.swift"),
        ("projectListView", "ShellViewCommands.swift"),
        ("projectLiveDucking", "ShellClipDialogs.swift"),
        ("projectNotes", "ShellClipDialogs.swift"),
        ("projectThumbnailLarger", "ShellViewCommands.swift"),
        ("projectThumbnailSmaller", "ShellViewCommands.swift"),
        ("punchInCuts", "ShellClipDialogs.swift"),
        ("quickApply", "ShellAnalysis.swift"),
        ("quickExport", "ShellClipDialogs.swift"),
        ("recordVoiceOver", "ShellAudioFlows.swift"),
        ("rejectProposedCutAtPlayhead", "ShellAudioFlows.swift"),
        ("rejectProposedCuts", "ShellAudioFlows.swift"),
        ("removeFillerWords", "CaptionsHost+Audio.swift"),
        ("removeSilences", "ShellClipDialogs.swift"),
        ("removeTimeRemapping", "TimelinePanel+SpeedCommands.swift"),
        ("replaceClipFromProject", "ShellViewCommands.swift"),
        ("replaceClipFromSource", "SourceHost.swift"),
        ("replaceMode", "SourceHost.swift"),
        ("resetLayout", "ShellDock+Shell.swift"),
        ("reverseMatchFrame", "SourceHost.swift"),
        ("revert", "ShellHost.swift"),
        ("reviewProposedCuts", "ShellAudioFlows.swift"),
        ("save", "ShellHost.swift"),
        ("saveAs", "ShellHost.swift"),
        ("saveAsTemplate", "TimelinePanel+ViewCommands.swift"),
        ("saveCopy", "ShellHost.swift"),
        ("selectLayerAbove", "GraphicsHost.swift"),
        ("selectLayerBelow", "GraphicsHost.swift"),
        ("selectLeftEdge", "TimelinePanel+ViewCommands.swift"),
        ("selectNextPanel", "ShellDock+Shell.swift"),
        ("selectPreviousPanel", "ShellDock+Shell.swift"),
        ("selectRightEdge", "TimelinePanel+ViewCommands.swift"),
        ("sequenceSettings", "ShellClipDialogs.swift"),
        ("setPosterFrame", "MonitorCardHost.swift"),
        ("shuttleForward", "ShellKeyRoute.swift"),
        ("shuttleReverse", "ShellKeyRoute.swift"),
        ("shuttleSlowForward", "ShellKeyRoute.swift"),
        ("shuttleSlowReverse", "ShellKeyRoute.swift"),
        ("shuttleStop", "ShellKeyRoute.swift"),
        ("slipKeyframesStayTool", "TimelinePanel+ViewCommands.swift"),
        ("snapToBeats", "ShellTimelineOps.swift"),
        ("speedDuration", "ShellClipDialogs.swift"),
        ("speedRampPreset", "TimelinePanel+SpeedCommands.swift"),
        ("stabilize", "ShellAnalysis.swift"),
        ("switchAngle", "ShellTimelineOps.swift"),
        ("syncAudioToReference", "ShellClipDialogs.swift"),
        ("thumbnailMode", "TimelinePanel+ViewCommands.swift"),
        ("toggleAnimationZones", "TimelinePanel+ViewCommands.swift"),
        ("toggleAudioScrubbing", "ShellViewCommands.swift"),
        ("toggleCaptionsInMonitor", "ShellViewCommands.swift"),
        ("toggleFitTracks", "TimelinePanel+ViewCommands.swift"),
        ("toggleHoldInterpolation", "InspectorHost.swift"),
        ("toggleHoverScrub", "ShellViewCommands.swift"),
        ("toggleLinkedSelection", "TimelinePanel+ViewCommands.swift"),
        ("toggleMagnetic", "TimelinePanel+ViewCommands.swift"),
        ("toggleOverlays", "MonitorCardHost.swift"),
        ("toggleSafeAreas", "MonitorCardHost.swift"),
        ("toggleSelectionFollowsPlayhead", "ShellViewCommands.swift"),
        ("toggleSnapping", "TimelinePanel+ViewCommands.swift"),
        ("toggleTimeRemapping", "TimelinePanel+SpeedCommands.swift"),
        ("toggleTrimMode", "ShellTrim.swift"),
        ("toggleTrimType", "ShellTrim.swift"),
        ("toneSettings", "ShellClipDialogs.swift"),
        ("tool", "TimelinePanel+ViewCommands.swift"),
        ("trackHeightAuto", "TimelinePanel+ViewCommands.swift"),
        ("trackHeightLarge", "TimelinePanel+ViewCommands.swift"),
        ("trackHeightMedium", "TimelinePanel+ViewCommands.swift"),
        ("trackHeightSmall", "TimelinePanel+ViewCommands.swift"),
        ("trimBackward", "TimelinePanel+ViewCommands.swift"),
        ("trimBackward5", "TimelinePanel+ViewCommands.swift"),
        ("trimForward", "TimelinePanel+ViewCommands.swift"),
        ("trimForward5", "TimelinePanel+ViewCommands.swift"),
        ("uiScaleLarger", "ShellViewCommands.swift"),
        ("uiScaleReset", "ShellViewCommands.swift"),
        ("uiScaleSmaller", "ShellViewCommands.swift"),
        ("videoTracksShorter", "TimelinePanel+ViewCommands.swift"),
        ("videoTracksTaller", "TimelinePanel+ViewCommands.swift"),
        ("viewGamma", "SharedUIController+ShellHooks.swift"),
        ("voiceChain", "ShellAudioFlows.swift"),
        ("voiceover", "ShellAudioFlows.swift"),
        ("whooshAtCuts", "ShellHost.swift"),
        ("zoomFit", "TimelinePanel+ViewCommands.swift"),
        ("zoomIn", "TimelinePanel+ViewCommands.swift"),
        ("zoomOut", "TimelinePanel+ViewCommands.swift"),
    ];

    fn owner(name: &str) -> Option<&'static str> {
        Self::OWNERS.iter().find(|(n, _)| *n == name).map(|(_, f)| *f)
    }

    /// The route of `c`; `None` when nobody runs it (the audit fails on that).
    pub fn route(c: &EditorCommand) -> Option<Route> {
        let n = Self::name(c);
        if let Some((_, why)) = Self::NOT_YET_SHARED.iter().find(|(k, _)| *k == n) {
            return Some(Route::NotYetShared(why));
        }
        if !CommandRouting::is_supported(c) {
            return Some(Route::Unwired);
        }
        if let Some(file) = Self::owner(&n) {
            return Some(Route::Owner(file));
        }
        let mut ids = SequentialIds::default();
        let project = EditorSession::make_untitled(&mut ids);
        let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-draw-shell-coverage-probe"));
        deps.ids = Box::new(ids);
        let mut probe = EditorSession::new(project, deps);
        (ShellCommands::run(*c, &mut probe, &MemorySettings::default(), &AudioRoleDefaults::standard()).is_some())
            .then_some(Route::Session)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_uikit::command_catalog::CommandCatalog;
    use sq_uikit::command_map::CommandMap;

    /// Fails when a command in the catalog, a key map or a menu is neither run by the shared app nor listed as not yet shared.
    #[test]
    fn every_audited_command_has_a_route() {
        let mut missing: Vec<String> = CommandCatalog::audited(&CommandMap::premiere_default())
            .iter()
            .filter(|c| SharedCommandCoverage::route(c).is_none())
            .map(SharedCommandCoverage::name)
            .collect();
        missing.sort();
        missing.dedup();
        assert!(
            missing.is_empty(),
            "No shared route (add the owner to SharedCommandCoverage::OWNERS or list it as not yet shared): {missing:?}"
        );
    }

    #[test]
    fn owners_are_sorted_and_unique() {
        let names: Vec<&str> = SharedCommandCoverage::OWNERS.iter().map(|(n, _)| *n).collect();
        let mut sorted = names.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(names, sorted);
    }

    #[test]
    fn case_names_drop_the_arguments() {
        assert_eq!(SharedCommandCoverage::name(&EditorCommand::SwitchAngle(2)), "switchAngle");
        assert_eq!(SharedCommandCoverage::name(&EditorCommand::TagSFX), "tagSFX");
        assert_eq!(SharedCommandCoverage::name(&EditorCommand::ExportEDL), "exportEDL");
    }

    #[test]
    fn session_rows_are_routed_to_the_session() {
        assert_eq!(SharedCommandCoverage::route(&EditorCommand::Undo), Some(Route::Session));
        assert_eq!(SharedCommandCoverage::route(&EditorCommand::Save), Some(Route::Owner("ShellHost.swift")));
    }
}
