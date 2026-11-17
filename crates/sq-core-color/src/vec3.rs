// SPDX-License-Identifier: GPL-3.0-or-later
//! Three-channel float helpers for Swift's `SIMD3<Float>` math: the same operation order as the Swift operators.

/// An RGB or Lab triple (Swift `SIMD3<Float>`).
pub(crate) type V3 = [f32; 3];

/// Component-wise sum.
pub(crate) fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

/// Component-wise difference.
pub(crate) fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

/// Component-wise product.
pub(crate) fn mul(a: V3, b: V3) -> V3 {
    [a[0] * b[0], a[1] * b[1], a[2] * b[2]]
}

/// Every component times `s`.
pub(crate) fn scale(a: V3, s: f32) -> V3 {
    [a[0] * s, a[1] * s, a[2] * s]
}

/// Sum of the components, left to right.
pub(crate) fn sum(a: V3) -> f32 {
    a[0] + a[1] + a[2]
}

/// Largest component.
pub(crate) fn max_of(a: V3) -> f32 {
    a[0].max(a[1]).max(a[2])
}

/// Smallest component.
pub(crate) fn min_of(a: V3) -> f32 {
    a[0].min(a[1]).min(a[2])
}

/// Each component limited to `lo...hi` (`min(max(v, lo), hi)`).
pub(crate) fn clamp3(v: V3, lo: f32, hi: f32) -> V3 {
    v.map(|x| x.max(lo).min(hi))
}

/// Dot-free squared length.
pub(crate) fn length_squared(a: V3) -> f32 {
    sum(mul(a, a))
}
