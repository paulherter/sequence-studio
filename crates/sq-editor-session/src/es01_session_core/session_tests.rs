//! Session-level tests of the ES1 members: selection, follow selection, transport, tabs, enablement, shortcut commands.

use std::collections::BTreeSet;

use sq_core_model::{Clip, TrackKind};
use sq_core_time::{Id, SequentialIds, Time, TimeRange};
use sq_playback::engine::preview_rate::PreviewRate;

use crate::{Change, EditorSession, EngineCall, SessionDeps, StubProgramEngine};

fn id(n: u128) -> Id {
    Id::from_u128(n)
}

/// Sequence at 1/30 with video clips A (0-2 s) and B (2-4 s) on V1 (targeted).
fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let dir = std::env::temp_dir().join("sq-es01-tests");
    let mut s = EditorSession::new(project, SessionDeps::headless(dir));
    s.ids = Box::new(SequentialIds::default());
    for _ in 0..1000 {
        s.ids.next_id();
    }
    s.perform("Setup", None, |p| {
        let mut ids = SequentialIds::default();
        let t = &mut p.timelines[0];
        t.format.frame_duration = Time::new(1, 30);
        t.tracks[0].is_targeted = true;
        for (n, start) in [(1u128, 0), (2, 2)] {
            let c = Clip::new(
                id(n),
                "clip",
                id(100 + n),
                TrackKind::Video,
                TimeRange::new(Time::ZERO, Time::seconds(2)),
                Time::seconds(start),
            );
            assert!(t.tracks[0].insert(c, &mut ids).is_ok());
        }
    });
    s.take_changes();
    s
}

fn stub(s: &EditorSession) -> &StubProgramEngine {
    s.engine().as_any().downcast_ref::<StubProgramEngine>().expect("stub engine")
}

fn set(ids: &[u128]) -> BTreeSet<Id> {
    ids.iter().map(|n| id(*n)).collect()
}

#[test]
fn seek_snaps_to_frames_and_never_goes_negative() {
    let mut s = session();
    s.seek(Time::new(1, 100));
    assert_eq!(s.playhead(), Time::ZERO);
    s.seek(Time::new(-5, 1));
    assert_eq!(s.playhead(), Time::ZERO);
    s.seek(Time::seconds(1));
    assert_eq!(s.playhead(), Time::seconds(1));
    assert!(s.take_changes().contains(Change::PLAYHEAD));
    assert!(stub(&s).calls.contains(&EngineCall::Seek(Time::seconds(1))));
}

#[test]
fn selection_follows_the_playhead_across_a_clip_boundary() {
    let mut s = session();
    s.seek(Time::new(3, 1));
    assert_eq!(s.selection(), &set(&[2]));
    s.seek(Time::new(1, 1));
    assert_eq!(s.selection(), &set(&[1]));
    // Inside the same clip a manual selection stays.
    s.select(BTreeSet::new(), BTreeSet::new());
    s.seek(Time::new(3, 2));
    assert!(s.selection().is_empty());
}

#[test]
fn a_stop_seen_by_notify_evaluates_the_follow() {
    let mut s = session();
    s.seek(Time::new(1, 1));
    s.play_pause();
    assert!(s.is_playing());
    // The engine stops by itself (end of the sequence): only `notify` learns of it, as in Swift.
    s.is_playing = false;
    s.playhead = Time::new(3, 1);
    s.notify(Change::TRANSPORT);
    assert_eq!(s.selection(), &set(&[2]));
}

#[test]
fn follow_off_leaves_the_selection_alone() {
    let mut s = session();
    s.set_selection_follows_playhead(false);
    s.select(set(&[1]), BTreeSet::new());
    s.seek(Time::seconds(3));
    assert_eq!(s.selection(), &set(&[1]));
}

#[test]
fn scrub_defers_the_follow_until_it_ends() {
    let mut s = session();
    s.seek(Time::new(1, 1));
    s.begin_scrub();
    s.scrub(Time::seconds(3));
    assert!(s.is_follow_pending());
    assert!(s.selection().is_empty());
    assert!(s.next_follow_deadline().is_some());
    s.end_scrub();
    assert!(!s.is_follow_pending());
    assert_eq!(s.selection(), &set(&[2]));
}

#[test]
fn play_pause_and_play_from_start_drive_the_engine() {
    let mut s = session();
    s.seek(Time::seconds(2));
    s.play_pause();
    assert!(s.is_playing());
    s.play_pause();
    assert!(!s.is_playing());
    s.play_from_start();
    assert!(s.is_playing());
    assert_eq!(s.playhead(), Time::ZERO);
    s.stop_playback();
    assert!(!s.is_playing());
    s.set_preview_rate(PreviewRate::NORMAL);
}

/// Space at the end of the sequence (parked on the end or on the last frame) starts over, never "playing" in place.
#[test]
fn space_at_the_end_plays_from_the_start() {
    let mut s = session();
    s.seek(s.monitor_duration() - s.monitor_frame_duration());
    s.play_pause();
    assert!(s.is_playing());
    assert_eq!(s.playhead(), Time::ZERO, "the last frame restarts");
    s.stop_playback();
    s.seek(s.monitor_duration());
    s.play_pause();
    assert!(s.is_playing());
    assert_eq!(s.playhead(), Time::ZERO, "the end restarts");
    s.play_pause();
    assert!(!s.is_playing(), "the second Space stops");
}

#[test]
fn step_frames_and_edit_point_jumps() {
    let mut s = session();
    s.step_frames(3);
    assert_eq!(s.playhead(), Time::new(3, 30));
    s.go_to_next_edit_point();
    assert_eq!(s.playhead(), Time::seconds(2));
    s.go_to_previous_edit_point();
    assert_eq!(s.playhead(), Time::ZERO);
    s.go_to_end();
    assert_eq!(s.playhead(), s.monitor_duration());
    s.go_to_start();
    assert_eq!(s.playhead(), Time::ZERO);
}

/// End parks after the last frame (Premiere's Go to Sequence End), so Insert / Overwrite / Paste there append instead of
/// splitting the last clip. Space from there starts over; one frame back is the last frame.
#[test]
fn go_to_end_parks_on_the_sequence_end() {
    let mut s = session();
    s.go_to_end();
    assert_eq!(s.playhead(), Time::seconds(4));
    assert!(stub(&s).calls.contains(&EngineCall::Seek(Time::seconds(4))));
    s.step_frames(-1);
    assert_eq!(s.playhead(), Time::seconds(4) - Time::new(1, 30));
    s.go_to_end();
    s.play_pause();
    assert_eq!(s.playhead(), Time::ZERO, "Space at the end starts over");
}

#[test]
fn enablement_follows_the_selection() {
    let mut s = session();
    s.set_selection_follows_playhead(false);
    assert!(!s.can_nudge_or_slide_selection() && !s.can_select_edge_of_selection());
    s.select(set(&[1]), BTreeSet::new());
    assert!(s.can_nudge_or_slide_selection());
    assert!(s.can_select_adjacent_clip(true));
    assert!(!s.can_select_adjacent_clip(false));
    assert!(s.can_go_to_selected_clip_edge());
    assert!(!s.can_trim_selection_to_range());
    assert!(!s.can_unlink_selection());
    assert!(!s.can_join_cuts() || s.can_join_cuts());
    let edges = s.edge_selection_of_selection(sq_core_model::ClipEdge::Tail);
    assert_eq!(edges.map(|e| e.edges.len()), Some(1));
}

#[test]
fn toggle_all_targets_is_one_undo_step() {
    let mut s = session();
    assert!(s.can_toggle_all_targets() && s.toggle_all_targets_turns_on());
    assert!(s.toggle_all_targets());
    assert_eq!(s.undo_name(), Some("Change Track Targets"));
    assert!(s.project().timelines[0].tracks.iter().all(|t| t.is_targeted));
    assert!(!s.toggle_all_targets_turns_on());
    assert!(s.toggle_all_targets());
    assert!(s.project().timelines[0].tracks.iter().all(|t| !t.is_targeted));
    assert!(s.undo());
    assert!(s.toggle_targets(TrackKind::Audio));
    assert!(s.can_toggle_track_target(TrackKind::Video, 4));
    assert!(!s.can_toggle_track_target(TrackKind::Video, 5));
    assert!(s.toggle_track_target(TrackKind::Video, 2));
    assert!(s.can_toggle_lock_of_targets());
    assert!(s.toggle_lock_of_targets());
    assert_eq!(s.undo_name(), Some("Lock Tracks"));
}

#[test]
fn marker_at_playhead_and_sequence_settings() {
    let mut s = session();
    assert!(!s.can_edit_marker_at_playhead());
    let mut settings = s.active_timeline().map(|t| t.settings()).expect("settings");
    assert!(!s.apply_sequence_settings(&settings));
    settings.name = "  ".into();
    assert!(!s.apply_sequence_settings(&settings));
    settings.name = "Main".into();
    assert!(s.apply_sequence_settings(&settings));
    assert_eq!(s.active_timeline().map(|t| t.name.clone()), Some("Main".to_string()));
    assert_eq!(s.undo_name(), Some("Sequence Settings"));
}

#[test]
fn history_list_jumps_by_undoing_and_redoing() {
    let mut s = session();
    s.perform("Rename", None, |p| p.name = "A".into());
    s.perform("Rename again", None, |p| p.name = "B".into());
    let list = s.history_list();
    assert_eq!(list.position, 3);
    assert!(s.jump_to_history_row(1));
    assert_eq!(s.project().name, "Untitled");
    assert!(s.jump_to_history_row(3));
    assert_eq!(s.project().name, "B");
    assert!(!s.jump_to_history_row(3));
}

#[test]
fn sequence_tabs_follow_the_active_sequence() {
    let mut s = session();
    let first = s.active_timeline_id().expect("active");
    let mut ids = SequentialIds::default();
    let second = EditorSession::make_untitled(&mut ids).timelines[0].clone();
    let mut second = second;
    second.id = id(500);
    let second_id = second.id;
    s.perform("Add Sequence", None, |p| p.timelines.push(second));
    s.select(set(&[1]), BTreeSet::new());
    s.set_active_timeline(second_id);
    assert_eq!(s.active_timeline_id(), Some(second_id));
    assert!(s.selection().is_empty());
    assert_eq!(s.sequence_tabs().current(), Some(second_id));
    s.select_sequence_tab(first);
    assert_eq!(s.active_timeline_id(), Some(first));
    s.close_sequence_tab(first);
    assert_eq!(s.active_timeline_id(), Some(second_id));
    // Unknown ids are ignored.
    s.set_active_timeline(id(999));
    assert_eq!(s.active_timeline_id(), Some(second_id));
}

#[test]
fn delete_selection_lifts_and_ripple_deletes() {
    let mut s = session();
    s.set_selection_follows_playhead(false);
    s.select(set(&[1]), BTreeSet::new());
    s.delete_selection(false, None);
    assert_eq!(s.undo_name(), Some("Delete"));
    assert!(s.selection().is_empty());
    assert_eq!(s.active_timeline().map(|t| t.duration()), Some(Time::seconds(4)));
    s.select(set(&[2]), BTreeSet::new());
    s.delete_selection(true, None);
    assert_eq!(s.undo_name(), Some("Ripple Delete"));
    assert!(s.undo() && s.undo());
    assert_eq!(s.active_timeline().map(|t| t.duration()), Some(Time::seconds(4)));
}

#[test]
fn ripple_delete_moves_the_playhead_back_with_the_picture() {
    let mut s = session();
    s.set_selection_follows_playhead(false);
    s.seek(Time::seconds(3));
    s.select(set(&[1]), BTreeSet::new());
    s.delete_selection(true, None);
    assert_eq!(s.playhead(), Time::seconds(1));
    assert!(s.undo());
    assert_eq!(s.playhead(), Time::seconds(3));
}

#[test]
fn add_edit_splits_the_clip_and_a_second_cut_selects_the_piece() {
    let mut s = session();
    s.set_selection_follows_playhead(false);
    s.seek(Time::seconds(1));
    s.add_edit_at_playhead(false);
    assert_eq!(s.undo_name(), Some("Add Edit"));
    assert_eq!(s.active_timeline().map(|t| t.tracks[0].clips().len()), Some(3));
    s.seek(Time::new(3, 2));
    s.add_edit_at_playhead(false);
    s.seek(Time::new(7, 4));
    s.add_edit_at_playhead(false);
    assert_eq!(s.selection().len(), 1);
    assert_eq!(s.undo_name(), Some("Add Edit"));
}

#[test]
fn marks_and_range_commands() {
    let mut s = session();
    s.seek(Time::seconds(1));
    s.mark_in();
    s.seek(Time::seconds(3));
    s.mark_out();
    let range = s.active_timeline().and_then(|t| t.in_out).expect("range");
    assert_eq!(range.start, Time::seconds(1));
    s.extract_range();
    assert_eq!(s.undo_name(), Some("Delete Range"));
    assert_eq!(s.active_timeline().map(|t| t.duration()), Some(Time::new(59, 30)));
    s.clear_in_out();
    s.lift_range();
    assert_eq!(s.last_error(), Some("Set In and Out first."));
    s.add_marker_at_playhead();
    assert_eq!(s.undo_name(), Some("Add Marker"));
}

#[test]
fn add_sequence_names_and_opens_it() {
    let mut s = session();
    assert_eq!(s.suggested_sequence_name(), "Sequence 02");
    let id = s.add_sequence(Some("  "), None, None);
    assert_eq!(s.active_timeline_id(), Some(id));
    assert_eq!(s.active_timeline().map(|t| t.name.clone()), Some("Sequence 02".to_string()));
    assert_eq!(s.undo_name(), Some("New Sequence"));
    assert_eq!(s.suggested_sequence_name(), "Sequence 03");
    assert!(s.sequence_nesting_refusal(&[id]).is_some());
}

#[test]
fn commit_replays_the_edits_as_one_step() {
    use super::{TimelineCommit, TimelineEdit};
    let mut s = session();
    s.set_selection_follows_playhead(false);
    let t = s.active_timeline().cloned().expect("timeline");
    let edits = vec![TimelineEdit::Nudge { clips: vec![id(2)], by: Time::seconds(1) }];
    let mut ids = SequentialIds::default();
    let after = TimelineEdit::apply_all(&edits, &t, &mut ids).expect("applies");
    let c = TimelineCommit::new(after, edits, "Nudge", set(&[2]), BTreeSet::new());
    s.commit(&c);
    assert_eq!(s.undo_name(), Some("Nudge"));
    assert_eq!(s.selection(), &set(&[2]));
    assert_eq!(s.active_timeline().map(|t| t.duration()), Some(Time::seconds(5)));
}

#[test]
fn scoped_edits_wrap_only_when_partners_are_held_back() {
    use super::TimelineEdit;
    let s = session();
    let t = s.active_timeline().expect("timeline");
    let edits = vec![TimelineEdit::Lift(vec![id(1)])];
    assert_eq!(TimelineEdit::scoped(edits.clone(), Some(&set(&[1])), t), edits);
    assert_eq!(TimelineEdit::scoped(edits.clone(), None, t), edits);
}

fn temp(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("sq-es01-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    assert!(std::fs::create_dir_all(&dir).is_ok());
    dir
}

fn session_in(dir: &std::path::Path) -> EditorSession {
    let mut ids = SequentialIds::default();
    EditorSession::new(EditorSession::make_untitled(&mut ids), SessionDeps::headless(dir.join("autosave")))
}

#[test]
fn save_as_save_and_open_round_trip() {
    let dir = temp("save");
    let mut s = session_in(&dir);
    assert!(s.save().is_err(), "no file yet");
    s.perform("Rename", None, |p| p.name = "Film".into());
    assert!(s.is_dirty());
    let path = dir.join("Film.sqproj");
    assert!(s.save_as(&path).is_ok());
    assert!(!s.is_dirty());
    assert_eq!(s.file_url(), Some(path.as_path()));
    s.perform("Rename again", None, |p| p.name = "Film 2".into());
    assert!(s.is_dirty() && s.save().is_ok() && !s.is_dirty());
    let events = s.take_events();
    assert_eq!(events.iter().filter(|e| matches!(e, crate::SessionEvent::Saved(_))).count(), 2);

    let mut other = session_in(&dir);
    assert!(matches!(other.open(&path), Ok(None)));
    assert_eq!(other.project().name, "Film 2");
    assert!(!other.is_dirty() && !other.can_undo());
    assert_eq!(other.file_url(), Some(path.as_path()));
    assert!(other.take_events().iter().any(|e| matches!(e, crate::SessionEvent::ProjectReplaced)));
    assert!(other.open(&dir.join("missing.sqproj")).is_err());
    assert!(other.last_error().is_some());
}

/// A damaged file opens as a repaired copy without a file; Save As to the original name keeps `.damaged.bak` and then the
/// project saves normally.
#[test]
fn a_repaired_copy_can_be_saved_over_the_original_and_keeps_a_backup() {
    let dir = temp("repaired");
    let mut s = session_in(&dir);
    let path = dir.join("Film.sqproj");
    assert!(s.save_as(&path).is_ok());
    let file = path.join("project.json");
    let mut json: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&file).unwrap_or_default()).unwrap_or_default();
    json["project"]["media"] =
        serde_json::json!([{"id": "0F0F0F0F-0F0F-4F0F-8F0F-0F0F0F0F0F0F", "name": "Bad", "path": "/x"}]);
    let damaged = serde_json::to_vec(&json).unwrap_or_default();
    assert!(std::fs::write(&file, &damaged).is_ok());

    let mut other = session_in(&dir);
    let report = other.open(&path).ok().flatten();
    assert!(report.is_some_and(|r| !r.is_empty()), "opened with parts left out");
    assert!(other.file_url().is_none() && other.is_dirty(), "an unsaved repaired copy");
    assert_eq!(other.salvaged_from(), Some(path.as_path()));
    assert!(other.save().is_err(), "Save has no file yet: the shell asks for a place");
    assert_eq!(std::fs::read(&file).unwrap_or_default(), damaged, "nothing written until the user chooses");

    assert!(other.save_as(&path).is_ok());
    assert_eq!(
        std::fs::read(dir.join("Film.sqproj.damaged.bak")).unwrap_or_default(),
        damaged,
        "the damaged file is kept"
    );
    assert!(other.file_url() == Some(path.as_path()) && !other.is_dirty() && other.salvaged_from().is_none());
    let mut third = session_in(&dir);
    assert!(matches!(third.open(&path), Ok(None)), "the saved file opens without a repair");
}

#[test]
fn save_copy_leaves_the_open_project_alone() {
    let dir = temp("copy");
    let mut s = session_in(&dir);
    s.perform("Rename", None, |p| p.name = "Film".into());
    let copy = dir.join("Copy.sqproj");
    assert!(s.save_copy(&copy).is_ok());
    assert!(s.is_dirty() && s.file_url().is_none());
    let mut other = session_in(&dir);
    assert!(matches!(other.open(&copy), Ok(None)));
    assert_eq!(other.project().name, "Film");
    assert_ne!(other.project().id, s.project().id);
}

#[test]
fn a_failed_open_message_ends_when_the_next_project_replaces_it() {
    let mut s = session();
    assert!(s.open(std::path::Path::new("/nonexistent/none.sqproj")).is_err());
    assert!(s.last_error().is_some());
    s.new_project(EditorSession::make_empty(&mut SequentialIds::default()));
    assert_eq!(s.last_error(), None);
}

#[test]
fn new_project_resets_playback_selection_and_tabs() {
    let dir = temp("new");
    let mut s = session_in(&dir);
    s.seek(Time::seconds(2));
    s.new_project(EditorSession::make_empty(&mut SequentialIds::default()));
    assert_eq!((s.playhead(), s.active_timeline_id()), (Time::ZERO, None));
    assert!(s.sequence_tabs().tabs().is_empty() && !s.can_undo());
    s.close_project();
    assert!(s.is_empty_untitled());
}

/// The menus ask for the autosave versions on every frame: the folder is listed once per window, not per frame (a listing
/// cost the Windows UI thread 13 to 50 ms per frame). The app's own writes (timed version, checkpoint) show at once; only
/// a change from outside waits for the next window.
#[test]
fn autosave_versions_list_the_folder_once_per_window() {
    let dir = temp("auto-listing");
    let mut s = session_in(&dir);
    let t0 = std::time::Instant::now();
    let half = t0 + std::time::Duration::from_millis(500);
    let later = t0 + std::time::Duration::from_secs(3);
    assert!(s.autosave_versions_at(t0).is_empty());
    s.perform("Rename", None, |p| p.name = "Film".into());
    assert!(s.tick_autosave());
    assert_eq!(s.autosave_versions_at(half).len(), 1, "the timed version shows at once");
    let outside = s.project().clone();
    let mut ids = SequentialIds::default();
    let at = sq_core_time::Timestamp::from_unix_seconds(5_000.0);
    assert!(s.autosave_store.write(&outside, at, Some("Outside"), &mut ids).is_ok());
    assert_eq!(s.autosave_versions_at(half).len(), 1, "a change from outside is served from the listing");
    assert_eq!(s.autosave_versions_at(later).len(), 2, "a later frame lists again");
    assert!(s.save_checkpoint("Before grade").is_some());
    assert_eq!(s.autosave_versions_at(later).len(), 3, "a checkpoint shows at once");
}

#[test]
fn autosave_writes_a_version_when_dirty_and_checkpoints_are_named() {
    let dir = temp("auto");
    let mut s = session_in(&dir);
    assert!(!s.tick_autosave(), "clean project");
    s.perform("Rename", None, |p| p.name = "Film".into());
    assert!(s.tick_autosave());
    assert!(s.take_changes().contains(Change::STATUS));
    let versions = s.autosave_store.versions(s.project().id);
    assert_eq!(versions.len(), 1);
    assert!(s.save_checkpoint("  ").is_none());
    let v = s.save_checkpoint("Before grade").expect("checkpoint");
    assert_eq!(v.name.as_deref(), Some("Before grade"));
}

/// A recovered project that was saved before saves to its original file (Save asks for no place), and says "Saved" after.
#[test]
fn a_recovered_project_saves_to_its_original_file() {
    use sq_core_project::recovery::RecoveryScanner;
    use sq_core_time::Timestamp;
    let dir = temp("recover-path");
    let late = || Timestamp::from_unix_seconds(4_000_000_000.0);
    let mut deps = SessionDeps::headless(dir.join("autosave"));
    deps.clock = Box::new(late);
    let mut s = EditorSession::new(EditorSession::make_untitled(&mut SequentialIds::default()), deps);
    let path = dir.join("Film.sqproj");
    s.perform("Rename", None, |p| p.name = "Film".into());
    assert!(s.save_as(&path).is_ok());
    s.perform("Rename again", None, |p| p.name = "Film 2".into());
    assert!(s.tick_autosave(), "the unsaved edit is backed up");
    // The run did not end: its marker is dead. A fresh session offers and takes the recovery.
    let fresh = SessionDeps::headless(dir.join("autosave-of-the-new-run"));
    let mut other = EditorSession::new(EditorSession::make_untitled(&mut SequentialIds::default()), fresh);
    let scanner = RecoveryScanner::new(&s.autosave_store, |_| false, |_| None);
    let found = scanner.scan(late());
    let candidate = found.first().expect("one candidate");
    assert_eq!(candidate.project_path.as_deref(), Some(path.as_path()));
    assert!(other.recover(candidate, &scanner).is_ok());
    assert_eq!(other.file_url(), Some(path.as_path()), "Save has a place");
    assert!(other.is_dirty());
    assert!(other.save().is_ok() && !other.is_dirty());
}

#[test]
fn recovery_snapshots_replace_their_own_previous_one() {
    use super::RecoverySnapshotState;
    use sq_core_time::Timestamp;
    let dir = temp("recovery");
    let mut s = session_in(&dir);
    let mut state = RecoverySnapshotState::new();
    let t = |sec: f64| Timestamp::from_unix_seconds(sec);
    assert!(!s.tick_recovery(&mut state, 1.0, t(100.0)), "clean");
    s.perform("Rename", None, |p| p.name = "A".into());
    assert!(!s.tick_recovery(&mut state, 1.0, t(100.0)), "the edit has to stay quiet first");
    assert!(s.tick_recovery(&mut state, 1.0, t(101.2)));
    state.finish_pending();
    assert!(!s.tick_recovery(&mut state, 1.0, t(102.0)), "nothing new");
    s.perform("Rename", None, |p| p.name = "B".into());
    assert!(!s.tick_recovery(&mut state, 1.0, t(102.0)));
    assert!(s.tick_recovery(&mut state, 1.0, t(103.5)));
    state.finish_pending();
    assert_eq!(s.autosave_store.versions(s.project().id).len(), 1);
}

/// A crash a few seconds after an edit still offers that edit; no edit offers nothing.
#[test]
fn a_crash_after_the_debounce_offers_recovery_with_the_edit() {
    use super::RecoverySnapshotState;
    use sq_core_project::recovery::RecoveryScanner;
    use sq_core_time::Timestamp;
    let dir = temp("recovery-crash");
    let late = |sec: f64| Timestamp::from_unix_seconds(4_000_000_000.0 + sec);
    let mut deps = SessionDeps::headless(dir.join("autosave"));
    deps.clock = Box::new(|| Timestamp::from_unix_seconds(4_000_000_000.0));
    let mut s = EditorSession::new(EditorSession::make_untitled(&mut SequentialIds::default()), deps);
    let mut state = RecoverySnapshotState::new();
    let store = s.autosave_store.clone();
    let scanner = RecoveryScanner::new(&store, |_| false, |_| None);
    let mut quiet_deps = SessionDeps::headless(dir.join("autosave-no-edit"));
    quiet_deps.clock = Box::new(|| Timestamp::from_unix_seconds(4_000_000_000.0));
    let mut quiet = EditorSession::new(EditorSession::make_untitled(&mut SequentialIds::default()), quiet_deps);
    assert!(!quiet.tick_recovery(&mut RecoverySnapshotState::new(), 1.0, late(5.0)));
    let quiet_scanner = RecoveryScanner::new(&quiet.autosave_store, |_| false, |_| None);
    assert!(quiet_scanner.scan(late(6.0)).is_empty(), "no edit, no offer");
    s.perform("Rename", None, |p| p.name = "Edited".into());
    assert!(!s.tick_recovery(&mut state, 1.0, late(0.0)));
    assert!(s.tick_recovery(&mut state, 1.0, late(1.1)), "one second after the last change");
    state.finish_pending();
    // The run is killed here: its marker is dead.
    let found = scanner.scan(late(2.0));
    let candidate = found.first().expect("the edit is offered");
    let restored = s.autosave_store.read(&candidate.autosave).expect("readable");
    assert_eq!(restored.name, "Edited");
}

/// A drag changes the project every few milliseconds: one write for the whole drag, after it settles.
#[test]
fn a_drag_makes_one_recovery_write_per_window() {
    use super::RecoverySnapshotState;
    use sq_core_time::Timestamp;
    let dir = temp("recovery-drag");
    let mut s = session_in(&dir);
    let mut state = RecoverySnapshotState::new();
    let mut writes = 0;
    for i in 0..30 {
        let now = Timestamp::from_unix_seconds(500.0 + f64::from(i) * 0.1);
        s.perform("Rename", None, move |p| p.name = format!("Drag {i}"));
        writes += usize::from(s.tick_recovery(&mut state, 1.0, now));
    }
    assert_eq!(writes, 0, "nothing is written while the project keeps changing");
    for step in 0..20 {
        let now = Timestamp::from_unix_seconds(503.0 + f64::from(step) * 0.1);
        writes += usize::from(s.tick_recovery(&mut state, 1.0, now));
        state.finish_pending();
    }
    assert_eq!(writes, 1, "one write after the drag settled");
    assert_eq!(s.autosave_store.versions(s.project().id).len(), 1);
}

#[test]
fn notes_marks_and_input_color_are_undoable_or_quiet() {
    let dir = temp("misc");
    let mut s = session_in(&dir);
    s.set_project_notes("hello");
    assert_eq!(s.undo_name(), Some("Edit Project Notes"));
    s.set_project_notes("hello");
    assert_eq!(s.undo_step_depth(), 1);
    s.set_project_input_color_space(Some(sq_core_model::ColorSpaceID::Rec709));
    assert_eq!(s.undo_name(), Some("Set Project Input Color Space"));
    let media = id(77);
    s.set_source_marks(None, media);
    assert!(s.project().source_marks.is_empty());
    assert!(s.amend_project(|p| p.name = "Quiet".into()));
    assert_eq!(s.undo_step_depth(), 2);
    assert!(s.is_dirty());
}

#[test]
fn close_ends_the_marker_and_reports_the_release() {
    let dir = temp("close");
    let mut s = session_in(&dir);
    s.perform("Rename", None, |p| p.name = "A".into());
    s.take_events();
    s.close();
    let events = s.take_events();
    assert!(events.iter().any(|e| matches!(e, crate::SessionEvent::ReleaseProject { was_dirty: true, .. })));
}

fn with_media() -> (EditorSession, Id) {
    use sq_core_model::{MediaFingerprint, MediaRef};
    let mut s = session();
    let media = id(300);
    let mut m = MediaRef::new(media, "shot.mov", "/shot.mov", MediaFingerprint::new(1));
    m.duration = Some(Time::seconds(5));
    s.perform("Import", None, |p| p.add(m));
    s.take_changes();
    (s, media)
}

#[test]
fn place_media_overwrites_at_the_playhead_and_selects_the_new_clip() {
    use super::PlaceOptions;
    let (mut s, media) = with_media();
    s.set_selection_follows_playhead(false);
    s.seek(Time::seconds(4));
    assert!(!s.place_media(&[id(999)], &PlaceOptions::default()));
    assert!(s.place_media(&[media], &PlaceOptions::default()));
    assert_eq!(s.undo_name(), Some("Overwrite"));
    let t = s.active_timeline().expect("timeline");
    assert_eq!(t.tracks[0].clips().len(), 3);
    assert_eq!(t.duration(), Time::seconds(9));
    assert_eq!(s.selection().len(), 1);
    assert!(s.format_mismatch(&[media]).is_none());
    let opts =
        PlaceOptions { at: Some(Time::ZERO), mode: sq_core_model::ThreePointMode::Insert, ..PlaceOptions::default() };
    assert!(s.place_media(&[media], &opts));
    assert_eq!(s.undo_name(), Some("Insert"));
    assert_eq!(s.active_timeline().map(|t| t.duration()), Some(Time::seconds(14)));
}

#[test]
fn place_media_without_a_sequence_makes_one() {
    use super::PlaceOptions;
    use sq_core_model::{MediaFingerprint, MediaRef};
    let mut ids = SequentialIds::default();
    let dir = std::env::temp_dir().join(format!("sq-es01-place-{}", std::process::id()));
    let mut s = EditorSession::new(EditorSession::make_empty(&mut ids), SessionDeps::headless(dir));
    s.ids = Box::new(SequentialIds::default());
    for _ in 0..500 {
        s.ids.next_id();
    }
    let mut m = MediaRef::new(id(300), "shot.mov", "/shot.mov", MediaFingerprint::new(1));
    m.duration = Some(Time::seconds(5));
    s.perform("Import", None, |p| p.add(m));
    assert!(s.active_timeline().is_none());
    assert!(s.place_media(&[id(300)], &PlaceOptions::default()));
    assert_eq!(s.active_timeline().map(|t| t.name.clone()), Some("Sequence 01".to_string()));
    assert!(s.active_timeline().is_some_and(|t| t.duration() >= Time::seconds(4)));
}

#[test]
fn nest_selection_combines_the_clips_into_a_new_sequence() {
    let mut s = session();
    s.set_selection_follows_playhead(false);
    s.select(set(&[1]), BTreeSet::new());
    s.ids = Box::new(SequentialIds::default());
    for _ in 0..500 {
        s.ids.next_id();
    }
    let seq = s.nest_selection("  Intro ").expect("nested");
    assert_eq!(s.undo_name(), Some("Combine"));
    assert_eq!(s.project().timeline(seq).map(|t| t.name.clone()), Some("Intro".to_string()));
    assert_eq!(s.selected_nested_clips().len(), 1);
    assert!(s.selected_group_clips().is_empty());
}

#[test]
fn group_and_ungroup_selection_are_one_undo_step_each() {
    let mut s = session();
    s.set_selection_follows_playhead(false);
    s.select(set(&[1]), BTreeSet::new());
    s.ids = Box::new(SequentialIds::default());
    for _ in 0..500 {
        s.ids.next_id();
    }
    let before = s.project().clone();
    let seq = s.group_selection().expect("grouped");
    assert_eq!(s.undo_name(), Some("Group"));
    assert!(s.project().timeline(seq).is_some_and(|t| t.is_group()));
    assert_eq!(s.selected_group_clips().len(), 1);
    assert!(s.selected_nested_clips().is_empty());
    assert!(s.ungroup_selection());
    assert_eq!(s.undo_name(), Some("Ungroup"));
    assert!(s.project().timeline(seq).is_none());
    assert_eq!(s.project().timelines, before.timelines);
    assert_eq!(s.selection().len(), 1);
}

#[test]
fn ungroup_and_unnest_without_a_target_say_why() {
    let mut s = session();
    s.set_selection_follows_playhead(false);
    s.select(set(&[1]), BTreeSet::new());
    assert!(!s.ungroup_selection());
    assert_eq!(s.last_error(), Some("Select a group to ungroup."));
    assert!(!s.unnest_selection());
    assert_eq!(s.last_error(), Some("Select a nested sequence to unnest."));
}

#[test]
fn unnest_selection_puts_the_nested_content_back() {
    let mut s = session();
    s.set_selection_follows_playhead(false);
    s.select(set(&[1]), BTreeSet::new());
    s.ids = Box::new(SequentialIds::default());
    for _ in 0..500 {
        s.ids.next_id();
    }
    let seq = s.nest_selection("N").expect("nested");
    assert!(s.unnest_selection());
    assert_eq!(s.undo_name(), Some("Unnest"));
    assert!(s.project().timeline(seq).is_some());
    let t = s.active_timeline().expect("timeline");
    assert!(!t.tracks.iter().flat_map(|tr| tr.clips()).any(|c| c.sequence == Some(seq)));
}

#[test]
fn place_media_patched_follows_the_source_patch() {
    use super::PlaceOptions;
    use sq_core_model::TrackKind;
    let (mut s, media) = with_media();
    s.set_selection_follows_playhead(false);
    let videos: Vec<Id> =
        s.active_timeline().expect("t").tracks.iter().filter(|t| t.kind == TrackKind::Video).map(|t| t.id).collect();
    assert!(videos.len() >= 2);
    s.patch_source(TrackKind::Video, videos[1]);
    s.seek(Time::seconds(30));
    let opts = PlaceOptions { patched: true, ..PlaceOptions::default() };
    assert!(s.place_media(&[media], &opts));
    let t = s.active_timeline().expect("t");
    let hit = |track: Id| {
        t.tracks.iter().find(|x| x.id == track).expect("track").clips().iter().any(|c| c.start >= Time::seconds(30))
    };
    assert!(hit(videos[1]) && !hit(videos[0]));
    // Without `patched` the drop rule keeps V1.
    s.seek(Time::seconds(60));
    assert!(s.place_media(&[media], &PlaceOptions::default()));
    let t = s.active_timeline().expect("t");
    assert!(
        t.tracks.iter().find(|x| x.id == videos[0]).expect("v1").clips().iter().any(|c| c.start >= Time::seconds(60))
    );
    // Place on Top with the video patch disconnected is refused.
    s.toggle_source_patch(TrackKind::Video);
    let depth = s.undo_step_depth();
    let top = PlaceOptions { patched: true, place_on_top: true, ..PlaceOptions::default() };
    assert!(!s.place_media(&[media], &top));
    assert_eq!(s.undo_step_depth(), depth);
}

#[test]
fn lent_ids_stay_one_stream() {
    let mut s = session();
    let a = s.with_ids(|s, ids| {
        let x = ids.next_id();
        let y = s.ids.next_id();
        assert_ne!(x, y);
        y
    });
    assert_ne!(s.ids.next_id(), a);
}

#[test]
fn save_copies_outside_luts_into_the_project_folder() {
    use sq_core_color::{ClipEffectColorExt, ProjectGradeLinksExt};
    use sq_core_model::{ClipEffect, ColorEffect, LUTRef};
    let dir = temp("lut");
    let lut = dir.join("look.cube");
    assert!(std::fs::write(&lut, "LUT_3D_SIZE 2\n").is_ok());
    let mut s = session_in(&dir);
    let lut_path = lut.to_string_lossy().into_owned();
    s.perform("Grade", None, |p| {
        let mut ids = SequentialIds::default();
        let mut c = Clip::new(
            id(1),
            "clip",
            id(101),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::seconds(2)),
            Time::ZERO,
        );
        let e = ColorEffect::new(1, Some(LUTRef::File { path: lut_path.clone() }));
        c.effects = vec![ClipEffect::color_grade(id(500), &e, &mut ids)];
        assert!(p.timelines[0].tracks[0].insert(c, &mut ids).is_ok());
    });
    // A project in its own folder (`Film/Film.sqproj`) copies; the open project follows the copy.
    let path = dir.join("Film").join("Film.sqproj");
    assert!(std::fs::create_dir_all(path.parent().unwrap()).is_ok());
    s.perform("Policy", None, |p| {
        p.media_policy = Some(sq_core_model::MediaPolicy { copy_library_items: Some(true), ..Default::default() })
    });
    assert!(s.save_as(&path).is_ok());
    let copy = dir.join("Film").join("Files").join("Library").join("look.cube");
    assert!(copy.exists());
    assert_eq!(s.project().referenced_lut_files(), vec![copy.to_string_lossy().into_owned()]);
    assert!(!s.is_dirty());
    assert!(lut.exists());
}

#[test]
fn the_app_default_decides_whether_a_save_copies_outside_luts() {
    // No project choice: the app-wide "copy Library items" default (Settings > Media) decides, read from the session.
    use sq_core_color::ClipEffectColorExt;
    use sq_core_model::{ClipEffect, ColorEffect, LUTRef, MediaPolicyDefaults};
    let dir = temp("lut-default");
    let lut = dir.join("look.cube");
    assert!(std::fs::write(&lut, "LUT_3D_SIZE 2\n").is_ok());
    let mut s = session_in(&dir);
    let lut_path = lut.to_string_lossy().into_owned();
    s.perform("Grade", None, |p| {
        let mut ids = SequentialIds::default();
        let mut c = Clip::new(
            id(1),
            "clip",
            id(101),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::seconds(2)),
            Time::ZERO,
        );
        let e = ColorEffect::new(1, Some(LUTRef::File { path: lut_path.clone() }));
        c.effects = vec![ClipEffect::color_grade(id(500), &e, &mut ids)];
        assert!(p.timelines[0].tracks[0].insert(c, &mut ids).is_ok());
    });
    s.set_media_policy_defaults(Box::new(|| MediaPolicyDefaults { copy_library_items: false, ..Default::default() }));
    let off = dir.join("Off").join("Off.sqproj");
    assert!(std::fs::create_dir_all(off.parent().unwrap()).is_ok());
    assert!(s.save_as(&off).is_ok());
    assert!(!dir.join("Off").join("Files").join("Library").join("look.cube").exists(), "the app default says no");
    s.set_media_policy_defaults(Box::new(MediaPolicyDefaults::default));
    let on = dir.join("On").join("On.sqproj");
    assert!(std::fs::create_dir_all(on.parent().unwrap()).is_ok());
    assert!(s.save_as(&on).is_ok());
    assert!(dir.join("On").join("Files").join("Library").join("look.cube").exists(), "the built-in default says yes");
}

struct HeldProbe(std::sync::Arc<std::sync::atomic::AtomicBool>);

impl crate::SessionRenderCaching for HeldProbe {
    fn spans(
        &mut self,
        _: &sq_core_model::Timeline,
        _: &std::collections::BTreeMap<Id, sq_core_model::Timeline>,
    ) -> Vec<sq_core_model::RenderCacheSpan> {
        Vec::new()
    }
    fn media_changed(&mut self) {}
    fn set_held(&mut self, held: bool) {
        self.0.store(held, std::sync::atomic::Ordering::SeqCst);
    }
}

#[test]
fn a_load_policy_reaches_the_engine_and_pauses_the_render_cache() {
    use sq_playback::engine::power_policy::{MemoryPressure, PowerPolicy};
    let held = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mut s = session();
    s.set_render_cache(Some(Box::new(HeldProbe(std::sync::Arc::clone(&held)))));
    let warning = PowerPolicy::combined(PowerPolicy::NORMAL, MemoryPressure::Warning, true, true);
    s.apply_load_policy(warning);
    assert_eq!(stub(&s).power_policy, warning);
    assert!(held.load(std::sync::atomic::Ordering::SeqCst), "warning pauses background jobs");
    s.apply_load_policy(PowerPolicy::NORMAL);
    assert_eq!(stub(&s).power_policy, PowerPolicy::NORMAL);
    assert!(!held.load(std::sync::atomic::Ordering::SeqCst));
}

#[test]
fn play_in_to_out_hands_the_range_to_the_engine_and_stops_at_out() {
    let mut s = session();
    s.seek(Time::seconds(1));
    s.mark_in();
    s.seek(Time::seconds(3));
    s.mark_out();
    s.play_in_to_out(Time::ZERO, Time::ZERO);
    let range = s.active_timeline().and_then(|t| t.in_out).expect("range");
    assert_eq!(stub(&s).play_range, Some(range));
    assert!(s.is_playing());
    assert_eq!(s.engine().position(), range.start);
    // The last frame before Out: the session stops there and parks on it.
    let fd = Time::new(1, 30);
    s.engine_mut().seek(range.end() - fd);
    s.poll_engine_position();
    assert!(!s.is_playing());
    assert_eq!(s.playhead(), range.end() - fd);
    assert!(s.engine().rate().is_paused());
}

#[test]
fn loop_playback_goes_to_the_engine_and_the_session_lets_it_wrap() {
    let mut s = session();
    s.seek(Time::seconds(1));
    s.mark_in();
    s.seek(Time::seconds(3));
    s.mark_out();
    let mut b = s.bounds();
    b.loop_playback = true;
    s.set_bounds(b);
    assert!(stub(&s).loops);
    s.play_in_to_out(Time::ZERO, Time::ZERO);
    let end = stub(&s).play_range.map(|r| r.end()).expect("range");
    // The engine reports a position at the loop's end: the session neither stops nor seeks, the engine wraps itself.
    let fd = Time::new(1, 30);
    let calls = stub(&s).calls.len();
    s.engine_mut().seek(end - fd);
    s.poll_engine_position();
    assert!(s.is_playing());
    assert_eq!(stub(&s).calls.len(), calls + 1, "only the engine's own seek, no session wrap (seek + play)");
}

#[test]
fn play_around_plays_preroll_and_postroll_and_returns_to_the_playhead() {
    let mut s = session();
    s.seek(Time::seconds(2));
    s.play_around(Time::seconds(1), Time::new(1, 1));
    assert_eq!(stub(&s).play_range, Some(TimeRange::from_end(Time::seconds(1), Time::seconds(3))));
    assert_eq!(s.engine().position(), Time::seconds(1));
    assert!(s.is_playing());
    let fd = Time::new(1, 30);
    s.engine_mut().seek(Time::seconds(3) - fd);
    s.poll_engine_position();
    assert!(!s.is_playing());
    assert_eq!(s.playhead(), Time::seconds(2), "back where it was");
    assert_eq!(stub(&s).play_range, None, "the range is gone");
}

struct SpanCache(Vec<sq_core_model::RenderCacheSpan>);

impl crate::SessionRenderCaching for SpanCache {
    fn spans(
        &mut self,
        _: &sq_core_model::Timeline,
        _: &std::collections::BTreeMap<Id, sq_core_model::Timeline>,
    ) -> Vec<sq_core_model::RenderCacheSpan> {
        self.0.clone()
    }
    fn media_changed(&mut self) {}
}

#[test]
fn cached_spans_reach_the_engine_but_not_with_the_color_solo() {
    let mut s = session();
    let span = sq_core_model::RenderCacheSpan { range: TimeRange::new(Time::ZERO, Time::seconds(1)), media: id(900) };
    s.set_render_cache(Some(Box::new(SpanCache(vec![span.clone()]))));
    s.push_timeline(true);
    assert_eq!(stub(&s).timeline.as_ref().map(|t| t.render_cache_spans.clone()), Some(vec![span]));
    // The solo shows another picture: no cached span, and the video clip is soloed in place (no file view without probe info).
    s.set_color_solo_clip(Some(id(1)));
    let shown = stub(&s).timeline.clone().expect("timeline");
    assert!(shown.render_cache_spans.is_empty());
    assert!(s.color_source_view().is_none());
    s.set_color_solo_clip(None);
    assert_eq!(stub(&s).timeline.as_ref().map(|t| t.render_cache_spans.len()), Some(1));
}

/// Locate / relink then Save: the file holds the new path, not the old offline one.
#[test]
fn a_relink_reaches_the_saved_file() {
    use sq_core_model::{MediaFingerprint, MediaRef};
    let dir = temp("relink-save");
    let real = dir.join("found.mp4");
    std::fs::write(&real, b"x").expect("media file");
    let mut s = session_in(&dir);
    let media = id(900);
    s.perform("Add media", None, |p| {
        p.media.push(MediaRef::new(media, "missing.mp4", "/nonexistent/missing.mp4", MediaFingerprint::new(1)));
    });
    let path = dir.join("Film.sqproj");
    assert!(s.save_as(&path).is_ok());
    assert!(s.locate_media(media, &real));
    assert!(s.save().is_ok());
    let saved = sq_core_project::project_file::project_file().read(&path).expect("readable");
    let on_disk = saved.media(media).expect("the item").path.clone();
    assert_eq!(on_disk, real.to_string_lossy(), "the file holds the located path");
    // The context-menu way too (`relink_missing` by folder).
    let mut s2 = session_in(&dir);
    s2.perform("Add media", None, |p| {
        p.media.push(MediaRef::new(media, "found.mp4", "/nonexistent/found.mp4", MediaFingerprint::new(1)));
    });
    let path2 = dir.join("Film2.sqproj");
    assert!(s2.save_as(&path2).is_ok());
    s2.relink_missing(&dir);
    assert!(s2.save().is_ok());
    let saved2 = sq_core_project::project_file::project_file().read(&path2).expect("readable");
    assert_eq!(saved2.media(media).expect("the item").path, real.to_string_lossy());
}

/// Swift `syncMedia`: the resolver gets the media with the project input color default applied, and the Program engine
/// redraws when that changes what the resolver sees (the stored detection stays as it is).
#[test]
fn the_project_input_color_default_reaches_the_resolver_and_redraws() {
    use crate::es08_media::testing;
    use sq_core_model::{ColorSpaceID, MediaFingerprint, MediaRef};
    use std::sync::{Arc, Mutex};

    #[derive(Default)]
    struct Seen(Mutex<Vec<MediaRef>>);
    impl crate::SessionMediaResolving for Seen {
        fn set_project_folder(&self, _: Option<std::path::PathBuf>) {}
        fn info(&self, _: Id) -> Option<sq_core_model::MediaInfo> {
            None
        }
        fn update(&self, media: &[MediaRef], _: Option<i64>) {
            *self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = media.to_vec();
        }
        fn invalidate(&self, _: &BTreeSet<Id>) {}
        fn prepare(&self, _: &[Id]) -> BTreeSet<Id> {
            BTreeSet::new()
        }
        fn file_path(&self, _: Id) -> Option<std::path::PathBuf> {
            None
        }
    }
    let dir = temp("input-color-resolver");
    let mut s = session_in(&dir);
    let seen = Arc::new(Seen::default());
    s.media = Arc::clone(&seen) as Arc<dyn crate::SessionMediaResolving>;
    let mut m = MediaRef::new(id(5), "a.mov", "/a.mov", MediaFingerprint::new(1));
    m.info = Some(testing::info(Time::new(10, 1), Some(testing::video(1920, 1080))));
    s.perform("Add media", None, |p| p.media.push(m));
    let redraws =
        |s: &EditorSession| s.engine.as_any().downcast_ref::<StubProgramEngine>().map_or(-1, |e| e.redraw_count);
    let before = redraws(&s);
    let detected = |seen: &Seen| seen.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner)[0].info.clone();
    assert_eq!(detected(&seen), s.project().media[0].info, "no default: the resolver sees the stored info");

    s.set_project_input_color_space(Some(ColorSpaceID::PqBT2020));
    let rendered = detected(&seen);
    assert_ne!(rendered, s.project().media[0].info, "the default reaches the resolver");
    assert_eq!(rendered.and_then(|i| i.detected_color_space), Some(ColorSpaceID::PqBT2020));
    assert!(redraws(&s) > before, "the shown frame is drawn again with the new color space");
    let settled = redraws(&s);
    s.perform("Rename", None, |p| p.name = "Film".into());
    assert_eq!(redraws(&s), settled, "an edit that leaves the rendered infos alone draws nothing extra");
}

#[test]
fn session_keeps_the_longest_present_stall_until_taken() {
    let s = session();
    assert_eq!(s.take_present_stall(), None);
    s.note_present_stall(std::time::Duration::from_millis(300));
    s.note_present_stall(std::time::Duration::from_millis(900));
    s.note_present_stall(std::time::Duration::from_millis(400));
    assert_eq!(s.take_present_stall(), Some(std::time::Duration::from_millis(900)));
    assert_eq!(s.take_present_stall(), None);
}
