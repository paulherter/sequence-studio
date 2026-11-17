//! Small vector and matrix types for the color maths. They mirror the Swift `SIMD3<Float>` / `simd_float3x3` /
//! `simd_double3x3` use one to one: f32 stays f32 and the operation order is the Swift order.

use std::ops::{Add, AddAssign, Div, Index, IndexMut, Mul, MulAssign, Neg, Sub};

/// Three f32 channels (RGB, XYZ or any triple).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Vec3 {
    /// First channel.
    pub x: f32,
    /// Second channel.
    pub y: f32,
    /// Third channel.
    pub z: f32,
}

impl Vec3 {
    /// All zero.
    pub const ZERO: Vec3 = Vec3::splat(0.0);
    /// All one.
    pub const ONE: Vec3 = Vec3::splat(1.0);

    /// New vector.
    pub const fn new(x: f32, y: f32, z: f32) -> Vec3 {
        Vec3 { x, y, z }
    }

    /// The same value in every channel.
    pub const fn splat(v: f32) -> Vec3 {
        Vec3 { x: v, y: v, z: v }
    }

    /// Dot product (`x*x' + y*y' + z*z'`).
    pub fn dot(self, o: Vec3) -> f32 {
        self.x * o.x + self.y * o.y + self.z * o.z
    }

    /// Euclidean length.
    pub fn length(self) -> f32 {
        self.dot(self).sqrt()
    }

    /// Applies `f` to each channel.
    pub fn map(self, f: impl Fn(f32) -> f32) -> Vec3 {
        Vec3::new(f(self.x), f(self.y), f(self.z))
    }

    /// Channel-wise minimum.
    pub fn min(self, o: Vec3) -> Vec3 {
        Vec3::new(self.x.min(o.x), self.y.min(o.y), self.z.min(o.z))
    }

    /// Channel-wise maximum.
    pub fn max(self, o: Vec3) -> Vec3 {
        Vec3::new(self.x.max(o.x), self.y.max(o.y), self.z.max(o.z))
    }

    /// Channel-wise clamp (`max(min(v, hi), lo)` like `simd_clamp`).
    pub fn clamp(self, lo: Vec3, hi: Vec3) -> Vec3 {
        self.min(hi).max(lo)
    }

    /// Largest channel.
    pub fn max_elem(self) -> f32 {
        self.x.max(self.y.max(self.z))
    }

    /// Smallest channel.
    pub fn min_elem(self) -> f32 {
        self.x.min(self.y.min(self.z))
    }

    /// True when all channels are finite.
    pub fn is_finite(self) -> bool {
        self.x.is_finite() && self.y.is_finite() && self.z.is_finite()
    }
}

impl From<[f32; 3]> for Vec3 {
    fn from(a: [f32; 3]) -> Vec3 {
        Vec3::new(a[0], a[1], a[2])
    }
}

impl From<Vec3> for [f32; 3] {
    fn from(v: Vec3) -> [f32; 3] {
        [v.x, v.y, v.z]
    }
}

impl Index<usize> for Vec3 {
    type Output = f32;
    fn index(&self, i: usize) -> &f32 {
        match i {
            0 => &self.x,
            1 => &self.y,
            _ => &self.z,
        }
    }
}

impl IndexMut<usize> for Vec3 {
    fn index_mut(&mut self, i: usize) -> &mut f32 {
        match i {
            0 => &mut self.x,
            1 => &mut self.y,
            _ => &mut self.z,
        }
    }
}

impl Add for Vec3 {
    type Output = Vec3;
    fn add(self, o: Vec3) -> Vec3 {
        Vec3::new(self.x + o.x, self.y + o.y, self.z + o.z)
    }
}

impl Sub for Vec3 {
    type Output = Vec3;
    fn sub(self, o: Vec3) -> Vec3 {
        Vec3::new(self.x - o.x, self.y - o.y, self.z - o.z)
    }
}

impl Mul for Vec3 {
    type Output = Vec3;
    fn mul(self, o: Vec3) -> Vec3 {
        Vec3::new(self.x * o.x, self.y * o.y, self.z * o.z)
    }
}

impl Mul<f32> for Vec3 {
    type Output = Vec3;
    fn mul(self, s: f32) -> Vec3 {
        Vec3::new(self.x * s, self.y * s, self.z * s)
    }
}

impl Mul<Vec3> for f32 {
    type Output = Vec3;
    fn mul(self, v: Vec3) -> Vec3 {
        Vec3::new(self * v.x, self * v.y, self * v.z)
    }
}

impl Div for Vec3 {
    type Output = Vec3;
    fn div(self, o: Vec3) -> Vec3 {
        Vec3::new(self.x / o.x, self.y / o.y, self.z / o.z)
    }
}

impl Div<f32> for Vec3 {
    type Output = Vec3;
    fn div(self, s: f32) -> Vec3 {
        Vec3::new(self.x / s, self.y / s, self.z / s)
    }
}

impl Neg for Vec3 {
    type Output = Vec3;
    fn neg(self) -> Vec3 {
        Vec3::new(-self.x, -self.y, -self.z)
    }
}

impl AddAssign for Vec3 {
    fn add_assign(&mut self, o: Vec3) {
        *self = *self + o;
    }
}

impl MulAssign<f32> for Vec3 {
    fn mul_assign(&mut self, s: f32) {
        *self = *self * s;
    }
}

/// Column-major 3x3 f32 matrix (`simd_float3x3`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Mat3 {
    /// The three columns.
    pub cols: [Vec3; 3],
}

impl Mat3 {
    /// The identity.
    pub const IDENTITY: Mat3 =
        Mat3 { cols: [Vec3::new(1.0, 0.0, 0.0), Vec3::new(0.0, 1.0, 0.0), Vec3::new(0.0, 0.0, 1.0)] };

    /// Matrix from columns.
    pub const fn from_cols(a: Vec3, b: Vec3, c: Vec3) -> Mat3 {
        Mat3 { cols: [a, b, c] }
    }

    /// `m * v`: `col0*v.x + col1*v.y + col2*v.z`, fused multiply-adds in the order the Apple simd routine uses (exactly
    /// specified by IEEE 754, so the result is the same on every platform).
    pub fn mul_vec(&self, v: Vec3) -> Vec3 {
        let [a, b, c] = self.cols;
        let ch = |a: f32, b: f32, c: f32| c.mul_add(v.z, b.mul_add(v.y, a * v.x));
        Vec3::new(ch(a.x, b.x, c.x), ch(a.y, b.y, c.y), ch(a.z, b.z, c.z))
    }

    /// `self * o` (apply `o` first).
    pub fn mul_mat(&self, o: &Mat3) -> Mat3 {
        Mat3::from_cols(self.mul_vec(o.cols[0]), self.mul_vec(o.cols[1]), self.mul_vec(o.cols[2]))
    }

    /// Inverse, computed in f64 and rounded (the Swift `inverse` is the f32 simd routine, within a few ulps).
    pub fn inverse(&self) -> Mat3 {
        Mat3d::from_f32(self).inverse().to_f32()
    }
}

/// Column-major 3x3 f64 matrix (`simd_double3x3`), used for the gamut and white point maths.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Mat3d {
    /// The three columns.
    pub cols: [[f64; 3]; 3],
}

impl Mat3d {
    /// Diagonal matrix.
    pub fn diagonal(d: [f64; 3]) -> Mat3d {
        Mat3d { cols: [[d[0], 0.0, 0.0], [0.0, d[1], 0.0], [0.0, 0.0, d[2]]] }
    }

    /// Matrix from rows (`simd_double3x3(rows:)`).
    pub fn from_rows(r: [[f64; 3]; 3]) -> Mat3d {
        Mat3d { cols: [[r[0][0], r[1][0], r[2][0]], [r[0][1], r[1][1], r[2][1]], [r[0][2], r[1][2], r[2][2]]] }
    }

    fn from_f32(m: &Mat3) -> Mat3d {
        let c = |v: Vec3| [f64::from(v.x), f64::from(v.y), f64::from(v.z)];
        Mat3d { cols: [c(m.cols[0]), c(m.cols[1]), c(m.cols[2])] }
    }

    /// Rounds every entry to f32.
    pub fn to_f32(&self) -> Mat3 {
        let c = |v: [f64; 3]| Vec3::new(v[0] as f32, v[1] as f32, v[2] as f32);
        Mat3::from_cols(c(self.cols[0]), c(self.cols[1]), c(self.cols[2]))
    }

    /// `m * v`.
    pub fn mul_vec(&self, v: [f64; 3]) -> [f64; 3] {
        let c = &self.cols;
        [0, 1, 2].map(|i| c[0][i] * v[0] + c[1][i] * v[1] + c[2][i] * v[2])
    }

    /// `self * o`.
    pub fn mul_mat(&self, o: &Mat3d) -> Mat3d {
        Mat3d { cols: [self.mul_vec(o.cols[0]), self.mul_vec(o.cols[1]), self.mul_vec(o.cols[2])] }
    }

    /// Inverse (adjugate over determinant). A singular matrix gives non-finite entries, like simd.
    pub fn inverse(&self) -> Mat3d {
        let [a, b, c] = self.cols;
        // Rows of the inverse are the cross products of the other two columns over the determinant.
        let cross = |u: [f64; 3], v: [f64; 3]| {
            [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
        };
        let r0 = cross(b, c);
        let r1 = cross(c, a);
        let r2 = cross(a, b);
        let det = a[0] * r0[0] + a[1] * r0[1] + a[2] * r0[2];
        let s = 1.0 / det;
        Mat3d::from_rows([r0.map(|v| v * s), r1.map(|v| v * s), r2.map(|v| v * s)])
    }
}
