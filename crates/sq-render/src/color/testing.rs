//! Test helpers shared by the color tests.

use super::cube_lut::{CubeKind, CubeLut};
use super::vec::Vec3;

/// The LCG of the Swift tests (`LCG` in CubeLUTTests.swift).
pub struct Lcg(pub u64);

impl Lcg {
    pub fn next_f32(&mut self) -> f32 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (self.0 >> 40) as f32 / (1u32 << 24) as f32
    }

    pub fn rgb(&mut self) -> Vec3 {
        Vec3::new(self.next_f32(), self.next_f32(), self.next_f32())
    }
}

/// Euclidean distance.
pub fn dist(a: Vec3, b: Vec3) -> f32 {
    (a - b).length()
}

/// `.cube` text of the identity cube.
pub fn identity_cube_3d(n: usize, extra: &str) -> String {
    let mut s = format!("TITLE \"id\"\n{extra}LUT_3D_SIZE {n}\n");
    let d = (n - 1) as f32;
    for b in 0..n {
        for g in 0..n {
            for r in 0..n {
                s += &format!("{} {} {}\n", r as f32 / d, g as f32 / d, b as f32 / d);
            }
        }
    }
    s
}

/// A 3D LUT whose entries are `f(r/(n-1), g/(n-1), b/(n-1))`.
pub fn lut_from(n: usize, f: impl Fn(Vec3) -> Vec3) -> CubeLut {
    let d = (n - 1) as f32;
    let mut t = Vec::new();
    for b in 0..n {
        for g in 0..n {
            for r in 0..n {
                t.push(f(Vec3::new(r as f32, g as f32, b as f32) / d));
            }
        }
    }
    CubeLut::new("", CubeKind::Lut3D, n, (Vec3::ZERO, Vec3::ONE), t, (false, false)).expect("valid table")
}

/// The identity LUT.
pub fn identity_lut(n: usize) -> CubeLut {
    lut_from(n, |v| v)
}

/// A constant LUT.
pub fn constant_lut(v: f32) -> CubeLut {
    CubeLut::new("", CubeKind::Lut3D, 2, (Vec3::ZERO, Vec3::ONE), vec![Vec3::splat(v); 8], (false, false))
        .expect("valid table")
}
