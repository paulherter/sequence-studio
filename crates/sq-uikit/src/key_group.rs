// Swift: KeyGroup.swift
//! Color group of a command on the keyboard picture.

use crate::editor_command::EditorCommand;

/// Color group of a command on the keyboard picture.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum KeyGroup {
    Transport,
    Marking,
    Tools,
    Editing,
    Clipboard,
    View,
    File,
    Audio,
    Keyframes,
    Other,
}

impl KeyGroup {
    /// Every group, in declaration order.
    pub const ALL: [KeyGroup; 10] = [
        KeyGroup::Transport,
        KeyGroup::Marking,
        KeyGroup::Tools,
        KeyGroup::Editing,
        KeyGroup::Clipboard,
        KeyGroup::View,
        KeyGroup::File,
        KeyGroup::Audio,
        KeyGroup::Keyframes,
        KeyGroup::Other,
    ];

    /// The Swift `String` raw value (the case name).
    pub fn raw_value(self) -> &'static str {
        match self {
            KeyGroup::Transport => "transport",
            KeyGroup::Marking => "marking",
            KeyGroup::Tools => "tools",
            KeyGroup::Editing => "editing",
            KeyGroup::Clipboard => "clipboard",
            KeyGroup::View => "view",
            KeyGroup::File => "file",
            KeyGroup::Audio => "audio",
            KeyGroup::Keyframes => "keyframes",
            KeyGroup::Other => "other",
        }
    }

    /// Name shown in the legend.
    pub fn title(self) -> &'static str {
        match self {
            KeyGroup::Transport => "Playback",
            KeyGroup::Marking => "In / Out and markers",
            KeyGroup::Tools => "Tools",
            KeyGroup::Editing => "Editing and trimming",
            KeyGroup::Clipboard => "Clipboard and undo",
            KeyGroup::View => "Zoom, tracks and panels",
            KeyGroup::File => "File and app",
            KeyGroup::Audio => "Audio",
            KeyGroup::Keyframes => "Keyframes",
            KeyGroup::Other => "Other",
        }
    }

    /// The group of a command.
    pub fn of(c: &EditorCommand) -> KeyGroup {
        match *c {
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
            | EditorCommand::PlayToOut
            | EditorCommand::NextKeyframe
            | EditorCommand::PreviousKeyframe
            | EditorCommand::PreviousEditPoint
            | EditorCommand::NextEditPoint
            | EditorCommand::GoToStart
            | EditorCommand::GoToEnd
            | EditorCommand::PlayInToOut
            | EditorCommand::PlayInToOutRoll
            | EditorCommand::PlayAround
            | EditorCommand::PlayFromStart
            | EditorCommand::GoToTimecode
            | EditorCommand::ToggleLoop
            | EditorCommand::NextEditPointAnyTrack
            | EditorCommand::PreviousEditPointAnyTrack => KeyGroup::Transport,
            EditorCommand::MarkIn
            | EditorCommand::MarkOut
            | EditorCommand::GoToIn
            | EditorCommand::GoToOut
            | EditorCommand::ClearInOut
            | EditorCommand::MarkClip
            | EditorCommand::ClearIn
            | EditorCommand::ClearOut
            | EditorCommand::AddMarker
            | EditorCommand::NextMarker
            | EditorCommand::PreviousMarker
            | EditorCommand::NextWeakTracking
            | EditorCommand::MarkSelection
            | EditorCommand::EditMarker
            | EditorCommand::AddAndEditMarker => KeyGroup::Marking,
            EditorCommand::Tool(..) | EditorCommand::SlipKeyframesStayTool => KeyGroup::Tools,
            EditorCommand::AddEdit
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
            | EditorCommand::RippleTrimPrevious
            | EditorCommand::RippleTrimNext
            | EditorCommand::ExtendEdit
            | EditorCommand::RollTrimPrevious
            | EditorCommand::RollTrimNext
            | EditorCommand::TrimPrevious
            | EditorCommand::TrimNext
            | EditorCommand::ToggleTrimType
            | EditorCommand::Lift
            | EditorCommand::Extract
            | EditorCommand::Bleep
            | EditorCommand::NewTone
            | EditorCommand::ToneSettings
            | EditorCommand::Insert
            | EditorCommand::Overwrite
            | EditorCommand::Delete
            | EditorCommand::RippleDelete
            | EditorCommand::NudgeLeft
            | EditorCommand::NudgeRight
            | EditorCommand::NudgeLeft10
            | EditorCommand::NudgeRight10
            | EditorCommand::TrimBackward
            | EditorCommand::TrimForward
            | EditorCommand::TrimBackward5
            | EditorCommand::TrimForward5
            | EditorCommand::MoveSelectionUp
            | EditorCommand::MoveSelectionDown
            | EditorCommand::ToggleSnapping
            | EditorCommand::SelectLayerAbove
            | EditorCommand::SelectLayerBelow
            | EditorCommand::ToggleLinkedSelection
            | EditorCommand::ToggleTrackTarget(..)
            | EditorCommand::ToggleLockOfTargets
            | EditorCommand::AddVideoTrack
            | EditorCommand::AddAudioTrack
            | EditorCommand::RemoveEmptyTracks
            | EditorCommand::DeleteTrack
            | EditorCommand::Link
            | EditorCommand::Solo
            | EditorCommand::Unlink
            | EditorCommand::MuteTracks
            | EditorCommand::DetachAudio
            | EditorCommand::TrimToRange
            | EditorCommand::EnableClip
            | EditorCommand::Duplicate
            | EditorCommand::SpeedDuration
            | EditorCommand::ReverseClip
            | EditorCommand::SelectClipAtPlayhead
            | EditorCommand::MatchFrame
            | EditorCommand::ReverseMatchFrame
            | EditorCommand::ApplyVideoTransition
            | EditorCommand::ApplyAudioTransition
            | EditorCommand::ApplyDefaultTransitions => KeyGroup::Editing,
            EditorCommand::Copy
            | EditorCommand::Cut
            | EditorCommand::Paste
            | EditorCommand::PasteAttributes
            | EditorCommand::PasteInsert
            | EditorCommand::PasteToTargets
            | EditorCommand::Undo
            | EditorCommand::Redo
            | EditorCommand::SelectAll
            | EditorCommand::DeselectAll
            | EditorCommand::DeleteProjectItems => KeyGroup::Clipboard,
            EditorCommand::ZoomIn
            | EditorCommand::ZoomOut
            | EditorCommand::ZoomFit
            | EditorCommand::FocusPanel(..)
            | EditorCommand::MaximizePanel
            | EditorCommand::MaximizeActivePanel
            | EditorCommand::SelectNextPanel
            | EditorCommand::SelectPreviousPanel
            | EditorCommand::ResetLayout
            | EditorCommand::VideoTracksTaller
            | EditorCommand::VideoTracksShorter
            | EditorCommand::AudioTracksTaller
            | EditorCommand::AudioTracksShorter
            | EditorCommand::MinimizeAllTracks
            | EditorCommand::ExpandAllTracks
            | EditorCommand::AllTracksTaller
            | EditorCommand::AllTracksShorter
            | EditorCommand::ToggleFitTracks => KeyGroup::View,
            EditorCommand::ImportMedia
            | EditorCommand::NewSequence
            | EditorCommand::Save
            | EditorCommand::Export
            | EditorCommand::QuickExport
            | EditorCommand::ExportFrame
            | EditorCommand::ExportMarkersCSV
            | EditorCommand::NewProject
            | EditorCommand::OpenProject
            | EditorCommand::SaveAs
            | EditorCommand::SaveCopy
            | EditorCommand::KeyboardShortcuts
            | EditorCommand::Preferences
            | EditorCommand::QuickApply
            | EditorCommand::NewBin
            | EditorCommand::Find
            | EditorCommand::ImportTimeline
            | EditorCommand::ExportEDL
            | EditorCommand::ExportFCPXML
            | EditorCommand::ExportFinalCutXML
            | EditorCommand::ExportOpenTimelineIO
            | EditorCommand::ImportLottie
            | EditorCommand::ImportMotionGraphicsTemplate
            | EditorCommand::ImportPremiereProject
            | EditorCommand::ImportPremierePresets
            | EditorCommand::ImportProject => KeyGroup::File,
            EditorCommand::AudioGain
            | EditorCommand::AudioGainDown
            | EditorCommand::AudioGainUp
            | EditorCommand::AudioGainDown6
            | EditorCommand::AudioGainUp6
            | EditorCommand::ToggleAudioScrubbing => KeyGroup::Audio,
            EditorCommand::EaseLinear
            | EditorCommand::EasyEase
            | EditorCommand::EaseIn
            | EditorCommand::EaseOut
            | EditorCommand::ToggleHoldInterpolation
            | EditorCommand::AddKeyframe => KeyGroup::Keyframes,
            _ => KeyGroup::Other,
        }
    }
}
