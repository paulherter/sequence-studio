// SPDX-License-Identifier: GPL-3.0-or-later
//! Rule: an effect acts over the whole clip. Something that acts only at a clip edge is a
//! transition and lives under Transitions. Shake once sat in the Effects list but settled after its 0.5 s Duration, so it
//! felt like a transition. This walks the whole catalog, so no effect can act only in an intro or outro window again:
//! - every video effect, evaluated on a 4 s clip, differs from the bare clip in a window at the start, one in the middle
//!   and one at the end (windows, not single instants: Pulse, Wiggle and Strobe Light rest at one point of their loop);
//! - no catalog entry, audio and tool-written ones included, carries the edge-window keys (Duration, Out Duration).

use crate::effect_transform_stage::ClipStageEval;
use crate::effect_transform_stage::test_support::{canvas, fd};
use crate::effects_evaluation::ClipEffectsEval;
use crate::evaluation::ClipPosterize;
use sq_core_color::ClipGradeExt;
use sq_core_model::{AnimatedProperty, Clip, ClipEffect, EffectCatalog, EffectParamKind, TrackKind};
use sq_core_time::{Id, IdSource as _, Keyframe, KeyframeTrack, SequentialIds, Time, TimeRange, Vec2};

const FRAME: Vec2 = Vec2::new(1920.0, 1080.0);
const CLIP_SECONDS: i64 = 4;

/// Amounts that rest at their floor in the catalog ("drop-in" defaults that do nothing) get 25 % of their range here, so
/// the effect is on. Everything else is probed at its default, apart from the rows below.
const PROBE_OVERRIDES: &[(&str, &str, f64)] = &[
    (ClipEffect::TRANSFORM_KIND, ClipEffect::STAGE_POSITION_X_KEY, 40.0),
    (ClipEffect::BRIGHTNESS_CONTRAST_KIND, ClipEffect::BRIGHTNESS_KEY, 20.0),
    (ClipEffect::TWIRL_KIND, ClipEffect::TWIRL_ANGLE_KEY, 90.0),
    (ClipEffect::ALPHA_ADJUST_KIND, ClipEffect::ALPHA_OPACITY_KEY, 50.0),
    (ClipEffect::LENS_DISTORTION_KIND, ClipEffect::LENS_CURVATURE_KEY, 30.0),
];

/// Corner Warp is the one effect probed through a point: the top left corner moves.
const CORNER_WARP_OFFSET: Vec2 = Vec2::new(40.0, 30.0);

/// Kinds that act through data no bare clip holds. Each is checked by its parameters only (no edge-window keys).
const NEEDS_EXTERNAL_DATA: &[(&str, &str)] = &[
    (ClipEffect::STABILIZE_KIND, "corrects with the motion the picture analysis stored in the effect"),
    (ClipEffect::COLOR_GRAPH_KIND, "the Pro grade is rendered by the clip's grade, not by the effect chain"),
    (
        ClipEffect::DATE_STAMP_KIND,
        "a text layer built by sq-core-graphics (its own whole-clip test is in date_stamp.rs)",
    ),
];

fn ms(n: i64) -> Time {
    Time::new(n, 1000)
}

/// The 4 s clip. Motion Blur only shows on a clip that moves, so `moving` makes it glide across the whole 4 s.
fn bare_clip(moving: bool) -> Clip {
    let source = TimeRange::new(Time::ZERO, Time::new(CLIP_SECONDS, 1));
    let mut c = Clip::new(Id::from_u128(1), "v", Id::from_u128(2), TrackKind::Video, source, Time::ZERO);
    if moving {
        let mut ids = SequentialIds::default();
        let mut key = |t: Time, x: f64| Keyframe::new(ids.next_id(), t, Vec2::new(x, 0.0));
        let (a, b) = (key(Time::ZERO, 0.0), key(Time::new(CLIP_SECONDS, 1), 400.0));
        c.animation.position = AnimatedProperty { value: Vec2::ZERO, track: KeyframeTrack::with_keys(vec![a, b]) };
    }
    c
}

/// The effect of `kind` switched on: defaults, amounts at their floor raised, then the explicit rows.
fn probe(kind: &str) -> ClipEffect {
    let mut e = ClipEffect::make(Id::from_u128(7), kind).expect("catalog kind");
    let spec = EffectCatalog::spec_for(kind).expect("catalog spec");
    for p in &spec.params {
        let (lo, hi) = (*p.range.start(), *p.range.end());
        if p.kind == EffectParamKind::Slider && p.default_value == lo && hi - lo <= 10_000.0 {
            e.parameters.insert(p.key.clone(), AnimatedProperty::new(lo + (hi - lo) * 0.25));
        }
    }
    for (k, key, v) in PROBE_OVERRIDES {
        if *k == kind {
            e.parameters.insert((*key).to_string(), AnimatedProperty::new(*v));
        }
    }
    if kind == ClipEffect::CORNER_PIN_KIND {
        e.points.insert(ClipEffect::CORNER_PIN_TOP_LEFT_KEY.to_string(), AnimatedProperty::new(CORNER_WARP_OFFSET));
    }
    if kind == ClipEffect::TRACK_MASK_KIND {
        e.mask_track = Some(Id::from_u128(99)); // a matte track to read
    }
    e
}

/// Whether `with` (the clip carrying the effect) draws anything different from `bare` at clip time `t`.
fn differs(with: &Clip, bare: &Clip, t: Time) -> bool {
    with.effects_at(t) != bare.effects_at(t)
        || with.render_transform(t, FRAME) != bare.render_transform(t, FRAME)
        // Posterize Time holds frames (it moves the time the picture is read at); Motion Blur opens a shutter.
        || with.posterized_time(t, None) != bare.posterized_time(t, None)
        || with.motion_blur(t, fd(), &canvas(), 1.0).is_some()
}

/// The first clip-time (ms) in `[from, to)` where the effect shows, 40 ms apart.
fn first_shown(with: &Clip, bare: &Clip, from: i64, to: i64) -> Option<i64> {
    (from..to).step_by(40).find(|n| differs(with, bare, ms(*n)))
}

#[test]
fn every_video_effect_acts_at_the_start_in_the_middle_and_at_the_end() {
    let mut checked = 0;
    let mut failures: Vec<String> = Vec::new();
    for spec in EffectCatalog::every_spec() {
        let kind = spec.kind.as_str();
        if NEEDS_EXTERNAL_DATA.iter().any(|(k, _)| *k == kind) {
            continue;
        }
        let moving = kind == ClipEffect::MOTION_BLUR_KIND;
        let (bare, mut with) = (bare_clip(moving), bare_clip(moving));
        with.effects = vec![probe(kind)];
        if kind == ClipEffect::COLOR_KIND {
            // The clip's grade renders it (not the effect chain): it has no range, so it grades the whole clip.
            let e = &with.effects[0];
            let on = |t: Time| with.color_effect_renders(e, 0, t);
            assert!(e.color_range.is_none() && on(Time::ZERO) && on(ms(2000)) && on(ms(3960)), "Color");
            checked += 1;
            continue;
        }
        let windows = [("start", 0, 1200), ("middle", 1400, 2600), ("end", 2800, 3960)];
        let missing: Vec<&str> =
            windows.iter().filter(|(_, a, b)| first_shown(&with, &bare, *a, *b).is_none()).map(|w| w.0).collect();
        if !missing.is_empty() {
            failures.push(format!("{} ({kind}): not acting at the {}", spec.title, missing.join(", ")));
        }
        checked += 1;
    }
    assert!(failures.is_empty(), "effects that do not act over the whole clip:\n{}", failures.join("\n"));
    assert!(checked >= 50, "the catalog walk covered only {checked} effects");
}

#[test]
fn no_catalog_entry_has_an_edge_window() {
    let edge_keys = [ClipEffect::MOTION_DURATION_KEY, ClipEffect::MOTION_OUT_DURATION_KEY];
    let mut specs: Vec<_> = EffectCatalog::every_spec().to_vec();
    specs.extend(EffectCatalog::every_audio_spec().iter().cloned());
    specs.extend(EffectCatalog::generator_specs().iter().cloned());
    for kind in [
        ClipEffect::REFRAME_KIND,
        ClipEffect::DYNAMIC_ZOOM_KIND,
        ClipEffect::STABILIZE_KIND,
        ClipEffect::GROUP_TRANSFORM_KIND,
    ] {
        specs.extend(EffectCatalog::spec_for(kind));
    }
    for s in &specs {
        let bad: Vec<&str> = s.params.iter().map(|p| p.key.as_str()).filter(|k| edge_keys.contains(k)).collect();
        assert!(bad.is_empty(), "{} has edge-window parameters {bad:?}: that is a transition", s.title);
    }
}

#[test]
fn the_motion_effects_that_act_once_at_an_edge_are_not_offered_as_effects() {
    let offered = EffectCatalog::offered_video(false);
    for retired in [ClipEffect::MOVE_KIND, ClipEffect::ZOOM_KIND, ClipEffect::POP_KIND, ClipEffect::FADE_KIND] {
        assert!(!offered.iter().any(|s| s.kind == retired), "{retired} is a transition");
    }
    // Shake is offered as a whole-clip effect and, separately, exists as a transition.
    assert!(offered.iter().any(|s| s.kind == ClipEffect::SHAKE_KIND));
    assert!(crate::transition::ALL_TRANSITION_KINDS.contains(&sq_core_model::TransitionKind::Shake));
}

#[test]
fn the_probe_names_every_kind_the_walk_cannot_switch_on() {
    // A kind that is a no-op even with its amounts raised would pass the walk only by failing it: list it in
    // `PROBE_OVERRIDES` (with the parameter that switches it on) instead of exempting it.
    for (kind, why) in NEEDS_EXTERNAL_DATA {
        assert!(EffectCatalog::spec_for(kind).is_some() && !why.is_empty(), "{kind}");
    }
}
