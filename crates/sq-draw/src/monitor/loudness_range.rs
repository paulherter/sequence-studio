// Swift: LoudnessRange.swift
//! EBU Tech 3342 loudness range from a stream of short-term readings: samples at most every 0.1 s of measured time,
//! absolute gate -70 LUFS, relative gate 20 LU below the power mean, LRA = P95 - P10 of what passes.
//! Values under `MINIMUM_SECONDS` of measured signal are not trustworthy: `value` is `None` and the meter greys the number.

/// The loudness range tracker.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LoudnessRangeTracker {
    measured_seconds: f64,
    samples: Vec<f64>,
    pending: f64,
}

impl LoudnessRangeTracker {
    /// Seconds of signal before the value counts.
    pub const MINIMUM_SECONDS: f64 = 60.0;
    /// Seconds between two samples.
    pub const SAMPLE_INTERVAL: f64 = 0.1;
    /// One hour.
    const MAX_SAMPLES: usize = 36_000;

    /// An empty tracker.
    pub fn new() -> LoudnessRangeTracker {
        LoudnessRangeTracker::default()
    }

    /// Seconds of signal measured so far.
    pub fn measured_seconds(&self) -> f64 {
        self.measured_seconds
    }

    /// Feed one poll: `short_term_lufs` (`None` = no signal yet) and `dt`, the measured time since the previous poll.
    pub fn add(&mut self, short_term_lufs: Option<f64>, dt: f64) {
        let Some(v) = short_term_lufs.filter(|v| v.is_finite() && dt > 0.0) else { return };
        self.pending += dt;
        if self.pending < Self::SAMPLE_INTERVAL {
            return;
        }
        let n = (self.pending / Self::SAMPLE_INTERVAL) as i64;
        self.pending -= n as f64 * Self::SAMPLE_INTERVAL;
        self.measured_seconds += n as f64 * Self::SAMPLE_INTERVAL;
        if self.samples.len() < Self::MAX_SAMPLES {
            self.samples.push(v);
        }
    }

    /// Forgets everything.
    pub fn reset(&mut self) {
        *self = LoudnessRangeTracker::new();
    }

    /// Enough signal for a meaningful number (otherwise the UI greys the value out).
    pub fn is_reliable(&self) -> bool {
        self.measured_seconds >= Self::MINIMUM_SECONDS - 0.001
    }

    /// The loudness range in LU, `None` until `is_reliable` and something passes the gates.
    pub fn value(&self) -> Option<f64> {
        if self.is_reliable() { self.range() } else { None }
    }

    /// The range regardless of the 60 s rule (`None` when nothing passes the gates).
    pub fn range(&self) -> Option<f64> {
        let gated: Vec<f64> = self.samples.iter().copied().filter(|s| *s > -70.0).collect();
        if gated.is_empty() {
            return None;
        }
        let power = gated.iter().map(|s| 10.0_f64.powf(s / 10.0)).fold(0.0, |a, b| a + b) / gated.len() as f64;
        let relative = 10.0 * power.log10() - 20.0;
        let mut kept: Vec<f64> = gated.into_iter().filter(|s| *s > relative).collect();
        kept.sort_by(f64::total_cmp);
        if kept.len() < 2 {
            return if kept.is_empty() { None } else { Some(0.0) };
        }
        let percentile = |p: f64| {
            let pos = p * (kept.len() - 1) as f64;
            let lo = pos.floor() as usize;
            let hi = (lo + 1).min(kept.len() - 1);
            kept[lo] + (kept[hi] - kept[lo]) * (pos - lo as f64)
        };
        Some(percentile(0.95) - percentile(0.10))
    }

    /// "LRA 7.2 LU", or "LRA --" while under a minute of signal.
    pub fn text(&self) -> String {
        match self.value() {
            Some(v) => format!("LRA {v:.1} LU"),
            None => "LRA --".to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fed(seconds: f64, level: impl Fn(f64) -> f64) -> LoudnessRangeTracker {
        let mut t = LoudnessRangeTracker::new();
        let mut s = 0.0;
        while s < seconds {
            t.add(Some(level(s)), 0.1);
            s += 0.1;
        }
        t
    }

    #[test]
    fn under_a_minute_is_greyed_out() {
        let t = fed(30.0, |s| if s < 15.0 { -30.0 } else { -20.0 });
        assert!(!t.is_reliable());
        assert!(t.value().is_none());
        assert_eq!(t.text(), "LRA --");
        assert!(t.range().is_some());
    }

    #[test]
    fn range_is_p95_minus_p10_of_gated_values() {
        let t = fed(90.0, |s| if s < 45.0 { -30.0 } else { -20.0 });
        assert!(t.is_reliable());
        assert!((t.value().unwrap_or(0.0) - 10.0).abs() < 0.2);
        assert!(t.text().starts_with("LRA 10"));
    }

    #[test]
    fn quiet_passages_below_the_relative_gate_are_ignored() {
        let t = fed(90.0, |s| if s < 80.0 { -20.0 } else { -60.0 });
        assert!(t.value().unwrap_or(99.0).abs() < 0.1);
    }

    #[test]
    fn silence_never_counts() {
        let mut t = LoudnessRangeTracker::new();
        for _ in 0..1000 {
            t.add(None, 0.1);
        }
        assert_eq!(t.measured_seconds(), 0.0);
        assert!(t.value().is_none());
    }

    #[test]
    fn reset_clears() {
        let mut t = fed(70.0, |_| -23.0);
        assert!(t.is_reliable());
        t.reset();
        assert!(!t.is_reliable());
    }
}
