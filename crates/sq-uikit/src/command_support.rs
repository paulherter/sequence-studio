// Swift: CommandSupport.swift
//! Which commands the app wires up. Lives here (not in the app crate) so tests can walk it against the menus and the key map.
//! The app executes the commands; a command that is not listed here shows "not available yet" and its menu item is hidden.

use crate::editor_command::EditorCommand;

/// Which commands the app wires up.
pub enum CommandSupport {}

impl CommandSupport {
    /// Commands handled by the main switch of `AppController.execute` and by the source/project flow.
    pub fn is_core(c: &EditorCommand) -> bool {
        matches!(
            *c,
            EditorCommand::ShuttleReverse
                | EditorCommand::ShuttleStop
                | EditorCommand::ShuttleForward
                | EditorCommand::ShuttleSlowReverse
                | EditorCommand::ShuttleSlowForward
                | EditorCommand::PlayPause
                | EditorCommand::StepBackward
                | EditorCommand::StepForward
                | EditorCommand::StepBackward5
                | EditorCommand::StepForward5
                | EditorCommand::StepBackward10
                | EditorCommand::StepForward10
                | EditorCommand::PlayToOut
                | EditorCommand::PreviousEditPoint
                | EditorCommand::NextEditPoint
                | EditorCommand::GoToStart
                | EditorCommand::GoToEnd
                | EditorCommand::MarkIn
                | EditorCommand::MarkOut
                | EditorCommand::MarkClip
                | EditorCommand::GoToIn
                | EditorCommand::GoToOut
                | EditorCommand::ClearInOut
                | EditorCommand::ClearIn
                | EditorCommand::ClearOut
                | EditorCommand::Lift
                | EditorCommand::Extract
                | EditorCommand::Bleep
                | EditorCommand::NewTone
                | EditorCommand::ToneSettings
                | EditorCommand::Insert
                | EditorCommand::Overwrite
                | EditorCommand::AddMarker
                | EditorCommand::PlayInToOut
                | EditorCommand::ToggleLoop
                | EditorCommand::ExportFrame
                | EditorCommand::NewBin
                | EditorCommand::MatchFrame
                | EditorCommand::ReverseMatchFrame
                | EditorCommand::Tool(..)
                | EditorCommand::SlipKeyframesStayTool
                | EditorCommand::AddEdit
                | EditorCommand::AddEditAllTracks
                | EditorCommand::JumpCutAlternate
                | EditorCommand::SplitEditAudio
                | EditorCommand::SplitEditVideo
                | EditorCommand::CutOut
                | EditorCommand::PlaceOnTop
                | EditorCommand::CloseGapAtPlayhead
                | EditorCommand::JCut
                | EditorCommand::LCut
                | EditorCommand::JCutByOffset
                | EditorCommand::LCutByOffset
                | EditorCommand::NudgeAudioEditLeft
                | EditorCommand::NudgeAudioEditRight
                | EditorCommand::NudgeVideoEditLeft
                | EditorCommand::NudgeVideoEditRight
                | EditorCommand::FitToFill
                | EditorCommand::ReplaceClipFromSource
                | EditorCommand::ReplaceClipFromProject
                | EditorCommand::RippleTrimPrevious
                | EditorCommand::RippleTrimNext
                | EditorCommand::Delete
                | EditorCommand::RippleDelete
                | EditorCommand::ToggleSnapping
                | EditorCommand::Undo
                | EditorCommand::Redo
                | EditorCommand::ZoomIn
                | EditorCommand::ZoomOut
                | EditorCommand::ZoomFit
                | EditorCommand::FocusPanel(..)
                | EditorCommand::MaximizePanel
                | EditorCommand::MaximizeActivePanel
                | EditorCommand::ResetLayout
                | EditorCommand::VideoTracksTaller
                | EditorCommand::VideoTracksShorter
                | EditorCommand::AudioTracksTaller
                | EditorCommand::AudioTracksShorter
                | EditorCommand::AllTracksTaller
                | EditorCommand::AllTracksShorter
                | EditorCommand::ToggleFitTracks
                | EditorCommand::MinimizeAllTracks
                | EditorCommand::ExpandAllTracks
                | EditorCommand::TrackHeightSmall
                | EditorCommand::TrackHeightMedium
                | EditorCommand::TrackHeightLarge
                | EditorCommand::TrackHeightAuto
                | EditorCommand::SpeedDuration
                | EditorCommand::ReverseClip
                | EditorCommand::ToggleTimeRemapping
                | EditorCommand::RemoveTimeRemapping
                | EditorCommand::AddSpeedPoint
                | EditorCommand::ImportMedia
                | EditorCommand::NewSequence
                | EditorCommand::Save
                | EditorCommand::Export
                | EditorCommand::QuickExport
                | EditorCommand::AudioGain
                | EditorCommand::ToggleAudioScrubbing
                | EditorCommand::ToggleSelectionFollowsPlayhead
                | EditorCommand::ToggleCaptionsInMonitor
                | EditorCommand::ToggleSafeAreas
                | EditorCommand::KeywordAtPlayhead
                | EditorCommand::AddTitle
                | EditorCommand::AutoCaptions
                | EditorCommand::PlayInToOutRoll
                | EditorCommand::PlayAround
                | EditorCommand::SetPosterFrame
                | EditorCommand::ClearPosterFrame
                | EditorCommand::ToggleHoverScrub
                | EditorCommand::Find
                | EditorCommand::ProjectListView
                | EditorCommand::ProjectIconView
                | EditorCommand::ProjectThumbnailSmaller
                | EditorCommand::ProjectThumbnailLarger
                | EditorCommand::ApplyVideoTransition
                | EditorCommand::ApplyAudioTransition
                | EditorCommand::ApplyDefaultTransitions
                | EditorCommand::AudioGainDown
                | EditorCommand::AudioGainUp
                | EditorCommand::AudioGainDown6
                | EditorCommand::AudioGainUp6
                | EditorCommand::MatchLoudness
                | EditorCommand::AutoDuck
                | EditorCommand::AddBeatMarkers
                | EditorCommand::AddMarkersOnDownbeats
                | EditorCommand::ProjectLiveDucking
                | EditorCommand::RemoveSilences
                | EditorCommand::RemoveFillerWords
                | EditorCommand::Voiceover
                | EditorCommand::RecordVoiceOver
                | EditorCommand::VoiceChain
                | EditorCommand::DisguiseVoice
                | EditorCommand::ReviewProposedCuts
                | EditorCommand::AcceptProposedCuts
                | EditorCommand::RejectProposedCuts
                | EditorCommand::AcceptProposedCutAtPlayhead
                | EditorCommand::RejectProposedCutAtPlayhead
                | EditorCommand::TagDialogue
                | EditorCommand::TagMusic
                | EditorCommand::TagSFX
                | EditorCommand::EaseLinear
                | EditorCommand::EasyEase
                | EditorCommand::EaseIn
                | EditorCommand::EaseOut
                | EditorCommand::ToggleHoldInterpolation
                | EditorCommand::DeleteProjectItems
                | EditorCommand::CheckCuts
                | EditorCommand::WhooshAtCuts
                | EditorCommand::SyncAudioToReference
                | EditorCommand::PunchInCuts
                | EditorCommand::FillReel
                | EditorCommand::CreateAnglesClip
                | EditorCommand::SwitchAngle(..)
                | EditorCommand::PlayFromStart
                | EditorCommand::GoToTimecode
                | EditorCommand::ExportMarkersCSV
                | EditorCommand::ThumbnailMode(..)
                | EditorCommand::ToggleOverlays
                | EditorCommand::ViewGamma(..)
                | EditorCommand::DisplayView(..)
                | EditorCommand::ImportTimeline
                | EditorCommand::ExportEDL
                | EditorCommand::ExportFCPXML
                | EditorCommand::ExportFinalCutXML
                | EditorCommand::ExportOpenTimelineIO
                | EditorCommand::ImportLottie
                | EditorCommand::ImportMotionGraphicsTemplate
                | EditorCommand::ImportPremiereProject
                | EditorCommand::ImportPremierePresets
                | EditorCommand::ImportProject
        )
    }

    /// Timeline operations (clipboard, link, nudge, edge trims, markers).
    pub fn is_timeline_op(c: &EditorCommand) -> bool {
        matches!(
            *c,
            EditorCommand::SelectClipAtPlayhead
                | EditorCommand::DeselectAll
                | EditorCommand::NextEditPointAnyTrack
                | EditorCommand::PreviousEditPointAnyTrack
                | EditorCommand::Copy
                | EditorCommand::Cut
                | EditorCommand::Paste
                | EditorCommand::PasteInsert
                | EditorCommand::PasteToTargets
                | EditorCommand::SelectAll
                | EditorCommand::SelectLayerAbove
                | EditorCommand::SelectLayerBelow
                | EditorCommand::Link
                | EditorCommand::ToggleLinkedSelection
                | EditorCommand::ToggleMagnetic
                | EditorCommand::AppendToMainTrack
                | EditorCommand::InsertSpacer
                | EditorCommand::LiftOffMainTrack
                | EditorCommand::PutOnMainTrack
                | EditorCommand::SetAttachPoint
                | EditorCommand::PasteAttached
                | EditorCommand::AttachBacktimed
                | EditorCommand::CreateStoryline
                | EditorCommand::StorylineRippleDelete
                | EditorCommand::MoveClipLeft
                | EditorCommand::MoveClipRight
                | EditorCommand::DeleteSelectionOnly
                | EditorCommand::MarkSelection
                | EditorCommand::NextKeyframe
                | EditorCommand::PreviousKeyframe
                | EditorCommand::Solo
                | EditorCommand::Unlink
                | EditorCommand::MuteTracks
                | EditorCommand::DetachAudio
                | EditorCommand::TrimToRange
                | EditorCommand::NextMarker
                | EditorCommand::PreviousMarker
                | EditorCommand::NextWeakTracking
                | EditorCommand::NudgeLeft
                | EditorCommand::NudgeRight
                | EditorCommand::NudgeLeft5
                | EditorCommand::NudgeRight5
                | EditorCommand::NudgeLeft10
                | EditorCommand::NudgeRight10
                | EditorCommand::ClearMarker
                | EditorCommand::ClearAllMarkers
                | EditorCommand::SelectNextClip
                | EditorCommand::SelectPreviousClip
                | EditorCommand::GoToSelectedClipStart
                | EditorCommand::GoToSelectedClipEnd
                | EditorCommand::MarkOverhang
                | EditorCommand::NextSplitPoint
                | EditorCommand::PreviousSplitPoint
                | EditorCommand::SlideLeft
                | EditorCommand::SlideRight
                | EditorCommand::SlideLeft5
                | EditorCommand::SlideRight5
                | EditorCommand::SlipLeft
                | EditorCommand::SlipRight
                | EditorCommand::SlipLeft5
                | EditorCommand::SlipRight5
                | EditorCommand::TrimBackward
                | EditorCommand::TrimForward
                | EditorCommand::TrimBackward5
                | EditorCommand::TrimForward5
                | EditorCommand::ExtendEdit
                | EditorCommand::RollTrimPrevious
                | EditorCommand::RollTrimNext
                | EditorCommand::TrimPrevious
                | EditorCommand::TrimNext
                | EditorCommand::AddKeyframe
                | EditorCommand::ToggleAllTargets
                | EditorCommand::ToggleTrackTarget(..)
                | EditorCommand::ToggleLockOfTargets
                | EditorCommand::ToggleVideoTargets
                | EditorCommand::ToggleAudioTargets
                | EditorCommand::SelectLeftEdge
                | EditorCommand::SelectRightEdge
                | EditorCommand::EditMarker
                | EditorCommand::AddAndEditMarker
                | EditorCommand::AddVideoTrack
                | EditorCommand::AddAudioTrack
                | EditorCommand::RemoveEmptyTracks
                | EditorCommand::DeleteTrack
                | EditorCommand::EnableClip
                | EditorCommand::Duplicate
                | EditorCommand::ToggleTrimType
                | EditorCommand::ToggleTrimMode
                | EditorCommand::MoveSelectionUp
                | EditorCommand::MoveSelectionDown
                | EditorCommand::Group
                | EditorCommand::Ungroup
                | EditorCommand::Bundle
                | EditorCommand::Unbundle
                | EditorCommand::Combine
                | EditorCommand::JoinCuts
                | EditorCommand::MakeSubclip
                | EditorCommand::EditOriginal
                | EditorCommand::ExtendToSequenceEnd
                | EditorCommand::SaveAsTemplate
                | EditorCommand::ToggleAnimationZones
        )
    }

    /// App-level commands (project handling, windows).
    pub fn is_shell_command(c: &EditorCommand) -> bool {
        matches!(
            *c,
            EditorCommand::NewProject
                | EditorCommand::OpenProject
                | EditorCommand::SaveAs
                | EditorCommand::SaveCopy
                | EditorCommand::Revert
                | EditorCommand::CloseProject
                | EditorCommand::ProjectNotes
                | EditorCommand::SequenceSettings
                | EditorCommand::SetToFrameSize
                | EditorCommand::SetToFillFrame
                | EditorCommand::KeyboardShortcuts
                | EditorCommand::Preferences
                | EditorCommand::QuickApply
                | EditorCommand::MaximizeActivePanel
                | EditorCommand::SelectNextPanel
                | EditorCommand::SelectPreviousPanel
                | EditorCommand::ResetLayout
                | EditorCommand::UiScaleLarger
                | EditorCommand::UiScaleSmaller
                | EditorCommand::UiScaleReset
        )
    }

    /// Clip look commands (fades, frame holds, paste attributes, Auto Reframe, Stabilize).
    pub fn is_effects_look_op(c: &EditorCommand) -> bool {
        matches!(
            *c,
            EditorCommand::VideoFadeIn
                | EditorCommand::VideoFadeOut
                | EditorCommand::AddFrameHold
                | EditorCommand::InsertFrameHold
                | EditorCommand::PasteAttributes
                | EditorCommand::AutoReframe
                | EditorCommand::Anonymize
                | EditorCommand::DynamicZoomIn
                | EditorCommand::DynamicZoomOut
                | EditorCommand::EditDynamicZoom
                | EditorCommand::Stabilize
                | EditorCommand::FindSceneChanges
                | EditorCommand::MatchColorToClip
                | EditorCommand::AddSubjectMask
                | EditorCommand::SplitScreen(..)
                | EditorCommand::SpeedRampPreset(..)
                | EditorCommand::ReplaceMode(..)
                | EditorCommand::CutToBeats
                | EditorCommand::SnapToBeats
                | EditorCommand::FitBlurredFill
                | EditorCommand::FitCard
                | EditorCommand::RemoveBlurredFill
                | EditorCommand::TogglePunchIn
                | EditorCommand::FitMusicToLength
        )
    }

    /// True when the app can run `c` (any of the four groups).
    pub fn is_supported(c: &EditorCommand) -> bool {
        Self::is_core(c) || Self::is_shell_command(c) || Self::is_timeline_op(c) || Self::is_effects_look_op(c)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use EditorCommand as C;

    #[test]
    fn shift_twins_are_supported() {
        let twins = [
            C::StepBackward5,
            C::StepForward5,
            C::StepBackward10,
            C::StepForward10,
            C::NudgeLeft5,
            C::NudgeRight5,
            C::NudgeLeft10,
            C::NudgeRight10,
            C::TrimBackward5,
            C::TrimForward5,
            C::SlideLeft5,
            C::SlipRight5,
        ];
        for c in twins {
            assert!(CommandSupport::is_supported(&c), "{c:?}");
        }
    }

    #[test]
    fn the_four_groups_do_not_overlap_for_shell_commands() {
        assert!(CommandSupport::is_shell_command(&C::NewProject) && !CommandSupport::is_core(&C::NewProject));
    }
}
