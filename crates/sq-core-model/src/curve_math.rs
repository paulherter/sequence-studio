// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: CurveMath.swift
//! The color curve spline (RGB Curves, Hue Saturation Curves): portable, so the renderer and the curve editors of every
//! platform evaluate one curve the same way.

use crate::CurvePoint;

/// The diagonal every curve starts as.
fn diagonal() -> Vec<CurvePoint> {
    vec![CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 1.0, y: 1.0 }]
}

/// Sorted, deduplicated control points clamped to 0...1; fewer than 2 points = the diagonal.
pub fn normalized(pts: &[CurvePoint]) -> Vec<CurvePoint> {
    let mut p: Vec<CurvePoint> =
        pts.iter().map(|q| CurvePoint { x: q.x.clamp(0.0, 1.0), y: q.y.clamp(0.0, 1.0) }).collect();
    p.sort_by(|a, b| a.x.total_cmp(&b.x));
    let mut out: Vec<CurvePoint> = Vec::new();
    for q in p {
        match out.last_mut() {
            Some(l) if q.x - l.x < 1e-4 => *l = q,
            _ => out.push(q),
        }
    }
    if out.len() < 2 { diagonal() } else { out }
}

/// Monotone cubic Hermite value at `x` (flat beyond the end points).
pub fn evaluate(points: &[CurvePoint], x: f32) -> f32 {
    Spline::new(normalized(points)).value(x)
}

/// `count` values of the curve at x = 0 ... 1.
pub fn sample(points: &[CurvePoint], count: usize) -> Vec<f32> {
    let spline = Spline::new(normalized(points));
    (0..count).map(|i| spline.value(i as f32 / (count - 1) as f32)).collect()
}

/// Precomputed monotone cubic (Fritsch-Carlson) through `p` (already cleaned, at least 2 points, x ascending): the
/// slopes are worked out once, so sampling a curve many times does not repeat that.
#[derive(Clone, Debug, PartialEq)]
pub struct Spline {
    /// The control points.
    pub p: Vec<CurvePoint>,
    /// The slope at each point.
    pub m: Vec<f32>,
}

impl Spline {
    /// The spline through `p`.
    pub fn new(p: Vec<CurvePoint>) -> Spline {
        let n = p.len();
        if n < 2 {
            return Spline { p, m: vec![0.0] };
        }
        let d: Vec<f32> = (0..n - 1).map(|i| (p[i + 1].y - p[i].y) / (p[i + 1].x - p[i].x)).collect();
        let mut m = vec![0.0_f32; n];
        m[0] = d[0];
        m[n - 1] = d[n - 2];
        for i in 1..n - 1 {
            m[i] = if d[i - 1] * d[i] <= 0.0 { 0.0 } else { (d[i - 1] + d[i]) / 2.0 };
        }
        for i in 0..n - 1 {
            if d[i] == 0.0 {
                m[i] = 0.0;
                m[i + 1] = 0.0;
                continue;
            }
            let a = m[i] / d[i];
            let b = m[i + 1] / d[i];
            let s = a * a + b * b;
            if s > 9.0 {
                let k = 3.0 / s.sqrt();
                m[i] = k * a * d[i];
                m[i + 1] = k * b * d[i];
            }
        }
        Spline { p, m }
    }

    /// The curve value at `x`, clamped to 0...1.
    pub fn value(&self, x: f32) -> f32 {
        let p = &self.p;
        let n = p.len();
        if n < 2 {
            return p.first().map_or(0.5, |q| q.y);
        }
        if x <= p[0].x {
            return p[0].y;
        }
        if x >= p[n - 1].x {
            return p[n - 1].y;
        }
        let mut k = 0;
        while k < n - 2 && x > p[k + 1].x {
            k += 1;
        }
        let h = p[k + 1].x - p[k].x;
        let t = (x - p[k].x) / h;
        let t2 = t * t;
        let t3 = t2 * t;
        let v = (2.0 * t3 - 3.0 * t2 + 1.0) * p[k].y
            + (t3 - 2.0 * t2 + t) * h * self.m[k]
            + (-2.0 * t3 + 3.0 * t2) * p[k + 1].y
            + (t3 - t2) * h * self.m[k + 1];
        v.clamp(0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pt(x: f32, y: f32) -> CurvePoint {
        CurvePoint { x, y }
    }

    #[test]
    fn passes_through_its_points_and_stays_in_range() {
        let pts = [pt(0.0, 0.1), pt(0.4, 0.7), pt(1.0, 0.9)];
        for p in &pts {
            assert!((evaluate(&pts, p.x) - p.y).abs() < 1e-5);
        }
        for i in 0..=100 {
            let v = evaluate(&pts, i as f32 / 100.0);
            assert!((0.0..=1.0).contains(&v));
        }
        assert!((evaluate(&[], 0.3) - 0.3).abs() < 1e-6, "no points: the diagonal");
        assert_eq!(sample(&pts, 3), vec![evaluate(&pts, 0.0), evaluate(&pts, 0.5), evaluate(&pts, 1.0)]);
    }

    #[test]
    fn normalizing_sorts_clamps_and_merges_close_points() {
        let n = normalized(&[pt(0.5, 2.0), pt(-1.0, 0.0), pt(0.50005, 0.2), pt(1.0, 1.0)]);
        assert_eq!(n, vec![pt(0.0, 0.0), pt(0.50005, 0.2), pt(1.0, 1.0)]);
    }
}
