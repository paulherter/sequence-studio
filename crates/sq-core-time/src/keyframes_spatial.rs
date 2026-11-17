// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesSpatial.swift

use crate::{Id, Interpolation, KeyframeTrack, Vec2};

/// Cubic bezier path of a position segment with an arc-length table.
#[derive(Clone, Debug, PartialEq)]
pub struct SpatialPath {
    /// Start point.
    pub p0: Vec2,
    /// First control point.
    pub p1: Vec2,
    /// Second control point.
    pub p2: Vec2,
    /// End point.
    pub p3: Vec2,
    /// Cumulative length at s = i / (count - 1).
    table: Vec<f64>,
}

impl SpatialPath {
    /// Table resolution Swift uses when none is given.
    pub const DEFAULT_RESOLUTION: usize = 128;

    /// Builds the arc-length table with `resolution` steps.
    pub fn new(p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, resolution: usize) -> SpatialPath {
        let mut table = vec![0.0];
        let (mut prev, mut acc) = (p0, 0.0);
        for i in 1..=resolution {
            let pt = Self::eval(p0, p1, p2, p3, i as f64 / resolution as f64);
            acc += (pt - prev).length();
            table.push(acc);
            prev = pt;
        }
        SpatialPath { p0, p1, p2, p3, table }
    }

    fn eval(a: Vec2, b: Vec2, c: Vec2, d: Vec2, s: f64) -> Vec2 {
        let u = 1.0 - s;
        a * (u * u * u) + b * (3.0 * u * u * s) + c * (3.0 * u * s * s) + d * (s * s * s)
    }

    /// Arc length.
    pub fn length(&self) -> f64 {
        self.table.last().copied().unwrap_or(0.0)
    }

    /// Point at curve parameter `s` (0...1).
    pub fn point_at_parameter(&self, s: f64) -> Vec2 {
        Self::eval(self.p0, self.p1, self.p2, self.p3, s)
    }

    /// Point at a fraction (0...1) of the arc length: constant speed for linear progress.
    pub fn point_at_arc_fraction(&self, f: f64) -> Vec2 {
        let length = self.length();
        // Swift `guard length > 0`: NaN also returns the start.
        if length.partial_cmp(&0.0) != Some(std::cmp::Ordering::Greater) {
            return self.p0;
        }
        let target = f.clamp(0.0, 1.0) * length;
        let (mut lo, mut hi) = (0, self.table.len() - 1);
        while hi - lo > 1 {
            let m = (lo + hi) / 2;
            if self.table[m] <= target {
                lo = m;
            } else {
                hi = m;
            }
        }
        let span = self.table[hi] - self.table[lo];
        let frac = if span > 0.0 { (target - self.table[lo]) / span } else { 0.0 };
        self.point_at_parameter((lo as f64 + frac) / (self.table.len() - 1) as f64)
    }
}

/// One segment of a motion path for the program monitor.
#[derive(Clone, Debug, PartialEq)]
pub struct MotionPathSegment {
    /// Key that starts the segment.
    pub from_id: Id,
    /// Key that ends it.
    pub to_id: Id,
    /// Polyline along the path; a hold segment has only the point it shows.
    pub points: Vec<Vec2>,
}

impl KeyframeTrack<Vec2> {
    /// Motion path, `samples_per_segment` points per segment (at least 2).
    pub fn motion_path(&self, samples_per_segment: usize) -> Vec<MotionPathSegment> {
        let n = samples_per_segment.max(2);
        self.keys
            .windows(2)
            .map(|w| {
                let (a, b) = (&w[0], &w[1]);
                if a.interpolation.is_hold() {
                    let p = if a.interpolation == Interpolation::Hold { a.value } else { b.value };
                    return MotionPathSegment { from_id: a.id, to_id: b.id, points: vec![p] };
                }
                let path = SpatialPath::new(
                    a.value,
                    a.value + a.out_tangent,
                    b.value + b.in_tangent,
                    b.value,
                    SpatialPath::DEFAULT_RESOLUTION,
                );
                let points = (0..n)
                    .map(|i| if i == n - 1 { b.value } else { path.point_at_parameter(i as f64 / (n - 1) as f64) })
                    .collect();
                MotionPathSegment { from_id: a.id, to_id: b.id, points }
            })
            .collect()
    }
}
