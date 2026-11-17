// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: FilmLook.swift
//! The "film / tape look" of a clip at one instant: Film Grain, Halation, Bloom, Gate Weave, Scanlines, Chroma Bleed
//! and Tracking Noise, already evaluated and clamped.
//!
//! All sizes are px of a 1080-line frame; the renderer scales them with the layer's height, so a 4K clip looks like
//! its 1080p version. A `None` member is identity. The look runs as one extra pass after every other effect of the
//! clip, before the layer is transformed and composited; the order inside the pass is fixed: tracking noise, chroma
//! bleed, grain, scanlines. Gate Weave is not part of the pass: it moves the layer.

use sq_core_time::Time;
use std::f64::consts::PI;

/// Film grain.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Grain {
    /// 0...1 strength of the noise.
    pub amount: f64,
    /// Grain size in px (a grain covers about size x size).
    pub size: f64,
    /// 0...1 how much the noise is smoothed (pre-blur).
    pub softness: f64,
    /// 0...1: 0 = same grain everywhere, 1 = only in the mid-tones (fades out in deep shadows and highlights).
    pub luma_weight: f64,
    /// 0...1: 0 = one gray noise for all channels, 1 = independent noise per color channel.
    pub color: f64,
    /// Noise pattern id: changes 24 times a second when the grain is animated, constant otherwise.
    pub seed: u32,
}

/// Scanlines.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Scanlines {
    /// 0...1 how dark the gaps are.
    pub intensity: f64,
    /// Distance between two lines in px.
    pub spacing: f64,
    /// 0...1 share of the spacing that is dark.
    pub thickness: f64,
}

/// Chroma bleed.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ChromaBleed {
    /// Horizontal smear of the color in px.
    pub bleed: f64,
    /// Horizontal offset of the color against the brightness in px (tape lag).
    pub shift: f64,
}

/// Tracking noise.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Tracking {
    /// 0...1 strength of the line wobble and the noise streaks.
    pub amount: f64,
    /// 0...1 height of the disturbed band as a share of the frame.
    pub band_height: f64,
    /// 0...1 position of the band (0 = bottom edge, 1 = top edge); rolls with time.
    pub phase: f64,
    /// Noise pattern id.
    pub seed: u32,
}

/// Aged Film: dust, scratches and flicker of worn film, all per frame (1/24 s steps) and deterministic from the seed.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Aged {
    /// 0...1 how many specks of dust show on a frame.
    pub dust: f64,
    /// 0...1 how many vertical scratches show (up to 3 at 100 %).
    pub scratches: f64,
    /// 0...1 strength of the frame-to-frame exposure flutter.
    pub flicker: f64,
    /// Frame id: the dust and the flicker change every 1/24 s, the scratches stay for 3 steps.
    pub seed: u32,
}

/// The look of a clip at one instant.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct FilmLook {
    /// Film grain.
    pub grain: Option<Grain>,
    /// Aged Film.
    pub aged: Option<Aged>,
    /// Scanlines.
    pub scanlines: Option<Scanlines>,
    /// Chroma bleed.
    pub chroma_bleed: Option<ChromaBleed>,
    /// Tracking noise.
    pub tracking: Option<Tracking>,
    /// Gate weave.
    pub weave: Option<GateWeave>,
}

impl FilmLook {
    /// Grain steps per second: grain animates at the film frame rate, whatever the timeline rate is.
    pub const GRAIN_RATE: i64 = 24;

    /// Nothing to do at all (no pass, no weave).
    pub fn is_identity(&self) -> bool {
        !self.needs_pass() && self.weave.is_none()
    }

    /// The renderer must run the look pass (everything but Gate Weave, which only moves the layer).
    pub fn needs_pass(&self) -> bool {
        self.grain.is_some()
            || self.aged.is_some()
            || self.scanlines.is_some()
            || self.chroma_bleed.is_some()
            || self.tracking.is_some()
    }

    /// Noise pattern id at `local` (clip-local time): one step per 1/24 s.
    pub fn seed_at_local(local: Time) -> u32 {
        let n =
            (i128::from(local.value()) * i128::from(Self::GRAIN_RATE) / i128::from(local.timescale().max(1))).max(0);
        // Swift `UInt32(truncatingIfNeeded:)`: the pattern id wraps.
        n as u32
    }
}

/// Gate Weave: the picture drifts a little in the projector gate, a slow wander plus a per-frame tremble. The layer is
/// moved by `offset_x`/`offset_y` (px of a 1080-line frame) and turned by `rotation` degrees, and scaled up just
/// enough that the weave never shows the edge of the picture.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GateWeave {
    /// Horizontal offset.
    pub offset_x: f64,
    /// Vertical offset.
    pub offset_y: f64,
    /// Rotation in degrees.
    pub rotation: f64,
    /// The most the offset can reach (the Amount setting), for the overscan.
    pub max_offset: f64,
    /// The largest rotation, for the overscan.
    pub max_rotation: f64,
}

impl GateWeave {
    /// Scale (>= 1) that keeps a `width` x `height` frame covering its own rectangle at the worst weave. `scale`
    /// converts 1080-line px to the frame's px.
    pub fn overscan(&self, width: f64, height: f64, scale: f64) -> f64 {
        let off = self.max_offset * scale;
        let rot = self.max_rotation * PI / 180.0;
        let half_diag = 0.5 * (width * width + height * height).sqrt();
        let grow = 2.0 * off + 2.0 * half_diag * rot.sin();
        1.0 + grow / 1.0_f64.max(width.min(height))
    }

    /// Hash of an integer to 0...1 (deterministic, no state).
    fn hash(n: i64, salt: u64) -> f64 {
        let mut x = (n as u64).wrapping_add(salt.wrapping_mul(0x9E37_79B9_7F4A_7C15));
        x ^= x >> 30;
        x = x.wrapping_mul(0xBF58_476D_1CE4_E5B9);
        x ^= x >> 27;
        x = x.wrapping_mul(0x94D0_49BB_1331_11EB);
        x ^= x >> 31;
        (x >> 11) as f64 / (1u64 << 53) as f64
    }

    /// Smooth value noise in -1...1 at `t` (cosine-interpolated lattice values).
    fn noise(t: f64, salt: u64) -> f64 {
        let i = t.floor() as i64;
        let f = t - i as f64;
        let u = (1.0 - (f * PI).cos()) / 2.0;
        let a = Self::hash(i, salt) * 2.0 - 1.0;
        let b = Self::hash(i + 1, salt) * 2.0 - 1.0;
        a + (b - a) * u
    }

    /// The weave at clip-local `s` seconds: a wander at `speed` Hz plus a tremble that changes every 1/24 s.
    pub fn evaluate(amount: f64, speed: f64, rotation: f64, s: f64) -> GateWeave {
        let step = (s * FilmLook::GRAIN_RATE as f64).floor();
        let axis = |salt: u64| -> f64 {
            let wander = Self::noise(s * speed, salt);
            let tremble = (Self::hash(step as i64, salt.wrapping_add(77)) * 2.0 - 1.0) * 0.25;
            (wander * 0.8 + tremble).clamp(-1.0, 1.0)
        };
        GateWeave {
            offset_x: amount * axis(1),
            offset_y: amount * 0.7 * axis(2),
            rotation: rotation * axis(3),
            max_offset: amount,
            max_rotation: rotation,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gate_weave_stays_inside_its_amount_and_is_deterministic() {
        let mut xs: Vec<f64> = Vec::new();
        for i in 0..240 {
            let w = GateWeave::evaluate(6.0, 0.5, 0.5, f64::from(i) / 24.0);
            assert!(w.offset_x.abs() <= 6.0 && w.offset_y.abs() <= 6.0 && w.rotation.abs() <= 0.5);
            xs.push(w.offset_x);
        }
        xs.sort_by(f64::total_cmp);
        xs.dedup();
        assert!(xs.len() > 100, "it really moves");
        assert_eq!(GateWeave::evaluate(6.0, 0.5, 0.5, 7.0 / 24.0), GateWeave::evaluate(6.0, 0.5, 0.5, 7.0 / 24.0));
    }

    #[test]
    fn gate_weave_overscan_covers_the_worst_case() {
        let w = GateWeave { offset_x: 0.0, offset_y: 0.0, rotation: 0.0, max_offset: 5.0, max_rotation: 0.0 };
        assert!((w.overscan(1920.0, 1080.0, 1.0) - (1.0 + 10.0 / 1080.0)).abs() < 1e-9);
        let none = GateWeave { max_offset: 0.0, ..w };
        assert_eq!(none.overscan(100.0, 100.0, 1.0), 1.0);
        let turned = GateWeave { max_offset: 0.0, max_rotation: 1.0, ..w };
        assert!(turned.overscan(1920.0, 1080.0, 1.0) > 1.0);
    }

    #[test]
    fn grain_seed_steps_24_times_a_second_from_clip_local_zero() {
        assert_eq!(FilmLook::seed_at_local(Time::new(0, 1)), 0);
        assert_eq!(FilmLook::seed_at_local(Time::new(7, 24)), 7);
        assert_eq!(FilmLook::seed_at_local(Time::new(-3, 1)), 0);
        assert!(FilmLook::default().is_identity());
    }
}
