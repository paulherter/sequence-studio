// Swift: ShellCommands.swift
//! What the panels know that the menu rules ask about (`AppController.commandEnabled` reads them from the AppKit panels),
//! and the menu rules themselves.

use sq_core_edit::proposed_cuts::TimelineProposedCutsExt as _;
use sq_core_edit::timeline_cut_keys::JLCut;
use sq_core_edit::timeline_split_edit::SplitEditSide;
use sq_core_model::{AudioTag, ClipEdge, TimelineEditMode, TrackKind};
use sq_core_time::{EaseSide, EasingCurve, Time};
use sq_editor_session::{AudioRoleDefaults, CommandRouting, EditorLookCommands, EditorSession};
use sq_library::library_folder_store::SettingsStore;
use sq_uikit::editor_command::{EditorCommand, EditorTool};

/// What the panels know that the menu rules ask about. The host fills in what its panels have; defaults are "nothing there".
#[derive(Clone, Debug, PartialEq)]
pub struct ShellPanelFacts {
    /// The panels exist (set by the host once they are built).
    pub panels_loaded: bool,
    /// A dialog is up.
    pub dialog_shown: bool,
    /// The active sequence holds a piece of an Angles clip.
    pub has_angles_clip: bool,
    /// Effect Controls shows a clip.
    pub effect_controls_clip: bool,
    /// Effect Controls has no selected keys or sections.
    pub effect_selection_empty: bool,
    /// The Source monitor has media loaded.
    pub source_media_loaded: bool,
    /// Media items selected in the Project list.
    pub project_selected_media: i64,
    /// Sequences selected in the Project list.
    pub project_selected_sequences: i64,
    /// Insert / Overwrite have something to place.
    pub can_place_source: bool,
    /// Edit Original has a file.
    pub edit_original_available: bool,
    /// A timeline edit point is selected.
    pub edge_selected: bool,
    /// A media item selected in the Project list has a file (Edit Original with the Project focused).
    pub project_media_has_file: bool,
    /// A panel has something Delete would remove.
    pub has_delete_target: bool,
    /// Fill Reel has slots and media.
    pub fill_reel_enabled: bool,
    /// A voice-over recording is running.
    pub recording_voice_over: bool,
    /// The clipboard holds media Paste can import.
    pub can_paste_media: bool,
    /// An Anonymize run is going: the command cancels it and stays enabled.
    pub anonymizing: bool,
    /// The focus-dependent rows of Edit (`menuEnabled`): the Graphics panel's selection and layers, the Color panels' grade
    /// copy and paste. `None` = the host does not report it, the row stays enabled.
    pub graphics_has_selection: Option<bool>,
    /// See `graphics_has_selection`.
    pub graphics_has_layers: Option<bool>,
    /// See `graphics_has_selection`.
    pub can_copy_grade: Option<bool>,
    /// See `graphics_has_selection`.
    pub can_paste_grade: Option<bool>,
    /// A text field is open in some panel (the Mac `textResponder`): Edit's text verbs and Undo/Redo belong to it.
    pub text_editing: bool,
    /// Effect Controls' own Copy / Cut / Paste / Delete (`canCopyFocused`, `canCutFocused`, `canPasteFocused`, selected keys
    /// or a deletable section); `None` = the host does not report it.
    pub effect_can_copy: Option<bool>,
    /// See `effect_can_copy`.
    pub effect_can_cut: Option<bool>,
    /// See `effect_can_copy`.
    pub effect_can_paste: Option<bool>,
    /// See `effect_can_copy`.
    pub effect_can_delete: Option<bool>,
}

impl Default for ShellPanelFacts {
    fn default() -> ShellPanelFacts {
        ShellPanelFacts {
            panels_loaded: false,
            dialog_shown: false,
            has_angles_clip: false,
            effect_controls_clip: false,
            effect_selection_empty: true,
            source_media_loaded: false,
            project_selected_media: 0,
            project_selected_sequences: 0,
            can_place_source: false,
            edit_original_available: false,
            edge_selected: false,
            project_media_has_file: false,
            has_delete_target: false,
            fill_reel_enabled: false,
            recording_voice_over: false,
            can_paste_media: false,
            anonymizing: false,
            graphics_has_selection: None,
            graphics_has_layers: None,
            can_copy_grade: None,
            can_paste_grade: None,
            text_editing: false,
            effect_can_copy: None,
            effect_can_cut: None,
            effect_can_paste: None,
            effect_can_delete: None,
        }
    }
}

/// `AppController.commandEnabled` and the session-only part of `AppController.execute`.
pub enum ShellCommands {}

impl ShellCommands {
    /// Enabled state of a command's menu item (unwired commands are hidden by `ShellMenuBar::is_visible`).
    pub fn enabled(c: EditorCommand, session: &EditorSession, p: &ShellPanelFacts) -> bool {
        use EditorCommand as C;
        if !CommandRouting::is_supported(&c) {
            return false;
        }
        let has_timeline = session.active_timeline().is_some();
        let selection_empty = session.selection().is_empty();
        match c {
            C::Revert => session.file_url().is_some() && session.is_dirty(),
            C::CloseProject => !session.is_empty_untitled() && !p.dialog_shown,
            C::SwitchAngle(_) => p.has_angles_clip,
            C::ExportEDL
            | C::ExportFCPXML
            | C::ExportFinalCutXML
            | C::ExportOpenTimelineIO
            | C::AddVideoTrack
            | C::AddAudioTrack
            | C::RemoveEmptyTracks
            | C::DeleteTrack => has_timeline,
            C::Lift | C::Extract | C::GoToIn | C::GoToOut | C::ClearInOut => {
                session.active_timeline().is_some_and(|t| t.in_out.is_some())
            }
            C::Bleep => session.active_timeline().is_some_and(|t| t.in_out.is_some()) || !selection_empty,
            C::ToneSettings => session.selected_tone().is_some(),
            C::PlaceOnTop => p.source_media_loaded || p.project_selected_media > 0,
            C::Insert | C::Overwrite => p.panels_loaded && p.can_place_source,
            C::EnableClip | C::Duplicate | C::MoveSelectionUp | C::MoveSelectionDown | C::Group => !selection_empty,
            C::Ungroup => !session.selected_group_clips().is_empty(),
            C::Combine => !selection_empty,
            C::Bundle => session.bundle_menu_state().can_bundle,
            C::Unbundle => session.bundle_menu_state().can_unbundle,
            C::MakeSubclip => p.source_media_loaded || p.project_selected_media == 1,
            C::EditOriginal => p.panels_loaded && p.edit_original_available,
            C::SaveAsTemplate => session.can_save_selection_as_template(),
            C::ToggleAnimationZones => !session.selected_zone_clips().is_empty(),
            C::ExtendToSequenceEnd => !session.selected_adjustment_layers().is_empty(),
            C::SetToFrameSize | C::SetToFillFrame => session
                .command_clips_for_menu(Some(TrackKind::Video))
                .iter()
                .any(|clip| session.selection().contains(&clip.id)),
            C::AppendToMainTrack
            | C::InsertSpacer
            | C::LiftOffMainTrack
            | C::PutOnMainTrack
            | C::SetAttachPoint
            | C::PasteAttached
            | C::CreateStoryline
            | C::StorylineRippleDelete
            | C::MoveClipLeft
            | C::MoveClipRight
            | C::DeleteSelectionOnly => session.fast_cut_command_enabled(c),
            C::Tool(EditorTool::Position) => {
                session.active_timeline().is_some_and(|t| t.edit_mode() == TimelineEditMode::Magnetic)
            }
            C::AttachBacktimed => {
                session.fast_cut_command_enabled(c) && (p.source_media_loaded || p.project_selected_media > 0)
            }
            C::Link => session.link_menu_state().enabled,
            C::SpeedDuration => session.speed_dialog_model().is_some(),
            C::AudioGain => !session.audio_gain_targets().is_empty(),
            C::AudioGainDown
            | C::AudioGainUp
            | C::AudioGainDown6
            | C::AudioGainUp6
            | C::MatchLoudness
            | C::RemoveSilences
            | C::DisguiseVoice => !session.selected_audio_clips().is_empty(),
            C::TagDialogue => {
                !session.selected_audio_clips().is_empty() && session.audio_tag_menu_state(AudioTag::Dialogue).enabled
            }
            C::TagMusic => {
                !session.selected_audio_clips().is_empty() && session.audio_tag_menu_state(AudioTag::Music).enabled
            }
            C::TagSFX => {
                !session.selected_audio_clips().is_empty() && session.audio_tag_menu_state(AudioTag::Sfx).enabled
            }
            C::RemoveFillerWords | C::Voiceover => has_timeline,
            C::RecordVoiceOver => has_timeline || p.recording_voice_over,
            C::VoiceChain => !session.voice_chain_targets().is_empty(),
            C::AutoDuck => session.can_bake_live_duck(),
            C::CutToBeats | C::SnapToBeats => session.beat_edit_problem().is_none(),
            C::AddBeatMarkers | C::AddMarkersOnDownbeats => !session.beat_analysis_targets().is_empty(),
            C::ProjectLiveDucking => true,
            C::ReviewProposedCuts
            | C::AcceptProposedCuts
            | C::RejectProposedCuts
            | C::AcceptProposedCutAtPlayhead
            | C::RejectProposedCutAtPlayhead => !session.active_timeline().is_none_or(|t| t.proposed_cuts().is_empty()),
            C::Paste => session.clipboard().is_some() || session.can_paste_effect_clipboard() || p.can_paste_media,
            C::PasteInsert | C::PasteToTargets => session.clipboard().is_some(),
            C::ExtendEdit
            | C::ToggleTrimType
            | C::TrimBackward
            | C::TrimForward
            | C::TrimBackward5
            | C::TrimForward5 => p.edge_selected,
            C::EaseLinear | C::EasyEase | C::EaseIn | C::EaseOut | C::ToggleHoldInterpolation => {
                if !p.effect_selection_empty {
                    return true;
                }
                match c {
                    C::EaseLinear => session.speed_point_accepts_ease(&EasingCurve::linear(), EaseSide::Both),
                    C::EasyEase => session.speed_point_accepts_ease(&EasingCurve::ease_in_out(), EaseSide::Both),
                    C::EaseIn => session.speed_point_accepts_ease(&EasingCurve::ease_in(), EaseSide::In),
                    C::EaseOut => session.speed_point_accepts_ease(&EasingCurve::ease_out(), EaseSide::Out),
                    _ => false,
                }
            }
            C::VideoFadeIn
            | C::VideoFadeOut
            | C::AddFrameHold
            | C::InsertFrameHold
            | C::SplitScreen(..)
            | C::FitBlurredFill
            | C::FitCard
            | C::RemoveBlurredFill
            | C::TogglePunchIn
            | C::DynamicZoomIn
            | C::DynamicZoomOut
            | C::AddSubjectMask => EditorLookCommands::enabled(&c, session).unwrap_or(false),
            C::ReverseClip => session.can_reverse_selection(),
            C::ToggleTimeRemapping => session.can_toggle_time_remapping(),
            C::RemoveTimeRemapping => session.can_remove_time_remapping(),
            C::AddSpeedPoint => session.can_add_speed_point(),
            C::Delete | C::RippleDelete => {
                !selection_empty
                    || !session.caption_selection().is_empty()
                    || session.selected_transition().is_some()
                    || p.has_delete_target
            }
            C::SequenceSettings => has_timeline,
            C::JumpCutAlternate => session.jump_cut_enabled(),
            C::SplitEditAudio
            | C::SplitEditVideo
            | C::JCutByOffset
            | C::LCutByOffset
            | C::NudgeAudioEditLeft
            | C::NudgeAudioEditRight
            | C::NudgeVideoEditLeft
            | C::NudgeVideoEditRight => session.split_edit_enabled(),
            C::FitToFill => p.source_media_loaded && has_timeline,
            C::ReplaceClipFromSource => p.source_media_loaded && session.single_selected_clip().is_some(),
            C::ReplaceClipFromProject => {
                session.single_selected_clip().is_some()
                    && (p.project_selected_media == 1 || p.project_selected_sequences == 1)
            }
            C::PunchInCuts => session.punch_in_cuts_enabled(),
            C::Anonymize => session.anonymize_target().is_some() || p.anonymizing,
            C::PasteAttributes => session.can_paste_attributes(),
            C::FillReel => p.fill_reel_enabled,
            C::SelectNextClip => session.can_select_adjacent_clip(true),
            C::SelectPreviousClip => session.can_select_adjacent_clip(false),
            C::GoToSelectedClipStart | C::GoToSelectedClipEnd => session.can_go_to_selected_clip_edge(),
            C::MarkOverhang => session.can_mark_overhang(),
            C::NudgeLeft
            | C::NudgeRight
            | C::NudgeLeft5
            | C::NudgeRight5
            | C::NudgeLeft10
            | C::NudgeRight10
            | C::SlideLeft
            | C::SlideRight
            | C::SlideLeft5
            | C::SlideRight5
            | C::SlipLeft
            | C::SlipRight
            | C::SlipLeft5
            | C::SlipRight5 => session.can_nudge_or_slide_selection(),
            C::TrimToRange => session.can_trim_selection_to_range(),
            C::ToggleAllTargets => session.can_toggle_all_targets(),
            C::ToggleTrackTarget(kind, n) => session.can_toggle_track_target(kind, n),
            C::ToggleLockOfTargets => session.can_toggle_lock_of_targets(),
            C::ToggleVideoTargets => session.can_toggle_targets(TrackKind::Video),
            C::ToggleAudioTargets => session.can_toggle_targets(TrackKind::Audio),
            C::SelectLeftEdge | C::SelectRightEdge => session.can_select_edge_of_selection(),
            C::EditMarker => session.can_edit_marker_at_playhead(),
            C::Solo => session.can_solo_selected_tracks(),
            C::MuteTracks => session.can_mute_selected_tracks(),
            C::DetachAudio => session.can_detach_audio_selection(),
            C::Unlink => session.can_unlink_selection(),
            C::JoinCuts => session.can_join_cuts(),
            C::SyncAudioToReference => session.sync_audio_plan().is_some(),
            _ => true,
        }
    }

    /// The commands of `AppController.execute` that need only the session. Returns a status line to flash, "" when done
    /// quietly, `None` when the command is not one of these (the host's panels or dialogs handle it).
    /// `settings` and `roles` are the stored defaults the Jump Cut and J / L cut rows read (UserDefaults in Swift).
    pub fn run(
        c: EditorCommand,
        session: &mut EditorSession,
        settings: &dyn SettingsStore,
        roles: &AudioRoleDefaults,
    ) -> Option<String> {
        use EditorCommand as C;
        match c {
            C::PlayPause => session.play_pause(),
            C::StepBackward => session.step_frames(-1),
            C::StepForward => session.step_frames(1),
            C::StepBackward5 | C::StepBackward10 => session.step_frames(-10),
            C::StepForward5 | C::StepForward10 => session.step_frames(10),
            C::PlayToOut => {
                if !session.play_to_out() {
                    return Some("Move the playhead before the Out point first.".to_string());
                }
            }
            C::PreviousEditPoint => session.go_to_previous_edit_point(),
            C::NextEditPoint => session.go_to_next_edit_point(),
            C::GoToStart => session.go_to_start(),
            C::GoToEnd => session.go_to_end(),
            C::MarkIn => session.mark_in(),
            C::MarkOut => session.mark_out(),
            C::MarkClip => session.mark_clip(),
            C::GoToIn => session.go_to_in(),
            C::GoToOut => session.go_to_out(),
            C::ClearInOut => session.clear_in_out(),
            C::Lift => session.lift_range(),
            C::Extract => session.extract_range(),
            C::Bleep => session.bleep_range(),
            C::ClearIn => session.clear_in(),
            C::ClearOut => session.clear_out(),
            C::PlayInToOut => session.play_in_to_out(Time::ZERO, Time::ZERO),
            C::PlayFromStart => session.play_from_start(),
            C::ToggleLoop => session.toggle_loop(),
            C::AddEdit => session.add_edit_at_playhead(false),
            C::AddEditAllTracks => session.add_edit_at_playhead(true),
            C::CutOut => session.cut_out(),
            C::CloseGapAtPlayhead => {
                session.close_gap_at_playhead();
            }
            C::SplitEditAudio => {
                session.split_edit_to_playhead(SplitEditSide::Audio);
            }
            C::SplitEditVideo => {
                session.split_edit_to_playhead(SplitEditSide::Video);
            }
            C::NudgeAudioEditLeft => {
                session.nudge_split_edit(SplitEditSide::Audio, -1);
            }
            C::NudgeAudioEditRight => {
                session.nudge_split_edit(SplitEditSide::Audio, 1);
            }
            C::NudgeVideoEditLeft => {
                session.nudge_split_edit(SplitEditSide::Video, -1);
            }
            C::NudgeVideoEditRight => {
                session.nudge_split_edit(SplitEditSide::Video, 1);
            }
            C::JCut => {
                session.jl_cut_to_playhead(JLCut::JCut);
            }
            C::LCut => {
                session.jl_cut_to_playhead(JLCut::LCut);
            }
            C::JCutByOffset => {
                session.offset_split_edit(JLCut::JCut, None, roles);
            }
            C::LCutByOffset => {
                session.offset_split_edit(JLCut::LCut, None, roles);
            }
            C::RippleTrimPrevious => session.ripple_trim_to_playhead(ClipEdge::Head),
            C::RippleTrimNext => session.ripple_trim_to_playhead(ClipEdge::Tail),
            C::Delete | C::RippleDelete => {
                // Same as Swift `ShellCommands`: the Delete key reaches Effect Controls, a picked caption word and a selected gap
                // inside the panels (`TimelinePanel` key handler); the menu row runs the session rule below.
                if !session.remove_selected_transition() {
                    session.delete_selection(c == C::RippleDelete, None);
                }
            }
            C::ReverseClip => {
                if !session.toggle_reverse_selection() {
                    return Some("Select a video or audio clip first.".to_string());
                }
            }
            C::SetToFrameSize => {
                if !session.set_to_frame_size(None) {
                    return Some("Select clips to scale to the frame size.".to_string());
                }
            }
            C::SetToFillFrame => {
                if !session.set_to_fill_frame(None) {
                    return Some("Select clips to fill the frame.".to_string());
                }
            }
            C::Undo => {
                session.undo();
            }
            C::Redo => {
                session.redo();
            }
            _ => {
                return EditorLookCommands::run(&c, session).or_else(|| Self::run_timeline_op(c, session, settings));
            }
        }
        Some(String::new())
    }
}
