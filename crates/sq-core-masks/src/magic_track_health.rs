// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MagicTrackHealth.swift and MagicTrackHealth+Timeline.swift
//! Where tracking of a Magic mask is weak (the "confidence strip"). Nothing is stored for it: the stored matte areas
//! tell. A frame is weak when its matte shrank to a fraction of the typical one (the subject is nearly lost), when the
//! area jumped against the frame before (the follower grabbed another object or let go of part of the subject), or when
//! frames are missing (tracking skipped a stretch). Pure, in source seconds.

use sq_core_model::Clip;
use sq_core_time::Time;

/// One stored frame of a track.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HealthSample {
    /// Source seconds of the frame.
    pub pts: f64,
    /// Matte coverage of the frame, 0...1.
    pub area: f64,
}

/// A stretch of source seconds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HealthSpan {
    /// First second.
    pub start: f64,
    /// Last second.
    pub end: f64,
}

/// Weak tracking found from stored matte areas.
pub struct MagicTrackHealth;

impl MagicTrackHealth {
    /// A matte below this share of the median area is weak.
    pub const SHRUNK_BELOW: f64 = 0.4;
    /// A change of area above this share of the previous frame's is weak.
    pub const JUMP_ABOVE: f64 = 0.6;

    /// Weak stretches, merged, sorted. A weak frame covers its own time up to the next frame.
    pub fn weak_spans(samples: &[HealthSample]) -> Vec<HealthSpan> {
        let mut s = samples.to_vec();
        s.sort_by(|a, b| a.pts.total_cmp(&b.pts));
        if s.len() < 3 {
            return Vec::new();
        }
        let mut gaps: Vec<f64> = s.windows(2).map(|w| w[1].pts - w[0].pts).collect();
        gaps.sort_by(f64::total_cmp);
        let spacing = gaps[gaps.len() / 2].max(1e-6);
        let mut areas: Vec<f64> = s.iter().map(|x| x.area).collect();
        areas.sort_by(f64::total_cmp);
        let median = areas[areas.len() / 2];
        let mut out: Vec<HealthSpan> = Vec::new();
        let add = |out: &mut Vec<HealthSpan>, a: f64, b: f64| {
            if let Some(last) = out.last_mut()
                && a <= last.end + 1e-9
            {
                last.end = last.end.max(b);
                return;
            }
            out.push(HealthSpan { start: a, end: b });
        };
        for i in 0..s.len() {
            let end = if i + 1 < s.len() { s[i + 1].pts } else { s[i].pts + spacing };
            if i + 1 < s.len() && s[i + 1].pts - s[i].pts > spacing * 1.5 + 1e-6 {
                add(&mut out, s[i].pts, s[i + 1].pts); // missing frames
            }
            // An empty matte is a frame the subject was not found on: weak whatever the rest of the track looks like.
            let mut weak = s[i].area < median * Self::SHRUNK_BELOW || s[i].area <= 0.0;
            if i > 0 && s[i - 1].area > 1e-6 && (s[i].area - s[i - 1].area).abs() / s[i - 1].area > Self::JUMP_ABOVE {
                weak = true;
            }
            if weak {
                add(&mut out, s[i].pts, end);
            }
        }
        out
    }

    /// Total length of the spans.
    pub fn weak_seconds(spans: &[HealthSpan]) -> f64 {
        spans.iter().fold(0.0, |a, s| a + s.end - s.start)
    }

    /// Start of the first weak span beginning after `t` (the strip's "jump to the next weak frame"), `None` past the last.
    pub fn next(t: f64, spans: &[HealthSpan]) -> Option<f64> {
        spans.iter().find(|s| s.start > t + 1e-9).map(|s| s.start)
    }

    /// Timeline times where the clip's weak stretches begin (earlier timeline edge, so reversed clips work), clamped
    /// into the clip, sorted. Stretches outside the clip's source range are left out.
    pub fn weak_starts(clip: &Clip, spans: &[HealthSpan], frame_duration: Time) -> Vec<Time> {
        let lo = clip.source.start.value() as f64 / clip.source.start.timescale() as f64;
        let hi = clip.source.end().value() as f64 / clip.source.end().timescale() as f64;
        let at = |v: f64| clip.timeline_time_for_source(Time::new((v * 600.0).round() as i64, 600), frame_duration);
        let last = clip.timeline().end() - frame_duration;
        let mut out: Vec<Time> = spans
            .iter()
            .filter(|s| s.end > lo && s.start < hi)
            .map(|span| {
                let a = at(span.start.max(lo).min(hi));
                let b = at(span.end.max(lo).min(hi));
                a.min(b).max(clip.timeline().start).min(last)
            })
            .collect();
        out.sort();
        out
    }

    /// "Go to Next Weak Tracking": the earliest weak-stretch start after `t` over `clips`. `spans` gives each clip's weak
    /// stretches, `None` for clips without a tracked Magic mask.
    pub fn next_weak_start(
        t: Time,
        clips: &[Clip],
        spans: &dyn Fn(&Clip) -> Option<Vec<HealthSpan>>,
        frame_duration: Time,
    ) -> Option<Time> {
        clips
            .iter()
            .filter_map(|c| {
                spans(c).and_then(|s| Self::weak_starts(c, &s, frame_duration).into_iter().find(|x| *x > t))
            })
            .min()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_util::test_clip;
    use sq_core_time::{Id, TimeRange};

    fn samples(areas: &[f64]) -> Vec<HealthSample> {
        areas.iter().enumerate().map(|(i, a)| HealthSample { pts: i as f64 / 24.0, area: *a }).collect()
    }
    fn span(start: f64, end: f64) -> HealthSpan {
        HealthSpan { start, end }
    }

    #[test]
    fn steady_track_has_no_weak_spans() {
        assert!(MagicTrackHealth::weak_spans(&samples(&[0.2; 48])).is_empty());
        let rising: Vec<f64> = (0..48).map(|i| 0.2 + f64::from(i) * 0.001).collect();
        assert!(MagicTrackHealth::weak_spans(&samples(&rising)).is_empty());
    }

    #[test]
    fn too_few_frames_say_nothing() {
        assert!(MagicTrackHealth::weak_spans(&samples(&[0.2])).is_empty());
        assert!(MagicTrackHealth::weak_spans(&[]).is_empty());
    }

    #[test]
    fn a_shrunken_matte_is_weak_and_merged() {
        let mut a = vec![0.2; 48];
        for v in &mut a[20..=23] {
            *v = 0.02;
        }
        let spans = MagicTrackHealth::weak_spans(&samples(&a));
        assert_eq!(spans.len(), 1);
        assert!((spans[0].start - 20.0 / 24.0).abs() < 1e-9);
        assert!((spans[0].end - 25.0 / 24.0).abs() < 1e-9); // the jump back to normal at 24 is flagged too
    }

    #[test]
    fn a_sudden_jump_is_weak_even_when_large() {
        let mut a = vec![0.1; 30];
        for v in &mut a[22..30] {
            *v = 0.3;
        }
        let spans = MagicTrackHealth::weak_spans(&samples(&a));
        assert_eq!(spans.len(), 1);
        assert!((spans[0].start - 22.0 / 24.0).abs() < 1e-9);
    }

    #[test]
    fn a_gap_in_the_stored_frames_is_weak() {
        let mut s = samples(&[0.2; 40]);
        s.drain(18..22);
        let spans = MagicTrackHealth::weak_spans(&s);
        assert_eq!(spans.len(), 1);
        assert!(spans[0].start <= 17.0 / 24.0 + 1e-9 && spans[0].end >= 22.0 / 24.0 - 1e-9);
    }

    /// Frames stored empty (subject not found) are weak, also when most of the track is empty (median 0).
    #[test]
    fn empty_frames_are_weak_even_when_most_are_empty() {
        let mut a = vec![0.0; 24];
        for v in &mut a[0..8] {
            *v = 0.2;
        }
        let spans = MagicTrackHealth::weak_spans(&samples(&a));
        assert_eq!(spans.len(), 1);
        assert!((spans[0].start - 8.0 / 24.0).abs() < 1e-9 && (spans[0].end - 1.0).abs() < 1e-9);
    }

    #[test]
    fn weak_fraction_of_a_span() {
        let spans = [span(1.0, 2.0), span(3.0, 3.5)];
        assert_eq!(MagicTrackHealth::weak_seconds(&spans), 1.5);
        assert_eq!(MagicTrackHealth::next(2.0, &spans), Some(3.0));
        assert_eq!(MagicTrackHealth::next(3.5, &spans), None);
    }

    fn secs(n: i64) -> Time {
        Time::seconds(n)
    }

    // Clip: source 5...15 s at timeline 100...110 s.
    fn clip(reversed: bool) -> Clip {
        let mut c = test_clip();
        c.source = TimeRange::new(secs(5), secs(10));
        c.start = secs(100);
        c.reversed = reversed;
        c
    }

    #[test]
    fn weak_starts_are_timeline_stretch_starts_inside_the_clip() {
        let fd = Time::new(1, 30);
        let s = MagicTrackHealth::weak_starts(&clip(false), &[span(2.0, 6.0), span(8.0, 9.0), span(20.0, 21.0)], fd);
        assert_eq!(s, vec![secs(100), secs(103)]);
    }

    #[test]
    fn next_weak_across_clips_is_the_earliest_after_the_playhead() {
        let fd = Time::new(1, 30);
        let a = clip(false);
        let mut b = test_clip();
        b.id = Id::from_u128(2);
        b.source = TimeRange::new(Time::ZERO, secs(10));
        b.start = secs(50);
        let (aid, bid) = (a.id, b.id);
        let spans = move |c: &Clip| {
            if c.id == aid {
                Some(vec![span(8.0, 9.0)])
            } else if c.id == bid {
                Some(vec![span(1.0, 2.0), span(6.0, 7.0)])
            } else {
                None
            }
        };
        let clips = [a, b];
        let next = |t: Time| MagicTrackHealth::next_weak_start(t, &clips, &spans, fd);
        assert_eq!(next(secs(0)), Some(secs(51)));
        assert_eq!(next(secs(51)), Some(secs(56)));
        assert_eq!(next(secs(60)), Some(secs(103)));
        assert_eq!(next(secs(103)), None);
    }

    #[test]
    fn reversed_clip_weak_start_is_the_earlier_timeline_edge() {
        let fd = Time::new(1, 30);
        let s = MagicTrackHealth::weak_starts(&clip(true), &[span(8.0, 9.0)], fd);
        assert_eq!(s.len(), 1);
        assert!((s[0].value() as f64 / s[0].timescale() as f64 - 106.0).abs() < 0.1);
    }
}
