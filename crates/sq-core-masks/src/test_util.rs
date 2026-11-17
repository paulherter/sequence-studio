// SPDX-License-Identifier: GPL-3.0-or-later
//! Test helpers shared by the module tests.

/// Deterministic pseudo random numbers (the LCG of the Swift tests), so synthetic sequences are the same on every run.
pub struct Lcg(pub u64);

impl Lcg {
    /// 0..<1.
    pub fn next(&mut self) -> f64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (self.0 >> 11) as f64 / (1u64 << 53) as f64
    }

    /// -1..<1.
    pub fn symmetric(&mut self) -> f64 {
        self.next() * 2.0 - 1.0
    }
}

pub use swing::*;

mod swing {
    use super::Lcg;
    use crate::magic_follow::{InstanceFrame, MagicGuide};
    use crate::magic_mask::InstanceLabels;
    use crate::subject_mask::SubjectMatte;
    use sq_core_time::Vec2;

    /// The synthetic shot of the Magic tracking tests: a person-like subject (still body, head swinging fast from side to
    /// side) next to a still background object, with a known answer.
    pub struct SwingShot {
        rng: Lcg,
        /// The segmenter merges the lamp into the subject (one object), like Vision does with things touching a person.
        pub merge_lamp: bool,
        /// A red hat on the head that the segmenter misses (background label).
        pub hat: bool,
    }

    pub const W: usize = 192;
    pub const H: usize = 108;
    const HEAD_RADIUS: f64 = 13.0;

    impl SwingShot {
        pub fn new() -> SwingShot {
            SwingShot { rng: Lcg(99), merge_lamp: false, hat: false }
        }

        fn in_hat(x: f64, y: f64, c: Vec2) -> bool {
            (x - c.x).abs() <= 10.0 && (8.0..18.0).contains(&y)
        }

        /// Head center at frame `f`: swings 34 px either side in 16 frames.
        fn head(f: i64) -> Vec2 {
            Vec2::new(96.0 + 34.0 * (2.0 * std::f64::consts::PI * f as f64 / 16.0).sin(), 30.0)
        }

        /// Signed distance (px, negative inside) to the subject: body rectangle 76...116 x 46...108 and the head disc.
        fn subject_distance(x: f64, y: f64, c: Vec2, wobble: &dyn Fn(f64) -> f64) -> f64 {
            let dx = (76.0 - x).max(x - 116.0).max(0.0);
            let dy = (46.0 - y).max(0.0);
            let in_body = (76.0..=116.0).contains(&x) && y >= 46.0;
            let body = if in_body { -(x - 76.0).min(116.0 - x).min(y - 46.0) } else { (dx * dx + dy * dy).sqrt() };
            let (hx, hy) = (x - c.x, y - c.y);
            let disc = (hx * hx + hy * hy).sqrt() - (HEAD_RADIUS + wobble(hy.atan2(hx)));
            body.min(disc)
        }

        /// Background object (a still lamp) right of the body: 124...150 x 20...100.
        fn lamp(x: f64, y: f64) -> bool {
            (124.0..150.0).contains(&x) && (20.0..100.0).contains(&y)
        }

        /// The true subject at frame `f` (anti-aliased).
        pub fn truth(f: i64) -> SubjectMatte {
            let c = Self::head(f);
            let mut v = vec![0.0_f32; W * H];
            for y in 0..H {
                for x in 0..W {
                    v[y * W + x] = (0.5 - Self::subject_distance(x as f64 + 0.5, y as f64 + 0.5, c, &|_| 0.0))
                        .clamp(0.0, 1.0) as f32;
                }
            }
            SubjectMatte::new(W, H, v)
        }

        /// The true subject with the hat.
        pub fn truth_with_hat(f: i64) -> SubjectMatte {
            let mut m = Self::truth(f);
            let c = Self::head(f);
            for y in 0..H {
                for x in 0..W {
                    if Self::in_hat(x as f64 + 0.5, y as f64 + 0.5, c) {
                        m.values[y * W + x] = 1.0;
                    }
                }
            }
            m
        }

        /// What the segmenter sees at frame `f`: labels (subject 1, lamp 2, their numbers swap every frame) with a
        /// wobbling subject edge (peak 2 px), the hard labels as soft matte, and the picture.
        pub fn frame(&mut self, f: i64) -> InstanceFrame {
            let mut harmonics = Vec::new();
            for k in [2.0, 3.0, 5.0] {
                let a = self.rng.symmetric();
                let p = self.rng.next() * 2.0 * std::f64::consts::PI;
                harmonics.push((k, a, p));
            }
            let total = harmonics.iter().fold(0.0, |s, h| s + h.1.abs());
            let amp = if total > 0.0 { 2.0 / total } else { 0.0 };
            let wob = |th: f64| harmonics.iter().fold(0.0, |s, h| s + h.1 * amp * (h.0 * th + h.2).sin());
            let c = Self::head(f);
            let (subject, other): (u8, u8) = if f % 2 == 0 { (1, 2) } else { (2, 1) };
            let mut l = vec![0_u8; W * H];
            let mut rgb = vec![0.0_f32; W * H * 3];
            for y in 0..H {
                for x in 0..W {
                    let (px, py) = (x as f64 + 0.5, y as f64 + 0.5);
                    let i = y * W + x;
                    if Self::lamp(px, py) {
                        l[i] = if self.merge_lamp { subject } else { other };
                    }
                    if Self::subject_distance(px, py, c, &wob) <= 0.0 {
                        l[i] = subject;
                    }
                    // Picture: wall gray, lamp yellow, skin/shirt (truth, no wobble).
                    let mut col = (0.45_f32, 0.45_f32, 0.47_f32);
                    if Self::lamp(px, py) {
                        col = (0.85, 0.8, 0.3);
                    }
                    let truth_d = Self::subject_distance(px, py, c, &|_| 0.0);
                    if truth_d <= 0.0 {
                        col = if py < 46.0 { (0.8, 0.6, 0.5) } else { (0.2, 0.3, 0.7) };
                    }
                    if self.hat && Self::in_hat(px, py, c) && truth_d > 0.0 {
                        col = (0.8, 0.1, 0.1);
                    }
                    rgb[i * 3] = col.0;
                    rgb[i * 3 + 1] = col.1;
                    rgb[i * 3 + 2] = col.2;
                }
            }
            InstanceFrame::new(InstanceLabels::new(W, H, l), Some(MagicGuide::new(W, H, rgb)))
        }
    }

    /// Soft IoU, hard IoU (0.5) and leak of `m` against `truth`.
    pub fn matte_scores(m: &SubjectMatte, truth: &SubjectMatte) -> (f64, f64, f64) {
        let (mut mn, mut mx, mut hi, mut hu, mut leak, mut area) =
            (0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64);
        for i in 0..truth.values.len() {
            let (a, b) = (f64::from(m.values[i]), f64::from(truth.values[i]));
            mn += a.min(b);
            mx += a.max(b);
            let (ha, hb) = (a >= 0.5, b >= 0.5);
            if ha && hb {
                hi += 1.0;
            }
            if ha || hb {
                hu += 1.0;
            }
            leak += (a - b).max(0.0);
            area += b;
        }
        (
            if mx > 0.0 { mn / mx } else { 1.0 },
            if hu > 0.0 { hi / hu } else { 1.0 },
            if area > 0.0 { leak / area } else { 0.0 },
        )
    }
}

use sq_core_model::{Clip, ClipMask, MaskPath, MaskShapeKind, TrackKind};
use sq_core_time::{Id, Keyframe, KeyframeTrack, Time, TimeRange};

/// A 4 s video clip at 10 s.
pub fn test_clip() -> Clip {
    Clip::new(
        Id::from_u128(0xC0DE),
        "c",
        Id::from_u128(0xAED1A),
        TrackKind::Video,
        TimeRange::new(Time::ZERO, Time::new(4, 1)),
        Time::new(10, 1),
    )
}

/// A path mask with Swift's defaults and a fixed id.
pub fn test_mask(path: MaskPath) -> ClipMask {
    ClipMask::new(Id::from_u128(0x3A5C), "Mask", MaskShapeKind::Bezier, path)
}

/// A track of linear keys with fixed ids.
pub fn keys<V: sq_core_time::KeyframeValue>(items: &[(Time, V)]) -> KeyframeTrack<V> {
    KeyframeTrack::with_keys(
        items
            .iter()
            .enumerate()
            .map(|(i, (t, v))| Keyframe::new(Id::from_u128(0x100 + i as u128), *t, v.clone()))
            .collect(),
    )
}

/// Deterministic noise in -1...1 (the SplitMix of the Swift tests).
pub struct SplitMix(u64);

impl SplitMix {
    pub fn new(seed: u64) -> SplitMix {
        SplitMix(seed)
    }

    fn raw(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    pub fn unit(&mut self) -> f64 {
        (self.raw() >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0
    }
}
