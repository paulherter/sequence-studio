//! Ports of `TransitionSessionTests` and `TransitionStaleSelectionTests` (SQTimelineUI): default transitions at the playhead,
//! drop on a cut, one undo step per drag, Delete and the selection.

use std::collections::BTreeSet;

use sq_core_effects::transition::TrackTransitions as _;
use sq_core_model::{Clip, Project, SequenceFormat, Timeline, Track, TrackKind, TransitionAlignment, TransitionKind};
use sq_core_time::{Id, SequentialIds, Time, TimeRange};

use super::*;
use crate::{EditorSession, SessionDeps};
use sq_core_effects::transition::TransitionPoint;

const FD: Time = Time::new(1, 30);

fn f(n: i64) -> Time {
    FD * n
}

fn clip(n: u128, start: i64, kind: TrackKind, link: Option<u128>) -> Clip {
    let mut c = Clip::new(
        Id::from_u128(n),
        &format!("c{n}"),
        Id::from_u128(900 + n),
        kind,
        TimeRange::new(f(30), f(60)),
        f(start),
    );
    c.link = link.map(Id::from_u128);
    c.media_duration = Some(f(300));
    c
}

fn defaults() -> TransitionDefaults {
    TransitionDefaults::new(20, 1.0)
}

fn session_over(tracks: Vec<Track>) -> EditorSession {
    let tl = Timeline::new(Id::from_u128(50), "T", SequenceFormat::new(FD), tracks);
    let p = Project::new(Id::from_u128(1), "p", Vec::new(), vec![tl]);
    let mut s = EditorSession::new(p, SessionDeps::headless(std::env::temp_dir().join("sq-es04-transition-ui")));
    s.set_selection_follows_playhead(false);
    s
}

fn track(n: u128, kind: TrackKind, clips: Vec<Clip>) -> Track {
    let mut ids = SequentialIds::default();
    let mut t = Track::new(Id::from_u128(n), kind);
    t.is_targeted = true;
    for c in clips {
        assert!(t.overwrite(c, &mut ids).is_ok());
    }
    t
}

/// V1: A 0..60, B 60..120, gap, C 150..210; A1: a 0..60, b 60..120. V1 and A1 targeted.
fn session() -> EditorSession {
    let v = track(
        100,
        TrackKind::Video,
        vec![
            clip(1, 0, TrackKind::Video, Some(11)),
            clip(2, 60, TrackKind::Video, Some(12)),
            clip(3, 150, TrackKind::Video, None),
        ],
    );
    let a = track(
        101,
        TrackKind::Audio,
        vec![clip(4, 0, TrackKind::Audio, Some(11)), clip(5, 60, TrackKind::Audio, Some(12))],
    );
    session_over(vec![v, a])
}

fn tl(s: &EditorSession) -> &Timeline {
    s.active_timeline().expect("timeline")
}

#[test]
fn apply_default_is_one_undo_step_and_replaces_on_second_apply() {
    let mut s = session();
    s.seek(f(58));
    assert_eq!(s.apply_default_transitions(TransitionScope::Both, None, None, &defaults()), 2);
    assert_eq!(s.undo_name(), Some("Apply Transitions"));
    let t = tl(&s);
    assert!(t.tracks[0].transitions.len() == 1 && t.tracks[1].transitions.len() == 1);
    assert!(
        t.tracks[0].transitions[0].kind == TransitionKind::CrossDissolve
            && t.tracks[0].transitions[0].duration == f(20)
    );
    assert!(
        t.tracks[1].transitions[0].kind == TransitionKind::ConstantPower
            && t.tracks[1].transitions[0].duration == f(30)
    );
    assert_eq!(s.apply_default_transitions(TransitionScope::Video, None, None, &defaults()), 1);
    assert_eq!(tl(&s).tracks[0].transitions.len(), 1); // replaced, not stacked
    s.undo();
    s.undo();
    assert!(tl(&s).tracks.iter().all(|t| t.transitions.is_empty()));
}

#[test]
fn no_edit_to_apply_on_sets_a_message() {
    let mut s = session();
    let _ = s.perform_timeline("Untarget", None, |t| {
        t.tracks[0].is_targeted = false;
        Ok(())
    });
    assert_eq!(s.apply_default_transitions(TransitionScope::Video, None, None, &defaults()), 0);
    assert!(s.last_error().is_some());
}

#[test]
fn no_media_beyond_the_cut_holds_video_and_refuses_audio() {
    // A uses the end of its media and B the start: nothing beyond the cut.
    let whole = |kind: TrackKind| {
        let mut a = clip(1, 0, kind, None);
        a.source = TimeRange::new(f(240), f(60));
        let mut b = clip(2, 60, kind, None);
        b.source = TimeRange::new(f(0), f(60));
        track(100, kind, vec![a, b])
    };
    let mut s = session_over(vec![whole(TrackKind::Video)]);
    s.seek(f(58));
    assert_eq!(s.apply_default_transitions(TransitionScope::Video, None, None, &defaults()), 1);
    let t = tl(&s);
    let r = t.tracks[0].resolved_transitions(FD).into_iter().next().expect("resolved");
    assert!(r.held_before > 0 && r.held_after > 0 && r.span.duration == r.requested_duration);

    let mut au = session_over(vec![whole(TrackKind::Audio)]);
    au.seek(f(58));
    assert_eq!(au.apply_default_transitions(TransitionScope::Audio, None, None, &defaults()), 0);
    assert!(tl(&au).tracks[0].transitions.is_empty() && !au.can_undo());
    assert!(au.last_error().is_some_and(|e| e.contains("Not enough media")));
}

fn cut() -> TransitionPoint {
    TransitionPoint::Cut { outgoing: Id::from_u128(1), incoming: Id::from_u128(2) }
}

#[test]
fn drop_on_a_cut_honours_alignment_and_selects_it() {
    let mut s = session();
    let tr = Id::from_u128(100);
    let id = s
        .add_transition(TransitionKind::DipToBlack, tr, cut(), TransitionAlignment::EndAtCut, &defaults())
        .expect("added");
    assert_eq!(s.selected_transition(), Some(id));
    let r = tl(&s).tracks[0].resolved_transitions(FD).remove(0);
    assert!(r.span == TimeRange::new(f(40), f(20)) && r.kind == TransitionKind::DipToBlack);
    assert_eq!(s.undo_name(), Some("Apply Through Black"));
}

#[test]
fn drag_edits_of_one_gesture_are_one_undo_step() {
    let mut s = session();
    let id = s
        .add_transition(
            TransitionKind::CrossDissolve,
            Id::from_u128(100),
            cut(),
            TransitionAlignment::Center,
            &defaults(),
        )
        .expect("added");
    let depth = s.undo_step_depth();
    let change = |n| TransitionTimingChange { duration: Some(f(n)), alignment: None, custom_before: None, kind: None };
    s.set_transition(id, &change(24), false);
    s.set_transition(id, &change(26), true);
    s.set_transition(id, &change(28), true);
    assert!(s.undo_step_depth() == depth + 1 && tl(&s).tracks[0].transitions[0].duration == f(28));
    s.undo();
    assert_eq!(tl(&s).tracks[0].transitions[0].duration, f(20));
}

#[test]
fn delete_removes_the_selected_transition() {
    let mut s = session();
    s.add_transition(
        TransitionKind::CrossDissolve,
        Id::from_u128(100),
        cut(),
        TransitionAlignment::Center,
        &defaults(),
    );
    assert!(s.remove_selected_transition());
    assert!(tl(&s).tracks[0].transitions.is_empty() && s.selected_transition().is_none());
    assert!(!s.remove_selected_transition());
    s.undo();
    assert_eq!(tl(&s).tracks[0].transitions.len(), 1);
}

#[test]
fn selection_follows_clips_and_undo() {
    let mut s = session();
    s.add_transition(
        TransitionKind::CrossDissolve,
        Id::from_u128(100),
        cut(),
        TransitionAlignment::Center,
        &defaults(),
    );
    assert!(s.selected_transition().is_some());
    s.set_selection(BTreeSet::from([Id::from_u128(3)]), BTreeSet::new());
    assert!(s.selected_transition().is_none());
    s.undo();
    assert!(s.selected_transition().is_none());
}

#[test]
fn delete_falls_through_when_the_selected_transition_is_gone() {
    let mut s = session();
    s.add_transition(
        TransitionKind::CrossDissolve,
        Id::from_u128(100),
        cut(),
        TransitionAlignment::Center,
        &defaults(),
    );
    s.undo(); // the transition goes, the id may stay selected
    assert!(!s.remove_selected_transition());
    assert!(s.selected_transition().is_none());
}

#[test]
fn a_tagged_audio_clip_brings_its_roles_crossfade_length() {
    // The incoming clip of the audio cut is Dialogue (0.1 s = 3 frames); an untagged cut keeps the Settings length.
    let mut tagged = clip(5, 60, TrackKind::Audio, None);
    tagged.audio_tag = Some(sq_core_model::AudioTag::Dialogue);
    let a = track(101, TrackKind::Audio, vec![clip(4, 0, TrackKind::Audio, None), tagged]);
    let mut s = session_over(vec![a]);
    s.seek(f(58));
    assert_eq!(s.apply_default_transitions(TransitionScope::Audio, None, None, &defaults()), 1);
    assert_eq!(tl(&s).tracks[0].transitions[0].duration, f(3));
    // A user-chosen kind (drag from the Effects panel) is not a default: it keeps the Settings length.
    let mut s = session();
    s.seek(f(58));
    assert_eq!(s.apply_default_transitions(TransitionScope::Audio, None, None, &defaults()), 1);
    assert_eq!(tl(&s).tracks[1].transitions[0].duration, f(30));
}

#[test]
fn changing_the_transition_defaults_tells_the_app_to_save_them() {
    let mut s = session();
    s.seek(f(58));
    assert_eq!(s.apply_default_transitions(TransitionScope::Audio, None, None, &defaults()), 1);
    let (id, kind) = {
        let t = &tl(&s).tracks[1].transitions[0];
        (t.id, t.kind)
    };
    s.take_events();
    assert!(s.use_transition_as_default(id));
    let events = s.take_events();
    assert!(matches!(events.as_slice(), [crate::SessionEvent::EffectDefaultsChange(_)]));
    // The same default again changes nothing: no event.
    assert!(s.use_transition_as_default(id));
    assert!(s.take_events().is_empty());
    s.reset_transition_default_to_factory(kind);
    assert!(matches!(s.take_events().as_slice(), [crate::SessionEvent::EffectDefaultsChange(_)]));
}

/// Undo and Redo of an edit to the selected transition leave it selected (the Transition panel keeps its target).
#[test]
fn undo_and_redo_of_a_transition_edit_keep_it_selected() {
    let mut s = session();
    let id = s
        .add_transition(
            TransitionKind::CrossDissolve,
            Id::from_u128(100),
            cut(),
            TransitionAlignment::Center,
            &defaults(),
        )
        .expect("added");
    let change = TransitionTimingChange { duration: Some(f(24)), alignment: None, custom_before: None, kind: None };
    s.set_transition(id, &change, false);
    assert_eq!(s.selected_transition(), Some(id));
    assert!(s.undo());
    assert_eq!(s.selected_transition(), Some(id), "after Undo");
    assert!(s.redo());
    assert_eq!(s.selected_transition(), Some(id), "after Redo");
}
