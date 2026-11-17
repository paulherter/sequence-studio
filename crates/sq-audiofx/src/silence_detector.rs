//! Port of `SQAudioFX/Sources/SQAudioFX/SilenceDetector.swift`.

use crate::gain::GainMath;
use sq_core_time::{Time, TimeRange};

/// Finds pauses in audio from a level curve (one linear peak per equal window, e.g. waveform buckets). Pure.
/// The result feeds `SilenceRemoval` in the core, which turns it into frame-aligned ripple cuts.
pub enum SilenceDetector {}

impl SilenceDetector {
    /// Ranges (relative to the first window, `window` apart) whose level stays below `threshold_db` for at least
    /// `minimum_length`. A pause touching the start or end of the curve counts.
    pub fn silences(levels: &[f32], window: Time, threshold_db: f64, minimum_length: Time) -> Vec<TimeRange> {
        if window <= Time::ZERO || levels.is_empty() {
            return Vec::new();
        }
        let limit = GainMath::linear_from_db(threshold_db) as f32;
        let mut out = Vec::new();
        let mut run_start: Option<usize> = None;
        let mut close = |run_start: &mut Option<usize>, end: usize| {
            let Some(s) = run_start.take() else { return };
            let r = TimeRange::new(window * s as i64, window * (end - s) as i64);
            if r.duration >= minimum_length {
                out.push(r);
            }
        };
        for (i, &l) in levels.iter().enumerate() {
            if l < limit {
                if run_start.is_none() {
                    run_start = Some(i);
                }
            } else {
                close(&mut run_start, i);
            }
        }
        close(&mut run_start, levels.len());
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 10 ms windows: 0.5 s loud, 0.6 s quiet (-60 dB), 0.3 s loud, 0.1 s quiet at the end.
    fn levels() -> Vec<f32> {
        let mut v = vec![0.5; 50];
        v.extend(vec![0.001; 60]);
        v.extend(vec![0.5; 30]);
        v.extend(vec![0.001; 10]);
        v
    }
    const WINDOW: Time = Time::new(1, 100);

    #[test]
    fn finds_pauses_above_the_minimum_length() {
        let r = SilenceDetector::silences(&levels(), WINDOW, -40.0, Time::new(1, 2));
        assert_eq!(r, vec![TimeRange::new(Time::new(5, 10), Time::new(6, 10))]);
    }

    #[test]
    fn shorter_pauses_are_ignored_and_edge_pauses_count() {
        let r = SilenceDetector::silences(&levels(), WINDOW, -40.0, Time::new(1, 20));
        assert!(r.len() == 2 && r[1] == TimeRange::new(Time::new(14, 10), Time::new(1, 10)));
    }

    #[test]
    fn threshold_decides_what_is_silent() {
        assert!(SilenceDetector::silences(&levels(), WINDOW, -80.0, Time::new(1, 10)).is_empty());
        assert!(SilenceDetector::silences(&[], WINDOW, -40.0, Time::ZERO).is_empty());
    }
}
