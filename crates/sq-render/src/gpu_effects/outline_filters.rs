// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/OutlineFilters.swift
//! C5 Outline and Long Shadow planning (the Slang kernels are `filterOutline*` and `filterLongShadow*`). Both work on the
//! premultiplied working-linear padded intermediate in texture px, so they run at reduced size unchanged.
//!
//! Outline: a jump-flood distance field to the alpha edge. Seeds are the 0.5 crossings between a pixel and its 4 neighbors; each
//! texel then holds the nearest seed as an integer pixel offset plus the seed's sub-pixel part. log2(reach) + 1 jump passes, then
//! one apply pass. Long Shadow: about log2(length) passes over the alpha, s_k(p) = max(s_k-1(p), s_k-1(p - dir h_k) - fade h_k / L).

use crate::effects::gaussian_blur::MAX_SHAPE_PASS_PIXELS;

/// Seed texels whose x is beyond this are empty.
pub const EMPTY_SEED: f32 = 30_000.0;

/// Jump steps for a distance field that must reach `reach` texture px: powers of two from the first one >= reach / 2 down to 1,
/// then 1 again (the extra pass fixes most jump-flood misses).
pub fn jump_steps(reach: f64) -> Vec<i32> {
    let mut top = 1i32;
    while f64::from(top * 2) < reach {
        top *= 2;
    }
    let mut steps = Vec::new();
    let mut s = top;
    while s >= 1 {
        steps.push(s);
        s /= 2;
    }
    steps.push(1);
    steps
}

/// Size of the Long Shadow plane for a `width x height` working canvas: the same, or reduced (aspect kept) to hold
/// `MAX_SHAPE_PASS_PIXELS`.
pub fn shadow_plane_size(width: u32, height: u32) -> (u32, u32) {
    let (w, h) = (i64::from(width), i64::from(height));
    if w * h <= MAX_SHAPE_PASS_PIXELS {
        return (width, height);
    }
    let r = ((w * h) as f64 / MAX_SHAPE_PASS_PIXELS as f64).sqrt();
    let (mut pw, mut ph) = ((w as f64 / r).floor() as i64, (h as f64 / r).floor() as i64);
    while pw * ph > MAX_SHAPE_PASS_PIXELS {
        pw -= 1;
        ph = (ph - 1).max(1);
    }
    (pw.max(1) as u32, ph.max(1) as u32)
}

/// Step lengths (texture px) of the Long Shadow passes for `length`: 1, 2, 4 ... while their sum stays below the length, then
/// the rest. The sums of any subset then reach every whole px 0...length (and the length itself), never beyond.
pub fn shadow_steps(length: f64) -> Vec<f64> {
    if length <= 0.0 {
        return Vec::new();
    }
    let (mut steps, mut sum, mut h) = (Vec::new(), 0.0, 1.0);
    while sum + h < length {
        steps.push(h);
        sum += h;
        h *= 2.0;
    }
    steps.push(length - sum);
    steps
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jump_steps_halve_down_to_one_and_repeat_it() {
        assert_eq!(jump_steps(1.0), vec![1, 1]);
        assert_eq!(jump_steps(5.0), vec![4, 2, 1, 1]);
        assert_eq!(jump_steps(33.0), vec![32, 16, 8, 4, 2, 1, 1]);
    }

    #[test]
    fn steps_reach_every_pixel_up_to_the_length() {
        for length in [1.0, 2.0, 7.0, 10.0, 100.0] {
            let steps = shadow_steps(length);
            assert!((steps.iter().sum::<f64>() - length).abs() < 1e-9);
            let mut reach = vec![0.0];
            for s in &steps {
                let more: Vec<f64> = reach.iter().map(|r| r + s).collect();
                reach.extend(more);
            }
            for px in 0..=(length.floor() as i64) {
                assert!(reach.iter().any(|r| (r - px as f64).abs() < 1e-9), "length {length}: px {px}");
            }
            assert!(reach.iter().all(|r| *r <= length + 1e-9));
        }
        assert!(shadow_steps(0.0).is_empty());
    }

    #[test]
    fn shadow_plane_holds_its_budget_and_the_aspect() {
        assert_eq!(shadow_plane_size(1920, 1080), (1920, 1080));
        let (w, h) = shadow_plane_size(8192, 4608);
        assert!(i64::from(w) * i64::from(h) <= MAX_SHAPE_PASS_PIXELS);
        assert!((f64::from(w) / f64::from(h) - 8192.0 / 4608.0).abs() < 0.01);
    }
}
