// Swift: ShellTimelineOps.swift
//! The timeline operations of the Mac `executeTimelineOp` and `execute` that need only the session (clipboard, link,
//! markers, targets, nudge, slide, slip, Fast Cut rows, tags), so their menu rows and keys work in the shell too.
//! Same calls and status lines as the Mac; a row the session refuses says why.

use crate::shell_commands::ShellCommands;
use sq_core_edit::timeline_edits::SlipKeyframes;
use sq_core_edit::timeline_trim_to_playhead::PlayheadTrimMode;
use sq_core_model::{AudioTag, ClipEdge, TimelineEditMode, TrackKind};
use sq_core_time::step_status;
use sq_editor_session::{AngleSwitchResult, EditorSession, PasteAttributeGroup};
use sq_library::library_folder_store::SettingsStore;
use sq_uikit::editor_command::EditorCommand;
use std::collections::BTreeSet;

/// Runs a Fast Cut row, or says why it cannot.
fn fast_cut(s: &mut EditorSession, c: EditorCommand, run: impl FnOnce(&mut EditorSession) -> String) -> String {
    if !s.fast_cut_command_enabled(c) {
        return if s.active_timeline().is_some_and(|t| t.edit_mode() == TimelineEditMode::Magnetic) {
            "Select the right clips first.".to_string()
        } else {
            "Switch the sequence to Fast Cut first (Shift+G).".to_string()
        };
    }
    run(s)
}

fn plural(n: usize) -> &'static str {
    if n == 1 { "" } else { "s" }
}

/// The signed frame count of a nudge, slide or slip key: `small` for the plain keys, `large` for the 5 / 10 ones.
fn frames(left: bool, large: bool) -> i64 {
    (if left { -1 } else { 1 }) * (if large { step_status::LARGE } else { step_status::SMALL })
}

impl ShellCommands {
    // Rows that read the timeline view (edge trims, Select Left/Right Edge, Toggle Trim Type, Snapping, Linked
    // Selection, track heights) are the host panel's (`TimelinePanel.runViewCommand`, chained before the shell).
    // Rows that read the Project selection (Append to Main Track) or Effect Controls (Add Keyframe) stay with the host's
    // panels, as in Swift `ShellTimelineOps`.
    pub(crate) fn run_timeline_op(
        c: EditorCommand,
        s: &mut EditorSession,
        settings: &dyn SettingsStore,
    ) -> Option<String> {
        use EditorCommand as C;
        match c {
            C::Copy => {
                if !s.copy_selection() {
                    return Some("Select clips to copy.".to_string());
                }
            }
            C::Cut => {
                if s.selection().is_empty() {
                    return Some("Select clips to cut.".to_string());
                }
                s.cut_selection();
            }
            C::Paste | C::PasteInsert | C::PasteToTargets => {
                if c == C::Paste && s.built_in_clipboard().is_some() {
                    if !s.paste_attributes(&BTreeSet::from(PasteAttributeGroup::ALL), false) {
                        return Some("Select a clip of the same kind to paste the copied effect onto.".to_string());
                    }
                } else if let (C::Paste, Some(is_audio)) = (c, s.effect_clipboard().map(|e| e.is_audio())) {
                    if !s.paste_effect_clipboard() {
                        return Some(
                            if is_audio {
                                "Select an audio clip (or its linked video clip) that can take the copied effect."
                            } else {
                                "Select a video clip that can take the copied effect."
                            }
                            .to_string(),
                        );
                    }
                } else if s.clipboard().is_none() {
                    return Some("Nothing to paste. Copy clips first.".to_string());
                } else {
                    s.paste_clipboard(c == C::PasteInsert, c == C::PasteToTargets, false);
                }
            }
            C::PasteAttached => {
                if !s.fast_cut_command_enabled(c) {
                    return Some(
                        if s.active_timeline().is_some_and(|t| t.edit_mode() == TimelineEditMode::Magnetic) {
                            "Nothing to paste. Copy clips first."
                        } else {
                            "Switch the sequence to Fast Cut first (Shift+G)."
                        }
                        .to_string(),
                    );
                }
                s.paste_clipboard(false, false, true);
            }
            C::SelectAll => s.select_all_clips(),
            C::DeselectAll => s.select(BTreeSet::new(), BTreeSet::new()),
            C::SelectClipAtPlayhead => s.select_clip_at_playhead(),
            C::SelectNextClip | C::SelectPreviousClip => {
                if !s.select_adjacent_clip(c == C::SelectNextClip) {
                    return Some(
                        if s.selection().is_empty() {
                            "Select a clip first."
                        } else {
                            "No further clip on this track."
                        }
                        .to_string(),
                    );
                }
            }
            C::GoToSelectedClipStart | C::GoToSelectedClipEnd => {
                if !s.go_to_selected_clip_edge(c == C::GoToSelectedClipEnd) {
                    return Some("Select a clip first.".to_string());
                }
            }
            C::NextEditPointAnyTrack => s.go_to_edit_point_on_any_track(true),
            C::PreviousEditPointAnyTrack => s.go_to_edit_point_on_any_track(false),
            C::Link => s.toggle_link_selection(),
            C::Unlink => {
                if !s.unlink_selection() {
                    return Some("Select linked clips first.".to_string());
                }
            }
            C::Solo => {
                if s.solo_selected_tracks().is_none() {
                    return Some("Select clips with audio first.".to_string());
                }
            }
            C::MuteTracks => {
                if s.mute_selected_tracks().is_none() {
                    return Some("Select clips with audio first.".to_string());
                }
            }
            C::DetachAudio => {
                if !s.detach_audio_selection() {
                    return Some("Select video clips with linked audio first.".to_string());
                }
            }
            C::TrimToRange => {
                if s.active_timeline().is_none_or(|t| t.in_out.is_none()) {
                    return Some("Mark In and Out first.".to_string());
                }
                if s.selection().is_empty() {
                    return Some("Select clips to trim first.".to_string());
                }
                if s.trim_selection_to_range() == 0 {
                    return Some("The selection already lies inside In and Out.".to_string());
                }
            }
            C::NextKeyframe | C::PreviousKeyframe => {
                if !s.go_to_keyframe(c == C::NextKeyframe) {
                    return Some("No more keyframes that way.".to_string());
                }
            }
            C::AddVideoTrack => s.add_track(TrackKind::Video),
            C::AddAudioTrack => s.add_track(TrackKind::Audio),
            C::RemoveEmptyTracks => s.remove_empty_tracks(),
            C::DeleteTrack => s.delete_targeted_tracks(),
            C::InsertSpacer => return Some(fast_cut(s, c, |s| s.insert_spacer())),
            C::LiftOffMainTrack => return Some(fast_cut(s, c, |s| s.lift_off_main_track())),
            C::PutOnMainTrack => return Some(fast_cut(s, c, |s| s.put_on_main_track())),
            C::CreateStoryline => return Some(fast_cut(s, c, |s| s.create_storyline())),
            C::StorylineRippleDelete => return Some(fast_cut(s, c, |s| s.storyline_ripple_delete())),
            C::MoveClipLeft => return Some(fast_cut(s, c, |s| s.move_selected_main_clips(-1))),
            C::MoveClipRight => return Some(fast_cut(s, c, |s| s.move_selected_main_clips(1))),
            C::DeleteSelectionOnly => return Some(fast_cut(s, c, |s| s.delete_selection_only())),
            C::SetAttachPoint => return Some(fast_cut(s, c, |s| s.set_attach_point())),
            C::MarkSelection => s.mark_selection(),
            // The dialog that follows M on a marker / Add and Edit lives in `perform_dialog_command`; this is the bare add.
            C::AddMarker | C::AddAndEditMarker => {
                s.mark_at_playhead();
            }
            C::NextMarker => s.go_to_next_marker(),
            C::PreviousMarker => s.go_to_previous_marker(),
            C::MarkOverhang => {
                if !s.can_mark_overhang() {
                    return Some("No split edit under the playhead.".to_string());
                }
                s.mark_overhang();
            }
            C::NextSplitPoint => s.go_to_next_split_point(),
            C::PreviousSplitPoint => s.go_to_previous_split_point(),
            C::ClearMarker => {
                if !s.clear_marker_at_playhead() {
                    return Some("No marker at the playhead.".to_string());
                }
            }
            C::ClearAllMarkers => {
                if s.clear_all_markers() == 0 {
                    return Some("There are no markers to clear.".to_string());
                }
            }
            C::KeywordAtPlayhead => {
                if !s.add_keyword_at_playhead() {
                    return Some(s.last_error().unwrap_or("").to_string());
                }
            }
            C::SlideLeft | C::SlideRight | C::SlideLeft5 | C::SlideRight5 => {
                if s.selection().is_empty() {
                    return Some("Select clips to slide.".to_string());
                }
                let n = frames(matches!(c, C::SlideLeft | C::SlideLeft5), matches!(c, C::SlideLeft5 | C::SlideRight5));
                s.slide_selection(n);
                return Some(step_status::line("Slide", n));
            }
            C::SlipLeft | C::SlipRight | C::SlipLeft5 | C::SlipRight5 => {
                if s.selection().is_empty() {
                    return Some("Select clips to slip.".to_string());
                }
                let n = frames(matches!(c, C::SlipLeft | C::SlipLeft5), matches!(c, C::SlipLeft5 | C::SlipRight5));
                s.slip_selection(n, SlipKeyframes::FollowContent);
                return Some(step_status::line("Slip", n));
            }
            C::NudgeLeft | C::NudgeRight | C::NudgeLeft5 | C::NudgeRight5 | C::NudgeLeft10 | C::NudgeRight10 => {
                let n = frames(
                    matches!(c, C::NudgeLeft | C::NudgeLeft5 | C::NudgeLeft10),
                    !matches!(c, C::NudgeLeft | C::NudgeRight),
                );
                s.nudge_selection(n);
                return Some(step_status::line("Nudge", n));
            }
            C::ToggleAllTargets => {
                s.toggle_all_targets();
            }
            C::ToggleTrackTarget(kind, n) => {
                if !s.toggle_track_target(kind, n) {
                    let name = if kind == TrackKind::Video { "video" } else { "audio" };
                    return Some(format!("There is no {name} track {n}."));
                }
            }
            C::ToggleLockOfTargets => {
                if !s.toggle_lock_of_targets() {
                    return Some("Target a track first.".to_string());
                }
            }
            C::ToggleVideoTargets => {
                s.toggle_targets(TrackKind::Video);
            }
            C::ToggleAudioTargets => {
                s.toggle_targets(TrackKind::Audio);
            }
            C::RollTrimPrevious => s.trim_to_playhead(ClipEdge::Head, PlayheadTrimMode::Roll),
            C::RollTrimNext => s.trim_to_playhead(ClipEdge::Tail, PlayheadTrimMode::Roll),
            C::TrimPrevious => s.trim_to_playhead(ClipEdge::Head, PlayheadTrimMode::Plain),
            C::TrimNext => s.trim_to_playhead(ClipEdge::Tail, PlayheadTrimMode::Plain),
            C::EnableClip => {
                if s.selection().is_empty() {
                    return Some("Select clips to enable or disable.".to_string());
                }
                s.toggle_enabled_selection();
            }
            C::Group => {
                if s.selection().is_empty() {
                    return Some("Select clips to group.".to_string());
                }
                s.group_selection();
            }
            C::Ungroup => {
                s.ungroup_selection();
            }
            C::Bundle => {
                if !s.bundle_selection() {
                    return Some("Select two or more clips to bundle.".to_string());
                }
            }
            C::Unbundle => {
                if !s.unbundle_selection() {
                    return Some("Select a bundled clip to unbundle.".to_string());
                }
            }
            C::JoinCuts => {
                let n = s.join_cuts_in_selection();
                return Some(match n {
                    0 => "No through edits to join.".to_string(),
                    1 => "Joined 1 cut.".to_string(),
                    _ => format!("Joined {n} cuts."),
                });
            }
            C::ExtendToSequenceEnd => {
                if s.selected_adjustment_layers().is_empty() {
                    return Some("Select Adjustment Layers to extend.".to_string());
                }
                s.toggle_extend_to_sequence_end_selection();
            }
            C::Duplicate => {
                if s.selection().is_empty() {
                    return Some("Select clips to duplicate.".to_string());
                }
                s.duplicate_selection();
            }
            C::MoveSelectionUp | C::MoveSelectionDown => {
                if s.selection().is_empty() {
                    return Some("Select clips to move.".to_string());
                }
                if !s.move_selection_lane(c == C::MoveSelectionUp) {
                    return Some(
                        if c == C::MoveSelectionUp {
                            "The clips cannot go further up."
                        } else {
                            "The clips cannot go further down."
                        }
                        .to_string(),
                    );
                }
            }
            C::JumpCutAlternate => {
                if let Some(reason) = s.jump_cut_refusal() {
                    return Some(reason);
                }
                s.jump_cut_alternate(None, settings);
            }
            C::AudioGainDown | C::AudioGainUp | C::AudioGainDown6 | C::AudioGainUp6 => {
                let db = match c {
                    C::AudioGainDown => -1.0,
                    C::AudioGainUp => 1.0,
                    C::AudioGainDown6 => -6.0,
                    _ => 6.0,
                };
                return Some(
                    s.nudge_audio_gain_report(db).unwrap_or_else(|| "Select an audio clip first.".to_string()),
                );
            }
            C::CutToBeats | C::SnapToBeats => {
                // Clip > Beat Edits (the Mac `requestBeatEdit`).
                if let Some(why) = s.beat_edit_problem() {
                    return Some(why.to_string());
                }
                let cut = c == C::CutToBeats;
                // a refused edit reports itself
                let Some(n) = (if cut { s.cut_to_beats() } else { s.snap_to_beats() }) else {
                    return Some(s.last_error().unwrap_or("").to_string());
                };
                if cut {
                    return Some(if n == 0 {
                        "No beat falls inside the selection.".to_string()
                    } else {
                        format!("Cut at {n} beat{}.", plural(n))
                    });
                }
                return Some(if n == 0 {
                    "The selected clips already end on beats.".to_string()
                } else {
                    format!("Snapped {n} clip end{} to beats.", plural(n))
                });
            }
            C::SwitchAngle(n) => match s.switch_angle(n) {
                AngleSwitchResult::Switched | AngleSwitchResult::Unchanged => {}
                AngleSwitchResult::NoAnglesClip => {
                    return Some("No Angles clip is selected or under the playhead.".to_string());
                }
                AngleSwitchResult::NoSuchAngle { count } => {
                    return Some(format!("This Angles clip has {count} angles."));
                }
                AngleSwitchResult::Refused => {
                    return Some(s.last_error().unwrap_or("Could not switch the angle.").to_string());
                }
            },
            C::TagDialogue | C::TagMusic | C::TagSFX => {
                let tag = match c {
                    C::TagDialogue => AudioTag::Dialogue,
                    C::TagMusic => AudioTag::Music,
                    _ => AudioTag::Sfx,
                };
                if !s.toggle_audio_tag(tag) {
                    return Some("Select an audio clip first.".to_string());
                }
            }
            _ => return None,
        }
        Some(String::new())
    }
}
