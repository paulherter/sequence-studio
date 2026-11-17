// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: RegistrationMath.swift
//! Portable registration maths (the Vision and CoreVideo parts extend it in Stabilization.swift, not ported).
use sq_core_masks::stabilizer::CameraMotion;
use sq_core_time::Vec2;

/// Registration helpers.
pub struct Registration;

impl Registration {
    /// Least-squares similarity q = [a -b; b a] p + t through point pairs (Umeyama without reflection).
    pub fn fit_similarity(src: &[Vec2], dst: &[Vec2]) -> Option<CameraMotion> {
        let count = src.len().min(dst.len());
        if count < 2 {
            return None;
        }
        let n = count as f64;
        let (mut mp, mut mq) = (Vec2::ZERO, Vec2::ZERO);
        for i in 0..count {
            mp = mp + src[i];
            mq = mq + dst[i];
        }
        mp = mp * (1.0 / n);
        mq = mq * (1.0 / n);
        let (mut sa, mut sb, mut ss) = (0.0, 0.0, 0.0);
        for i in 0..count {
            let p = src[i] - mp;
            let q = dst[i] - mq;
            sa += p.x * q.x + p.y * q.y;
            sb += p.x * q.y - p.y * q.x;
            ss += p.x * p.x + p.y * p.y;
        }
        if ss <= 0.0 {
            return None;
        }
        let a = sa / ss;
        let b = sb / ss;
        let t = mq - Vec2::new(a * mp.x - b * mp.y, b * mp.x + a * mp.y);
        let s = (a * a + b * b).sqrt();
        if !(s.is_finite() && s > 0.0 && t.x.is_finite() && t.y.is_finite()) {
            return None;
        }
        // [a -b; b a] = s [cos -sin; sin cos] in y-down coordinates: positive angle = clockwise on screen.
        Some(CameraMotion::new(t.x, t.y, b.atan2(a) * 180.0 / std::f64::consts::PI, s))
    }

    /// A frame-to-frame motion a camera can make: under half the frame, under 20 degrees, under 25 % zoom.
    pub fn plausible(m: &CameraMotion, w: i64, h: i64) -> bool {
        m.dx.abs() < w as f64 / 2.0
            && m.dy.abs() < h as f64 / 2.0
            && m.rotation.abs() < 20.0
            && m.scale > 0.8
            && m.scale < 1.25
    }

    /// The motion with both shifts multiplied by `f`.
    pub fn scaled(m: &CameraMotion, f: f64) -> CameraMotion {
        CameraMotion::new(m.dx * f, m.dy * f, m.rotation, m.scale)
    }

    /// Own factor per axis: with non-square pixels (anamorphic) the picture is wider than the stored frame, not taller.
    pub fn scaled_xy(m: &CameraMotion, x: f64, y: f64) -> CameraMotion {
        CameraMotion::new(m.dx * x, m.dy * y, m.rotation, m.scale)
    }

    /// A frame-to-frame scale a camera can make.
    pub fn plausible_scale(m: &CameraMotion) -> bool {
        m.scale > 0.8 && m.scale < 1.25 && m.rotation.abs() < 20.0
    }
}

/// Small deterministic generator: the same frames always give the same motion.
#[derive(Clone, Copy, Debug)]
pub struct SplitMix {
    state: u64,
}

impl SplitMix {
    /// A generator from a seed.
    pub fn new(seed: u64) -> SplitMix {
        SplitMix { state: seed }
    }

    /// The next 64 random bits.
    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_similarity_is_recovered_from_point_pairs() {
        // 90 degrees clockwise on screen, scale 2, shift (5, -3): (x, y) -> (-2y + 5, 2x - 3).
        let src = [Vec2::new(0.0, 0.0), Vec2::new(1.0, 0.0), Vec2::new(0.0, 1.0), Vec2::new(2.0, 3.0)];
        let dst: Vec<Vec2> = src.iter().map(|p| Vec2::new(-2.0 * p.y + 5.0, 2.0 * p.x - 3.0)).collect();
        let m = Registration::fit_similarity(&src, &dst).expect("fit");
        assert!((m.dx - 5.0).abs() < 1e-9 && (m.dy - -3.0).abs() < 1e-9);
        assert!((m.rotation - 90.0).abs() < 1e-9 && (m.scale - 2.0).abs() < 1e-9);
    }

    #[test]
    fn degenerate_pairs_give_nothing() {
        assert!(Registration::fit_similarity(&[Vec2::ZERO], &[Vec2::ZERO]).is_none());
        let same = [Vec2::new(1.0, 1.0), Vec2::new(1.0, 1.0)];
        assert!(Registration::fit_similarity(&same, &same).is_none());
    }

    #[test]
    fn plausible_motions_are_small() {
        assert!(Registration::plausible(&CameraMotion::new(10.0, 5.0, 3.0, 1.05), 100, 100));
        assert!(!Registration::plausible(&CameraMotion::new(60.0, 0.0, 0.0, 1.0), 100, 100));
        assert!(!Registration::plausible_scale(&CameraMotion::new(0.0, 0.0, 25.0, 1.0)));
        assert_eq!(
            Registration::scaled_xy(&CameraMotion::new(2.0, 3.0, 4.0, 1.0), 2.0, 5.0),
            CameraMotion::new(4.0, 15.0, 4.0, 1.0)
        );
    }

    #[test]
    fn the_generator_repeats_for_a_seed() {
        let (mut a, mut b) = (SplitMix::new(7), SplitMix::new(7));
        assert!((0..8).all(|_| a.next_u64() == b.next_u64()));
        assert_ne!(SplitMix::new(7).next_u64(), SplitMix::new(8).next_u64());
    }
}
