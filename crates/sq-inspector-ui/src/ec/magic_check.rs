//! Step 3 of the Magic Mask ("Check the result") from what the tracker stored: the followed stretch and the stretches that
//! might slip, as fractions of the clip, plus where the first weak stretch begins on the timeline ("Show me where").
//! The weak stretches are `MagicTrackHealth::weak_spans` of the stored matte areas; nothing is stored for them.

use sq_core_masks::magic_track_health::{HealthSample, MagicTrackHealth};
use sq_core_model::Clip;
use sq_core_time::Time;

/// What the strip and the "Show me where" button need.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MagicCheck {
    /// The followed stretch of the clip, 0..1.
    pub tracked: Option<(f64, f64)>,
    /// Stretches that might slip, 0..1.
    pub weak: Vec<(f64, f64)>,
    /// Timeline time where the first weak stretch begins.
    pub first_weak: Option<Time>,
}

fn secs(t: Time) -> f64 {
    t.value() as f64 / t.timescale().max(1) as f64
}

impl MagicCheck {
    // shortcut: fractions follow the clip's source range left to right (a reversed or speed-ramped clip shows the strip
    // unflipped); upgrade with the clip's time mapping when the strip is checked on such clips.
    /// From the stored frames' coverage (source seconds) of the clip's Magic mask.
    pub fn from_samples(clip: &Clip, samples: &[HealthSample], frame_duration: Time) -> MagicCheck {
        if samples.is_empty() {
            return MagicCheck::default();
        }
        let (lo, hi) = (secs(clip.source.start), secs(clip.source.end()));
        let len = (hi - lo).max(1e-9);
        let f = |s: f64| ((s - lo) / len).clamp(0.0, 1.0);
        let mut times: Vec<f64> = samples.iter().map(|s| s.pts).collect();
        times.sort_by(f64::total_cmp);
        let step = times.windows(2).map(|w| w[1] - w[0]).filter(|d| *d > 1e-6).fold(f64::INFINITY, f64::min);
        let step = if step.is_finite() { step } else { secs(frame_duration) };
        let tracked = (f(times[0]), f(times[times.len() - 1] + step));
        let spans = MagicTrackHealth::weak_spans(samples);
        let weak = spans.iter().filter(|s| s.end > lo && s.start < hi).map(|s| (f(s.start), f(s.end))).collect();
        let first_weak = MagicTrackHealth::weak_starts(clip, &spans, frame_duration).first().copied();
        MagicCheck { tracked: Some(tracked), weak, first_weak }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::TrackKind;
    use sq_core_time::{Id, TimeRange};

    fn clip() -> Clip {
        // 10 s of source from 2 s, placed at 5 s.
        Clip::new(
            Id::from_u128(1),
            "c",
            Id::from_u128(2),
            TrackKind::Video,
            TimeRange::new(Time::new(2, 1), Time::new(10, 1)),
            Time::new(5, 1),
        )
    }

    fn samples(areas: &[f64]) -> Vec<HealthSample> {
        areas.iter().enumerate().map(|(i, a)| HealthSample { pts: 2.0 + i as f64, area: *a }).collect()
    }

    #[test]
    fn nothing_tracked_is_an_empty_check() {
        assert_eq!(MagicCheck::from_samples(&clip(), &[], Time::new(1, 30)), MagicCheck::default());
    }

    #[test]
    fn a_dropped_matte_is_a_weak_stretch_and_the_button_target() {
        // Ten frames a second apart, the subject nearly lost on the 5th (source 6 s).
        let s = samples(&[0.3, 0.3, 0.3, 0.3, 0.02, 0.3, 0.3, 0.3, 0.3, 0.3]);
        let c = MagicCheck::from_samples(&clip(), &s, Time::new(1, 30));
        assert_eq!(c.tracked, Some((0.0, 1.0)));
        assert!(!c.weak.is_empty());
        let (a, b) = c.weak[0];
        assert!((a - 0.4).abs() < 1e-9 && b > a, "{:?}", c.weak);
        // Source 6 s is 4 s into the clip: timeline 5 + 4 = 9 s.
        assert_eq!(c.first_weak, Some(Time::new(9, 1)));
    }

    #[test]
    fn an_even_track_has_no_weak_stretch() {
        let c = MagicCheck::from_samples(&clip(), &samples(&[0.3; 8]), Time::new(1, 30));
        assert!(c.weak.is_empty() && c.first_weak.is_none());
        assert_eq!(c.tracked.map(|t| t.0), Some(0.0));
        assert!(c.tracked.is_some_and(|t| t.1 > 0.7 && t.1 <= 1.0));
    }
}
