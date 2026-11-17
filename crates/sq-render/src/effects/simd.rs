// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PortableSIMD.swift, plus the SIMD2/3/4 operators the effect references use
//! Small vectors and matrices with the operator semantics of Swift's `SIMD` types (component-wise, scalar broadcast) and of
//! the portable `simd` replacements: plain scalar Rust, no `std::simd`, the same operation order as Swift so the f32
//! results match. Matrices are column-major like Apple's `simd_float3x3`.

use std::ops::{Add, AddAssign, Div, DivAssign, Index, Mul, MulAssign, Neg, Sub, SubAssign};

/// Swift's `Float.pi`: pi rounded toward zero (0x1.921fb4p1), one ulp below `std::f32::consts::PI`. Every Swift expression
/// that uses `.pi` as a `Float` needs this value to give the same bits.
pub const SWIFT_FLOAT_PI: f32 = f32::from_bits(0x4049_0FDA);

/// The float types the vectors work on (`f32` and `f64`).
pub trait Scalar:
    Copy
    + PartialOrd
    + Add<Output = Self>
    + Sub<Output = Self>
    + Mul<Output = Self>
    + Div<Output = Self>
    + Neg<Output = Self>
    + std::fmt::Debug
{
    /// 0.
    const ZERO: Self;
    /// 1.
    const ONE: Self;
    /// Absolute value.
    fn abs(self) -> Self;
    /// Square root.
    fn sqrt(self) -> Self;
    /// Rounded up.
    fn ceil(self) -> Self;
    /// Rounded down.
    fn floor(self) -> Self;
}

macro_rules! scalar_impl {
    ($t:ty) => {
        impl Scalar for $t {
            const ZERO: Self = 0.0;
            const ONE: Self = 1.0;
            fn abs(self) -> Self {
                <$t>::abs(self)
            }
            fn sqrt(self) -> Self {
                <$t>::sqrt(self)
            }
            fn ceil(self) -> Self {
                <$t>::ceil(self)
            }
            fn floor(self) -> Self {
                <$t>::floor(self)
            }
        }
    };
}
scalar_impl!(f32);
scalar_impl!(f64);

fn smin<S: Scalar>(a: S, b: S) -> S {
    if b < a { b } else { a }
}
fn smax<S: Scalar>(a: S, b: S) -> S {
    if b > a { b } else { a }
}

macro_rules! vec_type {
    ($name:ident, $n:expr, [$($f:ident),+]) => {
        /// A component-wise vector (Swift `SIMD`).
        #[derive(Clone, Copy, Debug, PartialEq, Default)]
        pub struct $name<S> {
            $(
                /// Component.
                pub $f: S,
            )+
        }
        impl<S: Scalar> $name<S> {
            /// All components zero.
            pub const ZERO: Self = Self { $($f: S::ZERO),+ };
            /// From the components.
            pub const fn new($($f: S),+) -> Self {
                Self { $($f),+ }
            }
            /// Every component `s`.
            pub const fn splat(s: S) -> Self {
                Self { $($f: s),+ }
            }
            /// Left-to-right sum of the components.
            pub fn sum(self) -> S {
                let a = [$(self.$f),+];
                let mut r = a[0];
                for v in &a[1..] {
                    r = r + *v;
                }
                r
            }
            /// Largest component.
            pub fn max_element(self) -> S {
                let a = [$(self.$f),+];
                let mut r = a[0];
                for v in &a[1..] {
                    r = smax(r, *v);
                }
                r
            }
            /// `simd_dot`: the sum of the component products.
            pub fn dot(self, o: Self) -> S {
                (self * o).sum()
            }
            /// `simd_length`.
            pub fn length(self) -> S {
                self.dot(self).sqrt()
            }
            /// Component-wise minimum.
            pub fn min(self, o: Self) -> Self {
                Self { $($f: smin(self.$f, o.$f)),+ }
            }
            /// Component-wise maximum.
            pub fn max(self, o: Self) -> Self {
                Self { $($f: smax(self.$f, o.$f)),+ }
            }
            /// `simd_clamp`: `min(max(self, lo), hi)`.
            pub fn clamp(self, lo: Self, hi: Self) -> Self {
                self.max(lo).min(hi)
            }
            /// Component-wise absolute value.
            pub fn abs(self) -> Self {
                Self { $($f: self.$f.abs()),+ }
            }
            /// Component-wise round up.
            pub fn ceil(self) -> Self {
                Self { $($f: self.$f.ceil()),+ }
            }
            /// Component-wise round down.
            pub fn floor(self) -> Self {
                Self { $($f: self.$f.floor()),+ }
            }
            /// Sets component `i` (ignored when out of range).
            pub fn set(&mut self, i: usize, v: S) {
                if let Some(c) = [$(&mut self.$f),+].into_iter().nth(i) {
                    *c = v;
                }
            }
            /// `simd_mix`: `a + (b - a) * t`.
            pub fn mix(a: Self, b: Self, t: Self) -> Self {
                a + (b - a) * t
            }
        }
        impl<S: Scalar> Add for $name<S> {
            type Output = Self;
            fn add(self, o: Self) -> Self {
                Self { $($f: self.$f + o.$f),+ }
            }
        }
        impl<S: Scalar> Sub for $name<S> {
            type Output = Self;
            fn sub(self, o: Self) -> Self {
                Self { $($f: self.$f - o.$f),+ }
            }
        }
        impl<S: Scalar> Mul for $name<S> {
            type Output = Self;
            fn mul(self, o: Self) -> Self {
                Self { $($f: self.$f * o.$f),+ }
            }
        }
        impl<S: Scalar> Div for $name<S> {
            type Output = Self;
            fn div(self, o: Self) -> Self {
                Self { $($f: self.$f / o.$f),+ }
            }
        }
        impl<S: Scalar> Add<S> for $name<S> {
            type Output = Self;
            fn add(self, s: S) -> Self {
                Self { $($f: self.$f + s),+ }
            }
        }
        impl<S: Scalar> Sub<S> for $name<S> {
            type Output = Self;
            fn sub(self, s: S) -> Self {
                Self { $($f: self.$f - s),+ }
            }
        }
        impl<S: Scalar> Mul<S> for $name<S> {
            type Output = Self;
            fn mul(self, s: S) -> Self {
                Self { $($f: self.$f * s),+ }
            }
        }
        impl<S: Scalar> Div<S> for $name<S> {
            type Output = Self;
            fn div(self, s: S) -> Self {
                Self { $($f: self.$f / s),+ }
            }
        }
        impl<S: Scalar> Neg for $name<S> {
            type Output = Self;
            fn neg(self) -> Self {
                Self { $($f: -self.$f),+ }
            }
        }
        impl<S: Scalar> AddAssign for $name<S> {
            fn add_assign(&mut self, o: Self) {
                *self = *self + o;
            }
        }
        impl<S: Scalar> SubAssign for $name<S> {
            fn sub_assign(&mut self, o: Self) {
                *self = *self - o;
            }
        }
        impl<S: Scalar> MulAssign<S> for $name<S> {
            fn mul_assign(&mut self, s: S) {
                *self = *self * s;
            }
        }
        impl<S: Scalar> DivAssign<S> for $name<S> {
            fn div_assign(&mut self, s: S) {
                *self = *self / s;
            }
        }
        impl<S: Scalar> Index<usize> for $name<S> {
            type Output = S;
            fn index(&self, i: usize) -> &S {
                [$(&self.$f),+][i]
            }
        }
        vec_scalar_lhs!($name, f32, [$($f),+]);
        vec_scalar_lhs!($name, f64, [$($f),+]);
    };
}

macro_rules! vec_scalar_lhs {
    ($name:ident, $t:ty, [$($f:ident),+]) => {
        impl Mul<$name<$t>> for $t {
            type Output = $name<$t>;
            fn mul(self, v: $name<$t>) -> $name<$t> {
                $name { $($f: self * v.$f),+ }
            }
        }
        impl Add<$name<$t>> for $t {
            type Output = $name<$t>;
            fn add(self, v: $name<$t>) -> $name<$t> {
                $name { $($f: self + v.$f),+ }
            }
        }
        impl Sub<$name<$t>> for $t {
            type Output = $name<$t>;
            fn sub(self, v: $name<$t>) -> $name<$t> {
                $name { $($f: self - v.$f),+ }
            }
        }
    };
}

vec_type!(V2, 2, [x, y]);
vec_type!(V3, 3, [x, y, z]);
vec_type!(V4, 4, [x, y, z, w]);

/// `SIMD2<Float>`.
pub type Float2 = V2<f32>;
/// `SIMD3<Float>`.
pub type Float3 = V3<f32>;
/// `SIMD4<Float>`.
pub type Float4 = V4<f32>;

/// `SIMD4<Int32>`: the integer lanes of the filter constants.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Int4 {
    /// Lane 0.
    pub x: i32,
    /// Lane 1.
    pub y: i32,
    /// Lane 2.
    pub z: i32,
    /// Lane 3.
    pub w: i32,
}

impl Int4 {
    /// From the lanes.
    pub const fn new(x: i32, y: i32, z: i32, w: i32) -> Self {
        Self { x, y, z, w }
    }
}

impl<S: Scalar> V4<S> {
    /// The first three components.
    pub fn xyz(self) -> V3<S> {
        V3::new(self.x, self.y, self.z)
    }
}

impl V3<f32> {
    /// `SIMD3<Float>(Double ...)`: each component rounded to f32.
    pub fn from_f64(v: [f64; 3]) -> Self {
        Self::new(v[0] as f32, v[1] as f32, v[2] as f32)
    }
}

/// A 3x3 matrix of columns (Apple's `simd_float3x3` / `simd_double3x3`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Matrix3<S> {
    /// The three columns.
    pub columns: [V3<S>; 3],
}

impl<S: Scalar> Matrix3<S> {
    /// From columns.
    pub fn from_columns(c0: V3<S>, c1: V3<S>, c2: V3<S>) -> Self {
        Self { columns: [c0, c1, c2] }
    }

    /// From rows.
    pub fn from_rows(r0: V3<S>, r1: V3<S>, r2: V3<S>) -> Self {
        Self::from_columns(V3::new(r0.x, r1.x, r2.x), V3::new(r0.y, r1.y, r2.y), V3::new(r0.z, r1.z, r2.z))
    }

    /// The diagonal matrix of `d`.
    pub fn diagonal(d: V3<S>) -> Self {
        let z = S::ZERO;
        Self::from_columns(V3::new(d.x, z, z), V3::new(z, d.y, z), V3::new(z, z, d.z))
    }

    /// The identity.
    pub fn identity() -> Self {
        Self::diagonal(V3::splat(S::ONE))
    }

    /// Rows become columns.
    pub fn transpose(&self) -> Self {
        let [a, b, c] = self.columns;
        Self::from_rows(a, b, c)
    }

    /// Determinant.
    pub fn determinant(&self) -> S {
        let [a, b, c] = self.columns;
        a.x * (b.y * c.z - c.y * b.z) - b.x * (a.y * c.z - c.y * a.z) + c.x * (a.y * b.z - b.y * a.z)
    }

    /// Inverse by the adjugate (a singular matrix gives non-finite values, as simd does).
    pub fn inverse(&self) -> Self {
        fn cross<S: Scalar>(u: V3<S>, v: V3<S>) -> V3<S> {
            V3::new(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
        }
        let [a, b, c] = self.columns;
        let d = self.determinant();
        Self::from_rows(cross(b, c) / d, cross(c, a) / d, cross(a, b) / d)
    }

    /// Matrix times vector.
    pub fn mul_vec(&self, v: V3<S>) -> V3<S> {
        self.columns[0] * v.x + self.columns[1] * v.y + self.columns[2] * v.z
    }

    /// Matrix times matrix.
    pub fn mul_mat(&self, n: &Self) -> Self {
        Self::from_columns(self.mul_vec(n.columns[0]), self.mul_vec(n.columns[1]), self.mul_vec(n.columns[2]))
    }

    /// Every element times `s`.
    pub fn scaled(&self, s: S) -> Self {
        Self::from_columns(self.columns[0] * s, self.columns[1] * s, self.columns[2] * s)
    }
}

impl<S: Scalar> Add for Matrix3<S> {
    type Output = Self;
    fn add(self, n: Self) -> Self {
        Self::from_columns(
            self.columns[0] + n.columns[0],
            self.columns[1] + n.columns[1],
            self.columns[2] + n.columns[2],
        )
    }
}

impl<S: Scalar> Sub for Matrix3<S> {
    type Output = Self;
    fn sub(self, n: Self) -> Self {
        Self::from_columns(
            self.columns[0] - n.columns[0],
            self.columns[1] - n.columns[1],
            self.columns[2] - n.columns[2],
        )
    }
}

/// A 2x2 matrix of columns (Apple's `simd_float2x2`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Matrix2<S> {
    /// The two columns.
    pub columns: [V2<S>; 2],
}

impl<S: Scalar> Matrix2<S> {
    /// Determinant.
    pub fn determinant(&self) -> S {
        self.columns[0].x * self.columns[1].y - self.columns[1].x * self.columns[0].y
    }

    /// Inverse by the adjugate.
    pub fn inverse(&self) -> Self {
        let [a, b] = self.columns;
        let d = self.determinant();
        Self { columns: [V2::new(b.y, -a.y) / d, V2::new(-b.x, a.x) / d] }
    }

    /// Matrix times vector.
    pub fn mul_vec(&self, v: V2<S>) -> V2<S> {
        self.columns[0] * v.x + self.columns[1] * v.y
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vectors_follow_the_swift_operators() {
        let a = Float3::new(1.0, 2.0, 3.0);
        assert_eq!(a.dot(Float3::new(4.0, 5.0, 6.0)), 32.0);
        assert_eq!((a * 2.0 + 1.0).max_element(), 7.0);
        assert_eq!(2.0 * a - a, a);
        assert_eq!(Float2::new(3.0, 4.0).length(), 5.0);
        assert_eq!(Float3::new(-1.0, 0.5, 2.0).clamp(Float3::ZERO, Float3::splat(1.0)), Float3::new(0.0, 0.5, 1.0));
        let mut v = Float4::new(1.0, 2.0, 3.0, 4.0);
        v.set(2, 9.0);
        v *= 2.0;
        assert_eq!((v[2], v.xyz().z), (18.0, 18.0));
    }

    #[test]
    fn matrix_inverse_gives_the_identity() {
        let m = Matrix3::<f64>::from_rows(V3::new(2.0, 0.0, 1.0), V3::new(1.0, 3.0, 0.0), V3::new(0.0, 1.0, 4.0));
        let p = m.mul_mat(&m.inverse());
        for c in 0..3 {
            for r in 0..3 {
                let want = if c == r { 1.0 } else { 0.0 };
                assert!((p.columns[c][r] - want).abs() < 1e-12);
            }
        }
        assert_eq!(m.transpose().transpose(), m);
        assert_eq!(Matrix3::<f32>::identity().mul_vec(Float3::new(1.0, 2.0, 3.0)), Float3::new(1.0, 2.0, 3.0));
        assert!((m.determinant() - 25.0).abs() < 1e-12);
        let two = Matrix2::<f32> { columns: [V2::new(2.0, 0.0), V2::new(0.0, 4.0)] };
        assert_eq!(two.inverse().mul_vec(V2::new(2.0, 4.0)), V2::new(1.0, 1.0));
    }
}
