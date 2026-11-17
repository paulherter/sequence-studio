// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PerspectiveTilt.swift
//! Perspective tilt of a layer (Tilt X / Tilt Y): the layer plane turns about the horizontal (X) and vertical (Y) axis
//! through its anchor, then a pinhole camera `focal` px in front of that plane projects it. One projective geometry for
//! render, the monitor overlay and hit-testing.
//!
//! Spaces: the input point is the offset from the anchor in sequence px, y down, after scale and in-plane rotation (the
//! tilt axes stay screen-aligned, the way a card turns in front of the camera). Positive Tilt X moves the top edge away
//! from the viewer, positive Tilt Y the right edge. The output is the offset from the anchor on screen.
//!
//! Identity at 0 / 0: `project` returns the input exactly, and the render path is the untouched affine one.

use sq_core_time::Vec2;

/// Largest turn either way; at 90 the plane would be edge-on (a line).
pub const MAX_DEGREES: f64 = 89.0;

/// `degrees` limited to the allowed turn; a non-finite value is 0.
pub fn clamped(degrees: f64) -> f64 {
    if !degrees.is_finite() {
        return 0.0;
    }
    degrees.clamp(-MAX_DEGREES, MAX_DEGREES)
}

/// No tilt on either axis.
pub fn is_identity(tilt_x: f64, tilt_y: f64) -> bool {
    tilt_x == 0.0 && tilt_y == 0.0
}

/// Camera distance in px. It exceeds the farthest point of the layer from its anchor (`layer_radius`, after scale), so
/// no point of the plane can reach or cross the camera plane at any tilt (its depth is at most that radius), and it
/// is never below 1.5 canvas sides, which keeps small layers at a natural strength of perspective.
pub fn focal(layer_radius: f64, canvas: Vec2) -> f64 {
    let r = if layer_radius.is_finite() { layer_radius.max(0.0) } else { 0.0 };
    let side = canvas.x.max(canvas.y).max(1.0);
    (1.5 * side).max(1.5 * r)
}

/// The farthest corner of a `size` layer (px) from `anchor` (layer-local, from the layer center) after `scale`.
pub fn layer_radius(size: Vec2, anchor: Vec2, scale: Vec2) -> f64 {
    let mut m = 0.0_f64;
    for sx in [-0.5, 0.5] {
        for sy in [-0.5, 0.5] {
            let d = Vec2::new((size.x * sx - anchor.x) * scale.x.max(0.0), (size.y * sy - anchor.y) * scale.y.max(0.0));
            m = m.max(d.length());
        }
    }
    m
}

fn rotated(x: f64, y: f64, z: f64, tilt_x: f64, tilt_y: f64) -> (f64, f64, f64) {
    let a = clamped(tilt_x) * std::f64::consts::PI / 180.0;
    let b = clamped(tilt_y) * std::f64::consts::PI / 180.0;
    let (ca, sa, cb, sb) = (a.cos(), a.sin(), b.cos(), b.sin());
    let y1 = y * ca + z * sa;
    let z1 = -y * sa + z * ca;
    (x * cb - z1 * sb, y1, x * sb + z1 * cb)
}

/// `(focal + depth) / focal` of the plane point `p` after the turn: the vertex stage's `w`. Positive for every point of
/// a layer within the radius `focal` was derived from.
pub fn depth_divisor(p: Vec2, tilt_x: f64, tilt_y: f64, focal: f64) -> f64 {
    let r = rotated(p.x, p.y, 0.0, tilt_x, tilt_y);
    (focal + r.2) / focal
}

/// Plane point `p` to its place on screen.
pub fn project(p: Vec2, tilt_x: f64, tilt_y: f64, focal: f64) -> Vec2 {
    if is_identity(tilt_x, tilt_y) {
        return p;
    }
    let r = rotated(p.x, p.y, 0.0, tilt_x, tilt_y);
    let w = (focal + r.2) / focal;
    if w <= 1e-6 {
        return Vec2::new(r.0 * 1e6, r.1 * 1e6);
    }
    Vec2::new(r.0 / w, r.1 / w)
}

/// Screen offset `q` back to the plane point that lands there (the ray through `q` meets the turned plane).
pub fn unproject(q: Vec2, tilt_x: f64, tilt_y: f64, focal: f64) -> Vec2 {
    if is_identity(tilt_x, tilt_y) {
        return q;
    }
    let a = clamped(tilt_x) * std::f64::consts::PI / 180.0;
    let b = clamped(tilt_y) * std::f64::consts::PI / 180.0;
    let (ca, sa, cb, sb) = (a.cos(), a.sin(), b.cos(), b.sin());
    // Plane normal after the turn: the turned (0, 0, 1).
    let n = rotated(0.0, 0.0, 1.0, tilt_x, tilt_y);
    // Camera at depth -focal; a ray through screen point q: P(k) = (q.x k, q.y k, focal (k - 1)); n . P = 0.
    let den = n.0 * q.x + n.1 * q.y + n.2 * focal;
    if den.abs() <= 1e-12 {
        return q;
    }
    let k = n.2 * focal / den;
    let (x2, y1, z2) = (q.x * k, q.y * k, focal * (k - 1.0));
    // Undo the turn about Y, then about X.
    let x = x2 * cb + z2 * sb;
    let z1 = -x2 * sb + z2 * cb;
    let y = y1 * ca - z1 * sa;
    Vec2::new(x, y)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn near(a: Vec2, b: Vec2, eps: f64) -> bool {
        (a.x - b.x).abs() < eps && (a.y - b.y).abs() < eps
    }

    #[test]
    fn identity_at_zero() {
        let p = Vec2::new(123.5, -77.25);
        assert_eq!(project(p, 0.0, 0.0, 1000.0), p);
        assert_eq!(unproject(p, 0.0, 0.0, 1000.0), p);
        assert!(is_identity(0.0, 0.0));
        assert!(!is_identity(0.0, 0.5));
    }

    #[test]
    fn anchor_stays_put() {
        assert_eq!(project(Vec2::ZERO, 40.0, -30.0, 900.0), Vec2::ZERO);
    }

    #[test]
    fn tilt_y_foreshortens_width_and_shrinks_the_far_edge() {
        let f = 1000.0;
        let right = project(Vec2::new(200.0, 100.0), 0.0, 45.0, f);
        let left = project(Vec2::new(-200.0, 100.0), 0.0, 45.0, f);
        assert!(right.x.abs() < 200.0 && left.x.abs() < 200.0);
        assert!(right.y < 100.0 && left.y > 100.0);
        let b = 45.0 * std::f64::consts::PI / 180.0;
        let s = f / (f + 200.0 * b.sin());
        assert!(near(right, Vec2::new(200.0 * b.cos() * s, 100.0 * s), 1e-9));
    }

    #[test]
    fn tilt_x_moves_the_top_away() {
        let f = 1000.0;
        let top = project(Vec2::new(100.0, -100.0), 30.0, 0.0, f);
        let bottom = project(Vec2::new(100.0, 100.0), 30.0, 0.0, f);
        assert!(top.x < 100.0 && bottom.x > 100.0);
    }

    #[test]
    fn unproject_inverts_project() {
        let cases = [(0.0, 0.0), (20.0, 0.0), (0.0, -35.0), (50.0, 40.0), (-80.0, 75.0), (89.0, -89.0)];
        for (a, b) in cases {
            for p in [Vec2::new(0.0, 0.0), Vec2::new(120.0, 80.0), Vec2::new(-300.0, 40.0), Vec2::new(10.0, -250.0)] {
                let f = focal(400.0, Vec2::new(1920.0, 1080.0));
                let q = project(p, a, b, f);
                assert!(near(unproject(q, a, b, f), p, 1e-6));
            }
        }
    }

    #[test]
    fn tilt_is_clamped_and_the_quad_never_crosses_the_camera_plane() {
        assert_eq!(clamped(200.0), 89.0);
        assert_eq!(clamped(-200.0), -89.0);
        assert_eq!(clamped(f64::NAN), 0.0);
        let f = focal(50_000.0, Vec2::new(1920.0, 1080.0));
        assert!(f > 50_000.0);
        for c in [
            Vec2::new(50_000.0, 0.0),
            Vec2::new(-50_000.0, 0.0),
            Vec2::new(0.0, 50_000.0),
            Vec2::new(0.0, -50_000.0),
            Vec2::new(35_000.0, 35_000.0),
        ] {
            assert!(depth_divisor(c, 89.0, 89.0, f) > 0.0);
        }
        assert!(focal(10.0, Vec2::new(1920.0, 1080.0)) >= 1920.0);
    }

    #[test]
    fn layer_radius_is_the_farthest_scaled_corner() {
        let r = layer_radius(Vec2::new(200.0, 100.0), Vec2::ZERO, Vec2::new(2.0, 1.0));
        assert!((r - (200.0_f64 * 200.0 + 50.0 * 50.0).sqrt()).abs() < 1e-9);
    }
}
