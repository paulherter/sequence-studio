// SPDX-License-Identifier: GPL-3.0-or-later
// Swift tests: TransitionTests (model, mix, budget, split), TransitionHeldFrameTests (resolution), ElementTransitionTests

use super::*;
use sq_core_model::{
    Clip, ClipEdge, ClipEffect, ClipSpeed, EditError, SequenceFormat, Timeline, Track, TrackKind, Transition,
    TransitionAlignment, TransitionKind,
};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};

pub(crate) fn fd() -> Time {
    Time::new(1, 30)
}

pub(crate) fn f(n: i64) -> Time {
    Time::new(n, 30)
}

pub(crate) fn range(start: i64, frames: i64) -> TimeRange {
    TimeRange::new(f(start), f(frames))
}

/// Clip `n` of `frames` frames of source from source frame `from`, media `media` frames long.
pub(crate) fn clip(n: u128, start: i64, from: i64, frames: i64, media: i64, kind: TrackKind) -> Clip {
    let mut c = Clip::new(Id::from_u128(n), "c", Id::from_u128(1000 + n), kind, range(from, frames), f(start));
    c.media_duration = Some(f(media));
    c
}

/// Default clip: 60 frames from source frame 30 of a 300-frame media.
pub(crate) fn plain(n: u128, start: i64, kind: TrackKind) -> Clip {
    clip(n, start, 30, 60, 300, kind)
}

/// One track with A at 0..60 and B at 60..120, both with 30 frames of head handle and lots of tail.
pub(crate) fn pair(kind: TrackKind, a: Option<Clip>, b: Option<Clip>) -> (Timeline, Clip, Clip) {
    let ca = a.unwrap_or_else(|| plain(1, 0, kind));
    let cb = b.unwrap_or_else(|| plain(2, 60, kind));
    let mut ids = SequentialIds::default();
    let mut t = Track::new(Id::from_u128(900), kind);
    t.overwrite(ca.clone(), &mut ids).unwrap();
    t.overwrite(cb.clone(), &mut ids).unwrap();
    (Timeline::new(Id::from_u128(901), "t", SequenceFormat::new(fd()), vec![t]), ca, cb)
}

pub(crate) fn video_pair() -> (Timeline, Clip, Clip) {
    pair(TrackKind::Video, None, None)
}

/// Ids for edits made by the tests: unique over the whole run and never equal to a clip or track id.
pub(crate) struct TestIds;

impl IdSource for TestIds {
    fn next_id(&mut self) -> Id {
        static NEXT: AtomicU64 = AtomicU64::new(10_000);
        Id::from_u128(u128::from(NEXT.fetch_add(1, Ordering::Relaxed)))
    }
}

pub(crate) fn ids() -> TestIds {
    TestIds
}

/// Applies a transition at the cut of `a` and `b`.
pub(crate) fn cut(
    t: &mut Timeline,
    kind: TransitionKind,
    a: &Clip,
    b: &Clip,
    frames: i64,
    alignment: TransitionAlignment,
) -> Result<Id, EditError> {
    edge(t, kind, Some(a.id), Some(b.id), frames, alignment)
}

pub(crate) fn edge(
    t: &mut Timeline,
    kind: TransitionKind,
    o: Option<Id>,
    i: Option<Id>,
    frames: i64,
    alignment: TransitionAlignment,
) -> Result<Id, EditError> {
    let new = NewTransition {
        kind,
        track: t.tracks[0].id,
        outgoing: o,
        incoming: i,
        duration: f(frames),
        alignment,
        custom_before: Time::ZERO,
    };
    t.add_transition(&new, &mut ids())
}

pub(crate) fn dissolve(t: &mut Timeline, a: &Clip, b: &Clip, frames: i64) -> Id {
    cut(t, TransitionKind::CrossDissolve, a, b, frames, TransitionAlignment::Center).unwrap()
}

pub(crate) fn resolved(t: &Timeline) -> Vec<ResolvedTransition> {
    t.resolved_transitions_on(t.tracks[0].id)
}

fn align(t: &mut Timeline, id: Id, alignment: TransitionAlignment, custom_before: Option<i64>) {
    let c = TransitionChange {
        alignment: Some(alignment),
        custom_before: custom_before.map(f),
        ..TransitionChange::default()
    };
    t.set_transition(id, &c).unwrap();
}

fn set_duration(t: &mut Timeline, id: Id, d: Time) {
    t.set_transition(id, &TransitionChange { duration: Some(d), ..TransitionChange::default() }).unwrap();
}

mod model {
    use super::*;
    use TransitionAlignment::*;

    #[test]
    fn kinds_belong_to_a_track_kind() {
        assert!(TransitionKind::CrossDissolve.track_kind() == TrackKind::Video);
        assert!(TransitionKind::DipToWhite.track_kind() == TrackKind::Video);
        assert!(TransitionKind::ConstantPower.track_kind() == TrackKind::Audio);
        assert!(TransitionKind::ConstantGain.track_kind() == TrackKind::Audio);
        assert_eq!(TransitionKind::default_kind_for(TrackKind::Video), TransitionKind::CrossDissolve);
        assert_eq!(TransitionKind::default_kind_for(TrackKind::Audio), TransitionKind::ConstantPower);
    }

    #[test]
    fn every_kind_has_exactly_one_track_kind_listing() {
        let all = ALL_TRANSITION_KINDS.len();
        assert_eq!(all, 52);
        assert_eq!(
            TransitionKind::kinds_for(TrackKind::Video).len() + TransitionKind::kinds_for(TrackKind::Audio).len(),
            all
        );
        assert_eq!(TransitionKind::kinds_for(TrackKind::Audio).len(), 3);
    }

    #[test]
    fn centred_span_straddles_the_cut() {
        let (mut t, a, b) = video_pair();
        let id = dissolve(&mut t, &a, &b, 20);
        let r = &resolved(&t)[0];
        assert!(r.id == id && r.cut == f(60));
        assert_eq!(r.span, range(50, 20));
        assert!(r.before == f(10) && r.after == f(10) && !r.is_clamped());
    }

    #[test]
    fn odd_duration_gives_the_extra_frame_after_the_cut() {
        let (mut t, a, b) = video_pair();
        dissolve(&mut t, &a, &b, 15);
        let r = &resolved(&t)[0];
        assert!(r.before == f(7) && r.after == f(8) && r.span.start == f(53));
    }

    #[test]
    fn alignments() {
        let (mut t, a, b) = video_pair();
        let id = cut(&mut t, TransitionKind::CrossDissolve, &a, &b, 20, StartAtCut).unwrap();
        assert_eq!(resolved(&t)[0].span, range(60, 20));
        align(&mut t, id, EndAtCut, None);
        assert_eq!(resolved(&t)[0].span, range(40, 20));
        align(&mut t, id, Custom, Some(5));
        let r = &resolved(&t)[0];
        assert!(r.span == range(55, 20) && r.before == f(5) && r.after == f(15));
        // a custom offset never leaves the cut: before is clamped to the duration
        align(&mut t, id, Custom, Some(500));
        assert_eq!(resolved(&t)[0].before, f(20));
    }

    #[test]
    fn handles_limit_the_duration() {
        // B starts at source frame 5: only 5 frames of head handle, so a centered transition holds at most 11 frames.
        let (mut t, a, b) = pair(TrackKind::Video, None, Some(clip(2, 60, 5, 60, 300, TrackKind::Video)));
        dissolve(&mut t, &a, &b, 30);
        let r = &resolved(&t)[0];
        assert!(!r.is_clamped(), "the stored duration was fitted when it was applied");
        assert!(r.before <= f(5) && r.after >= r.before && r.span.duration == f(11));
        assert_eq!(r.span, range(55, 11));
    }

    #[test]
    fn no_handles_holds_edge_frames_for_video_and_refuses_audio() {
        // A uses the end of its media and B the start: no media beyond either side of the cut.
        let a = clip(1, 0, 240, 60, 300, TrackKind::Video);
        let (mut t, a, b) = pair(TrackKind::Video, Some(a), Some(clip(2, 60, 0, 60, 300, TrackKind::Video)));
        for al in [Center, StartAtCut, EndAtCut] {
            cut(&mut t, TransitionKind::CrossDissolve, &a, &b, 20, al).unwrap();
            let r = &resolved(&t)[0];
            assert!(r.span.duration == f(20) && r.held_frames() == 20 && r.alignment == al);
        }
        assert_eq!(t.tracks[0].transitions.len(), 1);
        let (ca, cb) = (clip(1, 0, 240, 60, 300, TrackKind::Audio), clip(2, 60, 0, 60, 300, TrackKind::Audio));
        let (mut u, c, d) = pair(TrackKind::Audio, Some(ca), Some(cb));
        assert_eq!(cut(&mut u, TransitionKind::ConstantPower, &c, &d, 20, Center), Err(EditError::InsufficientMedia));
    }

    #[test]
    fn start_at_cut_only_needs_the_outgoing_tail() {
        let (mut t, a, b) = pair(TrackKind::Video, None, Some(clip(2, 60, 0, 60, 300, TrackKind::Video)));
        cut(&mut t, TransitionKind::CrossDissolve, &a, &b, 20, StartAtCut).unwrap();
        assert_eq!(resolved(&t)[0].span.duration, f(20));
    }

    #[test]
    fn handles_respect_speed_and_reverse() {
        // A plays 200 %: its 60 timeline frames are 120 source frames (source 0..120), media 150 -> 30 source frames
        // = 15 timeline frames of tail handle.
        let mut fast = clip(1, 0, 0, 120, 150, TrackKind::Video);
        fast.speed = ClipSpeed::from_percent(200.0);
        let (mut t, a, b) = pair(TrackKind::Video, Some(fast), None);
        assert_eq!(a.timeline().duration, f(60));
        cut(&mut t, TransitionKind::CrossDissolve, &a, &b, 60, StartAtCut).unwrap();
        assert_eq!(resolved(&t)[0].span.duration, f(15));
        // Reversed A: the tail plays toward the start of its source, so the handle is the source before source.start.
        let mut rev = clip(1, 0, 12, 60, 300, TrackKind::Video);
        rev.reversed = true;
        let (mut t2, a2, b2) = pair(TrackKind::Video, Some(rev), None);
        cut(&mut t2, TransitionKind::CrossDissolve, &a2, &b2, 60, StartAtCut).unwrap();
        assert_eq!(resolved(&t2)[0].span.duration, f(12));
    }

    #[test]
    fn single_sided_transitions() {
        let (mut t, a, _) = video_pair();
        edge(&mut t, TransitionKind::DipToBlack, None, Some(a.id), 12, Center).unwrap();
        edge(&mut t, TransitionKind::DipToBlack, Some(a.id), None, 200, Center).unwrap(); // longer than the clip
        let rs = resolved(&t);
        let head = rs.iter().find(|r| r.outgoing.is_none()).unwrap();
        let tail = rs.iter().find(|r| r.incoming.is_none()).unwrap();
        assert_eq!(head.span, range(0, 12));
        assert_eq!(tail.span, range(12, 48), "the clip also holds the 12-frame head fade");
    }

    #[test]
    fn second_apply_replaces_instead_of_stacking() {
        let (mut t, a, b) = video_pair();
        let first = dissolve(&mut t, &a, &b, 20);
        let second = cut(&mut t, TransitionKind::DipToBlack, &a, &b, 10, Center).unwrap();
        assert!(t.tracks[0].transitions.len() == 1 && second != first);
        assert_eq!(t.tracks[0].transitions[0].kind, TransitionKind::DipToBlack);
    }

    #[test]
    fn one_transition_per_clip_edge() {
        let (mut t, a, b) = video_pair();
        let dip = TransitionKind::DipToBlack;
        edge(&mut t, dip, Some(a.id), None, 10, Center).unwrap(); // tail of A
        edge(&mut t, dip, None, Some(b.id), 10, Center).unwrap(); // head of B
        edge(&mut t, dip, None, Some(a.id), 10, Center).unwrap(); // head of A: elsewhere
        assert_eq!(t.tracks[0].transitions.len(), 3);
        dissolve(&mut t, &a, &b, 10);
        // the cut replaced the tail of A and the head of B; the head of A stays
        let trs = &t.tracks[0].transitions;
        assert_eq!(trs.len(), 2);
        assert!(trs.iter().any(|x| x.outgoing.is_none() && x.incoming == Some(a.id)));
        assert!(trs.iter().any(|x| x.outgoing == Some(a.id) && x.incoming == Some(b.id)));
        edge(&mut t, TransitionKind::DipToWhite, Some(a.id), None, 10, Center).unwrap(); // tail of A replaces the cut
        assert!(!t.tracks[0].transitions.iter().any(|x| x.incoming == Some(b.id)));
    }

    #[test]
    fn refusals() {
        let (mut t, a, b) = video_pair();
        assert_eq!(cut(&mut t, TransitionKind::ConstantPower, &a, &b, 10, Center), Err(EditError::WrongTrackKind));
        let (mut gap, ga, gb) = pair(TrackKind::Video, None, Some(plain(2, 70, TrackKind::Video)));
        assert_eq!(cut(&mut gap, TransitionKind::CrossDissolve, &ga, &gb, 10, Center), Err(EditError::NotACut));
        t.tracks[0].is_locked = true;
        assert_eq!(cut(&mut t, TransitionKind::CrossDissolve, &a, &b, 10, Center), Err(EditError::TrackLocked));
        let new = NewTransition {
            kind: TransitionKind::CrossDissolve,
            track: Id::from_u128(77),
            outgoing: Some(a.id),
            incoming: Some(b.id),
            duration: f(10),
            alignment: Center,
            custom_before: Time::ZERO,
        };
        assert_eq!(t.add_transition(&new, &mut ids()), Err(EditError::ClipNotFound));
    }

    #[test]
    fn duration_is_snapped_to_whole_frames() {
        let (mut t, a, b) = video_pair();
        let new = NewTransition {
            kind: TransitionKind::CrossDissolve,
            track: t.tracks[0].id,
            outgoing: Some(a.id),
            incoming: Some(b.id),
            duration: Time::new(41, 60), // 20.5 frames
            alignment: Center,
            custom_before: Time::ZERO,
        };
        t.add_transition(&new, &mut ids()).unwrap();
        assert_eq!(t.tracks[0].transitions[0].duration, f(20));
        let id = t.tracks[0].transitions[0].id;
        set_duration(&mut t, id, f(0));
        assert_eq!(t.tracks[0].transitions[0].duration, f(1));
    }

    #[test]
    fn set_duration_clamps_to_available_media() {
        let (mut t, a, b) = pair(TrackKind::Video, None, Some(clip(2, 60, 8, 60, 300, TrackKind::Video)));
        let id = dissolve(&mut t, &a, &b, 10);
        set_duration(&mut t, id, f(100));
        assert_eq!(t.tracks[0].transitions[0].duration, f(17), "before = 8 (B's head handle), after = 9");
        assert!(!resolved(&t)[0].is_clamped());
    }

    #[test]
    fn linked_audio_and_video_transitions_are_independent() {
        let mut seq = SequentialIds::default();
        let (va, vb) = (plain(1, 0, TrackKind::Video), plain(2, 60, TrackKind::Video));
        let (aa, ab) = (plain(3, 0, TrackKind::Audio), plain(4, 60, TrackKind::Audio));
        let (mut v, mut au) =
            (Track::new(Id::from_u128(10), TrackKind::Video), Track::new(Id::from_u128(11), TrackKind::Audio));
        v.overwrite(va.clone(), &mut seq).unwrap();
        v.overwrite(vb.clone(), &mut seq).unwrap();
        au.overwrite(aa.clone(), &mut seq).unwrap();
        au.overwrite(ab.clone(), &mut seq).unwrap();
        let mut t = Timeline::new(Id::from_u128(20), "t", SequenceFormat::new(fd()), vec![v.clone(), au.clone()]);
        let add = |t: &mut Timeline, kind, track: Id, o: &Clip, i: &Clip, n| {
            let new = NewTransition {
                kind,
                track,
                outgoing: Some(o.id),
                incoming: Some(i.id),
                duration: f(n),
                alignment: Center,
                custom_before: Time::ZERO,
            };
            t.add_transition(&new, &mut ids()).unwrap()
        };
        add(&mut t, TransitionKind::CrossDissolve, v.id, &va, &vb, 20);
        assert!(t.resolved_transitions_on(au.id).is_empty());
        add(&mut t, TransitionKind::ConstantPower, au.id, &aa, &ab, 30);
        assert_eq!(t.resolved_transitions_on(v.id)[0].span.duration, f(20));
        assert_eq!(t.resolved_transitions_on(au.id)[0].span.duration, f(30));
        let audio_transition = t.tracks[1].transitions[0].id;
        t.remove_transition(audio_transition).unwrap();
        assert!(t.resolved_transitions_on(v.id).len() == 1 && t.resolved_transitions_on(au.id).is_empty());
    }

    #[test]
    fn nearest_edit_picks_cut_then_clip_edge() {
        let (mut t, a, b) = video_pair();
        let tr = t.tracks[0].id;
        assert_eq!(t.transition_point_near(f(55), tr), Some(TransitionPoint::Cut { outgoing: a.id, incoming: b.id }));
        assert_eq!(t.transition_point_near(f(3), tr), Some(TransitionPoint::Head(a.id)));
        assert_eq!(t.transition_point_near(f(118), tr), Some(TransitionPoint::Tail(b.id)));
        t.add_transition_at(
            TransitionPoint::Cut { outgoing: a.id, incoming: b.id },
            TransitionKind::CrossDissolve,
            tr,
            f(10),
            Center,
            &mut ids(),
        )
        .unwrap();
        assert_eq!(t.tracks[0].transitions.len(), 1);
    }

    #[test]
    fn default_duration_is_one_second_in_whole_frames() {
        assert_eq!(Timeline::default_transition_duration(Time::new(1001, 30000)), Time::new(1001, 30000) * 30);
        assert_eq!(Timeline::default_transition_duration(Time::new(1, 25)), Time::new(1, 25) * 25);
        assert_eq!(Timeline::default_transition_duration(Time::new(1, 24)), Time::new(1, 24) * 24);
    }

    #[test]
    fn full_resolution_agrees_with_the_models_prune() {
        // `Track::prune_transitions` (sq-core-model) keeps a transition exactly when `resolve` returns it.
        let (mut t, a, b) = pair(TrackKind::Video, None, Some(clip(2, 60, 0, 60, 60, TrackKind::Video)));
        dissolve(&mut t, &a, &b, 20);
        edge(&mut t, TransitionKind::DipToBlack, None, Some(a.id), 12, Center).unwrap();
        let mut stale = t.tracks[0].transitions[0].clone();
        stale.id = Id::from_u128(99);
        stale.incoming = Some(Id::from_u128(77));
        t.tracks[0].transitions.push(stale);
        let before: Vec<Id> =
            t.tracks[0].transitions.iter().filter(|x| t.tracks[0].resolve(x, fd()).is_some()).map(|x| x.id).collect();
        t.prune_transitions();
        let after: Vec<Id> = t.tracks[0].transitions.iter().map(|x| x.id).collect();
        assert_eq!(before, after);
        assert_eq!(after.len(), 2);
    }
}

mod mix {
    use super::*;

    #[test]
    fn cross_dissolve_weights_are_strictly_inside_and_sum_to_one() {
        let n = 10;
        let mut prev = 0.0;
        for i in 0..n {
            let w = TransitionMix::video_weight(i, n);
            assert!(w > prev && w < 1.0);
            prev = w;
            let m = TransitionMix::video(TransitionKind::CrossDissolve, w);
            assert!((m.outgoing + m.incoming - 1.0).abs() < 1e-12 && m.dip == 0.0);
        }
        assert_eq!(TransitionMix::video_weight(0, 1), 0.5);
    }

    #[test]
    fn dip_midpoint_is_fully_the_dip_colour() {
        let m = TransitionMix::video(TransitionKind::DipToBlack, 0.5);
        assert!(m.outgoing == 0.0 && m.incoming == 0.0 && m.dip == 1.0);
        let early = TransitionMix::video(TransitionKind::DipToWhite, 0.25);
        assert!((early.outgoing - 0.5).abs() < 1e-12 && early.incoming == 0.0 && (early.dip - 0.5).abs() < 1e-12);
        let late = TransitionMix::video(TransitionKind::DipToBlack, 0.75);
        assert!(late.outgoing == 0.0 && (late.incoming - 0.5).abs() < 1e-12);
        assert_eq!(TransitionMix::dip_color(TransitionKind::DipToWhite, None), [255, 255, 255]);
        assert_eq!(TransitionMix::dip_color(TransitionKind::DipToBlack, None), [0, 0, 0]);
    }

    #[test]
    fn audio_curves() {
        let cp0 = TransitionMix::audio_gains(TransitionKind::ConstantPower, 0.0);
        let cp1 = TransitionMix::audio_gains(TransitionKind::ConstantPower, 1.0);
        assert!(
            (cp0.0 - 1.0).abs() < 1e-12 && cp0.1.abs() < 1e-12 && cp1.0.abs() < 1e-12 && (cp1.1 - 1.0).abs() < 1e-12
        );
        for k in 0..=10 {
            let p = f64::from(k) * 0.1;
            let g = TransitionMix::audio_gains(TransitionKind::ConstantPower, p);
            assert!((g.0 * g.0 + g.1 * g.1 - 1.0).abs() < 1e-12);
            let l = TransitionMix::audio_gains(TransitionKind::ConstantGain, p);
            assert!((l.0 + l.1 - 1.0).abs() < 1e-12);
        }
        assert!((TransitionMix::audio_gains(TransitionKind::ConstantPower, 0.5).1 - 0.5f64.sqrt()).abs() < 1e-12);
    }

    #[test]
    fn envelope_follows_the_span() {
        let span = range(30, 30);
        let out = TransitionEnvelope { kind: TransitionKind::ConstantGain, span, role: EnvelopeRole::Outgoing };
        let inn = TransitionEnvelope { kind: TransitionKind::ConstantGain, span, role: EnvelopeRole::Incoming };
        assert!(out.gain(f(10)) == 1.0 && out.gain(f(70)) == 0.0);
        assert!(inn.gain(f(10)) == 0.0 && inn.gain(f(70)) == 1.0);
        assert!((out.gain(f(45)) - 0.5).abs() < 1e-12 && (inn.gain(f(45)) - 0.5).abs() < 1e-12);
    }
}

mod budget {
    use super::*;
    use TransitionAlignment::*;

    /// A 10-frame clip B between two long ones, with two 8-frame transitions on it (one on each edge).
    fn short_middle(kind: TrackKind) -> (Timeline, Clip, Clip, Clip) {
        let mut ids = SequentialIds::default();
        let (a, b, c) = (plain(1, 0, kind), clip(2, 60, 30, 10, 300, kind), plain(3, 70, kind));
        let mut t = Track::new(Id::from_u128(9), kind);
        for x in [&a, &b, &c] {
            t.overwrite(x.clone(), &mut ids).unwrap();
        }
        let mut tl = Timeline::new(Id::from_u128(8), "t", SequenceFormat::new(fd()), vec![t]);
        let k = if kind == TrackKind::Video { TransitionKind::CrossDissolve } else { TransitionKind::ConstantPower };
        cut(&mut tl, k, &a, &b, 8, StartAtCut).unwrap();
        cut(&mut tl, k, &b, &c, 8, EndAtCut).unwrap();
        (tl, a, b, c)
    }

    #[test]
    fn a_clip_never_holds_more_transition_frames_than_its_length() {
        let (t, _, b, _) = short_middle(TrackKind::Video);
        let rs = resolved(&t);
        assert_eq!(rs.len(), 2);
        let (head, tail) = (&rs[0], &rs[1]); // timeline order
        assert_eq!(head.span.duration, f(8), "the earlier one keeps its request");
        assert_eq!(tail.span.duration, f(2), "the later one gets the 2 frames left in B");
        assert!(head.after + tail.before <= b.timeline().duration);
    }

    #[test]
    fn video_and_audio_agree_on_the_clamped_spans() {
        let (v, ..) = short_middle(TrackKind::Video);
        let (au, ..) = short_middle(TrackKind::Audio);
        let spans = |t: &Timeline| resolved(t).iter().map(|r| r.span).collect::<Vec<_>>();
        assert_eq!(spans(&v), spans(&au));
    }

    #[test]
    fn setting_a_duration_on_the_later_transition_clamps_to_the_remainder() {
        let (mut t, ..) = short_middle(TrackKind::Video);
        let tid = t.tracks[0].transitions[1].id;
        set_duration(&mut t, tid, f(30));
        assert_eq!(resolved(&t)[1].span.duration, f(2));
        assert_eq!(t.tracks[0].transitions[1].duration, f(2));
    }
}

mod split {
    use super::*;
    use TransitionAlignment::Center;

    #[test]
    fn splitting_the_outgoing_clip_keeps_the_cut_transition_on_the_right_half() {
        let (mut t, a, b) = video_pair();
        dissolve(&mut t, &a, &b, 20);
        t.tracks[0].split(f(30), &mut ids()).unwrap();
        let rs = resolved(&t);
        assert!(rs.len() == 1 && rs[0].outgoing != Some(a.id) && rs[0].incoming == Some(b.id) && rs[0].cut == f(60));
        t.prune_transitions();
        assert_eq!(t.tracks[0].transitions.len(), 1);
    }

    #[test]
    fn splitting_a_clip_moves_its_tail_fade_to_the_right_half_and_keeps_the_head_fade() {
        let (mut t, a, _) = video_pair();
        let dip = TransitionKind::DipToBlack;
        edge(&mut t, dip, None, Some(a.id), 10, Center).unwrap();
        edge(&mut t, dip, Some(a.id), None, 10, Center).unwrap();
        t.tracks[0].split(f(30), &mut ids()).unwrap();
        let rs = resolved(&t);
        let (left, right) = (&t.tracks[0].clips()[0], &t.tracks[0].clips()[1]);
        assert_eq!(left.id, a.id);
        assert_eq!(
            rs.iter().find(|r| r.incoming == Some(a.id) && r.outgoing.is_none()).map(|r| r.span),
            Some(range(0, 10))
        );
        assert_eq!(
            rs.iter().find(|r| r.outgoing == Some(right.id) && r.incoming.is_none()).map(|r| r.span),
            Some(range(50, 10))
        );
        assert_eq!(rs.len(), 2);
    }
}

mod held {
    use super::*;
    use TransitionAlignment::*;

    #[test]
    fn a_centered_transition_moves_onto_the_side_that_has_media() {
        // No media before B's head (from 0): End at Cut would need the incoming head, Start at Cut needs the outgoing tail.
        let (t, a, b) = pair(TrackKind::Video, None, Some(clip(2, 60, 0, 60, 300, TrackKind::Video)));
        let tr = Transition::new(Id::from_u128(5), TransitionKind::CrossDissolve, f(20), Some(a.id), Some(b.id));
        assert_eq!(t.tracks[0].applied_alignment(&tr, fd()), StartAtCut);
        let (t2, a2, b2) = pair(TrackKind::Video, Some(clip(1, 0, 240, 60, 300, TrackKind::Video)), None);
        let tr2 = Transition::new(Id::from_u128(5), TransitionKind::CrossDissolve, f(20), Some(a2.id), Some(b2.id));
        assert_eq!(t2.tracks[0].applied_alignment(&tr2, fd()), EndAtCut);
        // Handles on both sides: the asked alignment stays.
        let (t3, a3, b3) = video_pair();
        let tr3 = Transition::new(Id::from_u128(5), TransitionKind::CrossDissolve, f(20), Some(a3.id), Some(b3.id));
        assert_eq!(t3.tracks[0].applied_alignment(&tr3, fd()), Center);
    }

    #[test]
    fn max_transition_frames_is_zero_for_a_gone_cut() {
        let (mut t, a, b) = video_pair();
        let id = dissolve(&mut t, &a, &b, 20);
        assert!(t.max_transition_frames(id) >= 20);
        assert_eq!(t.max_transition_frames(Id::from_u128(404)), 0);
    }
}

mod element {
    use super::*;
    use TransitionAlignment::Center;

    #[test]
    fn element_kinds_act_on_one_edge_only() {
        let (mut t, a, b) = video_pair();
        assert_eq!(cut(&mut t, TransitionKind::Move, &a, &b, 10, Center), Err(EditError::NotACut));
        let made = t
            .add_element_transitions(
                TransitionKind::Pop,
                t.tracks[0].id,
                a.id,
                &[ClipEdge::Head, ClipEdge::Tail],
                f(40),
                &mut ids(),
            )
            .unwrap();
        assert_eq!(made.len(), 2);
        // Both ends share the clip half and half: 60 frames -> at most 30 each.
        assert!(resolved(&t).iter().all(|r| r.span.duration == f(30)));
    }

    #[test]
    fn an_element_transition_sits_next_to_a_cut_transition() {
        let (mut t, a, b) = video_pair();
        dissolve(&mut t, &a, &b, 10);
        edge(&mut t, TransitionKind::Move, None, Some(b.id), 10, Center).unwrap();
        assert_eq!(t.tracks[0].transitions.len(), 2);
    }

    #[test]
    fn element_params_are_clamped_and_unknown_keys_refused() {
        let (mut t, a, _) = video_pair();
        let id = edge(&mut t, TransitionKind::Zoom, None, Some(a.id), 10, Center).unwrap();
        let key = ClipEffect::ZOOM_FROM_KEY.to_string();
        t.set_transition_params(id, &BTreeMap::from([(key.clone(), 99_999.0)]), false).unwrap();
        assert_eq!(t.tracks[0].transitions[0].params.as_ref().unwrap()[&key], 10_000.0);
        assert_eq!(
            t.set_transition_params(id, &BTreeMap::from([("nope".to_string(), 1.0)]), false),
            Err(EditError::InvalidFormat)
        );
        assert_eq!(t.tracks[0].transitions[0].param(&key), 10_000.0);
    }

    #[test]
    fn the_synthesized_motion_effect_plays_in_at_the_head_and_out_at_the_tail() {
        let (mut t, a, _) = video_pair();
        let head = edge(&mut t, TransitionKind::Pop, None, Some(a.id), 10, Center).unwrap();
        let tr = t.transition(head).unwrap().1;
        let e = tr.element_effect(0.5, 0.0).unwrap();
        assert_eq!(e.kind, ClipEffect::POP_KIND);
        assert_eq!(e.parameters[ClipEffect::MOTION_MODE_KEY].value, 0.0);
        assert_eq!(e.parameters[ELEMENT_SPAN_KEY].value, 0.5);
        assert!(!e.parameters.contains_key(ClipEffect::STAGE_SHUTTER_ANGLE_KEY));
        let tail = edge(&mut t, TransitionKind::Pop, Some(a.id), None, 10, Center).unwrap();
        let e = t.transition(tail).unwrap().1.element_effect(0.5, 2.0).unwrap();
        assert_eq!(e.parameters[ClipEffect::MOTION_MODE_KEY].value, 1.0);
        assert_eq!(e.parameters[ClipEffect::STAGE_SHUTTER_ANGLE_KEY].value, 360.0);
        // While the clip shows inside the span, the track hands out the clip with the effect appended.
        let c = t.tracks[0].clip_with_element_transitions(&a, f(3), fd());
        assert_eq!(c.effects.len(), 1);
        assert_eq!(t.tracks[0].clip_with_element_transitions(&a, f(30), fd()).effects.len(), 0);
    }
}
