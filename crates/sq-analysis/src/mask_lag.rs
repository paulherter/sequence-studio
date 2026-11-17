// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Benchmark/MaskLag.swift
//! Where a mask sits against the ground truth on one labeled frame: the lag report of the mask benchmark (the maintainer
//! 2026-10-18: the mask "still lags behind in parts" on a moving face). Pixel coordinates of the frame, y down.
use sq_core_time::Vec2;
use std::ops::RangeInclusive;

/// Where a mask sits against the ground truth on one labeled frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MaskLagSample {
    /// Source frame index of the clip.
    pub frame: i64,
    /// Centroid of the tracked mask; `None` when the frame has none (lost).
    pub predicted: Option<Vec2>,
    /// Centroid of the truth.
    pub truth: Vec2,
    /// Width of the truth's bounding box (the subject's size, for speeds in subject widths per second).
    pub truth_width: f64,
    /// Which labeled picture the mask's shape fits best, the one before, its own or the one after (`MaskLag::shape_lag`):
    /// + = the shape is behind. Catches a mask that keeps an old outline while its centroid stays (a head turning).
    pub shape_lag: Option<f64>,
}

impl MaskLagSample {
    /// A sample without a shape lag.
    pub fn new(frame: i64, predicted: Option<Vec2>, truth: Vec2, truth_width: f64) -> MaskLagSample {
        MaskLagSample { frame, predicted, truth, truth_width, shape_lag: None }
    }
}

/// How far a tracked mask is behind (or ahead of) the subject, fitted over labeled frames.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MaskLagReport {
    /// Least-squares fit of error = -lag * velocity, in source frames: + = the mask trails the motion, - = it leads.
    pub lag_frames: f64,
    /// Mean distance of the centroids (px).
    pub mean_error: f64,
    /// Mean signed error along the motion (px): - = behind the subject.
    pub along_error: f64,
    /// Mean subject speed (px per source frame).
    pub mean_speed: f64,
    /// Mean subject speed in subject widths per second.
    pub widths_per_second: f64,
    /// Correlation of the along-motion error with the speed (- = the faster, the further behind).
    pub correlation: f64,
    /// Samples used.
    pub count: usize,
    /// Mean `MaskLagSample::shape_lag` (labeled steps, + = behind); `None` when no sample has one.
    pub shape_lag: Option<f64>,
    /// Over how many samples.
    pub shape_count: usize,
}

/// The lag report of the mask benchmark.
pub struct MaskLag;

impl MaskLag {
    /// Centroid (px) of a mask, `None` when empty.
    pub fn centroid(mask: &[bool], width: usize) -> Option<Vec2> {
        let (mut sx, mut sy, mut n) = (0.0, 0.0, 0.0);
        for (i, _) in mask.iter().enumerate().filter(|(_, m)| **m) {
            sx += (i % width) as f64;
            sy += (i / width) as f64;
            n += 1.0;
        }
        (n > 0.0).then(|| Vec2::new(sx / n + 0.5, sy / n + 0.5))
    }

    /// Width of a mask's bounding box (px), 0 when empty.
    pub fn box_width(mask: &[bool], width: usize) -> f64 {
        let (mut x0, mut x1) = (usize::MAX, None::<usize>);
        for (i, _) in mask.iter().enumerate().filter(|(_, m)| **m) {
            let x = i % width;
            x0 = x0.min(x);
            x1 = Some(x1.map_or(x, |v| v.max(x)));
        }
        x1.map_or(0.0, |x1| (x1 - x0 + 1) as f64)
    }

    /// Where between the previous labeled truth (one step back = +1), its own (0) and the next (one step on = -1) a mask
    /// fits best, from its Jaccard against the three: the peak of the parabola through them, clamped to one step.
    /// + = the mask looks like the past. `None` when the three fits are the same (nothing to tell them apart by).
    pub fn shape_lag(previous: f64, own: f64, next: f64) -> Option<f64> {
        let curve = previous - 2.0 * own + next;
        if curve < -1e-9 {
            return Some(((previous - next) / (-2.0 * curve)).clamp(-1.0, 1.0));
        }
        if previous == own && own == next {
            return None;
        }
        Some(if previous > next {
            1.0
        } else if previous < next {
            -1.0
        } else {
            0.0
        })
    }

    /// The subject's velocity at each sample (px per source frame): central difference of the truth centroids of the
    /// neighboring samples, one-sided at the ends. Samples sorted by frame; fewer than two give none.
    pub fn velocities(samples: &[MaskLagSample]) -> Vec<Vec2> {
        if samples.len() < 2 {
            return Vec::new();
        }
        (0..samples.len())
            .map(|k| {
                let a = &samples[k.saturating_sub(1)];
                let b = &samples[(k + 1).min(samples.len() - 1)];
                let df = (b.frame - a.frame) as f64;
                if df > 0.0 { (b.truth - a.truth) * (1.0 / df) } else { Vec2::ZERO }
            })
            .collect()
    }

    /// The report over the samples with a mask, using velocities from all samples (a lost frame still says where the
    /// subject went). `min_speed` (px per frame; Swift default 0.5): slower samples are left out of the lag fit only (no
    /// direction to lag along). `widths_per_second`: keeps only samples whose speed in subject widths per second is in
    /// the range.
    pub fn report(
        samples: &[MaskLagSample],
        fps: f64,
        min_speed: f64,
        widths_per_second: Option<RangeInclusive<f64>>,
    ) -> Option<MaskLagReport> {
        let mut sorted = samples.to_vec();
        sorted.sort_by_key(|s| s.frame);
        let v = Self::velocities(&sorted);
        if v.len() != sorted.len() {
            return None;
        }
        let (mut ev, mut vv, mut dist, mut speed, mut wps, mut n) = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
        let mut speeds: Vec<f64> = Vec::new();
        let mut alongs: Vec<f64> = Vec::new();
        for (s, vel) in sorted.iter().zip(&v) {
            let Some(p) = s.predicted else { continue };
            let sp = vel.length();
            let w = sp * fps / s.truth_width.max(1.0);
            if widths_per_second.as_ref().is_some_and(|r| !r.contains(&w)) {
                continue;
            }
            let e = p - s.truth;
            dist += e.length();
            speed += sp;
            wps += w;
            n += 1.0;
            if sp < min_speed {
                continue;
            }
            ev += e.x * vel.x + e.y * vel.y;
            vv += sp * sp;
            let a = (e.x * vel.x + e.y * vel.y) / sp;
            speeds.push(sp);
            alongs.push(a);
        }
        if n <= 0.0 {
            return None;
        }
        let shapes: Vec<f64> = sorted
            .iter()
            .zip(&v)
            .filter_map(|(s, vel)| {
                s.predicted?;
                let l = s.shape_lag?;
                if let Some(r) = &widths_per_second
                    && !r.contains(&(vel.length() * fps / s.truth_width.max(1.0)))
                {
                    return None;
                }
                Some(l)
            })
            .collect();
        let m = speeds.len().max(1) as f64;
        let ms = speeds.iter().sum::<f64>() / m;
        let ma = alongs.iter().sum::<f64>() / m;
        let (mut cov, mut s1, mut s2) = (0.0, 0.0, 0.0);
        for (a, b) in speeds.iter().zip(&alongs) {
            cov += (a - ms) * (b - ma);
            s1 += (a - ms) * (a - ms);
            s2 += (b - ma) * (b - ma);
        }
        let corr = if s1 > 0.0 && s2 > 0.0 { cov / (s1 * s2).sqrt() } else { 0.0 };
        Some(MaskLagReport {
            lag_frames: if vv > 0.0 { -ev / vv } else { 0.0 },
            mean_error: dist / n,
            along_error: if speeds.is_empty() { 0.0 } else { ma },
            mean_speed: speed / n,
            widths_per_second: wps / n,
            correlation: corr,
            count: n as usize,
            shape_lag: if shapes.is_empty() { None } else { Some(shapes.iter().sum::<f64>() / shapes.len() as f64) },
            shape_count: shapes.len(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mask_metrics::rect;

    /// A subject moving 4 px per frame to the right, labeled every 5 frames; the mask sits `behind` frames back.
    fn samples(behind: f64, speed: f64) -> Vec<MaskLagSample> {
        (0..12)
            .map(|k| {
                let f = k * 5;
                let truth = Vec2::new(100.0 + speed * f as f64, 50.0);
                MaskLagSample::new(f, Some(truth - Vec2::new(speed * behind, 0.0)), truth, 40.0)
            })
            .collect()
    }

    fn report(s: &[MaskLagSample]) -> Option<MaskLagReport> {
        MaskLag::report(s, 30.0, 0.5, None)
    }

    #[test]
    fn centroid_and_box_width_of_a_rect() {
        let m = rect(20, 10, 4, 2, 10, 6);
        assert_eq!(MaskLag::centroid(&m, 20), Some(Vec2::new(7.0, 4.0)));
        assert_eq!(MaskLag::box_width(&m, 20), 6.0);
        assert!(MaskLag::centroid(&[false, false], 2).is_none() && MaskLag::box_width(&[false], 1) == 0.0);
    }

    #[test]
    fn a_trailing_mask_gives_a_positive_lag_in_frames() {
        let r = report(&samples(2.0, 4.0)).expect("report");
        assert!((r.lag_frames - 2.0).abs() < 1e-9);
        assert!((r.along_error - -8.0).abs() < 1e-9 && (r.mean_error - 8.0).abs() < 1e-9);
        assert!((r.mean_speed - 4.0).abs() < 1e-9 && (r.widths_per_second - 3.0).abs() < 1e-9); // 4 px * 30 fps / 40 px
        assert_eq!(r.count, 12);
    }

    #[test]
    fn a_leading_mask_is_negative_and_an_exact_one_is_zero() {
        assert!((report(&samples(-1.0, 4.0)).expect("report").lag_frames - -1.0).abs() < 1e-9);
        let exact = report(&samples(0.0, 4.0)).expect("report");
        assert!(exact.lag_frames == 0.0 && exact.mean_error == 0.0);
    }

    #[test]
    fn lost_frames_are_left_out_but_still_give_the_velocity() {
        let mut s = samples(1.0, 4.0);
        s[3].predicted = None;
        s[4].predicted = None;
        let r = report(&s).expect("report");
        assert!(r.count == 10 && (r.lag_frames - 1.0).abs() < 1e-9);
        let none: Vec<_> = s.iter().map(|x| MaskLagSample { predicted: None, ..*x }).collect();
        assert!(report(&none).is_none());
    }

    #[test]
    fn a_still_subject_has_no_lag_and_a_speed_range_filters() {
        let still: Vec<_> = samples(0.0, 0.0)
            .into_iter()
            .map(|x| MaskLagSample { predicted: Some(x.truth + Vec2::new(3.0, 0.0)), ..x })
            .collect();
        let r = report(&still).expect("report");
        assert!(r.lag_frames == 0.0 && (r.mean_error - 3.0).abs() < 1e-9);
        assert!(MaskLag::report(&samples(1.0, 4.0), 30.0, 0.5, Some(0.5..=1.5)).is_none());
        assert!(MaskLag::report(&samples(1.0, 4.0), 30.0, 0.5, Some(1.5..=3.5)).is_some());
    }

    #[test]
    fn shape_lag_finds_which_picture_the_mask_fits() {
        assert_eq!(MaskLag::shape_lag(0.5, 0.9, 0.5), Some(0.0));
        assert!(MaskLag::shape_lag(0.8, 0.8, 0.4).expect("lag") > 0.4); // between own and before
        assert!(MaskLag::shape_lag(0.4, 0.8, 0.8).expect("lag") < -0.4);
        assert_eq!(MaskLag::shape_lag(0.9, 0.6, 0.3), Some(1.0)); // fits the one before
        assert_eq!(MaskLag::shape_lag(0.7, 0.7, 0.7), None);
        let mut s = samples(0.0, 4.0);
        for (k, x) in s.iter_mut().enumerate() {
            x.shape_lag = Some(if k < 6 { 0.5 } else { 0.1 });
        }
        let r = report(&s).expect("report");
        assert!((r.shape_lag.expect("shape lag") - 0.3).abs() < 1e-9 && r.shape_count == 12);
    }

    #[test]
    fn lag_that_grows_with_speed_correlates_negatively() {
        // Speed rises frame to frame; the mask trails a fixed 2 frames, so the along error falls with speed.
        let mut s = Vec::new();
        let mut x = 0.0;
        for k in 0..10 {
            let v = f64::from(k + 1);
            x += v * 5.0;
            s.push(MaskLagSample::new(i64::from(k) * 5, Some(Vec2::new(x - 2.0 * v, 0.0)), Vec2::new(x, 0.0), 50.0));
        }
        let r = MaskLag::report(&s, 25.0, 0.5, None).expect("report");
        assert!(r.correlation < -0.9 && r.lag_frames > 1.0);
    }
}
