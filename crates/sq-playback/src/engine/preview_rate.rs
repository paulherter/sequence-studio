// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SQPlayback/PreviewRate.swift
//! Preview speed of the monitor's Play (0.5x to 10x). Preview only: export and the project never see it.

use sq_core_edit::playback::PlaybackRate;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PreviewRate {
    pub rate: PlaybackRate,
}

impl PreviewRate {
    pub const NORMAL: PreviewRate = PreviewRate { rate: PlaybackRate::FORWARD };

    /// The menu's presets, slowest first.
    pub fn presets() -> Vec<PreviewRate> {
        [(1, 2), (3, 4), (1, 1), (5, 4), (3, 2), (2, 1), (3, 1), (4, 1), (6, 1), (8, 1), (10, 1)]
            .into_iter()
            .map(|(n, d)| PreviewRate::new(PlaybackRate::new(n, d)))
            .collect()
    }

    /// Clamped into 0.5x...10x, forward only (reverse is the shuttle's job).
    pub fn new(rate: PlaybackRate) -> PreviewRate {
        let m = rate.magnitude();
        let (n, d) = (i64::from(m.num()), i64::from(m.den()));
        let rate = if n * 2 < d {
            PlaybackRate::new(1, 2)
        } else if n > 10 * d {
            PlaybackRate::whole(10)
        } else {
            m
        };
        PreviewRate { rate }
    }

    pub fn is_normal(self) -> bool {
        self.rate == PlaybackRate::FORWARD
    }

    /// Menu title: "0.5x", "1.25x", "10x"; 1x reads "Normal (1x)".
    pub fn title(self) -> String {
        if self.is_normal() {
            return "Normal (1x)".to_string();
        }
        let v = f64::from(self.rate.num()) / f64::from(self.rate.den());
        // Swift `%g`: shortest form, no trailing zeros.
        format!("{v}x")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn value(p: &PreviewRate) -> f64 {
        f64::from(p.rate.num()) / f64::from(p.rate.den())
    }

    #[test]
    fn presets_cover_half_speed_to_ten_times() {
        let values: Vec<f64> = PreviewRate::presets().iter().map(value).collect();
        assert!(values.first() == Some(&0.5) && values.last() == Some(&10.0));
        assert!(values.windows(2).all(|w| w[0] <= w[1]));
        assert!(PreviewRate::presets().contains(&PreviewRate::NORMAL));
    }

    #[test]
    fn clamps_into_range_and_drops_direction() {
        assert_eq!(PreviewRate::new(PlaybackRate::new(1, 8)).rate, PlaybackRate::new(1, 2));
        assert_eq!(PreviewRate::new(PlaybackRate::whole(32)).rate, PlaybackRate::whole(10));
        assert_eq!(PreviewRate::new(PlaybackRate::whole(-2)).rate, PlaybackRate::whole(2));
        assert_eq!(PreviewRate::new(PlaybackRate::whole(0)).rate, PlaybackRate::new(1, 2));
    }

    #[test]
    fn titles() {
        assert_eq!(PreviewRate::presets()[0].title(), "0.5x");
        assert_eq!(PreviewRate::new(PlaybackRate::new(5, 4)).title(), "1.25x");
        assert_eq!(PreviewRate::NORMAL.title(), "Normal (1x)");
        assert_eq!(PreviewRate::new(PlaybackRate::whole(10)).title(), "10x");
    }
}
