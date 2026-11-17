//! Translation of `EdgeCaseTests`: every session mutation is one undo step and redo restores the project exactly; the
//! playhead never goes negative and stays on the frame grid; empty timelines and stale selections are safe.

use std::collections::BTreeSet;

use sq_core_edit::timeline_edits::TimelineEditsExt as _;
use sq_core_model::{Clip, Project, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource as _, SequentialIds, Time, TimeRange};

use crate::{EditorSession, SessionDeps};

fn sec(n: i64) -> Time {
    Time::new(n, 1)
}

fn id(n: u128) -> Id {
    Id::from_u128(n)
}

fn clip(n: u128, start: Time, dur: Time, kind: TrackKind) -> Clip {
    Clip::new(id(n), "c", id(900 + n), kind, TimeRange::new(Time::ZERO, dur), start)
}

fn session_of(tracks: Vec<Track>) -> EditorSession {
    let t = Timeline::new(id(500), "M", SequenceFormat::new(Time::new(1, 30)), tracks);
    let project = Project::new(id(600), "P", Vec::new(), vec![t]);
    let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-es01-edge-tests"));
    deps.ids = Box::new(SequentialIds::default());
    let mut s = EditorSession::new(project, deps);
    s.ids = Box::new(SequentialIds::default());
    for _ in 0..1000 {
        s.ids.next_id();
    }
    s
}

fn track(n: u128, kind: TrackKind, clips: Vec<Clip>) -> Track {
    let mut t = Track::new(id(n), kind);
    t.set_clips(clips);
    t
}

/// V1: A [0,2) B [2,4); A1: C [0,4). In/out untouched.
fn rig() -> EditorSession {
    session_of(vec![
        track(
            1,
            TrackKind::Video,
            vec![clip(10, Time::ZERO, sec(2), TrackKind::Video), clip(11, sec(2), sec(2), TrackKind::Video)],
        ),
        track(2, TrackKind::Audio, vec![clip(12, Time::ZERO, sec(4), TrackKind::Audio)]),
    ])
}

fn pick(s: &mut EditorSession, ids: &[u128]) {
    s.select(ids.iter().map(|n| id(*n)).collect(), BTreeSet::new());
}

fn run(s: &mut EditorSession, name: &str) {
    match name {
        "delete" => {
            pick(s, &[10]);
            s.delete_selection(false, None);
        }
        "ripple delete" => {
            pick(s, &[10]);
            s.delete_selection(true, None);
        }
        "ripple delete two tracks" => {
            pick(s, &[10, 12]);
            s.delete_selection(true, None);
        }
        "add edit" => {
            s.seek(sec(1));
            s.add_edit_at_playhead(false);
        }
        "add edit all tracks" => {
            s.seek(sec(1));
            s.add_edit_at_playhead(true);
        }
        "mark in" => {
            s.seek(sec(1));
            s.mark_in();
        }
        "mark out" => {
            s.seek(sec(3));
            s.mark_out();
        }
        "mark clip" => {
            s.seek(sec(1));
            s.mark_clip();
        }
        "marker" => {
            s.seek(sec(1));
            s.add_marker_at_playhead();
        }
        "ripple trim head" => {
            s.seek(sec(1));
            s.ripple_trim_to_playhead(sq_core_model::ClipEdge::Head);
        }
        "ripple trim tail" => {
            s.seek(Time::new(3, 2));
            s.ripple_trim_to_playhead(sq_core_model::ClipEdge::Tail);
        }
        "lift range" | "extract range" => {
            s.seek(sec(1));
            s.mark_in();
            s.seek(Time::new(5, 2));
            s.mark_out();
            if name == "lift range" {
                s.lift_range();
            } else {
                s.extract_range();
            }
        }
        "new sequence" => {
            s.add_sequence(None, None, None);
        }
        "nest" => {
            pick(s, &[10, 11]);
            s.nest_selection("Nested");
        }
        "replace clip" => {
            let mut x = clip(10, Time::ZERO, sec(2), TrackKind::Video);
            x.name = "Renamed".into();
            s.replace_clip(&x, "Rename", false);
        }
        other => panic!("unknown action {other}"),
    }
}

/// The undoable part of the state is the project value; selection and playhead are UI state.
#[test]
fn every_action_is_one_undo_step_and_redo_restores_exactly() {
    let names = [
        "delete",
        "ripple delete",
        "ripple delete two tracks",
        "add edit",
        "add edit all tracks",
        "mark in",
        "mark out",
        "mark clip",
        "marker",
        "ripple trim head",
        "ripple trim tail",
        "lift range",
        "extract range",
        "new sequence",
        "nest",
        "replace clip",
    ];
    for name in names {
        let mut s = rig();
        let start = s.project().clone();
        run(&mut s, name);
        let after = s.project().clone();
        let mut steps = 0;
        while s.can_undo() {
            assert!(s.undo());
            steps += 1;
        }
        assert!(*s.project() == start, "{name}: undo restores the original project");
        // Setup steps (marks) are separate user actions; the action under test is always the last step.
        let max = if name == "lift range" || name == "extract range" { 3 } else { 1 };
        assert!((1..=max).contains(&steps), "{name}: {steps} undo steps");
        for _ in 0..steps {
            assert!(s.redo());
        }
        assert!(*s.project() == after, "{name}: redo restores exactly");
        assert!(!s.can_redo());
    }
}

#[test]
fn undone_actions_do_not_leave_a_stale_selection() {
    let mut s = rig();
    pick(&mut s, &[10]);
    s.delete_selection(true, None);
    assert!(s.selection().is_empty());
    s.undo();
    let ids = |s: &EditorSession| -> Vec<Id> {
        s.active_timeline().map(|t| t.tracks[0].clips().iter().map(|c| c.id).collect()).unwrap_or_default()
    };
    assert_eq!(ids(&s), vec![id(10), id(11)]);
    s.add_edit_at_playhead(false);
    s.seek(sec(1));
    s.add_edit_at_playhead(false);
    let right = s.active_timeline().map(|t| t.tracks[0].clips()[1].id).unwrap_or(id(0));
    s.select(BTreeSet::from([right]), BTreeSet::new());
    s.undo();
    assert!(!s.selection().contains(&right));
    s.redo();
    assert_eq!(s.active_timeline().map(|t| t.tracks[0].clips().len()), Some(3));
}

#[test]
fn playhead_never_goes_negative_and_stays_on_the_frame_grid() {
    let mut s = rig();
    let fd = Time::new(1, 30);
    s.seek(Time::new(-5, 1));
    assert_eq!(s.playhead(), Time::ZERO);
    s.step_frames(-100);
    assert_eq!(s.playhead(), Time::ZERO);
    s.scrub(Time::new(-1, 100));
    assert_eq!(s.playhead(), Time::ZERO);
    s.seek(Time::new(1001, 1000));
    assert_eq!(s.playhead().snapped(fd), s.playhead());
    s.step_frames(3);
    assert_eq!(s.playhead(), Time::new(1001, 1000).snapped(fd) + fd * 3);
}

#[test]
fn an_empty_sequence_never_enters_playing() {
    use sq_core_edit::playback::{PlaybackRate, ShuttleAction};
    let mut s = session_of(vec![Track::new(id(1), TrackKind::Video), Track::new(id(2), TrackKind::Audio)]);
    s.play_pause();
    assert!(!s.is_playing() && s.engine().rate().is_paused(), "Space on an empty sequence changes nothing");
    s.apply_shuttle(ShuttleAction::SetRate(PlaybackRate::FORWARD));
    s.apply_shuttle(ShuttleAction::SetRate(PlaybackRate::REVERSE));
    assert!(!s.is_playing() && s.engine().rate().is_paused(), "L and J do not start it either");
    assert_eq!(s.playhead(), Time::ZERO);
}

#[test]
fn an_empty_timeline_is_safe() {
    let mut s = session_of(vec![Track::new(id(1), TrackKind::Video), Track::new(id(2), TrackKind::Audio)]);
    s.go_to_end();
    assert_eq!(s.playhead(), Time::ZERO);
    s.go_to_start();
    s.go_to_next_edit_point();
    s.go_to_previous_edit_point();
    s.go_to_in();
    s.go_to_out();
    s.delete_selection(true, None);
    s.delete_selection(false, None);
    s.add_edit_at_playhead(false);
    s.add_edit_at_playhead(true);
    s.lift_range();
    s.extract_range();
    s.mark_clip();
    s.clear_in_out();
    s.ripple_trim_to_playhead(sq_core_model::ClipEdge::Head);
    s.ripple_trim_to_playhead(sq_core_model::ClipEdge::Tail);
    assert!(!s.can_undo(), "nothing happened, so nothing to undo: {:?}", s.undo_name());
    s.play_pause();
    s.play_pause();
    assert!(!s.is_playing());
    assert!(!s.undo() && !s.redo());
    s.mark_in();
    s.mark_out();
    if let Some(io) = s.active_timeline().and_then(|t| t.in_out) {
        assert!(io.end() >= io.start);
    }
}

/// Every `perform` runs the post-edit steps of Swift's `performSteps`: a flagged Adjustment Layer follows the cut inside the
/// same undo step.
#[test]
fn a_flagged_adjustment_layer_follows_the_cut_in_the_same_undo_step() {
    use sq_core_effects::adjustment_clip::ProjectAdjustmentExt as _;
    use sq_core_effects::adjustment_extend::ProjectAdjustmentExtendExt as _;
    let mut s = session_of(vec![
        track(1, TrackKind::Video, vec![clip(10, Time::ZERO, sec(10), TrackKind::Video)]),
        track(2, TrackKind::Video, vec![]),
    ]);
    let tl = s.active_timeline().map(|t| t.id).unwrap_or(id(0));
    let mut layer = None;
    s.perform("Adjustment", None, |p| {
        let mut ids = SequentialIds::default();
        for _ in 0..2000 {
            ids.next_id();
        }
        layer = p.add_adjustment_clip(tl, Time::ZERO, id(2), sec(4), &mut ids).ok();
        if let Some(l) = layer {
            p.set_extend_to_sequence_end(true, l, &mut |t, i, by| {
                let _ = t.trim(i, sq_core_model::ClipEdge::Tail, by);
            });
        }
    });
    let layer = layer.unwrap_or(id(0));
    let end = |s: &EditorSession| s.active_timeline().and_then(|t| t.find(layer)).map(|m| m.clip.timeline().end());
    assert_eq!(end(&s), Some(sec(10)));
    // Shorten the base clip: the layer follows without a step of its own.
    s.seek(sec(6));
    pick(&mut s, &[10]);
    s.ripple_trim_to_playhead(sq_core_model::ClipEdge::Tail);
    assert_eq!(end(&s), Some(sec(6)));
    s.undo();
    assert_eq!(end(&s), Some(sec(10)));
    let base_end = s.active_timeline().and_then(|t| t.find(id(10))).map(|m| m.clip.timeline().end());
    assert_eq!(base_end, Some(sec(10)));
}

/// Mark Clip (X) follows the edit-target rule for the selection, like Swift's `markClipRange(at:selection:)`.
#[test]
fn mark_clip_marks_the_selected_clip_else_the_union_under_the_playhead() {
    let mut s = rig();
    s.seek(sec(1));
    s.mark_clip();
    assert_eq!(s.active_timeline().and_then(|t| t.in_out), Some(TimeRange::new(Time::ZERO, sec(4))));
    s.clear_in_out();
    pick(&mut s, &[10]);
    s.mark_clip();
    assert_eq!(s.active_timeline().and_then(|t| t.in_out), Some(TimeRange::new(Time::ZERO, sec(2))));
}

/// `--select`, an accessibility click: selecting by hand takes the linked partners along like a click, unless linked
/// selection is off. (Before, Shift+Delete removed only the video and left a gap and the audio.)
#[test]
fn selecting_without_a_pointer_takes_the_linked_partners() {
    let mut v = clip(1, Time::ZERO, sec(3), TrackKind::Video);
    let mut a = clip(2, Time::ZERO, sec(3), TrackKind::Audio);
    let other = clip(3, sec(3), sec(3), TrackKind::Video);
    v.link = Some(id(77));
    a.link = Some(id(77));
    let mut s = session_of(vec![track(10, TrackKind::Video, vec![v, other]), track(11, TrackKind::Audio, vec![a])]);
    s.select_with_partners(BTreeSet::from([id(1)]));
    assert_eq!(s.selection(), &BTreeSet::from([id(1), id(2)]));
    s.select_with_partners(BTreeSet::from([id(3)]));
    assert_eq!(s.selection(), &BTreeSet::from([id(3)]), "an unlinked clip stays alone");
    s.set_linked_selection_mirror(false);
    s.select_with_partners(BTreeSet::from([id(1)]));
    assert_eq!(s.selection(), &BTreeSet::from([id(1)]), "linked selection off: just the clip");
    s.set_linked_selection_mirror(true);
    s.select_with_partners(BTreeSet::from([id(1)]));
    s.delete_selection(true, None);
    let left: Vec<u128> = s
        .active_timeline()
        .map(|t| t.tracks.iter().flat_map(|tr| tr.clips()).map(|c| c.id.as_u128()).collect())
        .unwrap_or_default();
    assert_eq!(left, [3], "video and its audio are both gone");
}

/// V1: A [0,4); A1: its sound [0,4), both linked; random ids like the app.
fn linked_random_rig() -> EditorSession {
    let mut v = clip(10, Time::ZERO, sec(4), TrackKind::Video);
    let mut a = clip(12, Time::ZERO, sec(4), TrackKind::Audio);
    (v.link, a.link) = (Some(id(77)), Some(id(77)));
    let mut s = session_of(vec![track(1, TrackKind::Video, vec![v]), track(2, TrackKind::Audio, vec![a])]);
    s.ids = Box::new(sq_core_time::RandomIds);
    s
}

#[test]
fn redo_of_a_blade_gives_back_the_same_ids_and_links() {
    let mut s = linked_random_rig();
    pick(&mut s, &[10]);
    s.seek(sec(1));
    s.add_edit_at_playhead(false);
    let after = s.project().clone();
    assert!(s.undo());
    assert!(s.redo());
    assert_eq!(*s.project(), after, "redo restores the post-state, ids and links included");
    let live: BTreeSet<Id> =
        s.project().timelines[0].tracks.iter().flat_map(|t| t.clips().iter().map(|c| c.id)).collect();
    assert!(s.selection().is_subset(&live), "the selection names clips that exist");
}

#[test]
fn blade_move_undo_twice_redo_twice_finds_the_clip_again() {
    let mut s = linked_random_rig();
    pick(&mut s, &[10]);
    s.seek(sec(1));
    s.add_edit_at_playhead(false);
    let right = s.active_timeline().map(|t| t.tracks[0].clips()[1].id).unwrap_or(id(0));
    pick_ids(&mut s, right);
    s.nudge_selection(5);
    let moved = s.project().clone();
    assert!(s.undo() && s.undo());
    assert!(s.redo() && s.redo());
    assert_eq!(*s.project(), moved);
}

fn pick_ids(s: &mut EditorSession, clip: Id) {
    s.select(BTreeSet::from([clip]), BTreeSet::new());
}

/// A panel's whole-clip write made from `base`: the opacity changes, everything else stays as the panel saw it.
fn with_opacity(base: &Clip, value: f64) -> Clip {
    let mut c = base.clone();
    c.animation.opacity.value = value;
    c
}

fn live_clip(s: &EditorSession, n: u128) -> Clip {
    s.clip_in_active(id(n)).unwrap_or_else(|| clip(n, Time::ZERO, sec(1), TrackKind::Video))
}

/// Another panel renames clip 10 in the same event; the panel then writes opacity from its pre-rename copy.
fn renamed_behind_the_panels_back(s: &mut EditorSession) -> Clip {
    let stale = live_clip(s, 10);
    let mut renamed = stale.clone();
    renamed.name = "Renamed".into();
    s.replace_clip(&renamed, "Rename", false);
    stale
}

#[test]
fn a_rebased_write_keeps_a_rename_made_after_the_panels_copy() {
    let mut s = rig();
    let stale = renamed_behind_the_panels_back(&mut s);
    s.replace_clip_rebased(&stale, &with_opacity(&stale, 0.25), "Opacity", false);
    let live = live_clip(&s, 10);
    assert_eq!((live.name.as_str(), live.animation.opacity.value), ("Renamed", 0.25));
    // One Undo reverts only the opacity, a second the name.
    assert!(s.undo());
    let live = live_clip(&s, 10);
    assert_eq!((live.name.as_str(), live.animation.opacity.value), ("Renamed", stale.animation.opacity.value));
    assert!(s.undo());
    assert_eq!(live_clip(&s, 10).name, "c");
}

#[test]
fn a_continuing_rebased_write_stays_one_undo_step() {
    let mut s = rig();
    let stale = renamed_behind_the_panels_back(&mut s);
    s.replace_clip_rebased(&stale, &with_opacity(&stale, 0.25), "Opacity", false);
    // The next drag step starts from the clip the panel just wrote.
    let shown = with_opacity(&stale, 0.25);
    s.replace_clip_rebased(&shown, &with_opacity(&shown, 0.5), "Opacity", true);
    let live = live_clip(&s, 10);
    assert_eq!((live.name.as_str(), live.animation.opacity.value), ("Renamed", 0.5));
    assert!(s.undo());
    let live = live_clip(&s, 10);
    assert_eq!((live.name.as_str(), live.animation.opacity.value), ("Renamed", stale.animation.opacity.value));
}

#[test]
fn a_rebased_write_of_the_live_clip_equals_the_plain_write() {
    let (mut plain, mut rebased) = (rig(), rig());
    let base = live_clip(&plain, 10);
    plain.replace_clip(&with_opacity(&base, 0.5), "Opacity", false);
    rebased.replace_clip_rebased(&base, &with_opacity(&base, 0.5), "Opacity", false);
    assert_eq!(plain.project(), rebased.project());
}

#[test]
fn a_rebased_displayed_clip_write_keeps_a_rename() {
    let mut s = rig();
    let stale = renamed_behind_the_panels_back(&mut s);
    s.replace_displayed_clip_rebased(&stale, with_opacity(&stale, 0.25), "Opacity", false);
    let live = live_clip(&s, 10);
    assert_eq!((live.name.as_str(), live.animation.opacity.value), ("Renamed", 0.25));
}

#[test]
fn rebased_displayed_clips_match_their_base_by_id_and_make_one_undo_step() {
    let mut s = rig();
    let (stale10, stale11) = (live_clip(&s, 10), live_clip(&s, 11));
    let mut renamed = stale10.clone();
    renamed.name = "Renamed".into();
    s.replace_clip(&renamed, "Rename", false);
    // The bases come in another order than the clips; an edit without a base is written as it is.
    let bases = [stale11.clone(), stale10.clone()];
    let clips = vec![with_opacity(&stale10, 0.25), with_opacity(&stale11, 0.75)];
    s.replace_displayed_clips_rebased(&bases, clips, "Opacity", false);
    let (a, b) = (live_clip(&s, 10), live_clip(&s, 11));
    assert_eq!((a.name.as_str(), a.animation.opacity.value, b.animation.opacity.value), ("Renamed", 0.25, 0.75));
    assert!(s.undo());
    let (a, b) = (live_clip(&s, 10), live_clip(&s, 11));
    assert_eq!(a.name, "Renamed");
    assert_eq!(a.animation.opacity.value, stale10.animation.opacity.value);
    assert_eq!(b.animation.opacity.value, stale11.animation.opacity.value);
}
