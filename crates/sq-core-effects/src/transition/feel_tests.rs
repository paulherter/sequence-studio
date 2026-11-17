// SPDX-License-Identifier: GPL-3.0-or-later
// Swift tests: TransitionFeelTests

use super::render_tests::SHAPE_KINDS;
use super::tests::{clip, cut, edge, f, fd, ids};
use super::*;
use crate::transition_custom_curve::TransitionEasing;
use crate::transition_feel::{
    TimelineTransitionFeel, TransitionFeelExt, TransitionKindFeel, TransitionLayerFeel, ZOOM_AMOUNT_KEY,
    zoom_amount_spec,
};
use crate::transition_layer::TransitionLayerExt;
use TransitionAlignment::Center;
use TransitionKind as K;
use sq_core_model::effect_defaults::TransitionPreset;
use sq_core_model::motion_easing::MotionCurve;
use sq_core_model::{
    ClipEffect, EaseShape, EditError, SequenceFormat, Timeline, Track, TrackKind, Transition, TransitionAlignment,
    TransitionDirection, TransitionKind, TransitionLayer,
};
use sq_core_time::{EaseHandle, EasingCurve, Id, Interpolation};
use std::collections::BTreeMap;

type Side = fn(&TransitionRender) -> f64;

/// Shape of a 0 -> 1 progress curve, sampled finely.
struct Shape {
    t90: f64,
    overshoot: f64,
    undershoot: f64,
    peak_at: f64,
    end_speed: f64,
}

impl Shape {
    fn of(p: impl Fn(f64) -> f64) -> Shape {
        let n = 2000usize;
        let y: Vec<f64> = (0..=n).map(|i| p(i as f64 / n as f64)).collect();
        let (mut t90, mut peak, mut peak_at) = (0.0, 0.0, 0.0);
        for i in 0..n {
            if (1.0 - y[i]).abs() > 0.1 {
                t90 = (i + 1) as f64 / n as f64;
            }
            let v = (y[i + 1] - y[i]).abs() * n as f64;
            if v > peak {
                peak = v;
                peak_at = i as f64 / n as f64;
            }
        }
        Shape {
            t90,
            overshoot: y.iter().copied().fold(f64::MIN, f64::max) - 1.0,
            undershoot: -y.iter().copied().fold(f64::MAX, f64::min),
            peak_at,
            end_speed: (y[n] - y[n - 20]).abs() * n as f64 / 20.0,
        }
    }
}

fn timeline() -> (Timeline, Id, sq_core_model::Clip, sq_core_model::Clip) {
    let (a, b) = (clip(1, 0, 60, 90, 600, TrackKind::Video), clip(2, 90, 60, 90, 600, TrackKind::Video));
    let mut v = Track::new(Id::from_u128(9), TrackKind::Video);
    v.overwrite(a.clone(), &mut ids()).unwrap();
    v.overwrite(b.clone(), &mut ids()).unwrap();
    (Timeline::new(Id::from_u128(8), "T", SequenceFormat::new(fd()), vec![v]), Id::from_u128(9), a, b)
}

fn look(k: K) -> (Option<i64>, Shape) {
    (k.preset_duration(fd()).map(|d| d.frame_index(fd())), Shape::of(|t| k.factory_easing().progress(t)))
}

fn change() -> TransitionChange {
    TransitionChange::default()
}

fn params(pairs: &[(&str, f64)]) -> BTreeMap<String, f64> {
    pairs.iter().map(|(k, v)| ((*k).to_string(), *v)).collect()
}

mod factory_look {
    use super::*;

    #[test]
    fn dissolve_starts_and_ends_soft() {
        let (frames, s) = look(K::CrossDissolve);
        assert!(frames.is_none(), "the Preferences length (1 s)");
        assert_eq!(K::CrossDissolve.factory_easing(), EasingCurve::ease_in_out());
        assert!(s.overshoot == 0.0 && s.undershoot == 0.0);
        assert!((s.peak_at - 0.5).abs() < 0.02 && s.end_speed < 0.1, "fastest in the middle, no speed left at the end");
    }

    #[test]
    fn dips_quick_fade_and_blur_dissolve_keep_their_curve() {
        for k in [K::DipToBlack, K::DipToWhite, K::DipToColour, K::QuickFade] {
            assert!(k.factory_easing() == EasingCurve::linear() && k.factory_easing() == k.default_easing(), "{k:?}");
        }
        assert_eq!(K::QuickFade.preset_duration(fd()), Some(f(3)));
        assert!(
            K::BlurDissolve.factory_easing() == EasingCurve::ease_in_out()
                && K::BlurDissolve.preset_duration(fd()).is_none()
        );
        assert!(
            K::SoftWipe.factory_easing() == EasingCurve::ease_in_out() && K::SoftWipe.preset_duration(fd()).is_none()
        );
    }

    /// Fast start, 90 % of the way before the middle, then a long settle with no speed left and no overshoot.
    fn expect_long_ease_out(k: K, want: i64) {
        let (frames, s) = look(k);
        assert_eq!(frames, Some(want), "{k:?}");
        assert_eq!(k.factory_easing(), EasingCurve::ease_out_100(), "{k:?}");
        assert!(s.t90 < 0.5, "{k:?}: 90 % at {}", s.t90);
        assert!(s.peak_at < 0.25, "{k:?}: fastest at {}", s.peak_at);
        assert!(s.end_speed < 0.01, "{k:?}: lands with no speed");
        assert!(s.overshoot < 1e-9 && s.undershoot < 1e-9, "{k:?}: a full frame never runs past its place");
    }

    #[test]
    fn push_slide_whip_zoom_pop_iris_and_cross_zoom_settle() {
        expect_long_ease_out(K::Push, 24);
        expect_long_ease_out(K::Slide, 30);
        expect_long_ease_out(K::Whip, 15);
        // The whip itself is as short as before (8 frames): 90 % of the way within the first 8 frames.
        assert!(look(K::Whip).1.t90 * 15.0 < 8.0);
        expect_long_ease_out(K::ZoomPop, 24);
        expect_long_ease_out(K::Iris, 24);
        expect_long_ease_out(K::CrossZoom, 24);
    }

    #[test]
    fn flash_peaks_early_and_decays_long() {
        expect_long_ease_out(K::Flash, 15);
        // The cut (weight 0.5) and with it the white peak sit in the first quarter; the decay takes the rest.
        let n = 15;
        let dips: Vec<f64> = (0..n)
            .map(|i| {
                TransitionMix::video(K::Flash, K::Flash.factory_easing().mix_weight(TransitionMix::video_weight(i, n)))
                    .dip
            })
            .collect();
        let max = dips.iter().copied().fold(f64::MIN, f64::max);
        let peak = dips.iter().position(|d| *d == max).unwrap();
        assert!(peak <= 3, "peak on frame {peak}");
        assert!(
            dips[n as usize - 1] < 0.01 && dips[peak + 4] > 0.02,
            "still glowing 4 frames after the peak, gone at the end"
        );
        assert!(dips.iter().all(|d| (0.0..=1.0).contains(d)));
    }

    #[test]
    fn spin_overshoots_and_comes_back() {
        let (frames, s) = look(K::Spin);
        assert_eq!(frames, Some(24));
        assert_eq!(K::Spin.factory_easing(), EasingCurve::overshoot());
        assert!(s.overshoot > 0.05 && s.overshoot < 0.15, "{}", s.overshoot);
        assert!(s.undershoot < 1e-9 && s.t90 < 0.35);
        // The pictures stay a clean mix while the rotation swings past its rest.
        let o = EasingCurve::overshoot();
        let at = |i| {
            let st = RenderStyle::new(K::Spin, TransitionDirection::Left, 0.0, 1.0, &o);
            TransitionRender::evaluate(&st, i, 24)
        };
        let mut swung = false;
        for i in 0..24 {
            let r = at(i);
            assert!(
                r.outgoing.opacity >= 0.0
                    && r.incoming.opacity <= 1.0
                    && (r.outgoing.opacity + r.incoming.opacity - 1.0).abs() < 1e-9
            );
            swung |= r.incoming.rotation > 0.01;
            assert!(r.incoming.scale >= 1.0 - 1e-9, "still covers the frame");
        }
        assert!(swung, "B (arriving from the negative side with direction left) passes zero");
        assert!(at(23).incoming.rotation.abs() < 0.02);
    }

    #[test]
    fn light_leak_and_light_noise_run_longer_and_smooth() {
        for k in [K::LightLeak, K::LightNoise] {
            assert_eq!(k.preset_duration(fd()), Some(f(30)), "{k:?}");
            assert_eq!(k.factory_easing(), EasingCurve::ease_in_out(), "{k:?}");
        }
    }

    #[test]
    fn glitch_static_and_strobe_are_unchanged() {
        assert_eq!(K::Glitch.preset_duration(fd()), Some(f(9)));
        assert_eq!(K::StaticNoise.preset_duration(fd()), Some(f(12)));
        assert_eq!(K::StrobeCut.preset_duration(fd()), Some(f(12)));
        for k in [K::Glitch, K::StaticNoise, K::StrobeCut] {
            assert_eq!(k.factory_easing(), k.default_easing());
        }
    }

    #[test]
    fn zoom_in_and_out_store_their_amount() {
        for k in [K::ZoomIn, K::ZoomOut] {
            assert_eq!(k.preset_duration(fd()), Some(f(21)), "0.7 s");
            assert_eq!(k.factory_params(true), Some(params(&[("amount", 110.0)])));
            let keys: Vec<String> = k.element_params().into_iter().map(|p| p.key).collect();
            assert!(keys == ["amount"] && k.has_params() && !k.is_element());
        }
        // B's settle: 90 % in the first third, a small swing past the rest, no speed at the end.
        let s = Shape::of(|u| {
            let u = u.clamp(0.0, 1.0);
            1.0 - (1.0 - u).powi(3) * (1.0 - 3.0 * u)
        });
        assert!(s.t90 < 0.33 && s.overshoot > 0.03 && s.overshoot < 0.1 && s.end_speed < 0.01 && s.undershoot == 0.0);
    }

    #[test]
    fn move_and_zoom_arrive_on_a_long_ease_out_and_leave_accelerating() {
        for k in [K::Move, K::Zoom] {
            assert_eq!(k.preset_duration(fd()), Some(f(24)));
            let head = k.factory_params(true).unwrap()[ClipEffect::MOTION_CURVE_KEY];
            let tail = k.factory_params(false).unwrap()[ClipEffect::MOTION_CURVE_KEY];
            assert!(
                head == MotionCurve::EaseOut100.raw_value() as f64 && tail == MotionCurve::EaseIn100.raw_value() as f64,
                "{k:?}"
            );
        }
        let arrive = Shape::of(|t| MotionCurve::EaseOut100.ease(t, None));
        let leave = Shape::of(|t| MotionCurve::EaseIn100.ease(t, None));
        assert!(arrive.t90 < 0.5 && arrive.end_speed < 0.01 && arrive.overshoot < 1e-9);
        assert!(leave.peak_at > 0.75 && leave.overshoot < 1e-9, "fastest when it is gone");
    }

    #[test]
    fn pop_rises_fast_and_settles_over_the_longer_part() {
        assert_eq!(K::Pop.preset_duration(fd()), Some(f(18)));
        let mut tr = Transition::new(Id::from_u128(5), K::Pop, f(18), None, Some(Id::from_u128(1)));
        tr.apply_factory_look(true);
        assert!(tr.param(ClipEffect::POP_FROM_KEY) == 85.0 && tr.param(ClipEffect::POP_PEAK_KEY) == 105.0);
        assert_eq!(tr.param(ClipEffect::POP_PEAK_AT_KEY), 40.0);
        // MotionEffects.stage (the evaluated scale of the synthesized effect) belongs to motion_effects.rs.
        let e = tr.element_effect(0.6, 0.0).unwrap();
        assert_eq!(e.parameters[ClipEffect::POP_PEAK_AT_KEY].value, 40.0);
    }

    #[test]
    fn every_video_kind_has_a_decision() {
        // Kinds whose factory look differs from the stored-nil look, and only those.
        let changed = [
            K::CrossDissolve,
            K::LightNoise,
            K::Push,
            K::Slide,
            K::Whip,
            K::ZoomPop,
            K::Iris,
            K::CrossZoom,
            K::Flash,
            K::Spin,
        ];
        for k in ALL_TRANSITION_KINDS {
            assert_eq!(k.factory_easing() != k.default_easing(), changed.contains(k), "{k:?}");
            if k.track_kind() == TrackKind::Audio {
                assert!(k.factory_params(true).is_none() && k.preset_duration(fd()).is_none());
            }
        }
        // Every factory curve has a name in the Curve pop-up (never "Custom") and stays editable as an ordinary curve.
        for k in ALL_TRANSITION_KINDS.iter().filter(|k| k.uses_easing()) {
            let e = k.factory_easing();
            assert_eq!(e.matching_transition_preset(), Some(e.clone()), "{k:?}");
            assert_eq!(EasingCurve::transition_curve(&sq_core_model::EasingCurveShape::shape(&e)), Some(e), "{k:?}");
        }
        assert_eq!(EasingCurve::overshoot().name, "Overshoot");
    }
}

mod mix_weights {
    use super::*;

    pub(super) fn wild() -> EasingCurve {
        let shape =
            EaseShape::new(Interpolation::Bezier, EaseHandle { dx: 0.2, dy: -1.5 }, EaseHandle { dx: 0.2, dy: -2.0 });
        EasingCurve::transition_custom(&shape).unwrap()
    }

    #[test]
    fn dissolve_weights_never_leave_zero_to_one() {
        let w = wild();
        let mut curves = EasingCurve::transition_presets();
        curves.extend([w.clone(), EasingCurve::premiere_default(), EasingCurve::soft_landing()]);
        assert!(Shape::of(|t| w.progress(t)).overshoot > 0.2, "the test curve really leaves 0...1");
        let n = 24;
        for c in &curves {
            for i in 0..n {
                let weight = c.mix_weight(TransitionMix::video_weight(i, n));
                assert!((0.0..=1.0).contains(&weight), "{} frame {i}: {weight}", c.name);
                for k in [K::CrossDissolve, K::QuickFade, K::DipToBlack, K::DipToWhite, K::DipToColour, K::Flash] {
                    let m = TransitionMix::video(k, weight);
                    for x in [m.outgoing, m.incoming, m.dip] {
                        assert!((0.0..=1.0).contains(&x), "{k:?} {} frame {i}", c.name);
                    }
                    assert!((m.outgoing + m.incoming + m.dip - 1.0).abs() < 1e-9, "{k:?} {} frame {i}", c.name);
                }
                for k in [K::Spin, K::CrossZoom] {
                    let st = RenderStyle::new(k, TransitionDirection::Left, 0.1, 1.0, c);
                    let r = TransitionRender::evaluate(&st, i, n);
                    assert!((0.0..=1.0).contains(&r.outgoing.opacity) && (0.0..=1.0).contains(&r.incoming.opacity));
                    assert!((r.outgoing.opacity + r.incoming.opacity - 1.0).abs() < 1e-9, "{k:?} {} frame {i}", c.name);
                }
            }
        }
    }
}

mod stored {
    use super::*;

    /// What a transition without an own curve has always resolved to. Pinned: changing this changes old projects.
    #[test]
    fn a_transition_without_an_own_curve_resolves_as_before() {
        let ease_in = [K::Slide, K::ZoomPop];
        let ease_in_out = [
            K::Push,
            K::Whip,
            K::ZoomIn,
            K::ZoomOut,
            K::SoftWipe,
            K::Iris,
            K::LightLeak,
            K::BlurDissolve,
            K::Spin,
            K::CrossZoom,
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
            K::MosaicDissolve,
        ];
        for k in ALL_TRANSITION_KINDS {
            let want = if ease_in.contains(k) {
                EasingCurve::ease_in()
            } else if ease_in_out.contains(k) {
                EasingCurve::ease_in_out()
            } else {
                EasingCurve::linear()
            };
            assert_eq!(k.default_easing(), want, "{k:?}");
        }
        // The element parameter defaults (what a stored transition without the key plays) are untouched.
        let mv = Transition::new(Id::from_u128(5), K::Move, f(15), None, Some(Id::from_u128(1)));
        assert_eq!(mv.param(ClipEffect::MOTION_CURVE_KEY), 0.0);
        let pop = Transition::new(Id::from_u128(5), K::Pop, f(15), None, Some(Id::from_u128(1)));
        assert!(pop.param(ClipEffect::POP_FROM_KEY) == 90.0 && pop.param(ClipEffect::POP_PEAK_KEY) == 105.0);
        assert_eq!(pop.param(ClipEffect::POP_PEAK_AT_KEY), 77.0);
    }

    #[test]
    fn a_stored_project_keeps_duration_curve_and_render() {
        // A project as an older build wrote it: transitions without easing / params, one with an own curve.
        let (mut t, _, a, b) = timeline();
        let c = clip(3, 180, 60, 90, 600, TrackKind::Video);
        t.tracks[0].overwrite(c.clone(), &mut ids()).unwrap();
        let slide = cut(&mut t, K::Slide, &a, &b, 25, Center).unwrap();
        let zoom = cut(&mut t, K::ZoomIn, &b, &c, 12, Center).unwrap();
        let fade = edge(&mut t, K::CrossDissolve, None, Some(a.id), 30, Center).unwrap();
        let own = edge(&mut t, K::Pop, Some(c.id), None, 15, Center).unwrap();
        let spring = MotionCurve::Spring.raw_value() as f64;
        t.set_transition_params(own, &params(&[(ClipEffect::MOTION_CURVE_KEY, spring)]), false).unwrap();
        for id in [slide, zoom, fade] {
            let tr = t.transition(id).unwrap().1;
            assert!(tr.easing.is_none() && tr.params.is_none(), "a plain add writes no look");
        }
        let r = t.tracks[0].resolved_transitions(fd());
        let (rs, rz, rf) = (
            r.iter().find(|x| x.id == slide).unwrap(),
            r.iter().find(|x| x.id == zoom).unwrap(),
            r.iter().find(|x| x.id == fade).unwrap(),
        );
        assert!(rs.duration() == f(25) && rs.easing == EasingCurve::ease_in());
        assert!(rz.duration() == f(12) && rz.zoom_amount.is_none());
        assert!(rf.duration() == f(30) && rf.easing == EasingCurve::linear());
        assert_eq!(t.transition(own).unwrap().1.params, Some(params(&[(ClipEffect::MOTION_CURVE_KEY, spring)])));
        // The fade in is still a straight ramp, the zoom still the two 100 -> 110 % layers (B ends at 110 %).
        for i in 0..30 {
            assert_eq!(rf.easing.mix_weight(TransitionMix::video_weight(i, 30)), (i + 1) as f64 / 31.0);
        }
        let entries = t.tracks[0].video_entries(f(185), fd());
        let ease = EasingCurve::ease_in_out();
        let legacy = TransitionRender::evaluate(
            &RenderStyle::new(K::ZoomIn, TransitionDirection::Left, 0.1, 1.0, &ease),
            11,
            12,
        );
        assert_eq!(entries.motion.map(|m| m.render), Some(legacy));
        assert!(
            (legacy.incoming.scale - 1.1).abs() < 0.001
                && !legacy.incoming.mirror_edges
                && !legacy.outgoing.mirror_edges
        );
    }

    #[test]
    fn the_factory_look_is_only_written_where_it_is_asked() {
        let (mut t, _, a, b) = timeline();
        let old = edge(&mut t, K::Push, None, Some(a.id), 15, Center).unwrap();
        let new = cut(&mut t, K::Push, &a, &b, 24, Center).unwrap();
        t.apply_factory_look(new, true).unwrap();
        assert!(t.transition(old).unwrap().1.easing.is_none());
        let n = t.transition(new).unwrap().1;
        assert!(n.easing == Some(EasingCurve::ease_out_100()) && n.duration == f(24));
        let r = t.tracks[0].resolved_transitions(fd());
        assert_eq!(r.iter().find(|x| x.id == old).unwrap().easing, EasingCurve::ease_in_out());
        assert_eq!(r.iter().find(|x| x.id == new).unwrap().easing, EasingCurve::ease_out_100());
        // A kind whose factory curve is the stored one writes nothing.
        let wipe = edge(&mut t, K::SoftWipe, Some(b.id), None, 15, Center).unwrap();
        t.apply_factory_look(wipe, true).unwrap();
        let w = t.transition(wipe).unwrap().1;
        assert!(w.easing.is_none() && w.params.is_none());
        t.tracks[0].is_locked = true;
        assert_eq!(t.apply_factory_look(old, true), Err(EditError::TrackLocked));
    }

    #[test]
    fn cross_zoom_scale_follows_the_curve_only_its_opacity_is_clamped() {
        let (n, o) = (24, EasingCurve::overshoot());
        let mut past = false;
        for i in 0..n {
            let e = o.progress(TransitionMix::video_weight(i, n));
            let r = TransitionRender::evaluate(
                &RenderStyle::new(K::CrossZoom, TransitionDirection::Left, 0.0, 1.0, &o),
                i,
                n,
            );
            assert!(r.outgoing.scale == 1.0 + TransitionRender::CROSS_ZOOM_AMOUNT * e);
            assert!(r.incoming.scale == 1.0 + TransitionRender::CROSS_ZOOM_AMOUNT * (1.0 - e));
            assert!(r.incoming.opacity == e.clamp(0.0, 1.0) && r.outgoing.opacity == 1.0 - e.clamp(0.0, 1.0));
            past |= e > 1.01;
        }
        assert!(past, "Overshoot runs the scale past its rest");
    }

    /// Every video kind on a curve that leaves 0...1, without any of the new fields: the values of the build before
    /// 2026-10-06. The only difference allowed: Spin / Cross Zoom opacity is clamped.
    #[test]
    fn a_stored_overshooting_curve_renders_as_before() {
        let wild = mix_weights::wild();
        let n = 12;
        let print = |s: &TransitionSide| {
            s.offset.x
                + 2.0 * s.offset.y
                + 3.0 * s.scale
                + 5.0 * s.opacity
                + 7.0 * s.blur.x
                + 11.0 * s.blur.y
                + 13.0 * s.zoom_blur
                + 17.0 * s.rotation
        };
        let third = [K::Flip3D, K::Spring, K::Fall, K::Burn, K::Flare, K::Warp, K::Shake];
        let pinned: BTreeMap<&str, f64> = BTreeMap::from([
            ("blurDissolve", 3065.567698017),
            ("crossDissolve", 1560.0),
            ("crossZoom", 1872.42438008),
            ("dipToBlack", 1560.0),
            ("dipToColour", 1560.0),
            ("dipToWhite", 1560.0),
            ("flash", 1560.0),
            ("glitch", 1560.0),
            ("iris", 3695.719965589),
            ("lightLeak", 3399.742832563),
            ("lightNoise", 3040.942832563),
            ("move", 1560.0),
            ("pop", 1560.0),
            ("push", 1172.588466439),
            ("quickFade", 1560.0),
            ("slide", 1421.153079863),
            ("softWipe", 3695.719965589),
            ("spin", -396.33248199),
            ("staticNoise", 1560.0),
            ("stinger", 1560.0),
            ("strobeCut", 1087.5),
            ("whip", 1172.588466439),
            ("zoom", 1560.0),
            ("zoomIn", 1225.705899917),
            ("zoomOut", 1201.988474401),
            ("zoomPop", 1574.060896849),
        ]);
        let mut got: BTreeMap<String, f64> = BTreeMap::new();
        for k in ALL_TRANSITION_KINDS
            .iter()
            .filter(|k| k.track_kind() == TrackKind::Video && !SHAPE_KINDS.contains(k) && !third.contains(k))
        {
            let mut sum = 0.0;
            for i in 0..n {
                let st = RenderStyle::new(*k, TransitionDirection::Up, 0.2, 1.0, &wild);
                let mut r = TransitionRender::evaluate(&st, i, n);
                assert!(!r.outgoing.mirror_edges && !r.incoming.mirror_edges);
                if matches!(k, K::Spin | K::CrossZoom) {
                    let e = wild.progress(TransitionMix::video_weight(i, n));
                    let w = e.clamp(0.0, 1.0);
                    assert!(r.outgoing.opacity == 1.0 - w && r.incoming.opacity == w, "{k:?} frame {i}");
                    r.outgoing.opacity = 1.0 - e; // what the older build passed on
                    r.incoming.opacity = e;
                }
                sum += (i + 1) as f64
                    * (print(&r.outgoing) + 1.5 * print(&r.incoming) + 19.0 * r.wipe.front + 23.0 * r.wipe.softness);
            }
            let name = serde_json::to_value(k).unwrap().as_str().unwrap().to_string();
            got.insert(name, (sum * 1e9).round() / 1e9);
        }
        assert_eq!(got.len(), pinned.len());
        for (k, v) in &got {
            assert!((pinned[k.as_str()] - v).abs() < 1e-6, "{k}: {v} vs {}", pinned[k.as_str()]);
        }
    }
}

mod kind_change {
    use super::*;

    #[test]
    fn leaves_a_transition_without_a_written_look_as_it_is() {
        let (mut t, _, a, b) = timeline();
        let id = cut(&mut t, K::Push, &a, &b, 15, Center).unwrap();
        t.change_transition_kind(id, K::Spin).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert!(tr.easing.is_none() && tr.params.is_none());
        t.change_transition_kind(id, K::ZoomIn).unwrap();
        assert!(t.transition(id).unwrap().1.params.is_none(), "no Amount: the older zoom");
        // An edited look is not the factory look: the curve stays, parameters go; Zoom In <-> Out keeps the Amount.
        t.set_transition_params(id, &params(&[("amount", 140.0)]), false).unwrap();
        assert!(!t.transition(id).unwrap().1.carries_factory_look());
        t.change_transition_kind(id, K::ZoomOut).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert!(tr.params == Some(params(&[("amount", 140.0)])) && tr.easing.is_none());
        t.change_transition_kind(id, K::Push).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert!(tr.params.is_none() && tr.easing.is_none());
        // Factory curve but edited parameters: not the full look either.
        t.change_transition_kind(id, K::ZoomIn).unwrap();
        t.apply_factory_look(id, true).unwrap();
        assert!(t.transition(id).unwrap().1.carries_factory_look());
        t.set_transition_params(id, &params(&[("amount", 120.0)]), false).unwrap();
        t.change_transition_kind(id, K::Spin).unwrap();
        assert!(t.transition(id).unwrap().1.easing.is_none());
        let mut l = TransitionLayer::new(K::Push, f(12));
        l.change_kind(K::Spin);
        assert!(l.easing.is_none() && l.params.is_none());
        l.change_kind(K::ZoomIn);
        l.set_param("amount", 150.0);
        l.change_kind(K::ZoomOut);
        assert_eq!(l.params, Some(params(&[("amount", 150.0)])));
        l.change_kind(K::Push);
        assert!(l.params.is_none() && l.easing.is_none());
    }

    #[test]
    fn starts_from_the_new_factory_look_but_keeps_an_own_curve() {
        let (mut t, _, a, b) = timeline();
        let id = cut(&mut t, K::Push, &a, &b, 24, Center).unwrap();
        t.apply_factory_look(id, true).unwrap();
        t.change_transition_kind(id, K::Spin).unwrap();
        assert_eq!(t.transition(id).unwrap().1.easing, Some(EasingCurve::overshoot()));
        t.change_transition_kind(id, K::ZoomIn).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert!(tr.easing.is_none() && tr.params == Some(params(&[("amount", 110.0)])));
        t.change_transition_kind(id, K::SoftWipe).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert!(tr.params.is_none() && tr.easing.is_none());
        t.set_transition(id, &TransitionChange { easing: Some(EasingCurve::fast_start()), ..change() }).unwrap();
        t.change_transition_kind(id, K::Slide).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert_eq!(tr.easing, Some(EasingCurve::fast_start()), "an own curve survives");
        assert_eq!(tr.duration, f(24), "the length is never touched");
    }

    #[test]
    fn reset_without_a_user_default_gives_the_factory_look() {
        let (mut t, _, a, b) = timeline();
        let id = cut(&mut t, K::Slide, &a, &b, 25, Center).unwrap();
        t.reset_transition(id, None, f(30)).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert!(tr.easing == Some(EasingCurve::ease_out_100()) && tr.duration == f(30));
        // A user default (saved with the look it had) wins and is applied exactly.
        let user = TransitionPreset::new(K::Slide, f(25));
        assert_eq!(user.easing, EasingCurve::ease_in());
        t.reset_transition(id, Some(&user), f(30)).unwrap();
        let tr = t.transition(id).unwrap().1;
        assert!(tr.easing == Some(EasingCurve::ease_in()) && tr.duration == f(25));
    }

    #[test]
    fn reset_clears_reversed_and_preset_carries_it() {
        let (mut t, _, a, b) = timeline();
        let id = cut(&mut t, K::Slide, &a, &b, 25, Center).unwrap();
        t.set_transition(id, &TransitionChange { reversed: Some(true), ..change() }).unwrap();
        let captured = TransitionPreset::capture(&t.transition(id).unwrap().1);
        assert_eq!(captured.reversed, Some(true));
        t.reset_transition(id, None, f(30)).unwrap();
        assert_eq!(t.transition(id).unwrap().1.reversed, None);
        t.reset_transition(id, Some(&captured), f(30)).unwrap();
        assert_eq!(t.transition(id).unwrap().1.reversed, Some(true));
        let old: TransitionPreset =
            serde_json::from_slice(&serde_json::to_vec(&TransitionPreset::new(K::Slide, f(25))).unwrap()).unwrap();
        assert_eq!(old.reversed, None);
    }
}

mod zoom_settle {
    use super::*;

    fn zoom(k: K, i: i64, n: i64, amount: f64, outgoing: bool, incoming: bool) -> TransitionRender {
        let e = EasingCurve::ease_in_out();
        let mut s = RenderStyle::new(k, TransitionDirection::Left, 0.1, 1.0, &e);
        (s.zoom_amount, s.zoom_settles, s.has_outgoing, s.has_incoming) = (amount, true, outgoing, incoming);
        TransitionRender::evaluate(&s, i, n)
    }

    fn z(k: K, i: i64, n: i64) -> TransitionRender {
        zoom(k, i, n, 1.1, true, true)
    }

    #[test]
    fn settling_zoom_is_at_rest_on_both_span_edges() {
        for k in [K::ZoomIn, K::ZoomOut] {
            for n in [9, 21, 30] {
                // A at the first frame and B at the last are within a hair of 100 %: no jump against the clip outside the span.
                assert!((z(k, 0, n).outgoing.scale - 1.0).abs() < 0.001, "{k:?} {n}");
                assert!((z(k, n - 1, n).incoming.scale - 1.0).abs() < 0.001, "{k:?} {n}");
                assert!(z(k, 0, n).outgoing.opacity == 1.0 && z(k, n - 1, n).incoming.opacity == 1.0);
                assert_eq!(z(k, n - 1, n).outgoing.opacity, 0.0);
                // No blur left where it meets the clip.
                assert!(z(k, n - 1, n).incoming.zoom_blur < 0.002 && z(k, 0, n).outgoing.zoom_blur < 0.002);
            }
            // Single-sided: the side that stays visible is at rest where the clip goes on / comes from.
            assert!((zoom(k, 20, 21, 1.1, false, true).incoming.scale - 1.0).abs() < 0.001);
            assert!((zoom(k, 0, 21, 1.1, true, false).outgoing.scale - 1.0).abs() < 0.001);
        }
    }

    #[test]
    fn settling_zoom_is_one_move_in_one_direction_with_its_peak_at_the_fade() {
        let n = 21;
        let col = |k: K, side: Side| (0..n).map(|i| side(&z(k, i, n))).collect::<Vec<_>>();
        let (out, inc): (Side, Side) = (|r| r.outgoing.scale, |r| r.incoming.scale);
        // Zoom In: A grows to the amount, B grows from 1 / amount; Zoom Out the reverse.
        let (a, b) = (col(K::ZoomIn, out), col(K::ZoomIn, inc));
        assert!(
            a.windows(2).all(|p| p[0] <= p[1]) && (a[12] - 1.1).abs() < 0.001,
            "A accelerates up to 110 %: {}",
            a[12]
        );
        let bmax = b.iter().copied().fold(f64::MIN, f64::max);
        assert!(
            (b[9] - 1.0 / 1.1).abs() < 0.03 && bmax > 1.001 && bmax < 1.01,
            "B from 91 %, a touch past 100 %: {bmax}"
        );
        assert!(a[10] - a[9] > a[5] - a[4], "A is fastest at its end");
        assert!(b[12] - b[11] > b[18] - b[17], "B is fastest at its start");
        let (a, b) = (col(K::ZoomOut, out), col(K::ZoomOut, inc));
        assert!(a.windows(2).all(|p| p[0] >= p[1]) && (a[12] - 1.0 / 1.1).abs() < 0.001);
        let bmin = b.iter().copied().fold(f64::MAX, f64::min);
        assert!(
            b[9..].windows(2).all(|p| p[0] >= p[1]) && (b[9] - 1.1).abs() < 0.03 && bmin >= 1.0,
            "B never below 100 %"
        );
        // The side that drops below 100 % repeats mirrored at its edges; the other needs nothing.
        assert!(z(K::ZoomIn, 12, n).incoming.mirror_edges && !z(K::ZoomIn, 12, n).outgoing.mirror_edges);
        assert!(z(K::ZoomOut, 5, n).outgoing.mirror_edges && !z(K::ZoomOut, 5, n).incoming.mirror_edges);
        // The fade is the one of the older look: B under A, A fades over a few frames in the middle.
        let ease = EasingCurve::ease_in_out();
        for k in [K::ZoomIn, K::ZoomOut] {
            for i in 0..n {
                let new = z(k, i, n);
                let old =
                    TransitionRender::evaluate(&RenderStyle::new(k, TransitionDirection::Left, 0.1, 1.0, &ease), i, n);
                assert!(new.outgoing.opacity == old.outgoing.opacity && new.incoming.opacity == old.incoming.opacity);
                assert_eq!(new.compose, Compose::OutgoingOver);
            }
        }
    }

    #[test]
    fn amount_is_a_parameter_of_zoom_in_and_out() {
        let (mut t, tid, a, b) = timeline();
        let id = cut(&mut t, K::ZoomIn, &a, &b, 21, Center).unwrap();
        assert!(t.tracks[0].resolved_transitions(fd())[0].zoom_amount.is_none(), "stored without: the older look");
        assert_eq!(t.transition(id).unwrap().1.param("amount"), 110.0, "the control shows the default");
        t.set_transition_params(id, &params(&[("amount", 130.0)]), false).unwrap();
        assert_eq!(t.tracks[0].resolved_transitions(fd())[0].zoom_amount, Some(1.3));
        t.set_transition_params(id, &params(&[("amount", 900.0)]), false).unwrap();
        assert_eq!(t.transition(id).unwrap().1.params, Some(params(&[("amount", 200.0)])), "clamped to the range");
        assert_eq!(t.set_transition_params(id, &params(&[("peak", 3.0)]), false), Err(EditError::InvalidFormat));
        t.set_transition_params(id, &params(&[("amount", 130.0)]), false).unwrap();
        // What plays is the settling zoom with that amount.
        let got = t.tracks[0].video_entries(f(90 - 10 + 10), fd()).motion.unwrap().render;
        assert_eq!(got, zoom(K::ZoomIn, 10, 21, 1.3, true, true));
        let peak = (0..21).map(|i| zoom(K::ZoomIn, i, 21, 1.3, true, true).outgoing.scale).fold(f64::MIN, f64::max);
        assert!((peak - 1.3).abs() < 0.001);
        // Presets and user defaults carry it; one saved from an older transition carries none.
        let preset = TransitionPreset::capture(&t.transition(id).unwrap().1);
        assert_eq!(preset.params, Some(params(&[("amount", 130.0)])));
        let other = t.add_transition_from_preset(&preset, TransitionPoint::Head(a.id), tid, &mut ids()).unwrap();
        assert_eq!(t.transition(other).unwrap().1.zoom_amount(), Some(1.3));
        t.apply_transition_preset(&TransitionPreset::new(K::ZoomIn, f(12)), other).unwrap();
        assert!(t.transition(other).unwrap().1.params.is_none());
        t.apply_transition_default(&preset, other).unwrap();
        assert_eq!(t.transition(other).unwrap().1.params, Some(params(&[("amount", 130.0)])));
        assert_eq!(zoom_amount_spec().key, ZOOM_AMOUNT_KEY);
    }
}

/// Swift EaseNameTests: the transition Curve list is the keyframe list without Hold, then the extra presets.
#[test]
fn the_transition_curve_list_uses_the_swift_names_in_order() {
    let names: Vec<String> = EasingCurve::transition_presets().iter().map(|c| c.display_name().to_string()).collect();
    assert_eq!(
        names,
        [
            "Linear",
            "Ease In & Out",
            "Ease In",
            "Ease Out",
            "Fast Start",
            "Fast End",
            "Ease In 100%",
            "Ease Out 100%",
            "Overshoot"
        ]
    );
}
