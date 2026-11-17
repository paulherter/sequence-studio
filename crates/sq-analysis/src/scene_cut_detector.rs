// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SceneCutDetector.swift
//! Finds shot changes in a series of per-frame differences. Pure: the analyzer produces the differences from decoded
//! frames; the threshold adapts to the activity around each frame so camera moves and flicker do not read as cuts.

/// Tuning of the detector.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Settings {
    /// A change must reach this histogram difference (0...1) whatever the surroundings.
    pub minimum_difference: f64,
    /// ... and this many times the mean difference of the frames around it.
    pub ratio: f64,
    /// Frames looked at on each side for the local activity.
    pub window: i64,
    /// Two cuts closer than this many frames: only the stronger one stays.
    pub minimum_gap_frames: i64,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { minimum_difference: 0.2, ratio: 4.0, window: 12, minimum_gap_frames: 8 }
    }
}

/// Finds shot changes in a series of per-frame differences.
pub struct SceneCutDetector;

impl SceneCutDetector {
    /// `d[i]` = change between frame i-1 and i (index 0 ignored). Returns the indices of the first frame of each new shot.
    pub fn cut_indices(d: &[f64], s: &Settings) -> Vec<usize> {
        if d.len() <= 2 {
            return Vec::new();
        }
        let count = d.len() as i64;
        let mut picked = Vec::new();
        for i in 1..count {
            let v = d[i as usize];
            if !(v.is_finite() && v >= s.minimum_difference) {
                continue;
            }
            let lo = 1.max(i - s.window);
            let hi = (count - 1).min(i + s.window);
            let mut sum = 0.0;
            let mut n = 0_u32;
            for j in lo..=hi {
                if (j != i && (j - i).abs() > 1) || (j != i && hi - lo < 3) {
                    let x = d[j as usize];
                    sum += if x.is_finite() { x } else { 0.0 };
                    n += 1;
                }
            }
            let local = if n > 0 { sum / f64::from(n) } else { 0.0 };
            if v < local * s.ratio {
                continue;
            }
            let gl = 1.max(i - s.minimum_gap_frames);
            let gh = (count - 1).min(i + s.minimum_gap_frames);
            // A stronger frame within the gap wins (ties: the earlier one).
            let best = !(gl..=gh).any(|j| j != i && (d[j as usize] > v || (d[j as usize] == v && j < i)));
            if best {
                picked.push(i as usize);
            }
        }
        picked
    }

    /// Difference of two normalized-or-not luma histograms of equal size: 0 identical, 1 disjoint.
    pub fn histogram_difference(a: &[i64], b: &[i64]) -> f64 {
        if a.len() != b.len() || a.is_empty() {
            return 0.0;
        }
        let ta: i64 = a.iter().sum();
        let tb: i64 = b.iter().sum();
        if ta <= 0 || tb <= 0 {
            return 0.0;
        }
        let mut s = 0.0;
        for i in 0..a.len() {
            s += (a[i] as f64 / ta as f64 - b[i] as f64 / tb as f64).abs();
        }
        s / 2.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn series(count: usize, noise: f64, spikes: &[(usize, f64)]) -> Vec<f64> {
        let spikes: BTreeMap<usize, f64> = spikes.iter().copied().collect();
        (0..count)
            .map(|i| {
                spikes.get(&i).copied().unwrap_or(if i == 0 { 0.0 } else { noise * if i % 2 == 0 { 1.0 } else { 0.5 } })
            })
            .collect()
    }

    fn cuts(d: &[f64]) -> Vec<usize> {
        SceneCutDetector::cut_indices(d, &Settings::default())
    }

    #[test]
    fn finds_spikes_over_quiet_footage() {
        assert_eq!(cuts(&series(200, 0.01, &[(50, 0.8), (120, 0.6)])), vec![50, 120]);
    }

    #[test]
    fn busy_footage_needs_a_bigger_jump() {
        // Constant heavy motion (0.15 per frame) never reads as a cut; a real cut on top of it does.
        assert!(cuts(&series(100, 0.15, &[])).is_empty());
        assert_eq!(cuts(&series(100, 0.15, &[(60, 0.9)])), vec![60]);
    }

    #[test]
    fn weak_change_below_floor_is_ignored() {
        assert!(cuts(&series(100, 0.01, &[(40, 0.1)])).is_empty());
    }

    #[test]
    fn close_spikes_keep_the_stronger_one() {
        assert_eq!(cuts(&series(100, 0.01, &[(40, 0.5), (43, 0.9)])), vec![43]);
    }

    #[test]
    fn tiny_inputs_are_safe() {
        assert!(cuts(&[]).is_empty());
        assert!(cuts(&[0.0, 0.9]).is_empty());
    }

    #[test]
    fn histogram_difference() {
        assert_eq!(SceneCutDetector::histogram_difference(&[4, 0], &[4, 0]), 0.0);
        assert_eq!(SceneCutDetector::histogram_difference(&[4, 0], &[0, 8]), 1.0);
        assert_eq!(SceneCutDetector::histogram_difference(&[1, 1], &[3, 3]), 0.0);
    }
}
