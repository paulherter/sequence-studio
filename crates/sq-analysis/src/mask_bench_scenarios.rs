// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Benchmark/MaskBenchScenarios.swift
//! Helpers for the benchmark's mid-clip prompt and occlusion scenarios. Pure math, no media or model.
use std::ops::Range;

/// Score of one labeled frame (for the windowed scenario reports of the mask benchmark).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MaskFrameScore {
    /// Frame index.
    pub frame: i64,
    /// Region similarity.
    pub j: f64,
    /// Boundary F-measure.
    pub f: f64,
}

impl MaskFrameScore {
    /// Mean of J and F.
    pub fn jf(&self) -> f64 {
        (self.j + self.f) / 2.0
    }
}

/// Mean scores over a window of labeled frames.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WindowScore {
    /// Mean J.
    pub j: f64,
    /// Mean F.
    pub f: f64,
    /// Mean J&F.
    pub jf: f64,
    /// Frames in the window.
    pub count: usize,
}

/// A box in pixel bounds, `x1`/`y1` exclusive.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PixelBox {
    /// Left.
    pub x0: usize,
    /// Top.
    pub y0: usize,
    /// Right, exclusive.
    pub x1: usize,
    /// Bottom, exclusive.
    pub y1: usize,
}

/// The benchmark's scenario helpers.
pub struct MaskBenchScenarios;

impl MaskBenchScenarios {
    /// Mean J, F, J&F over the labeled frames in `range` (`None` when none was scored there).
    pub fn window(frames: &[MaskFrameScore], range: Range<i64>) -> Option<WindowScore> {
        let inside: Vec<&MaskFrameScore> = frames.iter().filter(|f| range.contains(&f.frame)).collect();
        if inside.is_empty() {
            return None;
        }
        let n = inside.len() as f64;
        let j = inside.iter().fold(0.0, |a, f| a + f.j) / n;
        let f = inside.iter().fold(0.0, |a, x| a + x.f) / n;
        Some(WindowScore { j, f, jf: (j + f) / 2.0, count: inside.len() })
    }

    /// Frames from `end` (the first picture without the occlusion) to the first labeled frame at or after it whose J reaches
    /// `threshold` (Swift default 0.5); `None` when none does. The resolution is the labels' spacing.
    pub fn frames_to_recover(frames: &[MaskFrameScore], end: i64, threshold: f64) -> Option<i64> {
        frames.iter().filter(|f| f.frame >= end && f.j >= threshold).map(|f| f.frame).min().map(|f| f - end)
    }

    /// A click inside the subject, away from its edge: the centroid of the part of the mask that is at least half as far
    /// from the edge as its deepest point (the eroded interior); when the centroid falls outside it, the nearest eroded
    /// pixel. Returns pixel coordinates of the grid, `None` for an empty mask.
    pub fn interior_click(mask: &[bool], width: usize, height: usize) -> Option<(f64, f64)> {
        if width == 0 || height == 0 || mask.len() != width * height || !mask.contains(&true) {
            return None;
        }
        // City-block distance to the nearest outside pixel (the frame edge counts as outside), two passes.
        let mut d = vec![0_i64; mask.len()];
        let far = (width + height) as i64;
        for y in 0..height {
            for x in 0..width {
                if mask[y * width + x] {
                    let up = if y > 0 { d[(y - 1) * width + x] } else { 0 };
                    let left = if x > 0 { d[y * width + x - 1] } else { 0 };
                    d[y * width + x] = up.min(left).min(far) + 1;
                }
            }
        }
        for y in (0..height).rev() {
            for x in (0..width).rev() {
                if mask[y * width + x] {
                    let down = if y < height - 1 { d[(y + 1) * width + x] } else { 0 };
                    let right = if x < width - 1 { d[y * width + x + 1] } else { 0 };
                    d[y * width + x] = d[y * width + x].min(down + 1).min(right + 1);
                }
            }
        }
        let deepest = d.iter().copied().max().unwrap_or(0);
        let cut = 1.max((deepest + 1) / 2);
        let (mut sx, mut sy, mut n) = (0.0, 0.0, 0.0);
        for (i, v) in d.iter().enumerate() {
            if *v >= cut {
                sx += (i % width) as f64;
                sy += (i / width) as f64;
                n += 1.0;
            }
        }
        if n <= 0.0 {
            return None;
        }
        let (cx, cy) = (sx / n, sy / n);
        let ix = (cx.round().max(0.0) as usize).min(width - 1);
        let iy = (cy.round().max(0.0) as usize).min(height - 1);
        if d[iy * width + ix] >= cut {
            return Some((ix as f64, iy as f64));
        }
        let mut best = None;
        let mut best_dist = f64::INFINITY;
        for (i, v) in d.iter().enumerate() {
            if *v >= cut {
                let dx = (i % width) as f64 - cx;
                let dy = (i / width) as f64 - cy;
                if dx * dx + dy * dy < best_dist {
                    best_dist = dx * dx + dy * dy;
                    best = Some(i);
                }
            }
        }
        best.map(|b| ((b % width) as f64, (b / width) as f64))
    }

    /// Horizontal picture shift (fraction of the width, negative = left) that takes a subject spanning `x0...x1` out of the
    /// frame through the nearer side, with a margin of 0.02.
    pub fn exit_distance(x0: f64, x1: f64) -> f64 {
        if (x0 + x1) / 2.0 < 0.5 { -(x1 + 0.02) } else { (1.0 - x0) + 0.02 }
    }

    /// The exit scenario's shift at `frame`: over `start..<start+length` the picture slides out by `distance` in the first
    /// third, stays out for the middle third and slides back in the last third; 0 outside.
    pub fn exit_shift(frame: i64, start: i64, length: i64, distance: f64) -> f64 {
        let k = frame - start;
        if k < 0 || k >= length {
            return 0.0;
        }
        let third = (length / 3).max(1);
        let back = Self::exit_return(start, length) - start;
        if k < third {
            return distance * (k + 1) as f64 / third as f64;
        }
        if k < back {
            return distance;
        }
        distance * (length - k) as f64 / (length - back + 1) as f64
    }

    /// First frame of the exit scenario's way back in (the last third of `start..<start+length`).
    pub fn exit_return(start: i64, length: i64) -> i64 {
        start + length - (length / 3).max(1)
    }

    /// Horizontal shift (fraction of the width) of the "moved" scenario: 0.3 toward the side with more room, at most as far as
    /// the subject `x0...x1` stays in the frame.
    pub fn move_distance(x0: f64, x1: f64) -> f64 {
        if x0 > 1.0 - x1 { -(0.3_f64.min(x0)) } else { 0.3_f64.min(1.0 - x1) }
    }

    /// `values` (width x height) moved right by `dx` pixels (left when negative); uncovered pixels take `fill`.
    pub fn shifted<T: Clone>(values: &[T], width: usize, height: usize, dx: i64, fill: T) -> Vec<T> {
        if dx == 0 {
            return values.to_vec();
        }
        let mut out = vec![fill; values.len()];
        if dx.unsigned_abs() as usize >= width {
            return out;
        }
        let from = dx.max(0) as usize;
        let to = (width as i64 + dx).min(width as i64) as usize;
        for y in 0..height {
            for x in from..to {
                out[y * width + x] = values[((y * width + x) as i64 - dx) as usize].clone();
            }
        }
        out
    }

    /// Frames from `from` to the first frame at or after it (up to `last`) the tracker did not answer lost; `None` when none.
    pub fn frames_to_reacquire(lost: &[i64], from: i64, last: i64) -> Option<i64> {
        if from > last {
            return None;
        }
        (from..=last).find(|f| !lost.contains(f)).map(|f| f - from)
    }

    /// Bounding box of the mask grown by `margin` of its size on every side.
    pub fn grown_box(mask: &[bool], width: usize, height: usize, margin: f64) -> Option<PixelBox> {
        let (mut x0, mut y0, mut x1, mut y1) = (width, height, None::<usize>, None::<usize>);
        for (i, _) in mask.iter().enumerate().filter(|(_, m)| **m) {
            let (x, y) = (i % width, i / width);
            x0 = x0.min(x);
            x1 = Some(x1.map_or(x, |v| v.max(x)));
            y0 = y0.min(y);
            y1 = Some(y1.map_or(y, |v| v.max(y)));
        }
        let (x1, y1) = (x1?, y1?);
        let gx = ((x1 - x0 + 1) as f64 * margin).ceil() as usize;
        let gy = ((y1 - y0 + 1) as f64 * margin).ceil() as usize;
        Some(PixelBox {
            x0: x0.saturating_sub(gx),
            y0: y0.saturating_sub(gy),
            x1: width.min(x1 + 1 + gx),
            y1: height.min(y1 + 1 + gy),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mask_metrics::rect;

    #[test]
    fn windows_and_recovery() {
        let frames: Vec<_> = [0, 5, 10, 15, 20, 25]
            .iter()
            .map(|&f| MaskFrameScore { frame: f, j: if !(10..25).contains(&f) { 0.9 } else { 0.1 }, f: 0.5 })
            .collect();
        let before = MaskBenchScenarios::window(&frames, 0..10).expect("window");
        assert!(before.count == 2 && (before.j - 0.9).abs() < 1e-9 && (before.jf - 0.7).abs() < 1e-9);
        assert!(MaskBenchScenarios::window(&frames, 30..40).is_none());
        assert_eq!(MaskBenchScenarios::frames_to_recover(&frames, 20, 0.5), Some(5));
        assert_eq!(MaskBenchScenarios::frames_to_recover(&frames, 30, 0.5), None);
    }

    #[test]
    fn interior_click_is_deep_inside_the_subject() {
        // A 20x20 square plus a thin 1 px tail: the click must be in the square's middle, not on the tail.
        let mut m = rect(60, 40, 10, 10, 30, 30);
        for x in 30..55 {
            m[20 * 60 + x] = true;
        }
        let c = MaskBenchScenarios::interior_click(&m, 60, 40).expect("click");
        assert!((c.0 - 19.5).abs() <= 2.5 && (c.1 - 19.5).abs() <= 2.5);
        assert!(m[c.1 as usize * 60 + c.0 as usize]);
        assert!(MaskBenchScenarios::interior_click(&[false; 12], 4, 3).is_none());
    }

    #[test]
    fn grown_box_stays_in_the_frame() {
        let m = rect(100, 100, 40, 40, 60, 60);
        let b = MaskBenchScenarios::grown_box(&m, 100, 100, 0.25).expect("box");
        assert_eq!(b, PixelBox { x0: 35, y0: 35, x1: 65, y1: 65 });
        let edge = MaskBenchScenarios::grown_box(&rect(100, 100, 0, 0, 20, 20), 100, 100, 0.5).expect("box");
        assert!(edge.x0 == 0 && edge.x1 == 30);
    }

    #[test]
    fn exit_pushes_the_subject_out_through_the_nearer_side() {
        // A subject left of the middle leaves left (its right edge past 0), one right of it leaves right.
        assert!((MaskBenchScenarios::exit_distance(0.1, 0.4) - -0.42).abs() < 1e-9);
        assert!((MaskBenchScenarios::exit_distance(0.6, 0.8) - 0.42).abs() < 1e-9);
    }

    #[test]
    fn exit_shift_ramps_out_holds_and_comes_back() {
        let s: Vec<f64> = (0..20).map(|f| MaskBenchScenarios::exit_shift(f, 5, 15, -0.6)).collect();
        assert!(s[0..5].iter().all(|v| *v == 0.0)); // before
        assert!((s[5] - -0.12).abs() < 1e-9 && (s[9] - -0.6).abs() < 1e-9); // out over 5 frames
        assert!(s[10..15].iter().all(|v| (v - -0.6).abs() < 1e-9)); // gone
        assert!((s[15] - -0.5).abs() < 1e-9 && (s[19] - -0.1).abs() < 1e-9); // back over 5 frames
        assert_eq!(MaskBenchScenarios::exit_shift(20, 5, 15, -0.6), 0.0);
        // Monotonic out, then back.
        assert!(s[5..10].iter().zip(&s[6..11]).all(|(a, b)| a >= b));
        assert!(s[15..19].iter().zip(&s[16..20]).all(|(a, b)| a <= b));
        assert_eq!(MaskBenchScenarios::exit_return(5, 15), 15);
    }

    #[test]
    fn moved_shift_goes_to_the_roomier_side_and_keeps_the_subject_inside() {
        assert!((MaskBenchScenarios::move_distance(0.1, 0.4) - 0.3).abs() < 1e-9);
        assert!((MaskBenchScenarios::move_distance(0.5, 0.9) - -0.3).abs() < 1e-9);
        // A wide subject: only the room there is.
        assert!((MaskBenchScenarios::move_distance(0.05, 0.85) - 0.15).abs() < 1e-9);
    }

    #[test]
    fn shifted_moves_pixels_and_fills_the_gap() {
        let m: Vec<f32> = vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0];
        assert_eq!(MaskBenchScenarios::shifted(&m, 4, 2, 1, 0.0), [0.0, 1.0, 2.0, 3.0, 0.0, 5.0, 6.0, 7.0]);
        assert_eq!(MaskBenchScenarios::shifted(&m, 4, 2, -2, 9.0), [3.0, 4.0, 9.0, 9.0, 7.0, 8.0, 9.0, 9.0]);
        assert_eq!(MaskBenchScenarios::shifted(&m, 4, 2, 5, 0.0), [0.0; 8]);
        assert_eq!(MaskBenchScenarios::shifted(&m, 4, 2, 0, 0.0), m);
    }

    #[test]
    fn frames_to_reacquire_counts_from_the_return() {
        // Lost 10...17: found again at 18, three frames after the return at 15.
        let lost: Vec<i64> = (10..=17).collect();
        assert_eq!(MaskBenchScenarios::frames_to_reacquire(&lost, 15, 30), Some(3));
        assert_eq!(MaskBenchScenarios::frames_to_reacquire(&(10..=14).collect::<Vec<_>>(), 15, 30), Some(0));
        assert_eq!(MaskBenchScenarios::frames_to_reacquire(&(10..=30).collect::<Vec<_>>(), 15, 30), None);
    }
}
