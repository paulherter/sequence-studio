// SPDX-License-Identifier: GPL-3.0-or-later
// Swift tests: TransitionHeldFrameTests, TransitionPresetTests

use super::tests::{clip, cut, f, fd, ids, pair, range, resolved};
use super::*;
use TransitionAlignment::*;
use sq_core_model::effect_defaults::{PayloadError, PayloadReadError, TransitionPreset};
use sq_core_model::{
    Clip, EditError, SequenceFormat, Timeline, Track, TrackKind, Transition, TransitionAlignment, TransitionKind,
};
use sq_core_time::{EasingCurve, Id, Time, TimeRange};

const V: TrackKind = TrackKind::Video;

/// Clip `n` playing 60 frames from source frame `from` of a 300-frame media.
fn c(n: u128, start: i64, from: i64) -> Clip {
    clip(n, start, from, 60, 300, V)
}

fn two(a: Clip, b: Clip) -> (Timeline, Clip, Clip) {
    pair(V, Some(a), Some(b))
}

fn dissolve(t: &mut Timeline, a: &Clip, b: &Clip, frames: i64, al: TransitionAlignment) -> Result<Id, EditError> {
    cut(t, TransitionKind::CrossDissolve, a, b, frames, al)
}

/// A centered transition as an older project stores it (no apply-time alignment pick): appended directly.
fn stored(t: &mut Timeline, a: &Clip, b: &Clip, frames: i64) {
    t.tracks[0].transitions.push(Transition::new(
        Id::from_u128(50),
        TransitionKind::CrossDissolve,
        f(frames),
        Some(a.id),
        Some(b.id),
    ));
}

mod held_frames {
    use super::*;

    #[test]
    fn stored_centred_transition_with_no_outgoing_tail_still_holds_after_the_cut() {
        // A ends exactly at the end of its media (no tail); B has 30 frames of head handle. Old projects: unchanged.
        let (mut t, a, b) = two(c(1, 0, 240), c(2, 60, 30));
        stored(&mut t, &a, &b, 20);
        let r = &resolved(&t)[0];
        assert!(r.alignment == Center && r.span == range(50, 20));
        assert!(r.held_frames() == 10 && r.held_after == 10 && r.held_before == 0 && r.is_held() && r.is_clamped());
    }

    #[test]
    fn stored_centred_transition_with_no_incoming_head_still_holds_before_the_cut() {
        let (mut t, a, b) = two(c(1, 0, 30), c(2, 60, 0));
        stored(&mut t, &a, &b, 20);
        let r = &resolved(&t)[0];
        assert!(r.span == range(50, 20) && r.held_frames() == 10 && r.held_before == 10 && r.is_clamped());
    }

    #[test]
    fn centred_apply_with_no_outgoing_tail_ends_at_the_cut() {
        // Media only on the incoming side, so the whole transition sits before the cut on B's head handle.
        let (mut t, a, b) = two(c(1, 0, 240), c(2, 60, 30));
        dissolve(&mut t, &a, &b, 20, Center).unwrap();
        let r = &resolved(&t)[0];
        assert!(r.alignment == EndAtCut && r.span == range(40, 20) && !r.is_held() && !r.is_clamped());
    }

    #[test]
    fn centred_apply_with_no_incoming_head_starts_at_the_cut() {
        let (mut t, a, b) = two(c(1, 0, 30), c(2, 60, 0));
        dissolve(&mut t, &a, &b, 20, Center).unwrap();
        let r = &resolved(&t)[0];
        assert!(r.alignment == StartAtCut && r.span == range(60, 20) && !r.is_held());
    }

    #[test]
    fn one_sided_handle_too_short_for_the_move_falls_back_to_the_centred_hold() {
        // A no tail, B only 5 frames of head: End at Cut would give 5 frames, so it stays centered at the length the small
        // handle allows.
        let (mut t, a, b) = two(c(1, 0, 240), c(2, 60, 5));
        dissolve(&mut t, &a, &b, 20, Center).unwrap();
        let r = &resolved(&t)[0];
        assert!(r.alignment == Center && r.span == range(55, 11) && r.held_after == 6 && r.held_before == 0);
    }

    #[test]
    fn real_handles_are_not_marked() {
        let (mut t, a, b) = two(c(1, 0, 30), c(2, 60, 30));
        dissolve(&mut t, &a, &b, 20, Center).unwrap();
        let r = &resolved(&t)[0];
        assert!(r.alignment == Center && r.held_frames() == 0 && !r.is_held() && !r.is_clamped());
    }

    #[test]
    fn small_but_non_zero_handle_still_clamps() {
        let (mut t, a, b) = two(c(1, 0, 30), c(2, 60, 5));
        dissolve(&mut t, &a, &b, 30, Center).unwrap();
        let r = &resolved(&t)[0];
        assert!(r.held_frames() == 0 && r.span.duration == f(11));
    }

    #[test]
    fn both_sides_empty_hold_both_edge_frames() {
        // Whole clips end to end: no media beyond the cut on either side. Applied at the full length, centered.
        let (mut t, a, b) = two(c(1, 0, 240), c(2, 60, 0));
        dissolve(&mut t, &a, &b, 20, Center).unwrap();
        let r = resolved(&t).remove(0);
        assert!(r.alignment == Center && r.span == range(50, 20) && r.span.duration == r.requested_duration);
        assert!(r.held_before == 10 && r.held_after == 10 && r.held_frames() == 20 && r.is_clamped());
        // Both clips read their edge frame there (Clip::source_time clamps to the media edge).
        assert_eq!(a.source_time(f(65), fd()), f(299));
        assert_eq!(b.source_time(f(55), fd()), Time::ZERO);
        assert_eq!(t.max_transition_frames(r.id), 120, "only the clips bound it");
    }

    #[test]
    fn both_sides_empty_honour_explicit_alignments() {
        let (mut t, a, b) = two(c(1, 0, 240), c(2, 60, 0));
        dissolve(&mut t, &a, &b, 12, StartAtCut).unwrap();
        let r = &resolved(&t)[0];
        assert!(r.span == range(60, 12) && r.held_after == 12 && r.held_before == 0);
        dissolve(&mut t, &a, &b, 12, EndAtCut).unwrap();
        let r = &resolved(&t)[0];
        assert!(r.span == range(48, 12) && r.held_before == 12 && r.held_after == 0);
    }

    #[test]
    fn clips_shorter_than_the_transition_bound_it_even_when_held() {
        // 10-frame whole clips, 30 frames asked: the transition spans both clips entirely (20 frames), no more.
        let (mut t, a, b) = two(clip(1, 0, 290, 10, 300, V), clip(2, 10, 0, 10, 300, V));
        dissolve(&mut t, &a, &b, 30, Center).unwrap();
        let r = &resolved(&t)[0];
        assert!(r.span == range(0, 20) && r.held_before == 10 && r.held_after == 10);
    }

    #[test]
    fn apply_at_every_cut_of_whole_clips_succeeds() {
        let cs: Vec<Clip> = (0..4).map(|i| clip(1 + i as u128, i * 60, 0, 60, 60, V)).collect();
        let mut track = Track::new(Id::from_u128(9), V);
        for x in &cs {
            track.overwrite(x.clone(), &mut ids()).unwrap();
        }
        let mut t = Timeline::new(Id::from_u128(8), "t", SequenceFormat::new(fd()), vec![track]);
        for i in 0..3 {
            let p = TransitionPoint::Cut { outgoing: cs[i].id, incoming: cs[i + 1].id };
            t.add_transition_at(p, TransitionKind::CrossDissolve, t.tracks[0].id, f(30), Center, &mut ids()).unwrap();
        }
        let rs = resolved(&t);
        assert!(rs.len() == 3 && rs.iter().all(|r| r.span.duration == f(30) && r.held_frames() == 30));
    }

    #[test]
    fn audio_transitions_never_hold() {
        let ac = |n, start, from| clip(n, start, from, 60, 300, TrackKind::Audio);
        let (mut t, a, b) = pair(TrackKind::Audio, Some(ac(1, 0, 240)), Some(ac(2, 60, 30)));
        let new = |t: &Timeline, a: &Clip, b: &Clip| NewTransition {
            kind: TransitionKind::ConstantPower,
            track: t.tracks[0].id,
            outgoing: Some(a.id),
            incoming: Some(b.id),
            duration: f(20),
            alignment: Center,
            custom_before: Time::ZERO,
        };
        assert_eq!(t.add_transition(&new(&t, &a, &b), &mut ids()), Err(EditError::InsufficientMedia));
        let (mut u, c1, d) = pair(TrackKind::Audio, Some(ac(1, 0, 240)), Some(ac(2, 60, 0)));
        assert_eq!(u.add_transition(&new(&u, &c1, &d), &mut ids()), Err(EditError::InsufficientMedia));
    }

    #[test]
    fn start_at_cut_with_no_tail_holds_the_whole_span() {
        let (mut t, a, b) = two(c(1, 0, 240), c(2, 60, 30));
        dissolve(&mut t, &a, &b, 12, StartAtCut).unwrap();
        let r = &resolved(&t)[0];
        assert!(r.span == range(60, 12) && r.held_frames() == 12 && r.held_after == 12);
    }

    #[test]
    fn source_time_outside_the_clip_holds_the_media_edges() {
        let a = c(1, 0, 240); // media 300 frames, plays 240..300
        assert_eq!(a.source_time(f(70), fd()), f(299)); // past the end: last frame
        assert_eq!(a.source_time(f(50), fd()), f(290)); // inside: unchanged
        let b = c(2, 60, 0);
        assert_eq!(b.source_time(f(50), fd()), Time::ZERO); // before the start: first frame
    }

    #[test]
    fn held_frame_is_the_clips_own_edge_frame_at_200_percent() {
        // A plays source 180..300 at 200 %: 60 timeline frames, last frame shows source 298 (not the media's 299).
        let mut a = clip(1, 0, 180, 120, 300, V);
        a.speed = sq_core_model::ClipSpeed::from_percent(200.0);
        assert!(a.duration() == f(60) && a.tail_room() == Some(Time::ZERO));
        for t in [59, 65, 60] {
            assert_eq!(a.source_time(f(t), fd()), f(298));
        }
    }

    #[test]
    fn reversed_outgoing_without_tail_holds_its_last_frame() {
        // Reversed A plays source 0..60 backwards: its tail is the media start, so after the cut it holds source 0.
        let mut a = clip(1, 0, 0, 60, 300, V);
        a.reversed = true;
        let (mut t, a, b) = two(a, c(2, 60, 30));
        stored(&mut t, &a, &b, 20);
        let r = &resolved(&t)[0];
        assert_eq!(r.held_after, 10);
        assert_eq!(a.source_time(f(69), fd()), a.source_time(f(59), fd()));
    }

    #[test]
    fn both_sides_held_around_a_short_middle_clip_share_its_frames() {
        // A | M (10 frames, whole media) | B, all whole clips. M's frames are budgeted between its two transitions: the first
        // takes all 10 after its cut, the second gets what is left (M's last frame held) and never overlaps.
        let (a, m, b) = (c(1, 0, 240), clip(2, 60, 0, 10, 10, V), c(3, 70, 0));
        let mut track = Track::new(Id::from_u128(9), V);
        for x in [&a, &m, &b] {
            track.overwrite(x.clone(), &mut ids()).unwrap();
        }
        let mut t = Timeline::new(Id::from_u128(8), "t", SequenceFormat::new(fd()), vec![track]);
        let tid = t.tracks[0].id;
        let at = |o: &Clip, i: &Clip| TransitionPoint::Cut { outgoing: o.id, incoming: i.id };
        let first =
            t.add_transition_at(at(&a, &m), TransitionKind::CrossDissolve, tid, f(20), Center, &mut ids()).unwrap();
        let second =
            t.add_transition_at(at(&m, &b), TransitionKind::CrossDissolve, tid, f(20), Center, &mut ids()).unwrap();
        let rs = resolved(&t);
        let r1 = rs.iter().find(|r| r.id == first).unwrap();
        let r2 = rs.iter().find(|r| r.id == second).unwrap();
        assert!(r1.span == range(50, 20) && r1.held_before == 10 && r1.held_after == 10);
        assert!(
            r1.span.end() <= r2.span.start && r2.before == Time::ZERO && r2.held_after == r2.after.frame_index(fd())
        );
        assert!(r1.after + r2.before <= m.duration());
    }

    #[test]
    fn sub_frame_handle_counts_as_no_handle() {
        // B starts half a frame into its media: less than one whole frame of head handle, so it holds like zero.
        let mut b = c(2, 60, 0);
        b.source = TimeRange::new(Time::new(1, 60), f(60));
        let (mut t, a, b) = two(c(1, 0, 240), b);
        dissolve(&mut t, &a, &b, 20, Center).unwrap();
        let r = &resolved(&t)[0];
        assert!(r.span == range(50, 20) && r.held_before == 10 && r.held_after == 10);
        assert_eq!(b.source_time(f(55), fd()), Time::new(1, 60), "B's own first frame, not media frame 0");
    }

    #[test]
    fn reversed_clip_before_its_start_holds_inside_the_media() {
        // Reversed B plays source 240..300 backwards: its head is the media end, so a held head reads the last frame.
        let mut b = c(2, 60, 240);
        b.reversed = true;
        assert_eq!(b.source_time(f(60), fd()), f(299));
        assert_eq!(b.source_time(f(50), fd()), f(299)); // before the start: stays on the last frame
    }
}

mod presets {
    use super::*;

    fn fixture() -> (Timeline, Id, Clip, Clip) {
        let (mut t, a, b) = two(c(1, 0, 30), c(2, 60, 30));
        let id = cut(&mut t, TransitionKind::Push, &a, &b, 12, Center).unwrap();
        let look = TransitionChange {
            easing: Some(EasingCurve::fast_start()),
            direction: Some(sq_core_model::TransitionDirection::Up),
            motion_blur: Some(1.5),
            ..TransitionChange::default()
        };
        t.set_transition(id, &look).unwrap();
        (t, id, a, b)
    }

    #[test]
    fn capture_takes_kind_duration_easing_and_params() {
        let (t, id, ..) = fixture();
        let p = TransitionPreset::capture(&t.transition(id).unwrap().1);
        assert!(p.kind == TransitionKind::Push && p.duration == f(12));
        assert!(
            p.easing == EasingCurve::fast_start()
                && p.direction == sq_core_model::TransitionDirection::Up
                && p.motion_blur == 1.5
        );
        assert_eq!(p.alignment, Center);
    }

    #[test]
    fn custom_alignment_is_saved_as_center() {
        let mut tr = Transition::new(
            Id::from_u128(5),
            TransitionKind::CrossDissolve,
            f(10),
            Some(Id::from_u128(1)),
            Some(Id::from_u128(2)),
        );
        tr.alignment = Custom;
        tr.custom_before = f(3);
        assert_eq!(TransitionPreset::capture(&tr).alignment, Center);
        tr.alignment = EndAtCut;
        assert_eq!(TransitionPreset::capture(&tr).alignment, EndAtCut);
    }

    #[test]
    fn custom_alignment_in_payload_is_normalized_on_decode() {
        let p = TransitionPreset::new(TransitionKind::CrossDissolve, f(10));
        let mut json: serde_json::Value = serde_json::from_slice(&p.payload().unwrap()).unwrap();
        json["alignment"] = serde_json::json!("custom");
        let data = serde_json::to_vec(&json).unwrap();
        assert_eq!(TransitionPreset::from_payload(&data, 1).unwrap().alignment, Center);
    }

    #[test]
    fn payload_round_trips_and_rejects_newer_version() {
        let (t, id, ..) = fixture();
        let p = TransitionPreset::capture(&t.transition(id).unwrap().1);
        let data = p.payload().unwrap();
        assert_eq!(TransitionPreset::from_payload(&data, TransitionPreset::PAYLOAD_VERSION).unwrap(), p);
        let err = TransitionPreset::from_payload(&data, 2).unwrap_err();
        assert!(matches!(err, PayloadReadError::Version(PayloadError::NewerVersion { found: 2, supported: 1 })));
    }

    #[test]
    fn apply_to_existing_transition_changes_kind_duration_and_style() {
        let (mut t, id, ..) = fixture();
        let mut p = TransitionPreset::new(TransitionKind::SoftWipe, f(20));
        p.alignment = StartAtCut;
        p.easing = EasingCurve::ease_in();
        p.direction = sq_core_model::TransitionDirection::Down;
        p.softness = 0.25;
        p.motion_blur = 0.0;
        t.apply_transition_preset(&p, id).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert!(tr.kind == TransitionKind::SoftWipe && tr.duration == f(20) && tr.alignment == StartAtCut);
        assert!(
            tr.effective_easing() == EasingCurve::ease_in()
                && tr.effective_direction() == sq_core_model::TransitionDirection::Down
        );
        assert!(tr.effective_softness() == 0.25 && tr.effective_motion_blur() == 0.0);
    }

    #[test]
    fn apply_refuses_wrong_track_kind() {
        let (mut t, id, ..) = fixture();
        let audio = TransitionPreset::new(TransitionKind::ConstantPower, f(10));
        assert_eq!(t.apply_transition_preset(&audio, id), Err(EditError::WrongTrackKind));
        assert_eq!(t.transition(id).unwrap().1.kind, TransitionKind::Push, "untouched");
    }

    #[test]
    fn add_at_cut_builds_the_transition_from_the_preset() {
        let (mut t, a, b) = two(c(1, 0, 30), c(2, 60, 30));
        let mut p = TransitionPreset::new(TransitionKind::Slide, f(8));
        p.easing = EasingCurve::ease_out();
        p.direction = sq_core_model::TransitionDirection::Left;
        p.motion_blur = 0.5;
        let point = TransitionPoint::Cut { outgoing: a.id, incoming: b.id };
        let id = t.add_transition_from_preset(&p, point, t.tracks[0].id, &mut ids()).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert!(tr.kind == TransitionKind::Slide && tr.duration == f(8));
        assert!(tr.effective_easing() == EasingCurve::ease_out() && tr.effective_motion_blur() == 0.5);
    }

    #[test]
    fn capture_carries_the_border_and_apply_replaces_it() {
        let (mut t, id, ..) = fixture();
        assert_eq!(TransitionPreset::capture(&t.transition(id).unwrap().1).border_width, None);
        t.set_transition(
            id,
            &TransitionChange {
                border_width: Some(0.03),
                border_color: Some(vec![255, 0, 0]),
                ..TransitionChange::default()
            },
        )
        .unwrap();
        let p = TransitionPreset::capture(&t.transition(id).unwrap().1);
        assert!(p.border_width == Some(0.03) && p.border_color == Some(vec![255, 0, 0]));
        let old = serde_json::to_string(&TransitionPreset::new(TransitionKind::Push, f(10))).unwrap();
        assert!(!old.contains("border"));
        // A preset without a border takes the target's old border away.
        t.apply_transition_preset(&TransitionPreset::new(TransitionKind::Push, f(12)), id).unwrap();
        assert_eq!(t.tracks[0].transitions[0].border_width, None);
        assert_eq!(t.tracks[0].transitions[0].border_color, None);
    }

    #[test]
    fn the_init_rules_drop_what_a_preset_cannot_keep() {
        let mut p = TransitionPreset::new(TransitionKind::Push, f(10));
        p.alignment = Custom;
        p.reversed = Some(false);
        p.border_width = Some(0.0);
        p.border_color = Some(vec![1, 2, 3]);
        let n = p.normalized();
        assert!(n.alignment == Center && n.reversed.is_none() && n.border_width.is_none() && n.border_color.is_none());
        assert_eq!(TransitionPreset::new(TransitionKind::Push, f(10)).track_kind(), TrackKind::Video);
    }

    #[test]
    fn reset_goes_back_to_the_user_default_or_the_factory_look() {
        let (mut t, id, ..) = fixture();
        t.reset_transition(id, None, f(24)).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert!(tr.duration == f(24) && tr.direction.is_none() && tr.motion_blur.is_none());
        // Push's factory look is a long ease-out written into the transition.
        assert_eq!(tr.easing, Some(EasingCurve::ease_out_100()));
        let mut d = TransitionPreset::new(TransitionKind::Push, f(18));
        d.softness = 0.2;
        t.reset_transition(id, Some(&d), f(24)).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert!(tr.duration == f(18) && tr.softness == Some(0.2));
        // A default of another kind is ignored.
        let other = TransitionPreset::new(TransitionKind::Slide, f(5));
        t.reset_transition(id, Some(&other), f(24)).unwrap();
        assert_eq!(t.transition(id).unwrap().1.duration, f(24));
    }
}
