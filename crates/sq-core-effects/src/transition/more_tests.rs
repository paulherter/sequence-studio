// SPDX-License-Identifier: GPL-3.0-or-later
// Swift tests: StingerTransitionTests, ElementTransitionTests (logic parts), EffectsInTransitionTests (held clip)

use super::tests::{clip, cut, edge, f, fd, ids, pair, range, resolved, video_pair};
use super::*;
use TransitionAlignment::Center;
use TransitionKind as K;
use sq_core_model::effect_defaults::TransitionPreset;
use sq_core_model::{
    Clip, ClipEdge, ClipEffect, EditError, Timeline, TrackKind, Transition, TransitionAlignment, TransitionKind,
    TransitionStinger,
};
use sq_core_time::{Id, Time, Vec2};
use std::collections::BTreeMap;

const STINGER: Id = Id::from_u128(4242);

fn whole(n: u128, start: i64, frames: i64) -> Clip {
    clip(n, start, 0, frames, frames, TrackKind::Video)
}

/// Two touching 60 frame clips without handles (source = whole media), cut at frame 60.
fn cut_timeline() -> (Timeline, Clip, Clip) {
    pair(TrackKind::Video, Some(whole(1, 0, 60)), Some(whole(2, 60, 60)))
}

fn stinger_timeline(cut_fraction: f64, frames: i64) -> (Timeline, Id, Clip, Clip) {
    let (mut t, a, b) = cut_timeline();
    let id = cut(&mut t, K::Stinger, &a, &b, frames, Center).unwrap();
    t.set_stinger(id, Some(TransitionStinger { media: STINGER, cut_fraction, scale: None })).unwrap();
    (t, id, a, b)
}

mod stinger {
    use super::*;

    #[test]
    fn kind_is_a_video_transition_that_is_not_a_motion_mix() {
        let k = K::Stinger;
        assert!(k.track_kind() == TrackKind::Video && k.name() == "Stinger" && !k.is_motion());
        assert!(!k.uses_direction() && !k.uses_softness() && !k.uses_motion_blur());
        assert!(K::kinds_for(TrackKind::Video).contains(&k) && k.is_stinger());
    }

    #[test]
    fn needs_no_handles_and_puts_the_cut_frame_on_the_edit() {
        let (t, id, ..) = stinger_timeline(0.5, 30);
        let r = resolved(&t).into_iter().find(|r| r.id == id).unwrap();
        assert_eq!(r.cut, f(60));
        assert!(r.before == f(15) && r.after == f(15));
        assert_eq!(r.span, range(45, 30));
        assert!(r.stinger_start == Time::ZERO && !r.is_clamped());
    }

    #[test]
    fn cut_fraction_moves_the_span_around_the_edit() {
        let (t, id, ..) = stinger_timeline(0.2, 30);
        let r = resolved(&t).into_iter().find(|r| r.id == id).unwrap();
        assert!(r.before == f(6) && r.after == f(24));
    }

    #[test]
    fn short_clips_trim_the_stinger_but_keep_its_cut_on_the_edit() {
        // A is only 10 frames: the stinger's first 5 of 15 before-cut frames are skipped (it starts 5 frames into its media).
        let (mut t, a, b) = pair(TrackKind::Video, Some(whole(1, 0, 10)), Some(whole(2, 10, 60)));
        let id = cut(&mut t, K::Stinger, &a, &b, 30, Center).unwrap();
        t.set_stinger(id, Some(TransitionStinger { media: STINGER, cut_fraction: 0.5, scale: None })).unwrap();
        assert_eq!(t.transition(id).unwrap().1.duration, f(30), "the request is kept");
        let r = &resolved(&t)[0];
        assert!(r.before == f(10) && r.after == f(15));
        assert_eq!(r.stinger_start, f(5));
        assert!(r.is_clamped());
    }

    #[test]
    fn single_sided_stinger_is_refused() {
        let (mut t, a, _) = cut_timeline();
        assert_eq!(edge(&mut t, K::Stinger, None, Some(a.id), 30, Center), Err(EditError::NotACut));
    }

    #[test]
    fn set_stinger_sets_and_clears_the_clip() {
        let (mut t, a, b) = cut_timeline();
        let id = cut(&mut t, K::Stinger, &a, &b, 20, Center).unwrap();
        t.set_stinger(id, None).unwrap();
        assert!(t.transition(id).unwrap().1.stinger.is_none());
        t.set_stinger(id, Some(TransitionStinger { media: STINGER, cut_fraction: 0.75, scale: None })).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert!(tr.stinger.as_ref().map(|s| s.cut_fraction) == Some(0.75) && tr.kind == K::Stinger);
        // A dissolve becomes a stinger when a clip is picked; a single-sided one cannot.
        let d = cut(&mut t, K::CrossDissolve, &a, &b, 20, Center).unwrap();
        t.set_stinger(d, Some(TransitionStinger { media: STINGER, cut_fraction: 0.5, scale: None })).unwrap();
        assert_eq!(t.transition(d).unwrap().1.kind, K::Stinger);
        let head = edge(&mut t, K::CrossDissolve, None, Some(a.id), 10, Center).unwrap();
        assert_eq!(
            t.set_stinger(head, Some(TransitionStinger { media: STINGER, cut_fraction: 0.5, scale: None })),
            Err(EditError::NotACut)
        );
    }

    #[test]
    fn before_the_edit_shows_a_with_the_stinger_on_top() {
        let (t, id, a, _) = stinger_timeline(0.5, 30);
        let e = t.tracks[0].video_entries(f(50), fd());
        assert_eq!(e.items.len(), 2);
        assert_eq!(e.items[0].0.id, a.id);
        assert_eq!(e.items[1].0.media, STINGER);
        assert_eq!(e.items[1].0.id, id);
        // The stinger clip plays from its first frame at the span start: frame 5 of the stinger at timeline frame 50.
        let s = &e.items[1].0;
        assert!(s.source.start == Time::ZERO && s.start == f(45) && s.source.duration == f(30));
        assert!(
            e.stinger == Some(id) && e.pair.is_none() && e.motion.is_none() && e.items.iter().all(|(_, o)| *o == 1.0)
        );
    }

    #[test]
    fn from_the_edit_on_shows_b_with_the_stinger_on_top() {
        let (t, id, _, b) = stinger_timeline(0.5, 30);
        let e = t.tracks[0].video_entries(f(60), fd());
        let ids: Vec<Id> = e.items.iter().map(|(c, _)| c.id).collect();
        assert_eq!(ids, [b.id, id]);
        assert_eq!(e.items[1].0.media, STINGER);
    }

    #[test]
    fn outside_the_span_there_is_no_stinger() {
        let (t, _, a, b) = stinger_timeline(0.5, 30);
        let at = |n| t.tracks[0].video_entries(f(n), fd());
        assert_eq!(at(44).items.iter().map(|(c, _)| c.id).collect::<Vec<_>>(), [a.id]);
        assert_eq!(at(75).items.iter().map(|(c, _)| c.id).collect::<Vec<_>>(), [b.id]);
        assert!(at(44).stinger.is_none());
    }

    #[test]
    fn stinger_without_media_is_a_plain_cut() {
        let (mut t, a, b) = cut_timeline();
        cut(&mut t, K::Stinger, &a, &b, 30, Center).unwrap();
        let at = |n| t.tracks[0].video_entries(f(n), fd()).items.iter().map(|(c, _)| c.id).collect::<Vec<_>>();
        assert_eq!(at(50), [a.id]);
        assert_eq!(at(60), [b.id]);
    }

    #[test]
    fn stinger_uses_its_fit_scale() {
        let (mut t, id, ..) = stinger_timeline(0.5, 30);
        t.set_stinger(id, Some(TransitionStinger { media: STINGER, cut_fraction: 0.5, scale: Some(0.5) })).unwrap();
        let e = t.tracks[0].video_entries(f(50), fd());
        assert_eq!(e.items[1].0.animation.scale.value, Vec2::new(0.5, 0.5));
    }

    #[test]
    fn disabled_side_leaves_only_the_stinger() {
        let (mut t, _, mut a, _) = stinger_timeline(0.5, 30);
        a.is_enabled = false;
        t.tracks[0].replace(a);
        let e = t.tracks[0].video_entries(f(50), fd());
        assert_eq!(e.items.iter().map(|(c, _)| c.media).collect::<Vec<_>>(), [STINGER]);
    }
}

mod effects_in_transition {
    use super::*;

    #[test]
    fn a_held_clip_has_unlimited_handles_like_a_still() {
        let a = clip(1, 0, 30, 60, 300, TrackKind::Video);
        let mut b = clip(2, 60, 0, 60, 300, TrackKind::Video); // no head handle at all
        b.hold_frame = Some(f(0));
        let (mut t, a, b) = pair(TrackKind::Video, Some(a), Some(b));
        // 20 frames centered on the cut need 10 frames of B's head: a clip with no media before its first frame cannot give
        // them, a held clip can (its picture is one frame).
        cut(&mut t, K::CrossDissolve, &a, &b, 20, Center).unwrap();
        let r = &resolved(&t)[0];
        assert!(!r.is_clamped() && r.before == f(10));
        // And without the hold, a centered apply moves onto A's tail (Start at Cut); stored centered (an older project) it
        // holds B's edge frame and is marked.
        let plain = clip(2, 60, 0, 60, 300, TrackKind::Video);
        let (mut t2, a2, plain) = pair(TrackKind::Video, Some(a), Some(plain));
        cut(&mut t2, K::CrossDissolve, &a2, &plain, 20, Center).unwrap();
        let r2 = &resolved(&t2)[0];
        assert!(r2.alignment == TransitionAlignment::StartAtCut && r2.before == Time::ZERO && !r2.is_held());
        t2.tracks[0].transitions =
            vec![Transition::new(Id::from_u128(50), K::CrossDissolve, f(20), Some(a2.id), Some(plain.id))];
        let r3 = &resolved(&t2)[0];
        assert!(r3.before == f(10) && r3.is_held() && r3.is_clamped());
    }
}

mod element_kinds {
    use super::*;

    #[test]
    fn move_zoom_pop_are_one_sided_video_transitions() {
        for k in ELEMENT_KINDS {
            assert!(k.is_element() && k.track_kind() == TrackKind::Video, "{k:?}");
            assert!(!k.is_motion(), "drawn on the clip's own transform, not by the transition node");
            assert!(k.uses_motion_blur() && !k.uses_easing() && !k.uses_direction(), "{k:?}");
            assert!(k.element_effect_kind().is_some());
        }
        assert_eq!(ELEMENT_KINDS.map(|k| k.name()), ["Move", "Zoom", "Pop"]);
        assert!(!K::CrossDissolve.is_element() && !K::Slide.is_element());
    }

    #[test]
    fn params_come_from_the_motion_effect_without_mode_or_duration() {
        let keys: Vec<String> = K::Move.element_params().into_iter().map(|p| p.key).collect();
        let has = |k: &str| keys.iter().any(|x| x == k);
        assert!(has(ClipEffect::MOVE_DIRECTION_KEY) && has(ClipEffect::MOTION_CURVE_KEY));
        assert!(
            !has(ClipEffect::MOTION_MODE_KEY)
                && !has(ClipEffect::MOTION_DURATION_KEY)
                && !has(ClipEffect::MOTION_OUT_DURATION_KEY)
        );
        let pop: Vec<String> = K::Pop.element_params().into_iter().map(|p| p.key).collect();
        assert!(!pop.iter().any(|k| k == ClipEffect::POP_SETTLE_KEY), "a pop settles at 100 %");
        assert!(K::CrossDissolve.element_params().is_empty());
        // Zoom has one "Scale at Edge" value instead of From / To.
        let zoom: Vec<String> = K::Zoom.element_params().into_iter().map(|p| p.title).collect();
        assert!(zoom.iter().any(|t| t == "Scale at Edge") && !zoom.iter().any(|t| t == "To"));
    }
}

mod element_edits {
    use super::*;

    #[test]
    fn goes_on_a_clip_edge_not_on_a_cut() {
        let (mut t, a, b) = video_pair();
        assert_eq!(cut(&mut t, K::Move, &a, &b, 15, Center), Err(EditError::NotACut));
        // The head of B even though A touches it: the edge of the clip, not the cut.
        let id = edge(&mut t, K::Move, None, Some(b.id), 15, Center).unwrap();
        assert_eq!(resolved(&t).into_iter().find(|r| r.id == id).unwrap().span, range(60, 15));
    }

    #[test]
    fn coexists_with_the_cut_transition_on_that_edge() {
        let (mut t, a, b) = video_pair();
        let kinds = |t: &Timeline| t.tracks[0].transitions.iter().map(|x| x.kind).collect::<Vec<_>>();
        cut(&mut t, K::CrossDissolve, &a, &b, 10, Center).unwrap();
        edge(&mut t, K::Zoom, None, Some(b.id), 15, Center).unwrap();
        edge(&mut t, K::Move, Some(a.id), None, 15, Center).unwrap();
        assert_eq!(kinds(&t), [K::CrossDissolve, K::Zoom, K::Move], "no second picture: nothing to replace");
        // A cut transition leaves the element ones alone, only replaces its own class.
        cut(&mut t, K::DipToBlack, &a, &b, 10, Center).unwrap();
        assert_eq!(kinds(&t), [K::Zoom, K::Move, K::DipToBlack]);
        edge(&mut t, K::Pop, None, Some(b.id), 15, Center).unwrap();
        assert_eq!(kinds(&t), [K::Move, K::DipToBlack, K::Pop], "same class, same edge: replaced");
    }

    #[test]
    fn element_and_cut_transitions_do_not_share_the_clip_budget() {
        let (mut t, _, b) = video_pair();
        edge(&mut t, K::Zoom, None, Some(b.id), 45, Center).unwrap();
        let dissolve = edge(&mut t, K::CrossDissolve, Some(b.id), None, 30, Center).unwrap();
        let frames = |t: &Timeline, id| resolved(t).into_iter().find(|r| r.id == id).map(|r| r.frames());
        assert_eq!(frames(&t, dissolve), Some(30), "the Zoom does not eat B's frames");
        let out = edge(&mut t, K::Move, Some(b.id), None, 30, Center).unwrap();
        assert_eq!(frames(&t, out), Some(15), "two elements share B's 60 frames");
    }

    #[test]
    fn both_ends_of_a_short_clip_fit_half_each() {
        let (short, tiny) = (clip(1, 0, 30, 20, 300, TrackKind::Video), clip(2, 100, 30, 1, 300, TrackKind::Video));
        let (mut t, short, tiny) = pair(TrackKind::Video, Some(short), Some(tiny));
        let tid = t.tracks[0].id;
        let both = [ClipEdge::Head, ClipEdge::Tail];
        let made = t.add_element_transitions(K::Move, tid, short.id, &both, f(15), &mut ids()).unwrap();
        assert_eq!(made.len(), 2);
        let frames: Vec<i64> = resolved(&t).iter().filter(|r| made.contains(&r.id)).map(|r| r.frames()).collect();
        assert_eq!(frames, [10, 10]);
        // One frame: the head gets it, the tail is skipped instead of failing the whole drop.
        let one = t.add_element_transitions(K::Move, tid, tiny.id, &both, f(15), &mut ids()).unwrap();
        assert_eq!(one.len(), 1);
        // A long clip keeps the full length on both ends.
        let (mut long, _, b) = video_pair();
        let tid = long.tracks[0].id;
        let ids2 = long.add_element_transitions(K::Pop, tid, b.id, &both, f(15), &mut ids()).unwrap();
        let frames: Vec<i64> = resolved(&long).iter().filter(|r| ids2.contains(&r.id)).map(|r| r.frames()).collect();
        assert_eq!(frames, [15, 15]);
        assert_eq!(Timeline::element_duration(f(15), f(20), true, fd()), f(10));
        assert_eq!(Timeline::element_duration(f(15), f(20), false, fd()), f(15));
        assert_eq!(
            long.add_element_transitions(K::CrossDissolve, tid, b.id, &both, f(15), &mut ids()),
            Err(EditError::NotACut)
        );
    }

    #[test]
    fn motion_blur_is_capped_at_what_renders() {
        let (mut t, _, b) = video_pair();
        let id = edge(&mut t, K::Move, None, Some(b.id), 15, Center).unwrap();
        t.set_transition(id, &TransitionChange { motion_blur: Some(3.0), ..TransitionChange::default() }).unwrap();
        assert_eq!(t.transition(id).unwrap().1.effective_motion_blur(), 1.0, "one frame = a 360 degree shutter");
    }

    #[test]
    fn a_cut_transition_cannot_become_an_element() {
        let (mut t, a, b) = video_pair();
        let id = cut(&mut t, K::CrossDissolve, &a, &b, 10, Center).unwrap();
        let to_pop = TransitionChange { kind: Some(K::Pop), ..TransitionChange::default() };
        assert_eq!(t.set_transition(id, &to_pop), Err(EditError::NotACut));
        let head = edge(&mut t, K::CrossDissolve, Some(b.id), None, 10, Center).unwrap();
        t.set_transition(head, &to_pop).unwrap();
        assert_eq!(t.transition(head).unwrap().1.kind, K::Pop);
    }

    #[test]
    fn params_are_clamped_and_merged() {
        let (mut t, _, b) = video_pair();
        let id = edge(&mut t, K::Move, None, Some(b.id), 15, Center).unwrap();
        let one = |k: &str, v: f64| BTreeMap::from([(k.to_string(), v)]);
        t.set_transition_params(id, &one(ClipEffect::MOVE_DIRECTION_KEY, 90.0), false).unwrap();
        t.set_transition_params(id, &one(ClipEffect::MOVE_DISTANCE_KEY, 50_000.0), false).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert_eq!(tr.param(ClipEffect::MOVE_DIRECTION_KEY), 90.0);
        assert_eq!(tr.param(ClipEffect::MOVE_DISTANCE_KEY), 1_000.0);
        assert_eq!(tr.param(ClipEffect::MOVE_ROTATION_KEY), 0.0, "unset = the effect's default");
        assert_eq!(t.set_transition_params(id, &one("nonsense", 1.0), false), Err(EditError::InvalidFormat));
        // The Custom curve keys are accepted on element transitions: X 0...1, Y -2...3.
        t.set_transition_params(id, &one(ClipEffect::CURVE_X1_KEY, 4.0), false).unwrap();
        t.set_transition_params(id, &one(ClipEffect::CURVE_Y1_KEY, -9.0), false).unwrap();
        let p = t.transition(id).unwrap().1.params.unwrap();
        assert!(
            p[ClipEffect::CURVE_X1_KEY] == 1.0
                && p[ClipEffect::CURVE_Y1_KEY] == -2.0
                && p[ClipEffect::MOVE_DIRECTION_KEY] == 90.0
        );
    }

    #[test]
    fn the_stored_clip_keeps_its_effects() {
        let (mut t, _, b) = video_pair();
        edge(&mut t, K::Move, None, Some(b.id), 15, Center).unwrap();
        let stored = t.tracks[0].clips()[1].clone();
        assert!(stored.effects.is_empty());
        assert_eq!(t.tracks[0].clip_with_element_transitions(&stored, f(62), fd()).effects.len(), 1);
        assert!(t.tracks[0].clip_with_element_transitions(&stored, f(100), fd()).effects.is_empty());
        // The track hands the same out while it shows, without a mixing state and at full opacity.
        let e = t.tracks[0].video_entries(f(62), fd());
        assert!(e.pair.is_none() && e.motion.is_none() && e.items.len() == 1);
        assert!(e.items[0].1 == 1.0 && e.items[0].0.effects.len() == 1);
    }

    #[test]
    fn span_follows_the_duration() {
        let (mut t, _, b) = video_pair();
        let id = edge(&mut t, K::Move, None, Some(b.id), 10, Center).unwrap();
        let effects_at = |t: &Timeline, n| t.tracks[0].clip_with_element_transitions(&b, f(n), fd()).effects.len();
        assert_eq!(effects_at(&t, 72), 0);
        t.set_transition(id, &TransitionChange { duration: Some(f(20)), ..TransitionChange::default() }).unwrap();
        assert_eq!(effects_at(&t, 72), 1);
    }

    #[test]
    fn preset_replaces_the_params_of_the_same_kind() {
        let (mut t, _, b) = video_pair();
        let id = edge(&mut t, K::Move, None, Some(b.id), 12, Center).unwrap();
        let p = |pairs: &[(&str, f64)]| pairs.iter().map(|(k, v)| ((*k).to_string(), *v)).collect::<BTreeMap<_, _>>();
        t.set_transition_params(
            id,
            &p(&[(ClipEffect::MOVE_ROTATION_KEY, 45.0), (ClipEffect::MOVE_DISTANCE_KEY, 20.0)]),
            false,
        )
        .unwrap();
        let mut preset = TransitionPreset::new(K::Move, f(12));
        preset.params = Some(p(&[(ClipEffect::MOVE_DIRECTION_KEY, 90.0)]));
        t.apply_transition_preset(&preset, id).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert_eq!(tr.param(ClipEffect::MOVE_DIRECTION_KEY), 90.0);
        assert!(
            tr.param(ClipEffect::MOVE_ROTATION_KEY) == 0.0 && tr.param(ClipEffect::MOVE_DISTANCE_KEY) == 100.0,
            "the saved look, not a merge"
        );
        t.apply_transition_preset(&TransitionPreset::new(K::Move, f(12)), id).unwrap();
        assert!(t.transition(id).unwrap().1.params.is_none(), "a preset without params is the default look");
    }

    #[test]
    fn preset_keeps_the_params() {
        let (mut t, a, b) = video_pair();
        let tid = t.tracks[0].id;
        let id = edge(&mut t, K::Move, None, Some(b.id), 12, Center).unwrap();
        let params = BTreeMap::from([
            (ClipEffect::MOVE_DIRECTION_KEY.to_string(), 90.0),
            (ClipEffect::MOVE_ROTATION_KEY.to_string(), 30.0),
        ]);
        t.set_transition_params(id, &params, false).unwrap();
        let preset = TransitionPreset::capture(&t.transition(id).unwrap().1);
        let back =
            TransitionPreset::from_payload(&preset.payload().unwrap(), TransitionPreset::PAYLOAD_VERSION).unwrap();
        let other = t.add_transition_from_preset(&back, TransitionPoint::Tail(a.id), tid, &mut ids()).unwrap();
        let tr = t.transition(other).unwrap().1;
        assert!(
            tr.kind == K::Move
                && tr.param(ClipEffect::MOVE_ROTATION_KEY) == 30.0
                && tr.param(ClipEffect::MOVE_DIRECTION_KEY) == 90.0
        );
    }
}
