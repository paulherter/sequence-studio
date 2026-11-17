//! Session tests of the timeline verbs (translations of `TimelineOpsSessionTests`, `TrackToggleSessionTests`,
//! `SourcePatchSessionTests`). Selection is set directly and the playhead through its field: `select` / `seek` belong to
//! ES1 and are still `pending!` on this branch.

use std::collections::BTreeSet;

use sq_core_model::{Clip, ClipEdge, MarkerColor, Project, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};

use super::*;
use crate::{EditorSession, SessionDeps};

fn s(n: i64) -> Time {
    Time::new(n, 1)
}

fn clip(n: u128, start: i64, dur: i64, kind: TrackKind) -> Clip {
    Clip::new(
        Id::from_u128(n),
        &format!("c{n}"),
        Id::from_u128(900 + n),
        kind,
        TimeRange::new(Time::ZERO, s(dur)),
        s(start),
    )
}

fn track(n: u128, kind: TrackKind, clips: Vec<Clip>) -> Track {
    let mut t = Track::new(Id::from_u128(n), kind);
    t.set_clips(clips);
    t
}

fn session(tracks: Vec<Track>) -> EditorSession {
    let t = Timeline::new(Id::from_u128(500), "Main", SequenceFormat::new(Time::new(1, 30)), tracks);
    let project = Project::new(Id::from_u128(600), "P", Vec::new(), vec![t]);
    let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-es02-tests"));
    deps.ids = Box::new(sq_core_time::SequentialIds::default());
    EditorSession::new(project, deps)
}

fn pick(ses: &mut EditorSession, ids: &[u128]) {
    ses.set_selection_raw(ids.iter().map(|n| Id::from_u128(*n)).collect::<BTreeSet<_>>());
}

fn starts(ses: &EditorSession, track: usize) -> Vec<Time> {
    let Some(t) = ses.active_timeline() else { return Vec::new() };
    t.tracks[track].clips().iter().map(|c| c.start).collect()
}

#[test]
fn link_menu_state_follows_the_selection() {
    let mut ses = session(vec![
        track(1, TrackKind::Video, vec![clip(10, 1, 2, TrackKind::Video)]),
        track(2, TrackKind::Audio, vec![clip(11, 1, 2, TrackKind::Audio)]),
    ]);
    assert!(!ses.link_menu_state().enabled);
    pick(&mut ses, &[10]);
    assert!(!ses.link_menu_state().enabled);
    pick(&mut ses, &[10, 11]);
    assert!(ses.link_menu_state().enabled && !ses.link_menu_state().unlink);
    ses.toggle_link_selection();
    assert!(ses.link_menu_state().enabled && ses.link_menu_state().unlink);
    assert_eq!(ses.undo_name(), Some("Link"));
    pick(&mut ses, &[10]);
    assert!(ses.link_menu_state().enabled && ses.link_menu_state().unlink);
    assert!(ses.unlink_selection());
    assert!(!ses.unlink_selection());
}

#[test]
fn nudge_moves_the_selected_clip_by_whole_frames() {
    let mut ses = session(vec![track(1, TrackKind::Video, vec![clip(10, 1, 2, TrackKind::Video)])]);
    pick(&mut ses, &[10]);
    ses.nudge_selection(3);
    assert_eq!(starts(&ses, 0), vec![s(1) + Time::new(3, 30)]);
    ses.nudge_selection(-3);
    assert_eq!(starts(&ses, 0), vec![s(1)]);
    assert_eq!(ses.undo_name(), Some("Nudge Clips"));
}

#[test]
fn copy_selection_needs_a_selection() {
    let mut ses = session(vec![track(1, TrackKind::Video, vec![clip(10, 0, 2, TrackKind::Video)])]);
    assert!(!ses.copy_selection());
    pick(&mut ses, &[10]);
    assert!(ses.copy_selection());
}

#[test]
fn markers_add_edit_delete_and_clear() {
    let mut ses = session(vec![track(1, TrackKind::Video, vec![clip(10, 0, 4, TrackKind::Video)])]);
    ses.playhead = s(1);
    let first = ses.mark_at_playhead().expect("marker");
    assert!(!first.open_edit);
    assert_eq!(ses.active_timeline().map(|t| t.markers.len()), Some(1));
    let again = ses.mark_at_playhead().expect("existing marker");
    assert!(again.open_edit && again.id == first.id);
    assert_eq!(ses.active_timeline().map(|t| t.markers.len()), Some(1));
    ses.edit_marker(first.id, "Cue", MarkerColor::Red, "note");
    let m = ses.active_timeline().map(|t| t.markers[0].clone()).expect("marker");
    assert_eq!((m.name.as_str(), m.color, m.comment.as_str()), ("Cue", MarkerColor::Red, "note"));
    ses.move_marker(first.id, s(2));
    assert_eq!(ses.active_timeline().map(|t| t.markers[0].time), Some(s(2)));
    assert!(!ses.clear_marker_at_playhead());
    ses.delete_marker(first.id);
    assert_eq!(ses.clear_all_markers(), 0);
}

#[test]
fn clip_markers_follow_the_clip() {
    let mut ses = session(vec![track(1, TrackKind::Video, vec![clip(10, 2, 4, TrackKind::Video)])]);
    let id = ses.add_clip_marker(Id::from_u128(10), s(3)).expect("clip marker");
    ses.delete_clip_marker(id, Id::from_u128(10));
    assert_eq!(ses.undo_name(), Some("Delete Clip Marker"));
    assert!(ses.add_clip_marker(Id::from_u128(77), s(3)).is_none());
    assert!(ses.last_error().is_some());
}

#[test]
fn add_track_goes_after_the_last_of_its_kind() {
    let mut ses = session(vec![
        track(1, TrackKind::Video, vec![]),
        track(2, TrackKind::Video, vec![]),
        track(3, TrackKind::Audio, vec![]),
    ]);
    ses.add_track(TrackKind::Video);
    ses.add_track(TrackKind::Audio);
    let kinds: Vec<TrackKind> =
        ses.active_timeline().map(|t| t.tracks.iter().map(|x| x.kind).collect()).unwrap_or_default();
    use TrackKind::{Audio, Video};
    assert_eq!(kinds, vec![Video, Video, Video, Audio, Audio]);
    assert_eq!(ses.undo_name(), Some("Add Audio Track"));
}

#[test]
fn snapping_and_linked_selection_are_undoable_sequence_settings() {
    let mut ses = session(vec![track(1, TrackKind::Video, vec![])]);
    assert!(!ses.set_snapping(true));
    assert!(ses.set_snapping(false));
    assert_eq!(ses.undo_name(), Some("Snapping Off"));
    assert!(ses.undo());
    assert!(!ses.set_snapping(true));
    assert!(ses.set_linked_selection(false));
    assert!(!ses.linked_selection);
    assert!(!ses.set_linked_selection(false));
}

#[test]
fn rename_and_label_apply_to_the_selection() {
    let mut ses = session(vec![track(1, TrackKind::Video, vec![clip(10, 0, 2, TrackKind::Video)])]);
    ses.rename_track(Id::from_u128(1), "  Picture ");
    assert_eq!(ses.active_timeline().map(|t| t.tracks[0].name.clone()), Some("Picture".into()));
    pick(&mut ses, &[10]);
    ses.rename_selected_clip("  ");
    assert_eq!(ses.undo_name(), Some("Rename Track"));
    ses.rename_selected_clip(" Hero ");
    assert_eq!(ses.active_timeline().map(|t| t.tracks[0].clips()[0].name.clone()), Some("Hero".into()));
    ses.set_label(Some(sq_core_model::LabelColor::Purple));
    assert_eq!(
        ses.active_timeline().map(|t| t.tracks[0].clips()[0].label),
        Some(Some(sq_core_model::LabelColor::Purple))
    );
}

#[test]
fn track_toggle_applies_to_all_tracks_of_a_kind() {
    let mut ses = session(vec![
        track(1, TrackKind::Audio, vec![]),
        track(2, TrackKind::Audio, vec![]),
        track(3, TrackKind::Video, vec![]),
    ]);
    ses.toggle_tracks(Id::from_u128(1), TrackToggle::Mute, true);
    let muted: Vec<bool> =
        ses.active_timeline().map(|t| t.tracks.iter().map(|x| x.is_muted).collect()).unwrap_or_default();
    assert_eq!(muted, vec![true, true, false]);
    assert_eq!(ses.undo_name(), Some("Mute Tracks"));
    ses.toggle_tracks(Id::from_u128(1), TrackToggle::Lock, false);
    assert_eq!(ses.undo_name(), Some("Lock Track"));
}

#[test]
fn source_patch_chips_connect_and_solo() {
    let mut ses = session(vec![track(1, TrackKind::Video, vec![]), track(2, TrackKind::Audio, vec![])]);
    assert!(ses.source_patch().video.is_connected);
    ses.toggle_source_patch(TrackKind::Video);
    assert!(!ses.source_patch().video.is_connected);
    assert_eq!(ses.undo_name(), Some("Disconnect Source Video"));
    assert!(ses.take_changes().contains(crate::Change::SOURCE_PATCH));
    ses.toggle_source_patch(TrackKind::Video);
    assert_eq!(ses.undo_name(), Some("Connect Source Video"));
    ses.solo_source_patch(TrackKind::Video);
    assert!(!ses.source_patch().audio.is_connected);
}

#[test]
fn trim_selection_to_range_needs_a_range() {
    let mut ses = session(vec![track(1, TrackKind::Video, vec![clip(10, 0, 6, TrackKind::Video)])]);
    pick(&mut ses, &[10]);
    assert_eq!(ses.trim_selection_to_range(), 0);
}

#[test]
fn edge_edits_prune_and_trim_use_the_session_timeline() {
    use sq_core_model::ClipEdge;
    let ses = session(vec![track(
        1,
        TrackKind::Video,
        vec![clip(10, 0, 2, TrackKind::Video), clip(11, 2, 2, TrackKind::Video)],
    )]);
    let Some(t) = ses.active_timeline() else { panic!("timeline") };
    let tail = EdgeRef::new(Id::from_u128(10), ClipEdge::Tail);
    let head = EdgeRef::new(Id::from_u128(11), ClipEdge::Head);
    let sel = EdgeSelection::new(vec![tail, head], false, true);
    assert!(EdgeEdits::is_roll(&sel, t));
    assert_eq!(EdgeEdits::trim(&sel, s(1), t), vec![TimelineEdit::Roll { clip: Id::from_u128(10), by: s(1) }]);
}

fn end_of(ses: &EditorSession, id: u128) -> Option<Time> {
    let t = ses.active_timeline()?;
    t.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == Id::from_u128(id)).map(|c| c.timeline().end())
}

#[test]
fn trim_edges_moves_the_tail_and_extend_edit_goes_to_the_playhead() {
    let mut ses = session(vec![track(1, TrackKind::Video, vec![clip(10, 0, 4, TrackKind::Video)])]);
    let sel = crate::EdgeSelection::new(vec![crate::EdgeRef::new(Id::from_u128(10), ClipEdge::Tail)], false, true);
    ses.trim_edges(&sel, -3);
    assert_eq!(end_of(&ses, 10), Some(s(4) - Time::new(3, 30)));
    assert_eq!(ses.undo_name(), Some("Trim Clip"));
    ses.playhead = s(3);
    ses.extend_edit(&sel);
    assert_eq!(end_of(&ses, 10), Some(s(3)));
    assert_eq!(ses.undo_name(), Some("Extend Edit"));
}

#[test]
fn close_gap_ripples_the_later_clips_left() {
    let mut ses = session(vec![track(
        1,
        TrackKind::Video,
        vec![clip(10, 0, 2, TrackKind::Video), clip(11, 4, 2, TrackKind::Video)],
    )]);
    ses.close_gap(&crate::GapSelection { track: Id::from_u128(1), range: TimeRange::new(s(2), s(2)) });
    assert_eq!(starts(&ses, 0), vec![s(0), s(2)]);
    assert_eq!(ses.undo_name(), Some("Ripple Delete"));
}

#[test]
fn close_gap_keeps_a_caption_inside_the_gap_and_says_so() {
    let mut ses = session(vec![track(1, TrackKind::Video, vec![clip(10, 27, 10, TrackKind::Video)])]);
    let ct: sq_core_model::CaptionTrack = serde_json::from_value(serde_json::json!({
        "id": Id::from_u128(60),
        "items": [{"id": Id::from_u128(70), "lines": ["Hello caption"],
            "range": {"start": {"value": 10, "timescale": 1}, "duration": {"value": 15, "timescale": 1}}}]}))
    .unwrap_or_else(|_| unreachable!());
    ses.perform_timeline("Add caption track", None, |t| {
        t.caption_tracks.push(ct);
        Ok(())
    })
    .unwrap_or_else(|_| unreachable!());
    ses.close_gap(&crate::GapSelection { track: Id::from_u128(1), range: TimeRange::new(s(0), s(27)) });
    let t = ses.active_timeline().unwrap_or_else(|| unreachable!());
    assert_eq!(t.caption_tracks[0].items().len(), 1, "the caption is not deleted");
    assert_eq!(t.caption_tracks[0].items()[0].range, TimeRange::new(s(10), s(15)));
    assert_eq!(starts(&ses, 0), vec![s(25)], "only the empty 2 s closed");
    assert_eq!(ses.last_error(), Some(EditorSession::GAP_BLOCKED_MESSAGE));
}

/// V1 with a 2 s clip and an 18 s clip, and a caption track with captions at the given (start, end) seconds.
fn caption_session(spans: &[(i64, i64)], fast_cut: bool) -> EditorSession {
    let mut ses = session(vec![track(
        1,
        TrackKind::Video,
        vec![clip(10, 0, 2, TrackKind::Video), clip(11, 2, 18, TrackKind::Video)],
    )]);
    let items: Vec<_> = spans
        .iter()
        .enumerate()
        .map(|(n, (a, b))| {
            serde_json::json!({"id": Id::from_u128(70 + n as u128), "lines": ["Hello caption"],
                "range": {"start": {"value": a, "timescale": 1}, "duration": {"value": b - a, "timescale": 1}}})
        })
        .collect();
    let ct: sq_core_model::CaptionTrack =
        serde_json::from_value(serde_json::json!({"id": Id::from_u128(60), "items": items}))
            .unwrap_or_else(|_| unreachable!());
    ses.perform_timeline("Add caption track", None, |t| {
        t.caption_tracks.push(ct);
        if fast_cut {
            t.set_edit_mode_stored(sq_core_model::TimelineEditMode::Magnetic);
        }
        Ok(())
    })
    .unwrap_or_else(|_| unreachable!());
    ses
}

fn caption_spans(ses: &EditorSession) -> Vec<TimeRange> {
    let Some(t) = ses.active_timeline() else { return Vec::new() };
    t.caption_tracks[0].items().iter().map(|i| i.range).collect()
}

/// Paste Insert of a 2 s clip before, inside and after a 3 s caption never changes a caption's length; captions that
/// start after the point move by the insert, the one under it stays; undo restores them (Normal mode and Fast Cut).
#[test]
fn paste_insert_never_stretches_a_caption_and_undo_restores_it() {
    // Captions 3..6 and 10..12. (point, first start, second start)
    for (at, first, second) in [(1, 5, 12), (4, 3, 12), (8, 3, 12), (11, 3, 10), (13, 3, 10)] {
        for fast_cut in [false, true] {
            let mut ses = caption_session(&[(3, 6), (10, 12)], fast_cut);
            let before = caption_spans(&ses);
            pick(&mut ses, &[10]);
            assert!(ses.copy_selection());
            ses.seek(s(at));
            ses.paste_clipboard(true, false, false);
            let after = caption_spans(&ses);
            let lens: Vec<_> = after.iter().map(|r| r.duration).collect();
            assert_eq!(lens, vec![s(3), s(2)], "lengths never change, insert at {at}, fast_cut {fast_cut}");
            let starts: Vec<_> = after.iter().map(|r| r.start).collect();
            assert_eq!(starts, vec![s(first), s(second)], "insert at {at}, fast_cut {fast_cut}");
            assert!(ses.undo());
            assert_eq!(caption_spans(&ses), before, "undo restores the captions, insert at {at}, fast_cut {fast_cut}");
        }
    }
}

/// Backspace on a gap that a caption (or a clip on another track) keeps from closing fully always says so, also when
/// only one frame or nothing can close; a repeat of the same refusal raises the status line again.
#[test]
fn close_gap_limited_by_a_caption_says_so_for_one_frame_and_for_nothing() {
    let fd = Time::new(1, 30);
    // V1: gap 0..4+1f, then a clip. (caption end, expected closed)
    for (caption_end, closed) in [(s(4), fd), (s(4) + fd, Time::ZERO), (s(5), Time::ZERO)] {
        let mut ses = session(vec![track(
            1,
            TrackKind::Video,
            vec![{
                let mut c = clip(10, 0, 10, TrackKind::Video);
                c.start = s(4) + fd;
                c
            }],
        )]);
        let ct: sq_core_model::CaptionTrack = serde_json::from_value(serde_json::json!({
            "id": Id::from_u128(60),
            "items": [{"id": Id::from_u128(70), "lines": ["Hello"],
                "range": {"start": {"value": 3, "timescale": 1},
                          "duration": {"value": (caption_end - s(3)).value(), "timescale": (caption_end - s(3)).timescale()}}}]}))
        .unwrap_or_else(|_| unreachable!());
        ses.perform_timeline("Add caption track", None, |t| {
            t.caption_tracks.push(ct);
            Ok(())
        })
        .unwrap_or_else(|_| unreachable!());
        let gap = crate::GapSelection { track: Id::from_u128(1), range: TimeRange::new(Time::ZERO, s(4) + fd) };
        ses.close_gap(&gap);
        assert_eq!(starts(&ses, 0), vec![s(4) + fd - closed], "closed {closed:?}");
        assert_eq!(ses.last_error(), Some(EditorSession::GAP_BLOCKED_MESSAGE), "caption end {caption_end:?}");
        let first = ses.error_serial();
        ses.close_gap(&crate::GapSelection {
            track: Id::from_u128(1),
            range: TimeRange::new(Time::ZERO, s(4) + fd - closed),
        });
        assert!(ses.error_serial() > first, "the same refusal again is a new message");
    }
}

/// V1 with a 10 s clip and a 5 s clip behind it, and a caption at 6..9 (it lies in the tail a 2x speed-up frees).
fn speed_session(fast_cut: bool) -> EditorSession {
    let mut ses = session(vec![track(
        1,
        TrackKind::Video,
        vec![clip(10, 0, 10, TrackKind::Video), clip(11, 10, 5, TrackKind::Video)],
    )]);
    let ct: sq_core_model::CaptionTrack = serde_json::from_value(serde_json::json!({
        "id": Id::from_u128(60),
        "items": [{"id": Id::from_u128(70), "lines": ["Hello caption"],
            "range": {"start": {"value": 6, "timescale": 1}, "duration": {"value": 3, "timescale": 1}}}]}))
    .unwrap_or_else(|_| unreachable!());
    ses.perform_timeline("Add caption track", None, |t| {
        t.caption_tracks.push(ct);
        if fast_cut {
            t.set_edit_mode_stored(sq_core_model::TimelineEditMode::Magnetic);
        }
        Ok(())
    })
    .unwrap_or_else(|_| unreachable!());
    pick(&mut ses, &[10]);
    ses
}

fn double_speed() -> sq_core_edit::timeline_speed::SpeedChange {
    sq_core_edit::timeline_speed::SpeedChange {
        speed: Some(sq_core_model::ClipSpeed::new(2, 1)),
        ripple: true,
        ..Default::default()
    }
}

fn caption_range(ses: &EditorSession) -> Option<TimeRange> {
    ses.active_timeline()?.caption_tracks.first()?.items().first().map(|i| i.range)
}

#[test]
fn normal_speed_up_stops_at_a_caption_and_says_so() {
    let mut ses = speed_session(false);
    assert!(ses.apply_speed(double_speed()));
    assert_eq!(caption_range(&ses), Some(TimeRange::new(s(6), s(3))), "the caption is not deleted");
    assert_eq!(starts(&ses, 0), vec![s(0), s(9)], "the ripple stops at the caption's end");
    assert_eq!(ses.last_error(), Some(EditorSession::CAPTION_BLOCKED_MESSAGE));
}

#[test]
fn fast_cut_speed_up_pulls_the_caption_in_and_undo_restores_it() {
    let mut ses = speed_session(true);
    assert!(ses.apply_speed(double_speed()));
    assert_eq!(starts(&ses, 0), vec![s(0), s(5)], "V1 closes fully");
    assert_eq!(caption_range(&ses), Some(TimeRange::new(s(5), s(3))), "kept, pulled in to the new end");
    assert_eq!(ses.last_error(), None, "nothing was limited");
    assert!(ses.undo());
    assert_eq!(caption_range(&ses), Some(TimeRange::new(s(6), s(3))));
    assert_eq!(starts(&ses, 0), vec![s(0), s(10)]);
}

#[test]
fn linked_selection_flag_follows_the_sequence_setting() {
    let mut ses = session(vec![track(1, TrackKind::Video, vec![clip(10, 0, 2, TrackKind::Video)])]);
    assert!(ses.set_linked_selection(false));
    assert!(!ses.linked_selection());
    assert!(!ses.set_linked_selection(false));
}

#[test]
fn angle_candidates_need_two_angles() {
    let mut ses = session(vec![
        track(1, TrackKind::Video, vec![clip(10, 0, 4, TrackKind::Video)]),
        track(2, TrackKind::Video, vec![clip(11, 0, 4, TrackKind::Video)]),
    ]);
    pick(&mut ses, &[10]);
    assert!(ses.angle_candidates_of_selection().is_empty());
    pick(&mut ses, &[11, 10]);
    let names: Vec<_> = ses.angle_candidates_of_selection().into_iter().map(|a| (a.name, a.has_audio)).collect();
    assert_eq!(names, [("c10".to_string(), false), ("c11".to_string(), false)]);
}

#[test]
fn create_angles_clip_replaces_the_selection_with_one_undo_step() {
    let mut ses = session(vec![
        track(1, TrackKind::Video, vec![clip(10, 0, 4, TrackKind::Video)]),
        track(2, TrackKind::Video, vec![clip(11, 0, 4, TrackKind::Video)]),
    ]);
    pick(&mut ses, &[10, 11]);
    let made = ses.create_angles_clip_from_selection(Some("  Talk "), None, 0, false);
    let Some(seq) = made else { panic!("no Angles sequence: {:?}", ses.last_error()) };
    assert_eq!(ses.project().timeline(seq).map(|t| t.name.clone()), Some("Talk".to_string()));
    assert_eq!(ses.undo_name(), Some("Create Angles Clip"));
    let Some(t) = ses.active_timeline() else { panic!("no timeline") };
    assert_eq!(t.tracks[0].clips().len(), 1);
    assert_eq!(t.tracks[0].clips()[0].sequence, Some(seq));
    assert!(ses.selection().contains(&t.tracks[0].clips()[0].id));
}

#[test]
fn create_angles_clip_with_one_clip_says_why() {
    let mut ses = session(vec![track(1, TrackKind::Video, vec![clip(10, 0, 4, TrackKind::Video)])]);
    assert_eq!(ses.create_angles_clip(&[Id::from_u128(10)], None, None, 0, false), None);
    assert_eq!(ses.last_error(), Some("An Angles clip needs at least two clips."));
}

#[test]
fn flatten_angles_replaces_the_piece_by_the_shown_angle() {
    let mut ses = session(vec![
        track(1, TrackKind::Video, vec![clip(10, 0, 4, TrackKind::Video)]),
        track(2, TrackKind::Video, vec![clip(11, 0, 4, TrackKind::Video)]),
    ]);
    pick(&mut ses, &[10, 11]);
    let made = ses.create_angles_clip_from_selection(Some("Talk"), None, 0, false);
    let Some(seq) = made else { panic!("no Angles sequence: {:?}", ses.last_error()) };
    let piece = ses.active_timeline().map(|t| t.tracks[0].clips()[0].id);
    let Some(piece) = piece else { panic!("no piece") };
    assert!(ses.set_angle(1, piece));
    assert!(ses.flatten_angles(piece));
    assert_eq!(ses.undo_name(), Some("Flatten Angles Clip"));
    let Some(t) = ses.active_timeline() else { panic!("no timeline") };
    let clips: Vec<&Clip> = t.tracks.iter().flat_map(|tr| tr.clips()).collect();
    assert_eq!(clips.len(), 1);
    assert!(clips[0].sequence.is_none() && clips[0].angle.is_none());
    assert_eq!(clips[0].media, Id::from_u128(911));
    // The Angles sequence itself stays in the project.
    assert!(ses.project().timeline(seq).is_some());
}

#[test]
fn flatten_angles_refuses_an_ordinary_clip() {
    let mut ses = session(vec![track(1, TrackKind::Video, vec![clip(10, 0, 4, TrackKind::Video)])]);
    assert!(!ses.flatten_angles(Id::from_u128(10)));
    assert!(ses.last_error().is_some());
}

#[test]
fn ripple_trim_to_playhead_closes_the_gap_and_names_the_step() {
    let mut ses = session(vec![track(
        1,
        TrackKind::Video,
        vec![clip(10, 0, 4, TrackKind::Video), clip(11, 4, 4, TrackKind::Video)],
    )]);
    ses.playhead = s(2);
    ses.trim_to_playhead(ClipEdge::Tail, sq_core_edit::timeline_trim_to_playhead::PlayheadTrimMode::Ripple);
    assert_eq!(starts(&ses, 0), vec![s(0), s(2)]);
    assert_eq!(ses.undo_name(), Some("Ripple Trim Next Edit"));
}

/// Every clip of every track as (start, duration, source in), the whole edit in one comparable value.
fn spans(ses: &EditorSession) -> Vec<Vec<(Time, Time, Time)>> {
    let Some(t) = ses.active_timeline() else { return Vec::new() };
    t.tracks.iter().map(|tr| tr.clips().iter().map(|c| (c.start, c.duration(), c.source.start)).collect()).collect()
}

/// End puts the playhead on the sequence end, so Paste and Paste Insert append on V1 and A1: the last clips keep every
/// frame, no 1-frame remainder appears, and one undo restores the sequence exactly.
#[test]
fn paste_at_the_sequence_end_appends_and_leaves_the_last_clip_whole() {
    for insert in [false, true] {
        let mut ses = session(vec![
            track(1, TrackKind::Video, vec![clip(10, 0, 2, TrackKind::Video), clip(12, 2, 2, TrackKind::Video)]),
            track(2, TrackKind::Audio, vec![clip(11, 0, 2, TrackKind::Audio), clip(13, 2, 2, TrackKind::Audio)]),
        ]);
        let before = spans(&ses);
        pick(&mut ses, &[10, 11]);
        assert!(ses.copy_selection());
        ses.go_to_end();
        assert_eq!(ses.playhead(), s(4), "End parks on the sequence end");
        ses.paste_clipboard(insert, false, false);
        let lane = [(s(0), s(2), s(0)), (s(2), s(2), s(0)), (s(4), s(2), s(0))];
        assert_eq!(spans(&ses), vec![lane.to_vec(), lane.to_vec()], "insert = {insert}");
        assert_eq!(ses.playhead(), s(6), "the playhead follows the pasted clips");
        assert!(ses.undo());
        assert_eq!(spans(&ses), before, "undo restores exactly, insert = {insert}");
    }
}

/// Paste Insert exactly on the last frame of the last clip splits that clip there: the 1-frame right part follows the
/// pasted clips (rational time, no frame lost or doubled).
#[test]
fn paste_insert_on_the_last_frame_splits_the_last_clip_exactly() {
    let fd = Time::new(1, 30);
    let mut ses = session(vec![track(
        1,
        TrackKind::Video,
        vec![clip(10, 0, 2, TrackKind::Video), clip(12, 2, 2, TrackKind::Video)],
    )]);
    pick(&mut ses, &[10]);
    assert!(ses.copy_selection());
    ses.seek(s(4) - fd);
    ses.paste_clipboard(true, false, false);
    assert_eq!(
        spans(&ses),
        vec![vec![(s(0), s(2), s(0)), (s(2), s(2) - fd, s(0)), (s(4) - fd, s(2), s(0)), (s(6) - fd, fd, s(2) - fd),]]
    );
}
