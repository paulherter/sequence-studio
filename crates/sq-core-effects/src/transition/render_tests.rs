// SPDX-License-Identifier: GPL-3.0-or-later
// Swift tests: TransitionMotionTests, MoreTransitionsTests, ShapeWipeTransitionTests, ThirdTransitionSetTests,
// GlitchTransitionTests, IrisLightLeakTransitionTests, TransitionBorderTests, TransitionShapeTests, ZoomTransitionTests

use super::tests::{clip, f, fd, ids, plain, resolved};
use super::*;
use crate::transition_custom_curve::TransitionEasing;
use crate::transition_layer::TransitionKindLayer;
use sq_core_model::{
    SequenceFormat, Timeline, Track, TrackKind, TransitionAlignment, TransitionDirection, TransitionKind,
};
use sq_core_time::{EasingCurve, Id, Vec2};

const DIRECTIONS: [TransitionDirection; 4] =
    [TransitionDirection::Left, TransitionDirection::Right, TransitionDirection::Up, TransitionDirection::Down];

/// Everything `evaluate` takes, with the defaults the Swift tests use.
struct Eval {
    kind: TransitionKind,
    direction: TransitionDirection,
    softness: f64,
    blur: Option<f64>,
    easing: Option<EasingCurve>,
    outgoing: bool,
    incoming: bool,
    amount: f64,
    settles: bool,
    border: Option<Border>,
}

fn ev(kind: TransitionKind) -> Eval {
    Eval {
        kind,
        direction: TransitionDirection::Left,
        softness: 0.1,
        blur: None,
        easing: None,
        outgoing: true,
        incoming: true,
        amount: TransitionRender::ZOOM_AMOUNT,
        settles: false,
        border: None,
    }
}

impl Eval {
    fn at(&self, i: i64, n: i64) -> TransitionRender {
        let easing = self.easing.clone().unwrap_or_else(|| self.kind.default_easing());
        let mut s = RenderStyle::new(
            self.kind,
            self.direction,
            self.softness,
            self.blur.unwrap_or_else(|| self.kind.default_motion_blur()),
            &easing,
        );
        s.has_incoming = self.incoming;
        s.has_outgoing = self.outgoing;
        s.zoom_amount = self.amount;
        s.zoom_settles = self.settles;
        s.border = self.border;
        TransitionRender::evaluate(&s, i, n)
    }
    fn dir(mut self, d: TransitionDirection) -> Self {
        self.direction = d;
        self
    }
    fn linear(mut self) -> Self {
        self.easing = Some(EasingCurve::linear());
        self
    }
    fn blur(mut self, b: f64) -> Self {
        self.blur = Some(b);
        self
    }
    fn soft(mut self, s: f64) -> Self {
        self.softness = s;
        self
    }
}

fn id() -> Side {
    TransitionSide::default()
}

type Side = TransitionSide;

mod easing {
    use super::*;

    #[test]
    fn linear_and_endpoints() {
        for c in [EasingCurve::linear(), EasingCurve::ease_in_out(), EasingCurve::ease_in(), EasingCurve::ease_out()] {
            assert!(c.progress(0.0) == 0.0 && c.progress(1.0) == 1.0, "{}", c.name);
            assert!(c.progress(-1.0) == 0.0 && c.progress(2.0) == 1.0, "{} clamps", c.name);
        }
        assert!((EasingCurve::linear().progress(0.3) - 0.3).abs() < 1e-12);
    }

    #[test]
    fn ease_shapes() {
        let io = EasingCurve::ease_in_out();
        assert!((io.progress(0.5) - 0.5).abs() < 1e-9);
        assert!(io.progress(0.2) < 0.2 && io.progress(0.8) > 0.8);
        // Premiere naming: Ease In slows into the end (decelerates), Ease Out leaves the start slowly.
        assert!(EasingCurve::ease_in().progress(0.25) > 0.25 && EasingCurve::ease_out().progress(0.25) < 0.25);
        let mut last = -1.0;
        for i in 0..=100 {
            let v = io.progress(f64::from(i) / 100.0);
            assert!(v >= last);
            last = v;
        }
    }

    #[test]
    fn hold_jumps_at_the_end() {
        assert!(EasingCurve::hold().progress(0.99) == 0.0 && EasingCurve::hold().progress(1.0) == 1.0);
    }

    #[test]
    fn mix_weight_never_leaves_zero_to_one_even_for_an_overshooting_curve() {
        let o = EasingCurve::overshoot();
        assert!((0..=100).any(|i| o.progress(f64::from(i) / 100.0) > 1.0));
        assert!((0..=100).all(|i| (0.0..=1.0).contains(&o.mix_weight(f64::from(i) / 100.0))));
    }
}

mod defaults {
    use super::*;
    use TransitionKind as K;

    #[test]
    fn new_kinds_are_video() {
        for k in [K::QuickFade, K::Push, K::Slide, K::Whip, K::ZoomIn, K::ZoomOut, K::ZoomPop, K::SoftWipe] {
            assert!(k.track_kind() == TrackKind::Video, "{k:?}");
            assert!(K::kinds_for(TrackKind::Video).contains(&k));
        }
    }

    #[test]
    fn easing_defaults_follow_pauls_usage() {
        // Dissolves stay linear; slides ease out; the rest ease in and out.
        assert_eq!(K::CrossDissolve.default_easing(), EasingCurve::linear());
        assert_eq!(K::QuickFade.default_easing(), EasingCurve::linear());
        assert_eq!(K::Slide.default_easing(), EasingCurve::ease_in());
        assert_eq!(K::ZoomPop.default_easing(), EasingCurve::ease_in());
        assert_eq!(K::Push.default_easing(), EasingCurve::ease_in_out());
        assert_eq!(K::Whip.default_easing(), EasingCurve::ease_in_out());
        assert_eq!(K::SoftWipe.default_easing(), EasingCurve::ease_in_out());
    }

    #[test]
    fn preset_durations_in_whole_frames() {
        let ntsc = Time::new(1001, 30000);
        assert_eq!(K::QuickFade.preset_duration(fd()), Some(f(3)));
        assert_eq!(K::QuickFade.preset_duration(ntsc), Some(ntsc * 3));
        assert_eq!(K::Slide.preset_duration(fd()), Some(f(30))); // 1 s
        assert_eq!(K::Whip.preset_duration(fd()), Some(f(15))); // 0.5 s
        assert_eq!(K::ZoomPop.preset_duration(fd()), Some(f(24))); // 0.8 s
        // Dissolves and dips follow the Preferences default.
        assert_eq!(K::CrossDissolve.preset_duration(fd()), None);
    }

    #[test]
    fn parameter_availability() {
        assert!(K::Push.uses_direction() && K::SoftWipe.uses_direction() && !K::ZoomIn.uses_direction());
        assert!(K::SoftWipe.uses_softness() && !K::Push.uses_softness());
        assert!(K::Whip.uses_motion_blur() && !K::CrossDissolve.uses_motion_blur());
        assert!(K::Whip.default_motion_blur() > K::Push.default_motion_blur());
        assert!(K::Push.is_motion() && !K::QuickFade.is_motion() && !K::DipToBlack.is_motion());
    }

    #[test]
    fn exponential_fade_is_an_audio_kind() {
        assert!(K::ExponentialFade.track_kind() == TrackKind::Audio);
        assert!(K::kinds_for(TrackKind::Audio).contains(&K::ExponentialFade));
        assert!(!K::kinds_for(TrackKind::Video).contains(&K::ExponentialFade));
        let g0 = TransitionMix::audio_gains(K::ExponentialFade, 0.0);
        let g1 = TransitionMix::audio_gains(K::ExponentialFade, 1.0);
        assert!(g0.0 == 1.0 && g0.1 == 0.0 && g1.0 == 0.0 && g1.1 == 1.0);
        let mid = TransitionMix::audio_gains(K::ExponentialFade, 0.5);
        assert!(mid.0 < 0.5 && mid.1 < 0.5);
    }

    #[test]
    fn names_are_unique_and_every_kind_has_one() {
        let mut names: Vec<&str> = ALL_TRANSITION_KINDS.iter().map(|k| k.name()).collect();
        assert!(names.iter().all(|n| !n.is_empty()));
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), ALL_TRANSITION_KINDS.len());
        assert_eq!(ALL_TRANSITION_KINDS.iter().filter(|k| k.name().contains("Whip")).count(), 1);
    }
}

mod motion {
    use super::*;
    use TransitionKind as K;

    #[test]
    fn push_moves_both_pictures_together() {
        let r = ev(K::Push).linear().at(4, 9);
        let e = 0.5;
        assert!((r.outgoing.offset.x + e).abs() < 1e-12 && r.outgoing.offset.y == 0.0);
        assert!((r.incoming.offset.x - (1.0 - e)).abs() < 1e-12);
        // The seam is shared: B's left edge sits exactly on A's right edge.
        assert!(((r.incoming.offset.x - r.outgoing.offset.x) - 1.0).abs() < 1e-12);
        assert_eq!(r.compose, Compose::Sum);
    }

    #[test]
    fn push_directions() {
        for d in DIRECTIONS {
            let r = ev(K::Push).dir(d).at(2, 9);
            let v = d.vector();
            assert!(
                r.outgoing.offset.x * v.x >= 0.0 && r.outgoing.offset.y * v.y >= 0.0,
                "{d:?} A moves along the direction"
            );
            assert!(
                (r.incoming.offset.x - r.outgoing.offset.x + v.x).abs() < 1e-12
                    && (r.incoming.offset.y - r.outgoing.offset.y + v.y).abs() < 1e-12
            );
        }
    }

    #[test]
    fn push_offsets_are_subpixel_and_eased() {
        // 30 fps, 0.67 s push at 1920 px: consecutive frames move by fractional pixels, and ease in/out moves least at the ends.
        let n = 20;
        let xs: Vec<f64> = (0..n).map(|i| ev(K::Push).at(i, n).outgoing.offset.x * 1920.0).collect();
        let steps: Vec<f64> = xs.windows(2).map(|w| (w[1] - w[0]).abs()).collect();
        assert!(steps.iter().any(|s| (s - s.round()).abs() > 0.01), "offsets are not snapped to whole pixels");
        let mid = steps[n as usize / 2];
        assert!(steps[0] < mid && steps[steps.len() - 1] < mid, "ease in/out: slow ends, fast middle");
    }

    #[test]
    fn motion_blur_follows_speed_and_direction() {
        let n = 20;
        let mid = ev(K::Push).at(n / 2, n);
        let end = ev(K::Push).at(0, n);
        assert!(mid.outgoing.blur.x < 0.0 && mid.outgoing.blur.y == 0.0, "smear along the motion");
        assert!(mid.outgoing.blur.x.abs() > end.outgoing.blur.x.abs());
        assert_eq!(mid.outgoing.blur, mid.incoming.blur);
        // 180 degree shutter: half the distance travelled in one frame.
        let a = ev(K::Push).blur(0.5).at(n / 2 - 1, n).outgoing.offset.x;
        let b = ev(K::Push).blur(0.5).at(n / 2 + 1, n).outgoing.offset.x;
        assert!((mid.outgoing.blur.x.abs() - 0.5 * (b - a).abs() / 2.0).abs() < 0.002);
        assert_eq!(ev(K::Push).blur(0.0).at(n / 2, n).outgoing.blur, Vec2::ZERO);
        // A whip smears much more than a push.
        assert!(ev(K::Whip).at(4, 8).outgoing.blur.x.abs() > 2.5 * ev(K::Push).at(4, 8).outgoing.blur.x.abs());
    }

    #[test]
    fn slide_moves_only_the_incoming_picture_over_the_outgoing_one() {
        let r = ev(K::Slide).dir(TransitionDirection::Up).at(3, 9);
        assert_eq!(r.outgoing, id());
        assert!(r.incoming.offset.x == 0.0 && r.incoming.offset.y > 0.0, "comes in from below when sliding up");
        assert_eq!(r.compose, Compose::IncomingOver);
    }

    #[test]
    fn soft_wipe_sweeps_from_all_a_to_all_b() {
        let first = ev(K::SoftWipe).linear().at(0, 30);
        let last = ev(K::SoftWipe).linear().at(29, 30);
        assert!(first.compose == Compose::Wipe && first.wipe.direction == TransitionDirection::Left.vector());
        assert_eq!(first.wipe.softness, 0.1);
        assert!(first.wipe.front + first.wipe.softness < 0.05, "nearly no B on the first frame");
        assert!(last.wipe.front - last.wipe.softness > 0.95, "nearly all B on the last frame");
        let mut prev = -10.0;
        for i in 0..30 {
            let fr = ev(K::SoftWipe).at(i, 30).wipe.front;
            assert!(fr > prev);
            prev = fr;
        }
    }

    #[test]
    fn zoom_pop_scales_down_to_rest() {
        let p0 = ev(K::ZoomPop).at(0, 20);
        let p1 = ev(K::ZoomPop).at(19, 20);
        assert!(p0.incoming.scale > 1.05 && (p1.incoming.scale - 1.0).abs() < 0.01);
        assert!(p0.incoming.zoom_blur > p1.incoming.zoom_blur && p1.compose == Compose::IncomingOver);
    }

    /// Tail-only (an outgoing clip, nothing incoming): every kind must take the outgoing picture away, not hard-cut it.
    #[test]
    fn tail_only_takes_the_outgoing_picture_away() {
        let n = 20;
        let tail = |k: K, i: i64| Eval { incoming: false, ..ev(k) }.at(i, n);
        // How much of A is still on screen, 0...1 (offset out of frame, faded, or wiped).
        let shown = |r: &TransitionRender| {
            if r.compose == Compose::Wipe {
                return (1.0 - r.wipe.front).clamp(0.0, 1.0);
            }
            let o = r.outgoing;
            (1.0 - o.offset.x.abs().max(o.offset.y.abs())).max(0.0) * o.opacity
        };
        let kinds = [K::Push, K::Slide, K::Whip, K::ZoomIn, K::ZoomOut, K::ZoomPop, K::SoftWipe, K::Spring, K::Fall];
        for k in kinds {
            let (first, mid, last) = (tail(k, 0), tail(k, n / 2), tail(k, n - 1));
            assert!(shown(&first) > 0.85, "{k:?} starts with A on screen");
            // Zoom Pop and Zoom In / Out keep A whole until their final fade; mid-way A is zooming.
            let zooming = matches!(k, K::ZoomPop | K::ZoomIn | K::ZoomOut);
            if zooming {
                assert!(mid.outgoing.scale != first.outgoing.scale, "{k:?} takes A away");
            } else {
                assert!(shown(&mid) < shown(&first), "{k:?} takes A away");
            }
            assert!(shown(&last) < 0.4, "{k:?} ends with A (nearly) gone: {}", shown(&last));
        }
        // Every other plain motion kind of the Swift list is covered by its own tests; the nine above are the movers.
        let movers: Vec<_> = ALL_TRANSITION_KINDS
            .iter()
            .copied()
            .filter(|k| {
                k.is_motion()
                    && !matches!(
                        k,
                        K::Glitch | K::Iris | K::LightLeak | K::Flip3D | K::Burn | K::Flare | K::Warp | K::Shake
                    )
                    && !k.is_shape_reveal()
                    && !MORE.contains(k)
                    && !SHAPE_KINDS.contains(k)
            })
            .collect();
        assert_eq!(movers.len(), 9);
        // Slide out: A moves along the direction; Zoom Pop out: A grows and fades.
        assert!(tail(K::Slide, n / 2).outgoing.offset.x < 0.0 && tail(K::Slide, n / 2).outgoing.offset.y == 0.0);
        assert!(tail(K::ZoomPop, n - 1).outgoing.scale > tail(K::ZoomPop, 0).outgoing.scale);
        // With an incoming side the slide still leaves A alone.
        assert_eq!(ev(K::Slide).at(n / 2, n).outgoing, id());
    }

    #[test]
    fn dissolves_have_no_render() {
        assert!(!K::CrossDissolve.is_motion());
    }

    #[test]
    fn style_parameters_are_clamped_by_set_transition() {
        let (mut t, a, b) = super::super::tests::video_pair();
        let tid = super::super::tests::cut(&mut t, K::SoftWipe, &a, &b, 20, TransitionAlignment::Center).unwrap();
        let c = TransitionChange {
            direction: Some(TransitionDirection::Down),
            softness: Some(0.3),
            motion_blur: Some(0.2),
            ..TransitionChange::default()
        };
        t.set_transition(tid, &c).unwrap();
        let r = resolved(&t).remove(0);
        assert!(r.direction == TransitionDirection::Down && r.softness == 0.3 && r.motion_blur == 0.2);
        assert_eq!(r.easing, EasingCurve::ease_in_out());
        // Out-of-range values are clamped.
        t.set_transition(
            tid,
            &TransitionChange { softness: Some(5.0), motion_blur: Some(-1.0), ..TransitionChange::default() },
        )
        .unwrap();
        let s = resolved(&t).remove(0);
        assert!(s.softness == 0.5 && s.motion_blur == 0.0);
        // A reversed transition travels the other way.
        t.set_transition(tid, &TransitionChange { reversed: Some(true), ..TransitionChange::default() }).unwrap();
        assert_eq!(resolved(&t)[0].direction, TransitionDirection::Up);
    }

    #[test]
    fn dissolve_easing_shapes_the_weight() {
        let (mut t, a, b) = super::super::tests::video_pair();
        let tid = super::super::tests::cut(&mut t, K::CrossDissolve, &a, &b, 9, TransitionAlignment::Center).unwrap();
        // Frame 1 of 9 (span starts at 56): linear weight 2/10.
        let lin = t.tracks[0].video_entries(f(57), fd());
        assert!((lin.items[1].1 - 0.2).abs() < 1e-9 && lin.motion.is_none());
        t.set_transition(
            tid,
            &TransitionChange { easing: Some(EasingCurve::ease_in_out()), ..TransitionChange::default() },
        )
        .unwrap();
        let eased = t.tracks[0].video_entries(f(57), fd());
        assert!((eased.items[1].1 - EasingCurve::ease_in_out().progress(0.2)).abs() < 1e-9);
        assert!(eased.items[1].1 < 0.2);
    }

    #[test]
    fn push_tags_the_motion_entry_with_the_render() {
        let (mut t, a, b) = super::super::tests::video_pair();
        let tid = super::super::tests::cut(&mut t, K::Push, &a, &b, 20, TransitionAlignment::Center).unwrap();
        let e = t.tracks[0].video_entries(f(60), fd());
        assert_eq!(e.items.len(), 2);
        assert!(e.items[0].0.id == a.id && e.items.iter().all(|(_, o)| *o == 1.0));
        let m = e.motion.unwrap();
        assert!(m.id == tid && m.incoming == Some(b.id) && m.render.outgoing.offset.x < 0.0);
    }

    #[test]
    fn single_sided_slides_play_on_their_clip() {
        let (mut t, a, b) = super::super::tests::video_pair();
        super::super::tests::edge(&mut t, K::Slide, None, Some(b.id), 10, TransitionAlignment::Center).unwrap();
        let e = t.tracks[0].video_entries(f(62), fd());
        let m = e.motion.unwrap();
        assert!(e.items.len() == 1 && m.incoming == Some(b.id));
        let (mut t2, a2, _) = super::super::tests::video_pair();
        super::super::tests::edge(&mut t2, K::Slide, Some(a2.id), None, 10, TransitionAlignment::Center).unwrap();
        let e2 = t2.tracks[0].video_entries(f(56), fd());
        let m2 = e2.motion.unwrap();
        assert!(e2.items.len() == 1 && m2.incoming.is_none());
        assert!(m2.render.outgoing.offset.x < -0.1, "A slides out instead of staying put until the hard cut");
        let _ = a;
    }
}

/// Round 4 set.
const MORE: [TransitionKind; 8] = [
    TransitionKind::BlurDissolve,
    TransitionKind::DipToColour,
    TransitionKind::Flash,
    TransitionKind::Spin,
    TransitionKind::CrossZoom,
    TransitionKind::StaticNoise,
    TransitionKind::LightNoise,
    TransitionKind::StrobeCut,
];

/// Parity set and second wipe set.
pub(super) const SHAPE_KINDS: [TransitionKind; 16] = [
    TransitionKind::AdditiveDissolve,
    TransitionKind::ClockWipe,
    TransitionKind::BoxIris,
    TransitionKind::DiamondIris,
    TransitionKind::CrossIris,
    TransitionKind::BarnDoors,
    TransitionKind::VenetianBlinds,
    TransitionKind::RadialWipe,
    TransitionKind::WedgeWipe,
    TransitionKind::Pinwheel,
    TransitionKind::CheckerWipe,
    TransitionKind::ZigZagBlocks,
    TransitionKind::InsetWipe,
    TransitionKind::RandomBlocks,
    TransitionKind::SliceWipe,
    TransitionKind::MosaicDissolve,
];

mod more {
    use super::*;
    use TransitionKind as K;

    fn eval(k: K, i: i64, n: i64) -> TransitionRender {
        ev(k).blur(1.0).linear().at(i, n)
    }

    #[test]
    fn new_kinds_are_video_layer_kinds_with_distinct_names() {
        let mut names: Vec<&str> =
            ALL_TRANSITION_KINDS.iter().filter(|k| !MORE.contains(k)).map(|k| k.name()).collect();
        for k in MORE {
            assert!(k.track_kind() == TrackKind::Video && k.is_layer_kind() && !k.is_element() && !k.is_stinger());
            assert!(K::layer_kinds().contains(&k));
            assert!(!names.contains(&k.name()), "duplicate name {}", k.name());
            names.push(k.name());
        }
    }

    #[test]
    fn dips_share_one_path() {
        assert!(K::DipToBlack.is_dip() && K::DipToWhite.is_dip() && K::DipToColour.is_dip() && K::Flash.is_dip());
        assert!(!K::CrossDissolve.is_dip() && !K::BlurDissolve.is_dip());
        assert!(K::DipToColour.uses_color() && !K::DipToBlack.uses_color());
        assert_eq!(TransitionMix::dip_color(K::DipToColour, Some(&[1, 2, 3])), [1, 2, 3]);
        assert_eq!(TransitionMix::dip_color(K::DipToColour, Some(&[1, 2])), TransitionMix::DEFAULT_DIP_COLOUR);
        assert_eq!(TransitionMix::dip_color(K::DipToColour, None), TransitionMix::DEFAULT_DIP_COLOUR);
        assert_eq!(TransitionMix::dip_color(K::Flash, Some(&[1, 2, 3])), [255, 255, 255]);
        let m = TransitionMix::video(K::DipToColour, 0.5);
        assert!(m.outgoing == 0.0 && m.incoming == 0.0 && m.dip == 1.0);
    }

    #[test]
    fn flash_is_a_sharper_peak_than_a_dip_and_cuts_at_the_middle() {
        let dip = TransitionMix::video(K::DipToWhite, 0.25);
        let fl = TransitionMix::video(K::Flash, 0.25);
        assert!(fl.dip < dip.dip && fl.outgoing > dip.outgoing && fl.incoming == 0.0);
        let peak = TransitionMix::video(K::Flash, 0.5);
        assert!(peak.dip == 1.0 && peak.outgoing == 0.0 && peak.incoming == 0.0);
        let late = TransitionMix::video(K::Flash, 0.75);
        assert!(
            late.outgoing == 0.0
                && late.incoming > 0.0
                && (late.outgoing + late.incoming + late.dip - 1.0).abs() < 1e-12
        );
        assert_eq!(K::Flash.preset_duration(fd()), Some(fd() * 15));
    }

    #[test]
    fn through_colour_keeps_its_colour_on_the_edge() {
        let a = clip(1, 0, 30, 30, 200, TrackKind::Video);
        let b = clip(2, 30, 30, 30, 200, TrackKind::Video);
        let (mut t, a, b) = super::super::tests::pair(TrackKind::Video, Some(a), Some(b));
        let tid = super::super::tests::cut(&mut t, K::DipToColour, &a, &b, 10, TransitionAlignment::Center).unwrap();
        assert_eq!(t.tracks[0].transitions[0].color, None);
        t.set_transition(tid, &TransitionChange { color: Some(vec![10, 20, 30]), ..TransitionChange::default() })
            .unwrap();
        assert_eq!(t.tracks[0].transitions[0].color, Some(vec![10, 20, 30]));
        let r = t.tracks[0].resolved_transitions(fd()).remove(0);
        assert_eq!(r.color, Some(vec![10, 20, 30]));
        // The solid behind the faded pictures carries the color while the transition runs.
        let e = t.tracks[0].video_entries(r.span.start + fd() * 5, fd());
        assert_eq!(e.dip.map(|d| d.1), Some([10, 20, 30]));
        t.set_transition(tid, &TransitionChange { color: Some(vec![1]), ..TransitionChange::default() }).unwrap(); // malformed: ignored
        assert_eq!(t.tracks[0].transitions[0].color, Some(vec![10, 20, 30]));
    }

    #[test]
    fn blur_dissolve_blur_peaks_in_the_middle_and_mixes_monotonically() {
        let n = 11;
        let radii: Vec<f64> = (0..n).map(|i| eval(K::BlurDissolve, i, n).wipe.softness).collect();
        let max = radii.iter().copied().fold(f64::MIN, f64::max);
        let min = radii.iter().copied().fold(f64::MAX, f64::min);
        let mid = radii[n as usize / 2];
        assert!(max == mid && min > 0.0 && radii[0] < mid && radii[n as usize - 1] < mid);
        assert!(mid <= blur_dissolve::MAX_RADIUS);
        for i in 0..n {
            assert_eq!(eval(K::BlurDissolve, i, n).compose, Compose::BlurDissolve);
        }
        let w: Vec<f64> = (0..n).map(|i| eval(K::BlurDissolve, i, n).wipe.front).collect();
        assert!(w.windows(2).all(|p| p[0] < p[1]) && w[0] > 0.0 && w[n as usize - 1] < 1.0);
        assert!(
            !K::BlurDissolve.uses_motion_blur() && !K::BlurDissolve.uses_direction() && K::BlurDissolve.uses_easing()
        );
    }

    #[test]
    fn spin_rotates_both_pictures_and_always_covers_the_frame() {
        for dir in [TransitionDirection::Left, TransitionDirection::Right] {
            for i in 0..11 {
                let r = ev(K::Spin).blur(1.0).linear().dir(dir).at(i, 11);
                assert!((r.outgoing.opacity + r.incoming.opacity - 1.0).abs() < 1e-12 && r.compose == Compose::Sum);
                for s in [r.outgoing, r.incoming] {
                    assert!(s.rotation.abs() <= TransitionRender::SPIN_ANGLE + 1e-12);
                    assert!(s.scale >= TransitionRender::cover_scale(s.rotation) - 1e-12 && s.scale >= 1.0);
                }
            }
        }
        let l = ev(K::Spin).blur(1.0).linear().dir(TransitionDirection::Left).at(5, 11);
        let r = ev(K::Spin).blur(1.0).linear().dir(TransitionDirection::Right).at(5, 11);
        assert!(l.outgoing.rotation == -r.outgoing.rotation && l.outgoing.rotation != 0.0);
        assert!(
            eval(K::Spin, 0, 100).outgoing.rotation.abs() < 0.05
                && eval(K::Spin, 99, 100).incoming.rotation.abs() < 0.05
        );
        assert_eq!(TransitionRender::cover_scale(0.0), 1.0);
        assert!(K::Spin.uses_direction() && K::Spin.uses_motion_blur());
    }

    #[test]
    fn cross_zoom_smears_in_the_middle_and_follows_the_shutter() {
        let n = 11;
        let (mid, edge) = (eval(K::CrossZoom, n / 2, n), eval(K::CrossZoom, 0, n));
        assert!(mid.outgoing.zoom_blur > edge.outgoing.zoom_blur && mid.incoming.zoom_blur == mid.outgoing.zoom_blur);
        assert_eq!(ev(K::CrossZoom).blur(0.0).linear().at(n / 2, n).outgoing.zoom_blur, 0.0);
        for i in 0..n {
            let r = eval(K::CrossZoom, i, n);
            assert!(
                (r.outgoing.opacity + r.incoming.opacity - 1.0).abs() < 1e-12
                    && r.outgoing.scale >= 1.0
                    && r.incoming.scale >= 1.0
            );
        }
        assert!(eval(K::CrossZoom, 0, 100).incoming.scale > eval(K::CrossZoom, 99, 100).incoming.scale);
    }

    #[test]
    fn strobe_alternates_hard_and_ends_on_the_incoming_picture() {
        let n = 24;
        let seq: Vec<f64> = (0..n).map(|i| eval(K::StrobeCut, i, n).incoming.opacity).collect();
        assert!(seq.iter().all(|o| *o == 0.0 || *o == 1.0));
        assert!(seq[0] == 0.0 && seq[seq.len() - 1] == 1.0);
        let flips = seq.windows(2).filter(|p| p[0] != p[1]).count() as i64;
        assert_eq!(flips, TransitionRender::STROBE_PARTS - 1);
        for i in 0..n {
            let r = eval(K::StrobeCut, i, n);
            assert_eq!(r.outgoing.opacity + r.incoming.opacity, 1.0);
        }
    }

    #[test]
    fn static_cuts_at_the_middle_with_noise_that_peaks_there() {
        let n = 20;
        let rs: Vec<Glitch> = (0..n).map(|i| eval(K::StaticNoise, i, n).glitch).collect();
        assert!(rs.iter().all(|g| g.intensity > 0.0 && g.intensity <= 1.0));
        let m = n as usize / 2;
        assert!(rs[m].intensity > rs[0].intensity && rs[m].intensity > rs[n as usize - 1].intensity);
        let mut seeds: Vec<u32> = rs.iter().map(|g| g.seed).collect();
        seeds.sort_unstable();
        seeds.dedup();
        assert_eq!(seeds.len(), n as usize, "every frame has its own noise");
        assert!(rs[0].mix < 0.5 && rs[n as usize - 1].mix > 0.5);
        assert_eq!(eval(K::StaticNoise, 3, n).glitch, eval(K::StaticNoise, 3, n).glitch, "deterministic for export");
        assert_eq!(eval(K::StaticNoise, 3, n).compose, Compose::StaticNoise);
    }

    /// Single-sided (a clip head or tail): the missing side is transparent, so A leaves / B arrives through the same maths.
    #[test]
    fn single_sided_uses_the_same_mix_so_a_fades_out_and_b_fades_in() {
        let n = 20;
        let tail = |k: K, i: i64| Eval { incoming: false, ..ev(k) }.linear().at(i, n);
        for k in [K::Spin, K::CrossZoom] {
            assert!(tail(k, n - 1).outgoing.opacity < 0.4 && tail(k, 0).outgoing.opacity > 0.6, "{k:?}");
        }
        assert!(tail(K::BlurDissolve, n - 1).wipe.front > 0.9 && tail(K::LightNoise, n - 1).wipe.front > 0.9);
        assert!(tail(K::StaticNoise, n - 1).glitch.mix > 0.9);
    }

    #[test]
    fn light_noise_progresses_monotonically() {
        let fr: Vec<f64> = (0..11).map(|i| eval(K::LightNoise, i, 11).wipe.front).collect();
        assert!(fr.windows(2).all(|p| p[0] < p[1]) && eval(K::LightNoise, 4, 11).compose == Compose::LightNoise);
    }
}

mod shape_wipe_tests {
    use super::*;
    use TransitionKind as K;
    use shape_wipe::{BLIND_COUNT, Shape, distance, mask};

    const SHAPE_ONLY: [TransitionKind; 14] = [
        K::ClockWipe,
        K::BoxIris,
        K::DiamondIris,
        K::CrossIris,
        K::BarnDoors,
        K::VenetianBlinds,
        K::RadialWipe,
        K::WedgeWipe,
        K::Pinwheel,
        K::CheckerWipe,
        K::ZigZagBlocks,
        K::InsetWipe,
        K::RandomBlocks,
        K::SliceWipe,
    ];

    fn eval(k: K, i: i64, dir: TransitionDirection) -> TransitionRender {
        ev(k).blur(0.0).linear().soft(0.1).dir(dir).at(i, 11)
    }

    fn near(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    #[test]
    fn kinds_are_video_layer_kinds_with_unique_names() {
        let mut names: Vec<&str> =
            ALL_TRANSITION_KINDS.iter().filter(|k| !SHAPE_KINDS.contains(k)).map(|k| k.name()).collect();
        for k in SHAPE_KINDS {
            assert!(
                k.track_kind() == TrackKind::Video
                    && k.is_layer_kind()
                    && k.is_motion()
                    && !k.is_dip()
                    && !k.uses_motion_blur()
            );
            assert!(!names.contains(&k.name()), "duplicate name {}", k.name());
            names.push(k.name());
        }
        for k in SHAPE_ONLY {
            assert!(k.uses_softness() && k.uses_easing());
        }
        assert!(K::BarnDoors.uses_direction() && !K::BoxIris.uses_direction());
    }

    #[test]
    fn additive_dissolve_overlaps_both_pictures_and_ends_clean() {
        let n = 11;
        let (first, mid, last) = (
            eval(K::AdditiveDissolve, 0, TransitionDirection::Left),
            eval(K::AdditiveDissolve, 5, TransitionDirection::Left),
            eval(K::AdditiveDissolve, n - 1, TransitionDirection::Left),
        );
        assert_eq!(first.compose, Compose::Sum);
        // Around the middle both are (nearly) fully opaque: the sum brightens. A plain dissolve never exceeds 1 in total.
        assert!(mid.outgoing.opacity + mid.incoming.opacity > 1.5);
        assert!(first.outgoing.opacity > 0.9 && first.incoming.opacity < 0.25);
        assert!(last.incoming.opacity > 0.9 && last.outgoing.opacity < 0.25);
        for i in 0..n {
            let r = eval(K::AdditiveDissolve, i, TransitionDirection::Left);
            assert!((0.0..=1.0).contains(&r.outgoing.opacity) && (0.0..=1.0).contains(&r.incoming.opacity));
        }
    }

    #[test]
    fn shapes_use_the_shape_compose_and_sweep_the_front_through_the_whole_range() {
        for k in SHAPE_ONLY {
            let (a, z) = (eval(k, 0, TransitionDirection::Left), eval(k, 10, TransitionDirection::Left));
            assert!(a.compose == Compose::Shape && z.compose == Compose::Shape, "{k:?}");
            assert!(a.wipe.front < 0.15 && z.wipe.front > 0.85, "{k:?} {} {}", a.wipe.front, z.wipe.front);
            assert_eq!(a.wipe.direction.x, z.wipe.direction.x);
        }
        // Different kinds select different distance fields.
        let mut xs: Vec<f64> =
            SHAPE_ONLY.iter().map(|k| eval(*k, 3, TransitionDirection::Left).wipe.direction.x).collect();
        xs.sort_by(f64::total_cmp);
        xs.dedup();
        assert_eq!(xs.len(), SHAPE_ONLY.len());
    }

    #[test]
    fn distance_fields_are_zero_at_their_origin_and_one_at_the_far_edge() {
        for s in [Shape::Box, Shape::Diamond, Shape::Cross, Shape::DoorsAcross, Shape::DoorsDown] {
            assert!(distance(s, 0.5, 0.5) < 1e-9, "{s:?}");
        }
        assert!(near(distance(Shape::Box, 1.0, 0.5), 1.0) && near(distance(Shape::Box, 1.0, 1.0), 1.0));
        assert!(near(distance(Shape::Diamond, 1.0, 1.0), 1.0) && near(distance(Shape::Diamond, 1.0, 0.5), 0.5));
        assert!(near(distance(Shape::Diamond, 0.9, 0.5), 0.4) && near(distance(Shape::Box, 0.9, 0.5), 0.8));
        // Cross: opens along both axes first (min of |x|, |y|).
        assert!(distance(Shape::Cross, 1.0, 0.5) < 1e-9 && distance(Shape::Cross, 0.5, 1.0) < 1e-9);
        assert!(near(distance(Shape::Cross, 1.0, 1.0), 1.0));
        // Barn doors: horizontal axis only / vertical only.
        assert!(near(distance(Shape::DoorsAcross, 1.0, 0.1), 1.0) && distance(Shape::DoorsAcross, 0.5, 0.0) < 1e-9);
        assert!(near(distance(Shape::DoorsDown, 0.1, 1.0), 1.0) && distance(Shape::DoorsDown, 0.0, 0.5) < 1e-9);
    }

    #[test]
    fn clock_sweeps_clockwise_from_twelve() {
        let d = |u, v| distance(Shape::Clock, u, v);
        assert!(d(0.5, 0.1) < 0.01); // 12 o'clock first
        assert!(near(d(0.9, 0.5), 0.25)); // 3 o'clock
        assert!(near(d(0.5, 0.9), 0.5)); // 6
        assert!(near(d(0.1, 0.5), 0.75)); // 9
        assert!(d(0.45, 0.1) > 0.97); // just before 12 again
    }

    #[test]
    fn blinds_repeat_in_bands() {
        let n = BLIND_COUNT as f64;
        assert!(distance(Shape::Blinds, 0.3, 0.0) < 1e-9);
        assert!(near(distance(Shape::Blinds, 0.3, 0.5 / n), 0.5));
        assert!(near(distance(Shape::Blinds, 0.3, 1.0 / n + 0.5 / n), 0.5));
    }

    #[test]
    fn mask_is_b_where_distance_is_below_the_front() {
        assert_eq!(mask(Shape::Box, 0.5, 0.5, 0.5, 0.05), 1.0);
        assert_eq!(mask(Shape::Box, 1.0, 0.5, 0.5, 0.05), 0.0);
        assert!(near(mask(Shape::Box, 0.75, 0.5, 0.5, 0.05), 0.5));
        assert_eq!(mask(Shape::Clock, 0.5, 0.95, 1.2, 0.1), 1.0);
        assert_eq!(mask(Shape::Clock, 0.5, 0.05, -0.2, 0.1), 0.0);
    }

    #[test]
    fn barn_doors_follow_the_direction_axis() {
        let w = |d| eval(K::BarnDoors, 3, d).wipe.direction;
        assert_eq!(w(TransitionDirection::Left), w(TransitionDirection::Right));
        assert_eq!(w(TransitionDirection::Up), w(TransitionDirection::Down));
        assert_ne!(w(TransitionDirection::Left), w(TransitionDirection::Up));
    }

    #[test]
    fn second_wipe_set_fields_stay_in_range_and_reach_both_ends() {
        for sh in [
            Shape::Radial,
            Shape::Wedge,
            Shape::Pinwheel,
            Shape::Checker,
            Shape::ZigZag,
            Shape::Inset,
            Shape::Random,
            Shape::Slice,
        ] {
            let (mut lo, mut hi) = (2.0f64, -1.0f64);
            for i in 0..40 {
                for j in 0..40 {
                    let d = distance(sh, (f64::from(i) + 0.5) / 40.0, (f64::from(j) + 0.5) / 40.0);
                    assert!((-1e-9..=1.0 + 1e-9).contains(&d), "{sh:?} {d}");
                    lo = lo.min(d);
                    hi = hi.max(d);
                }
            }
            assert!(lo < 0.1 && hi > 0.9, "{sh:?} {lo} {hi}");
        }
        assert!(distance(Shape::Radial, 0.0, 1.0) < 1e-9 && near(distance(Shape::Radial, 1.0, 0.0), 1.0));
        assert!(distance(Shape::Wedge, 0.5, 0.0).abs() < 1e-9 && near(distance(Shape::Wedge, 0.5, 1.0), 1.0));
        assert!((distance(Shape::Wedge, 0.1, 0.5) - distance(Shape::Wedge, 0.9, 0.5)).abs() < 1e-9);
        assert!(distance(Shape::Inset, 0.0, 0.0) == 0.0 && distance(Shape::Inset, 1.0, 1.0) == 1.0);
        // Random Blocks: a whole cell shares one order, neighbours differ, a hash is stable.
        assert_eq!(distance(Shape::Random, 0.01, 0.01), distance(Shape::Random, 0.07, 0.1));
        assert_ne!(distance(Shape::Random, 0.01, 0.01), distance(Shape::Random, 0.1, 0.01));
        assert_eq!(shape_wipe::cell_order(3, 5), shape_wipe::cell_order(3, 5));
        // Slice: neighbouring strips run in opposite directions.
        assert!(distance(Shape::Slice, 0.1, 0.05) < distance(Shape::Slice, 0.9, 0.05));
        assert!(distance(Shape::Slice, 0.1, 0.15) > distance(Shape::Slice, 0.9, 0.15));
        let m = eval(K::MosaicDissolve, 5, TransitionDirection::Left);
        assert!(m.compose == Compose::Mosaic && (m.wipe.front - 0.5).abs() < 0.01);
        // Zig-Zag: row 0 runs left to right, row 1 right to left.
        assert!(distance(Shape::ZigZag, 0.05, 0.05) < distance(Shape::ZigZag, 0.95, 0.05));
        assert!(distance(Shape::ZigZag, 0.05, 0.15) > distance(Shape::ZigZag, 0.95, 0.15));
    }
}

mod third_set {
    use super::*;
    use TransitionKind as K;

    const KINDS: [TransitionKind; 7] = [K::Flip3D, K::Spring, K::Fall, K::Burn, K::Flare, K::Warp, K::Shake];

    fn eval(k: K, i: i64, dir: TransitionDirection) -> TransitionRender {
        ev(k).blur(0.0).linear().soft(0.0).dir(dir).at(i, 11)
    }

    #[test]
    fn are_video_motion_transitions_with_a_default_length() {
        for k in KINDS {
            assert!(k.track_kind() == TrackKind::Video && k.is_motion() && !k.is_shape_reveal(), "{k:?}");
            assert!(k.preset_duration(fd()).is_some(), "{k:?}");
            assert!(!k.name().is_empty());
        }
    }

    #[test]
    fn progress_runs_from_almost_a_to_almost_b() {
        for k in [K::Flip3D, K::Burn, K::Flare, K::Warp, K::Shake] {
            let fr: Vec<f64> = (0..11).map(|i| eval(k, i, TransitionDirection::Left).wipe.front).collect();
            assert!(fr.windows(2).all(|p| p[0] <= p[1]) && fr[0] < 0.1 && fr[10] > 0.9, "{k:?}");
        }
    }

    #[test]
    fn flip_card_is_whole_at_rest_and_edge_on_in_the_middle() {
        let p = flip_3d::card_point(0.4, -0.3, 0.0).unwrap();
        assert!((p.0 - 0.4).abs() < 1e-9 && (p.1 + 0.3).abs() < 1e-9);
        assert!(flip_3d::card_point(0.0, 0.0, std::f64::consts::FRAC_PI_2).is_none());
        assert!(flip_3d::card_point(0.0, 0.0, -0.5).unwrap().0.abs() < 1e-9);
    }

    #[test]
    fn spring_overshoots_then_settles_exactly() {
        assert!(spring_fall::spring(0.0) == 0.0 && (spring_fall::spring(1.0) - 1.0).abs() < 1e-12);
        let top = (1..=99).map(|i| spring_fall::spring(f64::from(i) / 100.0)).fold(f64::MIN, f64::max);
        assert!(top > 1.03 && top < 1.2, "{top}");
        let r = eval(K::Spring, 5, TransitionDirection::Left);
        assert!(r.compose == Compose::IncomingOver && r.outgoing == id());
    }

    #[test]
    fn fall_drops_and_tilts() {
        let a = eval(K::Fall, 2, TransitionDirection::Down);
        let b = eval(K::Fall, 8, TransitionDirection::Down);
        assert!(a.compose == Compose::OutgoingOver && a.incoming == id());
        assert!(
            b.outgoing.offset.y > a.outgoing.offset.y
                && b.outgoing.rotation > a.outgoing.rotation
                && a.outgoing.rotation > 0.0
        );
        assert!(eval(K::Fall, 10, TransitionDirection::Down).outgoing.offset.y > 0.8);
    }
}

mod glitch_tests {
    use super::*;

    fn eval(i: i64, n: i64) -> TransitionRender {
        ev(TransitionKind::Glitch).blur(0.0).linear().soft(0.0).at(i, n)
    }

    #[test]
    fn is_a_video_motion_transition_without_blur_or_direction() {
        let g = TransitionKind::Glitch;
        assert!(g.is_motion() && g.track_kind() == TrackKind::Video);
        assert!(!g.uses_motion_blur() && !g.uses_direction());
        assert!(TransitionKind::kinds_for(TrackKind::Video).contains(&g));
        assert_eq!(g.name(), "Glitch");
    }

    #[test]
    fn deterministic_from_progress() {
        for i in 0..10 {
            assert_eq!(eval(i, 10), eval(i, 10));
        }
        assert_ne!(eval(3, 10), eval(4, 10));
    }

    #[test]
    fn intensity_is_a_bell_and_cut_happens_at_half() {
        let g: Vec<Glitch> = (0..11).map(|i| eval(i, 11).glitch).collect();
        assert!(g.iter().all(|x| x.intensity >= 0.0 && x.intensity <= 1.0));
        let peak = g.iter().map(|x| x.intensity).fold(f64::MIN, f64::max);
        assert_eq!(peak, g[5].intensity);
        assert!(g[0].intensity < g[5].intensity && g[10].intensity < g[5].intensity);
        assert!(g[..5].iter().all(|x| x.mix < 0.5) && g[6..].iter().all(|x| x.mix > 0.5));
        assert_eq!(eval(0, 10).compose, Compose::Glitch);
    }

    #[test]
    fn slice_offsets_are_deterministic_bounded_and_sparse() {
        let mut active = 0;
        for band in 0..Glitch::BANDS {
            let a = Glitch::slice_shift(band, 7, 1.0);
            assert_eq!(a, Glitch::slice_shift(band, 7, 1.0));
            assert!(a.abs() <= Glitch::MAX_SHIFT);
            if a != 0.0 {
                active += 1;
            }
            assert_eq!(Glitch::slice_shift(band, 7, 0.0), 0.0);
        }
        assert!(active > 0 && active < Glitch::BANDS);
        let shifts = |seed| (0..Glitch::BANDS).map(|b| Glitch::slice_shift(b, seed, 1.0)).collect::<Vec<_>>();
        assert_ne!(shifts(8), shifts(7));
    }

    #[test]
    fn rgb_split_scales_with_intensity() {
        assert_eq!(Glitch::rgb_split(0.0), 0.0);
        assert_eq!(Glitch::rgb_split(1.0), Glitch::MAX_SPLIT);
    }
}

mod iris_light_leak {
    use super::*;
    use TransitionKind as K;

    fn eval(k: K, i: i64, n: i64) -> TransitionRender {
        ev(k).blur(0.0).linear().at(i, n)
    }

    #[test]
    fn kinds_are_video_motion_with_editable_parameters() {
        for k in [K::Iris, K::LightLeak] {
            assert!(
                k.track_kind() == TrackKind::Video
                    && k.is_motion()
                    && k.uses_easing()
                    && k.uses_softness()
                    && !k.uses_motion_blur()
            );
            assert!(K::kinds_for(TrackKind::Video).contains(&k));
            assert!(k.preset_duration(fd()).is_some());
        }
        assert!(K::Iris.name() == "Iris" && K::LightLeak.name() == "Light Leak");
        assert!(K::LightLeak.uses_direction() && !K::Iris.uses_direction());
    }

    #[test]
    fn iris_grows_from_nothing_to_covering_the_frame() {
        let (first, last) = (eval(K::Iris, 0, 30), eval(K::Iris, 29, 30));
        assert!(first.compose == Compose::Iris && last.compose == Compose::Iris);
        // Corner radius is 1: the soft edge starts inside the center and ends beyond the corners.
        assert!(first.wipe.front - first.wipe.softness < 0.1);
        assert!(last.wipe.front - last.wipe.softness > 0.85);
        let mut prev = -1.0;
        for i in 0..11 {
            let fr = eval(K::Iris, i, 11).wipe.front;
            assert!(fr > prev);
            prev = fr;
        }
    }

    #[test]
    fn iris_mask_is_an_ellipse_fitting_the_frame() {
        assert_eq!(iris::radius(0.5, 0.5), 0.0);
        assert!((iris::radius(0.0, 0.0) - 1.0).abs() < 1e-12 && (iris::radius(1.0, 1.0) - 1.0).abs() < 1e-12);
        // Edge midpoints are equally far whatever the aspect: an ellipse, not a circle.
        assert!(
            (iris::radius(1.0, 0.5) - 1.0 / 2f64.sqrt()).abs() < 1e-12
                && iris::radius(1.0, 0.5) == iris::radius(0.5, 1.0)
        );
        assert_eq!(iris::mask(0.5, 0.5, 0.5, 0.1), 1.0);
        assert_eq!(iris::mask(0.0, 0.0, 0.5, 0.1), 0.0);
        assert!((iris::mask(1.0, 0.5, 1.0 / 2f64.sqrt(), 0.1) - 0.5).abs() < 1e-9);
    }

    #[test]
    fn light_leak_mixes_at_the_middle_and_peaks_there() {
        assert!(light_leak::mix_weight(0.0) == 0.0 && light_leak::mix_weight(1.0) == 1.0);
        assert!((light_leak::mix_weight(0.5) - 0.5).abs() < 1e-12);
        assert!(
            light_leak::bell(0.0) == 0.0
                && light_leak::bell(1.0).abs() < 1e-12
                && (light_leak::bell(0.5) - 1.0).abs() < 1e-12
        );
        let mid = light_leak::leak(0.5, 0.5, 0.5, Vec2::new(-1.0, 0.0), 0.1);
        let off = light_leak::leak(0.5, 0.5, 0.0, Vec2::new(-1.0, 0.0), 0.1);
        assert!(mid.0 > 0.8 && mid.0 >= mid.1 && mid.1 >= mid.2); // warm
        assert!(off.0 == 0.0 && off.1 == 0.0 && off.2 == 0.0);
        let r = eval(K::LightLeak, 5, 11);
        assert!(r.compose == Compose::LightLeak && (r.wipe.front - 0.5).abs() < 0.1 && r.wipe.softness == 0.1);
    }

    #[test]
    fn screen_blend_only_brightens() {
        let out = light_leak::screen((0.2, 0.4, 0.6), 1.0, (0.5, 0.5, 0.5));
        assert!(out.0 > 0.2 && out.1 > 0.4 && out.2 > 0.6 && out.0 <= 1.0);
        let none = light_leak::screen((0.2, 0.4, 0.6), 1.0, (0.0, 0.0, 0.0));
        assert!(none.0 == 0.2 && none.1 == 0.4 && none.2 == 0.6);
    }
}

mod border {
    use super::*;
    use TransitionKind as K;

    #[test]
    fn border_only_for_edge_kinds_and_off_by_default() {
        let eval = |k: K, b: Option<Border>| Eval { border: b, ..ev(k) }.blur(0.0).linear().at(4, 9);
        let b = Border::new(Some(0.02), None);
        assert!(b.is_some());
        let d = eval(K::Push, None);
        assert_eq!(d.border, None);
        let mut p = eval(K::Push, b);
        assert_eq!(p.border, b);
        p.border = None;
        p.wipe = d.wipe;
        assert_eq!(p, d, "the border changes nothing else");
        assert_eq!(eval(K::SoftWipe, b).border, b);
        assert_eq!(eval(K::Slide, b).border, b);
        assert_eq!(eval(K::CrossDissolve, b).border, None);
        assert_eq!(Border::new(Some(0.0), None), None);
        assert_eq!(
            Border::new(Some(5.0), None).map(|b| b.width),
            Some(<TransitionKind as TransitionKindExt>::MAX_BORDER_WIDTH)
        );
    }

    #[test]
    fn color_defaults_to_white_and_is_linearized() {
        let white = Border::new(Some(0.02), None).unwrap();
        assert!((white.r - 1.0).abs() < 1e-9 && (white.g - 1.0).abs() < 1e-9);
        let red = Border::new(Some(0.02), Some(&[255, 0, 0])).unwrap();
        assert!((red.r - 1.0).abs() < 1e-9 && red.g == 0.0 && red.b == 0.0);
        assert_eq!(Border::new(Some(0.02), Some(&[1, 2])), Border::new(Some(0.02), None));
    }

    #[test]
    fn coverage_is_one_inside_zero_outside_and_half_at_the_band_edge() {
        let f = Border::coverage;
        assert_eq!(f(0.5, 0.5, 0.1, 0.001), 1.0);
        assert_eq!(f(0.7, 0.5, 0.1, 0.001), 0.0);
        assert!((f(0.55, 0.5, 0.1, 0.001) - 0.5).abs() < 1e-9);
    }

    #[test]
    fn band_fades_at_the_first_and_last_frame() {
        let f = Border::coverage;
        assert!(f(0.01, 0.01, 0.1, 0.001) < 0.15, "e = 0.01: no solid strip");
        assert!(f(0.99, 0.99, 0.1, 0.001) < 0.15, "e = 0.99: no solid strip");
        assert_eq!(f(0.5, 0.5, 0.1, 0.001), 1.0);
    }

    #[test]
    fn the_set_transition_border_rules() {
        let (mut t, a, b) = super::super::tests::video_pair();
        let tid = super::super::tests::cut(&mut t, K::Push, &a, &b, 10, TransitionAlignment::Center).unwrap();
        let set = |t: &mut Timeline, w, c| {
            t.set_transition(
                tid,
                &TransitionChange { border_width: w, border_color: c, ..TransitionChange::default() },
            )
            .unwrap();
            (t.tracks[0].transitions[0].border_width, t.tracks[0].transitions[0].border_color.clone())
        };
        assert_eq!(set(&mut t, Some(5.0), Some(vec![255, 0, 0])), (Some(0.1), Some(vec![255, 0, 0])));
        assert_eq!(
            set(&mut t, None, Some(vec![1])),
            (Some(0.1), Some(vec![255, 0, 0])),
            "a malformed color is ignored"
        );
        assert_eq!(set(&mut t, Some(0.0), None).0, None, "width 0 clears the border");
    }
}

mod zoom {
    use super::*;
    use TransitionKind as K;

    const AMOUNT: f64 = TransitionRender::ZOOM_AMOUNT;

    fn render(k: K, i: i64, n: i64) -> TransitionRender {
        ev(k).at(i, n)
    }

    fn render_with(k: K, i: i64, n: i64, outgoing: bool, incoming: bool) -> TransitionRender {
        Eval { outgoing, incoming, ..ev(k) }.at(i, n)
    }

    /// Frames where A is partly transparent over B (the crossfade).
    fn fade_frames(k: K, n: i64) -> Vec<i64> {
        (0..n)
            .filter(|i| (render(k, *i, n).outgoing.opacity > 0.0) && render(k, *i, n).outgoing.opacity < 1.0)
            .collect()
    }

    #[test]
    fn defaults() {
        assert_eq!(TransitionRender::ZOOM_AMOUNT, 1.1);
        assert_eq!(TransitionRender::ZOOM_FADE_FRAMES, 3.0);
        for k in [K::ZoomIn, K::ZoomOut] {
            assert_eq!(k.preset_duration(fd()), Some(f(21)), "0.7 s");
            assert_eq!(k.default_motion_blur(), 1.0, "a 360 degree shutter");
            assert!(k.is_motion() && k.uses_motion_blur() && !k.uses_direction() && !k.uses_softness());
            assert!(!k.uses_easing(), "the speed curve is part of the look");
        }
        assert!(K::ZoomPop.default_motion_blur() == 0.5 && K::Push.default_motion_blur() == 0.5);
        assert!(K::Push.uses_easing() && K::ZoomPop.uses_easing());
    }

    #[test]
    fn two_layers_with_b_under_a_and_a_short_fade_of_a() {
        for k in [K::ZoomIn, K::ZoomOut] {
            let n = 12;
            let mut last_a = 1.0;
            for i in 0..n {
                let r = render(k, i, n);
                assert_eq!(r.compose, Compose::OutgoingOver, "A is drawn over B");
                let (a, b) = (r.outgoing.opacity, r.incoming.opacity);
                assert!(a <= last_a, "{k:?} frame {i}: A only fades out");
                last_a = a;
                // B is fully opaque whenever it is there at all (it sits under A, no B fade-in).
                assert!(b == 0.0 || b == 1.0, "{k:?} frame {i}: B {b}");
                // Never a blank frame: A fully there or B underneath.
                assert!(a == 1.0 || b == 1.0, "{k:?} frame {i}");
            }
            assert!(render(k, 0, n).outgoing.opacity == 1.0 && render(k, 0, n).incoming.opacity == 0.0);
            assert!(render(k, n - 1, n).outgoing.opacity == 0.0 && render(k, n - 1, n).incoming.opacity == 1.0);
            // The crossfade sits at the middle and only lasts a couple of frames.
            let fades = fade_frames(k, n);
            assert_eq!(fades, [5, 6], "{k:?}");
            for i in fades {
                assert_eq!(render(k, i, n).incoming.opacity, 1.0, "B under A during the fade");
            }
        }
    }

    #[test]
    fn fade_length_is_independent_of_the_span() {
        assert_eq!(fade_frames(K::ZoomIn, 12).len(), 2);
        assert_eq!(fade_frames(K::ZoomIn, 36).len(), 2);
        assert_eq!(fade_frames(K::ZoomIn, 60).len(), 2);
        assert!(fade_frames(K::ZoomIn, 36).iter().all(|i| (*i as f64 - 17.5).abs() < 2.0), "centered on the cut");
        // A very short span still fades (never a hard pop), within the span.
        assert!(!fade_frames(K::ZoomIn, 3).is_empty());
    }

    #[test]
    fn zoom_in_speed_peaks_at_the_transition_point() {
        let n = 24;
        let a: Vec<_> = (0..n).map(|i| render(K::ZoomIn, i, n).outgoing).collect();
        let b: Vec<_> = (0..n).map(|i| render(K::ZoomIn, i, n).incoming).collect();
        let fades = fade_frames(K::ZoomIn, n);
        let first_b = (0..n as usize).find(|i| b[*i].opacity > 0.0).unwrap();
        let last_a = (0..n as usize).rev().find(|i| a[*i].opacity > 0.0).unwrap();
        // A: 100 % -> towards 110 %, accelerating all the way to its end.
        assert!((a[0].scale - 1.0).abs() < 0.001, "A starts at rest");
        assert!(a[last_a].scale > 1.07 && a[last_a].scale <= AMOUNT + 1e-12);
        for i in 1..=last_a {
            assert!(a[i].scale > a[i - 1].scale, "A pushes in, frame {i}");
            if i >= 2 {
                assert!(a[i].scale - a[i - 1].scale > a[i - 1].scale - a[i - 2].scale, "A accelerates, frame {i}");
            }
        }
        // B: the same direction 100 % -> 110 %, fastest at its start, settling towards the end.
        assert!(b[first_b].scale < 1.03, "B starts near 100 %");
        assert!((b[n as usize - 1].scale - AMOUNT).abs() < 0.001, "B ends at 110 %");
        for i in (first_b + 1)..n as usize {
            assert!(b[i].scale > b[i - 1].scale, "B pushes in, frame {i}");
            if i >= first_b + 2 {
                assert!(b[i].scale - b[i - 1].scale < b[i - 1].scale - b[i - 2].scale, "B settles, frame {i}");
            }
        }
        // Speed of what is on screen: A's step before the fade, B's after; the peak sits at the fade.
        let step = |i: usize| {
            if i <= last_a && a[i].opacity == 1.0 {
                a[i].scale - a[i - 1].scale
            } else {
                b[i].scale - if i > first_b { b[i - 1].scale } else { 1.0 }
            }
        };
        let speeds: Vec<f64> = (1..n as usize).map(step).collect();
        let max = speeds.iter().copied().fold(f64::MIN, f64::max);
        let peak = speeds.iter().position(|s| *s == max).unwrap() as i64 + 1;
        assert!((peak - fades[0]).abs() <= 2, "peak at frame {peak}, fade {fades:?}");
        assert!(speeds[0] < max / 4.0 && speeds[speeds.len() - 1] < max / 4.0, "slow at both ends");
        // Never below 100 %: no empty edges.
        assert!(a.iter().chain(b.iter()).all(|s| s.scale >= 1.0 && s.offset == Vec2::ZERO));
    }

    #[test]
    fn zoom_out_is_one_hundred_ten_to_one_hundred_on_both_layers() {
        let n = 24;
        let a: Vec<_> = (0..n).map(|i| render(K::ZoomOut, i, n).outgoing).collect();
        let b: Vec<_> = (0..n).map(|i| render(K::ZoomOut, i, n).incoming).collect();
        let last_a = (0..n as usize).rev().find(|i| a[*i].opacity > 0.0).unwrap();
        let first_b = (0..n as usize).find(|i| b[*i].opacity > 0.0).unwrap();
        assert!((a[0].scale - AMOUNT).abs() < 0.001, "A starts at 110 %");
        assert!(a[last_a].scale < 1.03);
        assert!(b[first_b].scale > 1.07);
        assert!((b[n as usize - 1].scale - 1.0).abs() < 0.001, "B ends at 100 %");
        for i in 1..=last_a {
            assert!(a[i].scale < a[i - 1].scale);
        }
        for i in (first_b + 1)..n as usize {
            assert!(b[i].scale < b[i - 1].scale);
        }
        assert!(a.iter().chain(b.iter()).all(|s| s.scale >= 1.0 - 1e-12));
        // Same motion as Zoom In, mirrored in scale: 2.1 - s.
        for i in 0..n as usize {
            let zi = render(K::ZoomIn, i as i64, n);
            assert!((zi.outgoing.scale + a[i].scale - (1.0 + AMOUNT)).abs() < 1e-9);
            assert!((zi.incoming.scale + b[i].scale - (1.0 + AMOUNT)).abs() < 1e-9);
            assert!(zi.outgoing.opacity == a[i].opacity && zi.incoming.opacity == b[i].opacity);
        }
    }

    #[test]
    fn amount_is_adjustable() {
        let r = Eval { amount: 1.2, ..ev(K::ZoomIn) }.blur(0.0).linear().soft(0.0).at(11, 12);
        assert!((r.incoming.scale - 1.2).abs() < 0.001);
    }

    #[test]
    fn a_stored_amount_settles_on_both_span_edges() {
        let at = |k, i| Eval { settles: true, amount: 1.2, ..ev(k) }.at(i, 24);
        // Zoom In: A 100 % -> amount, B 100 / amount % -> 100 %; Zoom Out: A 100 % -> 100 / amount %, B amount -> 100 %.
        assert!((at(K::ZoomIn, 0).outgoing.scale - 1.0).abs() < 0.05);
        assert!((at(K::ZoomIn, 23).incoming.scale - 1.0).abs() < 0.01);
        assert!(at(K::ZoomIn, 23).incoming.mirror_edges && !at(K::ZoomIn, 23).outgoing.mirror_edges);
        assert!((at(K::ZoomOut, 23).incoming.scale - 1.0).abs() < 0.01);
        assert!(at(K::ZoomOut, 0).outgoing.mirror_edges);
        assert!(at(K::ZoomOut, 0).outgoing.scale <= 1.0 + 1e-9);
    }

    #[test]
    fn blur_follows_the_speed_and_peaks_at_the_fade() {
        let n = 24;
        let fades = fade_frames(K::ZoomIn, n);
        let shown: Vec<f64> = (0..n)
            .map(|i| {
                let r = render(K::ZoomIn, i, n);
                if r.outgoing.opacity == 1.0 { r.outgoing.zoom_blur } else { r.incoming.zoom_blur }
            })
            .collect();
        assert!(shown.iter().all(|b| *b >= 0.0));
        let max = shown.iter().copied().fold(f64::MIN, f64::max);
        let peak = shown.iter().position(|b| *b == max).unwrap() as i64;
        assert!((peak - fades[0]).abs() <= 2, "blur peak at {peak}, fade {fades:?}");
        assert!(shown[0] < max / 4.0 && shown[n as usize - 1] < max / 4.0);
        assert_eq!(ev(K::ZoomIn).blur(0.0).at(fades[0], n).outgoing.zoom_blur, 0.0);
        assert!(
            ev(K::ZoomIn).blur(2.0).at(fades[0], n).outgoing.zoom_blur
                > render(K::ZoomIn, fades[0], n).outgoing.zoom_blur
        );
    }

    #[test]
    fn head_only_plays_bs_move_and_fades_in() {
        let n = 12;
        let mut last = 0.0;
        for i in 0..n {
            let r = render_with(K::ZoomIn, i, n, false, true);
            assert_eq!(r.outgoing.opacity, 0.0);
            assert!(r.incoming.scale >= 1.0 && r.incoming.scale > last, "B keeps pushing in");
            last = r.incoming.scale;
        }
        let first = render_with(K::ZoomIn, 0, n, false, true).incoming;
        assert!(first.opacity > 0.0 && first.opacity < 1.0);
        assert_eq!(render_with(K::ZoomIn, 3, n, false, true).incoming.opacity, 1.0, "in after a few frames");
        assert!((render_with(K::ZoomIn, n - 1, n, false, true).incoming.scale - AMOUNT).abs() < 0.001);
        assert!(render_with(K::ZoomOut, n - 1, n, false, true).incoming.scale < 1.001);
    }

    #[test]
    fn tail_only_plays_as_move_and_fades_out() {
        let n = 12;
        let mut last = 0.0;
        for i in 0..n {
            let r = render_with(K::ZoomIn, i, n, true, false);
            assert_eq!(r.incoming.opacity, 0.0);
            assert!(r.outgoing.scale >= 1.0 && r.outgoing.scale > last, "A keeps pushing in");
            last = r.outgoing.scale;
        }
        assert_eq!(render_with(K::ZoomIn, 0, n, true, false).outgoing.opacity, 1.0);
        assert_eq!(render_with(K::ZoomIn, n - 4, n, true, false).outgoing.opacity, 1.0);
        let end = render_with(K::ZoomIn, n - 1, n, true, false).outgoing;
        assert!(end.opacity < 0.4 && end.scale > 1.07);
        assert!(render_with(K::ZoomOut, n - 1, n, true, false).outgoing.scale < 1.03);
    }

    #[test]
    fn head_only_on_the_timeline_shows_the_incoming_clip() {
        let b = plain(2, 60, TrackKind::Video);
        let mut t = Track::new(Id::from_u128(9), TrackKind::Video);
        t.overwrite(b.clone(), &mut ids()).unwrap();
        let mut tl = Timeline::new(Id::from_u128(8), "t", SequenceFormat::new(fd()), vec![t]);
        super::super::tests::edge(&mut tl, K::ZoomIn, None, Some(b.id), 12, TransitionAlignment::Center).unwrap();
        let e = tl.tracks[0].video_entries(f(62), fd());
        let m = e.motion.unwrap();
        assert!(e.items.len() == 1 && m.incoming == Some(b.id));
        assert!(m.render.incoming.opacity > 0.0 && m.render.incoming.scale >= 1.0);
    }

    #[test]
    fn disabled_outgoing_clip_shows_the_incoming_one_throughout() {
        let (mut t, mut a, b) = super::super::tests::video_pair();
        super::super::tests::cut(&mut t, K::ZoomIn, &a, &b, 12, TransitionAlignment::Center).unwrap();
        a.is_enabled = false;
        t.tracks[0].replace(a);
        // First frame of the span: B must already be on screen, not a blank half.
        let e = t.tracks[0].video_entries(f(54), fd());
        let m = e.motion.unwrap();
        assert!(e.items.len() == 1 && e.items[0].0.id == b.id);
        assert!(m.render.incoming.opacity > 0.0 && m.render.incoming.scale >= 1.0);
    }

    #[test]
    fn both_clips_are_layered_during_the_fade() {
        let (mut t, a, b) = super::super::tests::video_pair();
        super::super::tests::cut(&mut t, K::ZoomIn, &a, &b, 12, TransitionAlignment::Center).unwrap();
        // Span 54..66, frame 5 of 12 = 59: A partly over B.
        let e = t.tracks[0].video_entries(f(59), fd());
        let m = e.motion.unwrap();
        let ids: Vec<Id> = e.items.iter().map(|(c, _)| c.id).collect();
        assert_eq!(ids, [a.id, b.id]);
        assert!(m.render.outgoing.opacity > 0.0 && m.render.outgoing.opacity < 1.0 && m.render.incoming.opacity == 1.0);
    }
}
