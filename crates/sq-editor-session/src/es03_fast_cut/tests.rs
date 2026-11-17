//! Session tests of ES3 (translated from FastCutSessionTests, SpeedPointSessionTests, SpeedPresetSessionTests,
//! JumpCutSessionTests, CutCheckSessionTests, MusicFitSessionTests, BeatGridSessionTests, PunchInSessionTests).
//! The sessions are headless; selection and playhead are set directly because `select` and `seek` belong to ES1.

use std::collections::BTreeSet;

use sq_analysis::beat_grid::BeatGrid;
use sq_core_edit::cut_check::{CutCheckPlatform, CutFindingKind};
use sq_core_edit::punch_in::PunchInTimelineExt;
use sq_core_edit::punch_in_cuts::PunchInCutsOptions;
use sq_core_edit::timeline_beat_markers::TimelineBeatMarkersExt;
use sq_core_edit::timeline_speed::SpeedChange;
use sq_core_effects::speed_ramp_preset::SpeedRampPreset;
use sq_core_model::{
    AudioTag, Clip, ClipSpeed, Project, SequenceFormat, SpeedKeys, Timeline, TimelineEditMode, Track, TrackKind,
};
use sq_core_time::{Id, Time, TimeRange};
use sq_library::library_folder_store::MemorySettings;
use sq_uikit::editor_command::EditorCommand;

use super::*;
use crate::{EditorSession, SessionDeps, TimelineEdit};

fn s(n: i64) -> Time {
    Time::new(n, 1)
}
fn fd30() -> Time {
    Time::new(1, 30)
}
fn f(n: i64) -> Time {
    fd30() * n
}
fn id(n: u128) -> Id {
    Id::from_u128(n)
}

/// Ids from 1,000,000 up, so they never collide with the small fixture ids.
struct HighIds(u128);
impl sq_core_time::IdSource for HighIds {
    fn next_id(&mut self) -> Id {
        self.0 += 1;
        Id::from_u128(self.0)
    }
}

fn session(t: Timeline) -> EditorSession {
    let project = Project::new(id(9000), "P", Vec::new(), vec![t]);
    let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-es03-tests"));
    deps.ids = Box::new(HighIds(1_000_000));
    EditorSession::new(project, deps)
}

fn track(n: u128, kind: TrackKind, clips: Vec<Clip>) -> Track {
    let mut t = Track::new(id(n), kind);
    t.set_clips(clips);
    t
}

fn timeline(fd: Time, tracks: Vec<Track>) -> Timeline {
    Timeline::new(id(8000), "T", SequenceFormat::new(fd), tracks)
}

fn select(ses: &mut EditorSession, ids: &[Id]) {
    ses.set_selection_raw(ids.iter().copied().collect::<BTreeSet<_>>());
}

fn find(ses: &EditorSession, c: Id) -> Option<Clip> {
    ses.active_timeline().and_then(|t| clip_in(t, c)).cloned()
}

fn span(ses: &EditorSession, c: Id) -> Option<[i64; 2]> {
    let c = find(ses, c)?;
    let secs = |t: Time| t.value() / t.timescale();
    Some([secs(c.start), secs(c.timeline().end())])
}

fn row(ses: &EditorSession, c: Id) -> Option<usize> {
    ses.active_timeline()?.tracks.iter().position(|t| t.clips().iter().any(|x| x.id == c))
}

/// V1 as [start, end] pairs in seconds.
fn main_spans(ses: &EditorSession) -> Vec<[i64; 2]> {
    let Some(t) = ses.active_timeline() else { return Vec::new() };
    t.tracks[0].clips().iter().filter_map(|c| span(ses, c.id)).collect()
}

fn depth(ses: &EditorSession) -> usize {
    ses.history().undo_depth()
}

// MARK: Fast Cut

fn media_clip(n: u128, start: i64, dur: i64, kind: TrackKind, link: Option<Id>) -> Clip {
    let mut c = Clip::new(id(n), "c", id(500 + n), kind, TimeRange::new(s(10), s(dur)), s(start));
    c.link = link;
    c.media_duration = Some(s(100));
    c
}

/// V1: A[0-4] B[4-8] C[8-12] (each linked to its sound on A1). V2: X[9-11], attached to C.
struct Fx {
    ses: EditorSession,
    b: Id,
    c: Id,
    ab: Id,
    ac: Id,
    x: Id,
}

fn fast_cut(mode: TimelineEditMode) -> Fx {
    let (la, lb, lc) = (id(701), id(702), id(703));
    let v = |n, start, l| media_clip(n, start, 4, TrackKind::Video, Some(l));
    let a = |n, start, l| media_clip(n, start, 4, TrackKind::Audio, Some(l));
    let mut t = timeline(
        Time::new(1, 24),
        vec![
            track(1, TrackKind::Video, vec![v(11, 0, la), v(12, 4, lb), v(13, 8, lc)]),
            track(2, TrackKind::Video, vec![media_clip(14, 9, 2, TrackKind::Video, None)]),
            track(3, TrackKind::Audio, vec![a(21, 0, la), a(22, 4, lb), a(23, 8, lc)]),
            track(4, TrackKind::Audio, vec![]),
        ],
    );
    t.set_edit_mode(mode);
    Fx { ses: session(t), b: id(12), c: id(13), ab: id(22), ac: id(23), x: id(14) }
}

/// Runs `body` and checks it made exactly one undo step that restores the timeline.
fn one_step(ses: &mut EditorSession, body: impl FnOnce(&mut EditorSession)) {
    let before = ses.active_timeline().cloned();
    let d = depth(ses);
    body(ses);
    assert_eq!(depth(ses), d + 1);
    assert!(ses.undo());
    assert_eq!(ses.active_timeline().cloned(), before);
    assert!(ses.redo());
}

#[test]
fn mode_switch_is_one_undo_step_and_a_no_op_when_unchanged() {
    let mut fx = fast_cut(TimelineEditMode::Normal);
    assert!(!fx.ses.set_timeline_edit_mode(TimelineEditMode::Normal));
    let before = main_spans(&fx.ses);
    let d = depth(&fx.ses);
    assert!(fx.ses.set_timeline_edit_mode(TimelineEditMode::Magnetic));
    assert_eq!((depth(&fx.ses), fx.ses.undo_name()), (d + 1, Some("Switch to Fast Cut")));
    assert_eq!(main_spans(&fx.ses), before);
    assert!(fx.ses.undo());
    assert_eq!(fx.ses.active_timeline().map(Timeline::edit_mode), Some(TimelineEditMode::Normal));
}

#[test]
fn shift_delete_replaces_with_a_spacer() {
    let mut fx = fast_cut(TimelineEditMode::Magnetic);
    let (b, ab, c, x) = (fx.b, fx.ab, fx.c, fx.x);
    select(&mut fx.ses, &[b, ab]);
    let (before, d) = (fx.ses.active_timeline().cloned(), depth(&fx.ses));
    // The final `select` (clears the selection) is ES1's and still pending: it panics after the step was committed.
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| fx.ses.replace_selection_with_spacer()));
    assert_eq!(depth(&fx.ses), d + 1);
    assert!(fx.ses.undo());
    assert_eq!(fx.ses.active_timeline().cloned(), before);
    assert!(fx.ses.redo());
    assert!(find(&fx.ses, b).is_none());
    assert_eq!((span(&fx.ses, c), span(&fx.ses, x)), (Some([8, 12]), Some([9, 11])));
}

#[test]
fn insert_spacer_ripples_v1_and_its_attached_clips() {
    let mut fx = fast_cut(TimelineEditMode::Magnetic);
    fx.ses.playhead = s(4);
    let (b, c, ab, x) = (fx.b, fx.c, fx.ab, fx.x);
    one_step(&mut fx.ses, |s| assert_eq!(s.insert_spacer(), "Spacer inserted."));
    assert_eq!((span(&fx.ses, b), span(&fx.ses, c)), (Some([7, 11]), Some([11, 15])));
    assert_eq!((span(&fx.ses, x), span(&fx.ses, ab)), (Some([12, 14]), Some([7, 11])));
}

#[test]
fn lift_off_and_put_on_the_main_track() {
    let mut fx = fast_cut(TimelineEditMode::Magnetic);
    let (b, c) = (fx.b, fx.c);
    select(&mut fx.ses, &[b]);
    one_step(&mut fx.ses, |s| assert_eq!(s.lift_off_main_track(), "Lifted off the main track."));
    assert!(row(&fx.ses, b) != Some(0) && span(&fx.ses, b) == Some([4, 8]));
    assert_eq!(span(&fx.ses, c), Some([8, 12])); // a spacer stays on V1
    select(&mut fx.ses, &[b]);
    one_step(&mut fx.ses, |s| assert_eq!(s.put_on_main_track(), "Put on the main track."));
    assert!(row(&fx.ses, b) == Some(0) && span(&fx.ses, b) == Some([4, 8]));
}

#[test]
fn move_clip_right_swaps_with_the_neighbor_in_one_step() {
    let mut fx = fast_cut(TimelineEditMode::Magnetic);
    let (b, c, ab, x) = (fx.b, fx.c, fx.ab, fx.x);
    select(&mut fx.ses, &[b]);
    assert!(fx.ses.fast_cut_command_enabled(EditorCommand::MoveClipRight));
    one_step(&mut fx.ses, |s| assert_eq!(s.move_selected_main_clips(1), "Moved right."));
    assert_eq!((span(&fx.ses, b), span(&fx.ses, c)), (Some([8, 12]), Some([4, 8])));
    assert_eq!((span(&fx.ses, ab), span(&fx.ses, x)), (Some([8, 12]), Some([5, 7]))); // sound travels, X follows C
}

#[test]
fn move_clip_at_the_ends_says_so_and_changes_nothing() {
    let mut fx = fast_cut(TimelineEditMode::Magnetic);
    select(&mut fx.ses, &[id(11)]);
    let d = depth(&fx.ses);
    assert_ne!(fx.ses.move_selected_main_clips(-1), "Moved left.");
    assert_eq!(depth(&fx.ses), d);
}

#[test]
fn slower_speed_ripples_v1_and_carries_the_attached_clip() {
    let mut fx = fast_cut(TimelineEditMode::Magnetic);
    let (b, c, ab, ac, x) = (fx.b, fx.c, fx.ab, fx.ac, fx.x);
    select(&mut fx.ses, &[c, ac]);
    let half = SpeedChange { speed: Some(ClipSpeed::from_percent(50.0)), ..SpeedChange::default() };
    one_step(&mut fx.ses, |s| assert!(s.apply_speed(half)));
    assert_eq!((span(&fx.ses, c), span(&fx.ses, ac)), (Some([8, 16]), Some([8, 16])));
    select(&mut fx.ses, &[b, ab]);
    let double = SpeedChange { speed: Some(ClipSpeed::from_percent(200.0)), ..SpeedChange::default() };
    one_step(&mut fx.ses, |s| assert!(s.apply_speed(double)));
    assert_eq!(main_spans(&fx.ses), vec![[0, 4], [4, 6], [6, 14]]);
    assert_eq!(span(&fx.ses, x), Some([7, 9]));
    select(&mut fx.ses, &[b]);
    one_step(&mut fx.ses, |s| assert!(s.set_reversed(true)));
    assert_eq!(main_spans(&fx.ses), vec![[0, 4], [4, 6], [6, 14]]);
}

#[test]
fn set_attach_point_by_command_and_by_click() {
    let mut fx = fast_cut(TimelineEditMode::Magnetic);
    let (c, x) = (fx.c, fx.x);
    select(&mut fx.ses, &[x]);
    fx.ses.playhead = s(10);
    one_step(&mut fx.ses, |s| assert_eq!(s.set_attach_point(), "Attach point set."));
    one_step(&mut fx.ses, |s| assert!(s.set_attach_point_at(x, s9())));
    assert!(!fx.ses.set_attach_point_at(c, s9())); // a main clip has no attach point
}

fn s9() -> Time {
    s(9)
}

#[test]
fn fast_cut_commands_are_off_in_normal_and_follow_the_selection() {
    let mut fx = fast_cut(TimelineEditMode::Magnetic);
    let (b, x) = (fx.b, fx.x);
    assert!(fx.ses.fast_cut_command_enabled(EditorCommand::InsertSpacer));
    assert!(!fx.ses.fast_cut_command_enabled(EditorCommand::LiftOffMainTrack)); // nothing selected
    select(&mut fx.ses, &[b]);
    assert!(fx.ses.fast_cut_command_enabled(EditorCommand::LiftOffMainTrack));
    assert!(!fx.ses.fast_cut_command_enabled(EditorCommand::PutOnMainTrack));
    select(&mut fx.ses, &[x]);
    assert!(fx.ses.fast_cut_command_enabled(EditorCommand::PutOnMainTrack));
    assert!(fx.ses.fast_cut_command_enabled(EditorCommand::SetAttachPoint));
    assert!(!fx.ses.fast_cut_command_enabled(EditorCommand::PasteAttached)); // nothing copied
    let normal = fast_cut(TimelineEditMode::Normal);
    assert!(!normal.ses.fast_cut_command_enabled(EditorCommand::InsertSpacer));
    assert!(EditorSession::FAST_CUT_COMMANDS.contains(&EditorCommand::InsertSpacer));
}

// MARK: Speed points, presets, band

fn speed_session(beats: &[Time]) -> (EditorSession, Id) {
    let mut c = Clip::new(id(1), "v", id(2), TrackKind::Video, TimeRange::new(Time::ZERO, f(150)), Time::ZERO);
    c.media_duration = Some(f(4000));
    let mut tl = timeline(fd30(), vec![track(10, TrackKind::Video, vec![c])]);
    tl.replace_beat_markers(TimeRange::new(Time::ZERO, s(100)), beats, &mut HighIds(2_000_000));
    (session(tl), id(1))
}

fn keys_of(ses: &EditorSession, c: Id) -> Option<SpeedKeys> {
    find(ses, c).and_then(|c| c.speed_keys)
}

#[test]
fn adds_a_no_change_point_at_the_playhead_in_one_undo_step() {
    let (mut ses, c) = speed_session(&[]);
    assert!(!ses.can_add_speed_point()); // nothing selected
    select(&mut ses, &[c]);
    ses.playhead = f(60);
    assert!(ses.can_add_speed_point());
    let d = depth(&ses);
    assert!(ses.add_speed_point_at_playhead());
    assert_eq!(depth(&ses), d + 1);
    assert_eq!(keys_of(&ses, c).map(|k| k.boundaries()), Some(vec![Time::ZERO, f(60), f(150)]));
    assert_eq!(find(&ses, c).map(|c| c.duration()), Some(f(150)));
    assert!(!ses.can_add_speed_point() && !ses.add_speed_point_at_playhead());
    assert!(ses.undo());
    assert!(keys_of(&ses, c).is_none());
}

#[test]
fn no_point_at_the_clip_edge() {
    let (mut ses, c) = speed_session(&[]);
    select(&mut ses, &[c]);
    ses.playhead = Time::ZERO;
    assert!(!ses.can_add_speed_point() && !ses.add_speed_point_at_playhead());
}

#[test]
fn ease_on_a_point_opens_and_curves_a_transition() {
    let (mut ses, c) = speed_session(&[]);
    select(&mut ses, &[c]);
    ses.playhead = f(60);
    let both = sq_core_time::EasingCurve::ease_in_out();
    assert!(!ses.ease_speed_point_at_playhead(&both, sq_core_time::EaseSide::Both)); // a no-change point has nothing to ease
    assert!(ses.add_speed_point_at_playhead());
    assert!(!ses.ease_speed_point_at_playhead(&both, sq_core_time::EaseSide::Both));
    let k = keys_of(&ses, c).unwrap_or_else(|| panic!("keys"));
    let fast = k.retiming_key(1, Time::ZERO - f(30), fd30()).unwrap_or_else(|| panic!("retime"));
    assert_eq!(fast.segments[0].from.percent(), 200.0);
    ses.apply_speed_edit(&SpeedEdit::new(c, fast.clone(), SpeedEditPhase::Began, true));
    ses.apply_speed_edit(&SpeedEdit::new(c, fast, SpeedEditPhase::Changed, true));
    ses.playhead = f(30);
    let d = depth(&ses);
    assert!(ses.ease_speed_point_at_playhead(&both, sq_core_time::EaseSide::Both));
    assert_eq!(depth(&ses), d + 1);
    let e = keys_of(&ses, c).unwrap_or_else(|| panic!("keys"));
    assert!(e.segments.iter().any(|s| s.is_ramp() && s.ease().is_some()));
}

#[test]
fn esc_during_a_band_drag_restores_the_start_and_drops_the_step() {
    let (mut ses, c) = speed_session(&[]);
    let start = ses.active_timeline().cloned().unwrap_or_else(|| panic!("timeline"));
    let d = depth(&ses);
    let clip = find(&ses, c).unwrap_or_else(|| panic!("clip"));
    let k = SpeedKeys::of(&clip);
    let fast = k.adding_key(f(60), fd30()).map(|(k, _)| k).unwrap_or_else(|| panic!("key"));
    ses.apply_speed_edit(&SpeedEdit::new(c, k.clone(), SpeedEditPhase::Began, true));
    ses.apply_speed_edit(&SpeedEdit::new(c, fast, SpeedEditPhase::Changed, true));
    assert_eq!(depth(&ses), d + 1);
    ses.cancel_speed_edit(c, start.clone());
    assert_eq!(ses.active_timeline(), Some(&start));
    assert_eq!(depth(&ses), d);
    // a cancel before any change leaves nothing behind either
    ses.apply_speed_edit(&SpeedEdit::new(c, k, SpeedEditPhase::Began, true));
    ses.cancel_speed_edit(c, start);
    assert_eq!(depth(&ses), d);
}

#[test]
fn preset_is_one_undo_step_and_editable_afterwards() {
    let (mut ses, c) = speed_session(&[]);
    select(&mut ses, &[c]);
    let d = depth(&ses);
    assert_eq!(ses.apply_speed_preset(SpeedRampPreset::Punch, false), SpeedPresetOutcome::Applied { clips: 1 });
    assert_eq!(depth(&ses), d + 1);
    assert!(keys_of(&ses, c).is_some() && ses.can_remove_time_remapping());
    assert!(ses.undo());
    assert!(keys_of(&ses, c).is_none());
}

#[test]
fn hit_on_beat_needs_a_beat_inside_the_clip() {
    let (mut ses, c) = speed_session(&[s(30)]); // far outside the 5 s clip
    select(&mut ses, &[c]);
    assert_eq!(ses.apply_speed_preset(SpeedRampPreset::Pulse, true), SpeedPresetOutcome::NoBeat);
    assert!(keys_of(&ses, c).is_none());
}

#[test]
fn hit_on_beat_puts_the_peak_on_the_beat() {
    let (mut ses, c) = speed_session(&[s(2)]);
    select(&mut ses, &[c]);
    assert_eq!(ses.apply_speed_preset(SpeedRampPreset::Crest, true), SpeedPresetOutcome::Applied { clips: 1 });
    assert!(ses.has_beat_markers());
    assert!(keys_of(&ses, c).is_some());
}

#[test]
fn cut_and_snap_are_undoable() {
    let (mut ses, c) = speed_session(&[s(1), s(2), s(4)]);
    select(&mut ses, &[c]);
    assert_eq!(ses.cut_to_beats(), Some(3));
    assert_eq!(ses.active_timeline().map(|t| t.tracks[0].clips().len()), Some(4));
    assert!(ses.undo());
    assert_eq!(ses.active_timeline().map(|t| t.tracks[0].clips().len()), Some(1));
    assert_eq!(ses.snap_to_beats(), Some(1)); // the 5 s end moves to the 4 s beat
    assert_eq!(ses.active_timeline().map(|t| t.tracks[0].clips()[0].timeline().end()), Some(s(4)));
    assert!(ses.undo());
    assert_eq!(ses.active_timeline().map(|t| t.tracks[0].clips()[0].timeline().end()), Some(s(5)));
}

#[test]
fn remove_time_remapping_returns_to_normal_speed_in_one_step() {
    let (mut ses, c) = speed_session(&[]);
    select(&mut ses, &[c]);
    ses.apply_speed_preset(SpeedRampPreset::Punch, false);
    let d = depth(&ses);
    assert!(ses.remove_time_remapping());
    assert_eq!(depth(&ses), d + 1);
    assert!(keys_of(&ses, c).is_none() && !ses.can_remove_time_remapping());
    assert!(find(&ses, c).is_some_and(|c| c.speed.is_normal()));
    assert!(ses.can_toggle_time_remapping());
}

#[test]
fn speed_dialog_model_comes_from_the_retimable_selection() {
    let (mut ses, c) = speed_session(&[]);
    assert!(ses.speed_dialog_model().is_none());
    select(&mut ses, &[c]);
    let mut m = ses.speed_dialog_model().unwrap_or_else(|| panic!("model"));
    assert!(!m.has_changes());
    m.set_percent(200.0);
    assert_eq!(m.duration(), f(75));
    assert!(ses.apply_speed(m.change()));
    assert_eq!(find(&ses, c).map(|c| c.duration()), Some(f(75)));
    ses.begin_speed_gesture();
    assert!(ses.speed_gesture_key.is_some());
    ses.end_speed_gesture();
    assert!(ses.speed_gesture_key.is_none());
}

// MARK: Jump cut

fn jump_cut_session() -> EditorSession {
    let link = id(77);
    let src = TimeRange::new(s(5), s(10));
    let mut v = Clip::new(id(1), "take", id(2), TrackKind::Video, src, Time::ZERO);
    let mut a = Clip::new(id(3), "take", id(2), TrackKind::Audio, src, Time::ZERO);
    (v.link, a.link) = (Some(link), Some(link));
    (v.media_duration, a.media_duration) = (Some(s(60)), Some(s(60)));
    let (mut v1, mut a1) = (track(10, TrackKind::Video, vec![v]), track(12, TrackKind::Audio, vec![a]));
    (v1.is_targeted, a1.is_targeted) = (true, true);
    let mut tl =
        timeline(fd30(), vec![v1, track(11, TrackKind::Video, vec![]), a1, track(13, TrackKind::Audio, vec![])]);
    tl.format = SequenceFormat { width: 1080, height: 1920, ..tl.format };
    session(tl)
}

#[test]
fn jump_cut_is_one_undo_step_and_selects_the_moved_halves() {
    let mut ses = jump_cut_session();
    let settings = MemorySettings::default();
    let before = ses.active_timeline().cloned();
    ses.playhead = s(4);
    assert!(ses.jump_cut_enabled());
    // `select` is ES1's and pending: the moved halves are checked through the last undo step instead.
    let d = depth(&ses);
    let cut = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| ses.jump_cut_alternate(Some(9), &settings)));
    assert!(cut.is_err() || depth(&ses) == d + 1); // pending ES1 select panics after the step was committed
    assert_eq!(ses.undo_name(), Some("Jump Cut"));
    let t = ses.active_timeline().cloned().unwrap_or_else(|| panic!("timeline"));
    let v2 = &t.tracks.iter().filter(|x| x.kind == TrackKind::Video).nth(1).unwrap_or_else(|| panic!("V2"));
    assert_eq!(v2.clips().len(), 1);
    assert_eq!(v2.clips()[0].start, s(4) - f(9));
    assert!(ses.undo());
    assert_eq!(ses.active_timeline().cloned(), before);
}

#[test]
fn nothing_under_the_playhead_is_refused_and_the_default_overlap_is_point_three_seconds() {
    let mut ses = jump_cut_session();
    let settings = MemorySettings::default();
    assert_eq!(ses.jump_cut_overlap_frames(&settings), 9);
    ses.playhead = s(20);
    assert!(!ses.jump_cut_enabled());
    assert!(!ses.jump_cut_alternate(None, &settings));
    assert_eq!(ses.jump_cut_refusal().as_deref(), Some("No clip under the playhead to jump cut."));
    ses.playhead = s(4);
    assert_eq!(ses.jump_cut_refusal(), None);
    let mut custom = MemorySettings::default();
    sq_library::library_folder_store::SettingsStore::set_data(&mut custom, JUMP_CUT_OVERLAP_KEY, b"12".to_vec());
    assert_eq!(ses.jump_cut_overlap_frames(&custom), 12);
}

// MARK: Check Cuts

#[test]
fn check_cuts_marks_findings_as_one_undo_step() {
    let clip =
        |n, start| Clip::new(id(n), "a", id(n + 100), TrackKind::Video, TimeRange::new(Time::ZERO, s(2)), s(start));
    let tl = timeline(fd30(), vec![track(10, TrackKind::Video, vec![clip(1, 0), clip(2, 5)])]);
    let mut ses = session(tl);
    let d = depth(&ses);
    let report = ses.run_cut_check(CutCheckPlatform::Tiktok, None).unwrap_or_else(|| panic!("report"));
    assert_eq!(report.count(CutFindingKind::Gap), 1);
    assert_eq!(ses.active_timeline().map(|t| t.markers.len()), Some(1));
    assert_eq!(depth(&ses), d + 1);
    assert!(report.summary().contains("Gap: 1"));
    assert!(report.board_summary().ends_with("1 gap"));
    assert!(ses.undo());
    assert_eq!(ses.active_timeline().map(|t| t.markers.len()), Some(0));
}

#[test]
fn platform_picker_re_runs_into_the_same_undo_step() {
    let c = Clip::new(id(1), "a", id(2), TrackKind::Video, TimeRange::new(Time::ZERO, s(2)), Time::ZERO);
    let mut tl = timeline(fd30(), vec![track(10, TrackKind::Video, vec![c])]);
    tl.format = SequenceFormat { width: 1920, height: 1080, ..tl.format };
    let mut ses = session(tl);
    assert_eq!(ses.run_cut_check(CutCheckPlatform::Reels, None).map(|r| r.platform), Some(CutCheckPlatform::Reels));
    let d = depth(&ses);
    assert_eq!(ses.run_cut_check(CutCheckPlatform::Shorts, None).map(|r| r.platform), Some(CutCheckPlatform::Shorts));
    assert_eq!(depth(&ses), d);
}

// MARK: Punch in

#[test]
fn punch_in_cuts_is_one_undo_step() {
    let clips = (0..3)
        .map(|i| {
            Clip::new(id(1 + i), "c", id(100 + i), TrackKind::Video, TimeRange::new(Time::ZERO, s(2)), s(2 * i as i64))
        })
        .collect();
    let mut ses = session(timeline(fd30(), vec![track(10, TrackKind::Video, clips)]));
    assert!(ses.punch_in_cuts_enabled());
    let d = depth(&ses);
    assert!(ses.punch_in_cuts(&PunchInCutsOptions::new(vec![115.0])));
    assert_eq!(depth(&ses), d + 1);
    let punched =
        |ses: &EditorSession| ses.active_timeline().map(|t| t.is_punched_in(&t.tracks[0].clips()[1])).unwrap_or(false);
    assert!(punched(&ses));
    assert!(ses.undo());
    assert!(!punched(&ses));
}

#[test]
fn toggle_punch_in_is_one_undo_step_each_way() {
    let c = Clip::new(id(1), "m", id(2), TrackKind::Video, TimeRange::new(Time::ZERO, s(5)), Time::ZERO);
    let mut v = track(10, TrackKind::Video, vec![c]);
    v.is_targeted = true;
    let mut ses = session(timeline(fd30(), vec![v]));
    select(&mut ses, &[id(1)]);
    assert!(ses.punch_in_enabled());
    assert!(ses.toggle_punch_in());
    assert_eq!(ses.undo_name(), Some("Punch In"));
    assert!(ses.toggle_punch_in());
    assert_eq!(ses.undo_name(), Some("Punch Out"));
    assert!(find(&ses, id(1)).is_some_and(|c| c.effects.is_empty()));
    assert!(ses.undo());
    assert!(ses.active_timeline().is_some_and(find_punched));
}

fn find_punched(t: &Timeline) -> bool {
    t.tracks[0].clips().iter().all(|c| t.is_punched_in(c))
}

// MARK: Fit music, beats

fn music_session(in_out: Option<TimeRange>, blocker: bool) -> (EditorSession, Id) {
    let mut m = Clip::new(id(1), "m", id(2), TrackKind::Audio, TimeRange::new(Time::ZERO, s(20)), Time::ZERO);
    m.audio_tag = Some(AudioTag::Music);
    m.media_duration = Some(s(20));
    let mut clips = vec![m];
    if blocker {
        let mut o = Clip::new(id(3), "o", id(4), TrackKind::Audio, TimeRange::new(Time::ZERO, s(5)), s(22));
        o.media_duration = Some(s(5));
        clips.push(o);
    }
    let mut tl = timeline(fd30(), vec![track(10, TrackKind::Audio, clips)]);
    tl.in_out = in_out;
    let mut ses = session(tl);
    select(&mut ses, &[id(1)]);
    (ses, id(1))
}

fn bar_grid() -> BeatGrid {
    BeatGrid {
        beats: (0..20).map(s).collect(),
        downbeat_beat_indices: vec![0, 4, 8, 12, 16],
        beats_per_bar: 4,
        bpm: 60.0,
    }
}

#[test]
fn versions_fit_the_marked_range_and_the_row_title_names_the_fit() {
    let (ses, _) = music_session(Some(TimeRange::new(Time::ZERO, s(12))), false);
    let v = ses.music_fit_versions(&bar_grid(), None);
    assert!(!v.is_empty() && v.len() <= 3);
    assert!(v[0].length == s(12) && v[0].length_error == Time::ZERO);
    let title = EditorSession::music_fit_row_title(&v[0], 0);
    assert!(title.starts_with("Version 1: 12.0 s, exact, "));
    assert!(title.ends_with("bars") || title.ends_with("bar"));
}

#[test]
fn apply_music_fit_is_one_undo_step_with_crossfades() {
    let (mut ses, m) = music_session(Some(TimeRange::new(Time::ZERO, s(12))), false);
    let v = ses.music_fit_versions(&bar_grid(), None).remove(0);
    let d = depth(&ses);
    assert!(ses.apply_music_fit(&v, Some(m)));
    assert_eq!(depth(&ses), d + 1);
    let n = v.segments.iter().filter(|s| s.source.duration > Time::ZERO).count();
    let tr = &ses.active_timeline().unwrap_or_else(|| panic!("timeline")).tracks[0];
    assert_eq!(tr.clips().len(), n);
    assert!(tr.clips()[0].id == m && tr.end() == s(12));
    assert_eq!(tr.transitions.len(), n - 1);
    assert!(ses.undo());
    let tr = &ses.active_timeline().unwrap_or_else(|| panic!("timeline")).tracks[0];
    assert!(tr.clips().len() == 1 && tr.end() == s(20));
}

#[test]
fn longer_version_is_refused_when_it_hits_the_next_clip() {
    let (mut ses, m) = music_session(Some(TimeRange::new(Time::ZERO, s(26))), true);
    let vs = ses.music_fit_versions(&bar_grid(), None);
    assert!(!vs.is_empty());
    let d = depth(&ses);
    assert!(!ses.apply_music_fit(&vs[0], Some(m)) && depth(&ses) == d);
}

#[test]
fn no_clip_no_versions() {
    let (mut ses, _) = music_session(Some(TimeRange::new(Time::ZERO, s(12))), false);
    select(&mut ses, &[]);
    assert!(!ses.can_fit_music() && ses.music_fit_versions(&bar_grid(), None).is_empty());
}

fn beat_clip(speed: ClipSpeed, source_start: i64) -> (EditorSession, Clip) {
    let mut m = Clip::new(id(1), "m", id(2), TrackKind::Audio, TimeRange::new(s(source_start), s(10)), s(2));
    m.audio_tag = Some(AudioTag::Music);
    m.speed = speed;
    let ses = session(timeline(fd30(), vec![track(10, TrackKind::Audio, vec![m.clone()])]));
    (ses, m)
}

#[test]
fn beats_land_on_the_timeline_through_the_source_offset() {
    let (_, m) = beat_clip(ClipSpeed::NORMAL, 3); // plays source 3..<13 at timeline 2..<12
    let t = beat_times_of(&m, &bar_grid(), false);
    assert!(t.first() == Some(&s(2)) && t.last() == Some(&s(11)) && t.len() == 10);
}

#[test]
fn downbeats_only_and_double_speed() {
    let (_, m) = beat_clip(ClipSpeed::new(2, 1), 0);
    // source 0..<10 at 2x plays in 5 s; downbeats at 0, 4, 8 -> 0, 2, 4 s after the start
    assert_eq!(beat_times_of(&m, &bar_grid(), true), vec![s(2), s(4), s(6)]);
}

#[test]
fn markers_on_beat_is_one_undo_step_and_a_rerun_replaces() {
    let (mut ses, m) = beat_clip(ClipSpeed::NORMAL, 0);
    let grids = std::iter::once((m.id, bar_grid())).collect();
    let d = depth(&ses);
    assert_eq!(ses.add_markers_on_beat(&grids, false), 10);
    assert_eq!(depth(&ses), d + 1);
    assert!(
        ses.active_timeline().is_some_and(|t| t.markers.iter().all(|m| m.name == "Beat")) && ses.has_beat_markers()
    );
    assert_eq!(ses.add_markers_on_beat(&grids, true), 3);
    assert_eq!(ses.active_timeline().map(|t| t.markers.len()), Some(3));
    assert!(ses.undo() && ses.undo());
    assert_eq!(ses.active_timeline().map(|t| t.markers.len()), Some(0));
}

#[test]
fn no_grid_means_no_undo_step() {
    let (mut ses, _) = beat_clip(ClipSpeed::NORMAL, 0);
    let d = depth(&ses);
    assert!(ses.add_markers_on_beat(&Default::default(), false) == 0 && depth(&ses) == d);
}

#[test]
fn fast_cut_maps_edits_only_in_a_fast_cut_sequence() {
    for (mode, mapped) in [(TimelineEditMode::Normal, false), (TimelineEditMode::Magnetic, true)] {
        let fx = fast_cut(mode);
        let Some(t) = fx.ses.active_timeline() else { panic!("no sequence") };
        let out = TimelineEdit::fast_cut(&[TimelineEdit::Lift(vec![fx.b])], t, true, false);
        let want = if mapped {
            TimelineEdit::FastCut(FastCutEdit::Delete { ids: vec![fx.b], keep_attached: true })
        } else {
            TimelineEdit::Lift(vec![fx.b])
        };
        assert_eq!(out, vec![want]);
    }
}

#[test]
fn delete_selection_only_deletes_with_its_own_undo_name() {
    let mut fx = fast_cut(TimelineEditMode::Magnetic);
    assert_eq!(fx.ses.delete_selection_only(), "Select clips first.");
    select(&mut fx.ses, &[fx.b]);
    assert_eq!(fx.ses.delete_selection_only(), "Deleted, attached clips kept.");
    assert!(find(&fx.ses, fx.b).is_none());
    assert_eq!(fx.ses.undo_name(), Some("Delete Selection Only"));
    assert!(!fx.ses.keep_attached_held());
}
