// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MotionEffects.swift (catalog entries)

use super::util::{p, spec};
use crate::motion_easing::MotionCurve;
use crate::{ClipEffect, EffectParamSpec, EffectSpec};

const MOTION_MODE_TITLES: [&str; 4] = ["In", "Out", "In & Out", "Loop"];
const MOVE_SIDE_TITLES: [&str; 5] = ["Left", "Right", "Top", "Bottom", "Angle"];
const MOVE_SPIN_TITLES: [&str; 3] = ["None", "Clockwise", "Counter-clockwise"];

fn common() -> Vec<EffectParamSpec> {
    vec![
        EffectParamSpec::choice(ClipEffect::MOTION_MODE_KEY, "Mode", &MOTION_MODE_TITLES, 0),
        EffectParamSpec::choice(ClipEffect::MOTION_CURVE_KEY, "Curve", &MotionCurve::titles(), 0),
        p(ClipEffect::MOTION_DURATION_KEY, "Duration", "s", 0.5, 0.01, 60.0, 0.01, 2),
        p(ClipEffect::MOTION_OUT_DURATION_KEY, "Out Duration (0 = same)", "s", 0.0, 0.0, 60.0, 0.01, 2),
    ]
}

fn loop_common(period: f64) -> Vec<EffectParamSpec> {
    vec![
        p(ClipEffect::LOOP_PERIOD_KEY, "Period", "s", period, 0.05, 60.0, 0.01, 2),
        p(ClipEffect::LOOP_PHASE_KEY, "Phase", "%", 0.0, 0.0, 100.0, 1.0, 0),
    ]
}

fn move_spec() -> EffectSpec {
    spec(
        ClipEffect::MOVE_KIND,
        "Move",
        [
            common(),
            vec![
                EffectParamSpec::choice(ClipEffect::MOVE_SIDE_KEY, "Direction", &MOVE_SIDE_TITLES, 0),
                p(ClipEffect::MOVE_DIRECTION_KEY, "Angle", "\u{00B0}", 270.0, -3_600.0, 3_600.0, 1.0, 0),
                p(ClipEffect::MOVE_DISTANCE_KEY, "Distance", "% of frame", 100.0, 0.0, 1_000.0, 0.5, 1),
                // Clockwise by default: raising the strength turns the picture straight away (None switches it off).
                EffectParamSpec::choice(ClipEffect::MOVE_SPIN_KEY, "Rotation", &MOVE_SPIN_TITLES, 1),
                p(ClipEffect::MOVE_ROTATION_KEY, "Rotation Strength", "\u{00B0}", 0.0, -3_600.0, 3_600.0, 1.0, 1),
                p(ClipEffect::MOVE_SCALE_KEY, "Scale at Edge", "%", 100.0, 0.0, 10_000.0, 0.5, 1),
                EffectParamSpec::checkbox(ClipEffect::MOVE_FADE_KEY, "Fade", false),
                p(ClipEffect::MOVE_FADE_LENGTH_KEY, "Fade Length", "s", 0.14, 0.0, 60.0, 0.01, 2),
            ],
        ]
        .concat(),
    )
}

fn zoom_spec() -> EffectSpec {
    spec(
        ClipEffect::ZOOM_KIND,
        "Zoom",
        [
            common(),
            vec![
                p(ClipEffect::ZOOM_FROM_KEY, "From", "%", 100.0, 0.0, 10_000.0, 0.5, 1),
                p(ClipEffect::ZOOM_TO_KEY, "To", "%", 110.0, 0.0, 10_000.0, 0.5, 1),
            ],
        ]
        .concat(),
    )
}

fn pop_spec() -> EffectSpec {
    spec(
        ClipEffect::POP_KIND,
        "Pop",
        [
            common(),
            vec![
                p(ClipEffect::POP_FROM_KEY, "From", "%", 90.0, 0.0, 10_000.0, 0.5, 1),
                p(ClipEffect::POP_PEAK_KEY, "Peak", "%", 105.0, 0.0, 10_000.0, 0.5, 1),
                p(ClipEffect::POP_SETTLE_KEY, "Settle", "%", 100.0, 0.0, 10_000.0, 0.5, 1),
                p(ClipEffect::POP_PEAK_AT_KEY, "Peak at", "%", 77.0, 1.0, 99.0, 1.0, 0),
            ],
        ]
        .concat(),
    )
}

fn fade_spec() -> EffectSpec {
    spec(
        ClipEffect::FADE_KIND,
        "Fade",
        [common(), vec![p(ClipEffect::FADE_START_KEY, "Opacity at Edge", "%", 0.0, 0.0, 100.0, 1.0, 0)]].concat(),
    )
}

/// Shake: a constant camera shake over the whole clip. It has no Mode, Curve or Duration: an effect acts for the full
/// length of its clip, a one-sided shake at a clip edge is the Shake transition.
fn shake_spec() -> EffectSpec {
    spec(
        ClipEffect::SHAKE_KIND,
        "Shake",
        vec![
            p(ClipEffect::SHAKE_STRENGTH_KEY, "Strength", "% of frame", 2.0, 0.0, 100.0, 0.1, 1),
            p(ClipEffect::SHAKE_ROTATION_KEY, "Rotation", "\u{00B0}", 1.0, 0.0, 180.0, 0.1, 1),
            p(ClipEffect::SHAKE_SPEED_KEY, "Speed", "Hz", 8.0, 0.1, 60.0, 0.1, 1),
            p(ClipEffect::SHAKE_SEED_KEY, "Seed", "", 1.0, 0.0, 10_000.0, 1.0, 0),
        ],
    )
}

/// Bounce: a ball-like hop along Direction (0 = up) every Period; Squash stretches the picture at the top of the hop.
fn bounce_spec() -> EffectSpec {
    spec(
        ClipEffect::BOUNCE_KIND,
        "Bounce",
        [
            loop_common(0.6),
            vec![
                p(ClipEffect::BOUNCE_HEIGHT_KEY, "Height", "% of frame", 5.0, 0.0, 100.0, 0.1, 1),
                p(ClipEffect::BOUNCE_DIRECTION_KEY, "Direction", "\u{00B0}", 0.0, -3_600.0, 3_600.0, 1.0, 0),
                p(ClipEffect::BOUNCE_SQUASH_KEY, "Squash", "%", 0.0, 0.0, 50.0, 1.0, 0),
            ],
        ]
        .concat(),
    )
}

/// Pulse: scale breathes between From and To (smooth sine), optionally dipping the opacity at the small end.
fn pulse_spec() -> EffectSpec {
    spec(
        ClipEffect::PULSE_KIND,
        "Pulse",
        [
            loop_common(0.8),
            vec![
                p(ClipEffect::PULSE_FROM_KEY, "From", "%", 100.0, 0.0, 10_000.0, 0.5, 1),
                p(ClipEffect::PULSE_TO_KEY, "To", "%", 112.0, 0.0, 10_000.0, 0.5, 1),
                p(ClipEffect::PULSE_FADE_KEY, "Fade Depth", "%", 0.0, 0.0, 100.0, 1.0, 0),
            ],
        ]
        .concat(),
    )
}

/// Wiggle: rotates back and forth by +-Angle (sine) every Period; Shift adds a sideways sway in % of the frame.
fn wiggle_spec() -> EffectSpec {
    spec(
        ClipEffect::WIGGLE_KIND,
        "Wiggle",
        [
            loop_common(0.5),
            vec![
                p(ClipEffect::WIGGLE_ANGLE_KEY, "Angle", "\u{00B0}", 8.0, 0.0, 180.0, 0.1, 1),
                p(ClipEffect::WIGGLE_SHIFT_KEY, "Shift", "% of frame", 0.0, 0.0, 100.0, 0.1, 1),
            ],
        ]
        .concat(),
    )
}

/// Every parametric motion effect, in panel order.
pub(super) fn specs() -> Vec<EffectSpec> {
    vec![move_spec(), zoom_spec(), pop_spec(), fade_spec(), shake_spec(), bounce_spec(), pulse_spec(), wiggle_spec()]
}

/// FB-G: Move, Zoom, Pop and Fade act once at a clip edge, so they are transitions now. They are no longer offered as
/// effects but keep evaluating in old projects.
pub(super) fn is_retired(kind: &str) -> bool {
    [ClipEffect::MOVE_KIND, ClipEffect::ZOOM_KIND, ClipEffect::POP_KIND, ClipEffect::FADE_KIND].contains(&kind)
}
