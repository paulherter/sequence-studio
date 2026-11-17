// Swift: TrackConfidenceSpans.swift
//! Portable part of the track confidence strip (the drawing is Mac only).
//! MASK-UX 5.4: amber marks along the bottom of a clip with a tracked Magic mask where tracking is weak
//! (`MagicTrackHealth`); nothing where it holds. Tokens only.

use sq_core_masks::magic_track_health::{HealthSpan, MagicTrackHealth};
use sq_core_model::Clip;
use sq_core_time::Time;
use sq_uikit::keyframe_graph_geometry::Rect;
use std::ops::RangeInclusive;

/// The strip.
pub struct TrackConfidenceStrip;

impl TrackConfidenceStrip {
    /// Strip height.
    pub const HEIGHT: f64 = 3.0;

    /// Column ranges (0...width, in clip-local px) whose source time lies in a weak span. `source` maps the clip's
    /// fraction 0...1 to source seconds (through speed and reverse), sampled every `step` px.
    pub fn weak_ranges(
        width: f64,
        step: f64,
        source: &dyn Fn(f64) -> f64,
        spans: &[HealthSpan],
    ) -> Vec<RangeInclusive<f64>> {
        if !(width > 0.0 && step > 0.0 && !spans.is_empty()) {
            return Vec::new();
        }
        let mut out: Vec<RangeInclusive<f64>> = Vec::new();
        let mut x = 0.0;
        while x < width {
            let t = source((x + step / 2.0).min(width) / width);
            if spans.iter().any(|s| t >= s.start && t <= s.end) {
                let hi = (x + step).min(width);
                match out.last() {
                    Some(last) if *last.end() >= x - 1e-6 => {
                        let n = out.len();
                        out[n - 1] = *last.start()..=hi;
                    }
                    _ => out.push(x..=hi),
                }
            }
            x += step;
        }
        out
    }

    /// Click band of the strip: its height plus 3 px of slack above, so the 3 px strip is hittable.
    pub fn hit_band(clip_rect: &Rect) -> Rect {
        Rect::new(clip_rect.min_x(), clip_rect.max_y() - Self::HEIGHT - 3.0, clip_rect.width, Self::HEIGHT + 3.0)
    }

    /// Where a click on the strip at timeline time `t` jumps the playhead: the start (on the timeline) of the weak stretch
    /// under it, clamped into the clip. `None` when the click is not on a weak stretch.
    pub fn jump_target(clip: &Clip, spans: &[HealthSpan], t: Time, frame_duration: Time) -> Option<Time> {
        let s = clip.source_time(t, frame_duration);
        let sec = s.value() as f64 / s.timescale() as f64;
        let span = spans.iter().find(|s| sec >= s.start && sec <= s.end)?;
        let at = |v: f64| clip.timeline_time_for_source(Time::new((v * 600.0).round() as i64, 600), frame_duration);
        let early = at(span.start).min(at(span.end));
        Some(early.max(clip.timeline().start).min(clip.timeline().end() - frame_duration))
    }

    /// Timeline times where the clip's weak stretches begin (`MagicTrackHealth::weak_starts`, shared with the shared window).
    pub fn weak_starts(clip: &Clip, spans: &[HealthSpan], frame_duration: Time) -> Vec<Time> {
        MagicTrackHealth::weak_starts(clip, spans, frame_duration)
    }

    /// "Go to Next Weak Tracking" (`MagicTrackHealth::next_weak_start`).
    pub fn next_weak_start(
        t: Time,
        clips: &[Clip],
        spans: &dyn Fn(&Clip) -> Option<Vec<HealthSpan>>,
        frame_duration: Time,
    ) -> Option<Time> {
        MagicTrackHealth::next_weak_start(t, clips, spans, frame_duration)
    }

    /// Columns (clip-local px) where a weak stretch begins in clip order: the amber "tracking lost here" markers.
    pub fn marker_columns(width: f64, step: f64, source: &dyn Fn(f64) -> f64, spans: &[HealthSpan]) -> Vec<f64> {
        Self::weak_ranges(width, step, source, spans).into_iter().map(|r| *r.start()).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::*;
    use sq_core_model::TrackKind;
    use sq_core_time::TimeRange;

    fn span(start: f64, end: f64) -> HealthSpan {
        HealthSpan { start, end }
    }

    #[test]
    fn weak_spans_become_merged_column_ranges() {
        // Source time = 10 s over the clip's width; weak from 2 s to 4 s.
        let r = TrackConfidenceStrip::weak_ranges(100.0, 2.0, &|f| f * 10.0, &[span(2.0, 4.0)]);
        assert_eq!(r.len(), 1);
        assert!((r[0].start() - 20.0).abs() <= 2.0 && (r[0].end() - 40.0).abs() <= 2.0);
    }

    #[test]
    fn reversed_clip_flips_the_strip() {
        let r = TrackConfidenceStrip::weak_ranges(100.0, 2.0, &|f| 10.0 - f * 10.0, &[span(2.0, 4.0)]);
        assert_eq!(r.len(), 1);
        assert!((r[0].start() - 60.0).abs() <= 2.0 && (r[0].end() - 80.0).abs() <= 2.0);
    }

    #[test]
    fn no_spans_no_ranges() {
        assert!(TrackConfidenceStrip::weak_ranges(100.0, 2.0, &|f| f, &[]).is_empty());
        assert!(TrackConfidenceStrip::weak_ranges(0.0, 2.0, &|f| f, &[span(0.0, 1.0)]).is_empty());
    }

    fn clip(reversed: bool) -> Clip {
        let mut c = Clip::new(
            uid(),
            "c",
            uid(),
            TrackKind::Video,
            TimeRange::new(Time::seconds(5), Time::seconds(10)),
            Time::seconds(100),
        );
        c.reversed = reversed;
        c
    }

    const F30: Time = Time::new(1, 30);

    #[test]
    fn click_in_a_weak_stretch_jumps_to_its_start() {
        // Clip shows source 5...15 at timeline 100...110; weak source 8...9 = timeline 103...104.
        let t = TrackConfidenceStrip::jump_target(
            &clip(false),
            &[span(8.0, 9.0)],
            Time::seconds(103) + Time::new(1, 2),
            F30,
        );
        assert_eq!(t, Some(Time::seconds(103)));
    }

    #[test]
    fn click_outside_a_weak_stretch_does_nothing() {
        assert_eq!(TrackConfidenceStrip::jump_target(&clip(false), &[span(8.0, 9.0)], Time::seconds(106), F30), None);
    }

    #[test]
    fn span_starting_before_the_clip_jumps_to_the_clip_start() {
        let t = TrackConfidenceStrip::jump_target(&clip(false), &[span(2.0, 7.0)], Time::seconds(101), F30);
        assert_eq!(t, Some(Time::seconds(100)));
    }

    #[test]
    fn reversed_clip_jumps_to_the_earlier_timeline_edge() {
        // Reversed: source 9 shows near timeline 106, source 8 near 107; the stretch's timeline start is its source end.
        let t = TrackConfidenceStrip::jump_target(
            &clip(true),
            &[span(8.0, 9.0)],
            Time::seconds(106) + Time::new(1, 2),
            F30,
        );
        assert!(t.is_some_and(|t| (t.value() as f64 / t.timescale() as f64 - 106.0).abs() < 0.1));
    }

    #[test]
    fn hit_band_is_the_strip_plus_slack() {
        let r = Rect::new(0.0, 10.0, 100.0, 40.0);
        let band = TrackConfidenceStrip::hit_band(&r);
        assert!(band.contains(sq_uikit::keyframe_graph_geometry::Point::new(50.0, 49.0)));
        assert!(!band.contains(sq_uikit::keyframe_graph_geometry::Point::new(50.0, 30.0)));
    }

    #[test]
    fn markers_sit_at_the_start_of_each_weak_stretch() {
        let m = TrackConfidenceStrip::marker_columns(100.0, 2.0, &|f| f * 10.0, &[span(2.0, 4.0), span(7.0, 8.0)]);
        assert_eq!(m.len(), 2);
        assert!((m[0] - 20.0).abs() <= 2.0 && (m[1] - 70.0).abs() <= 2.0);
    }
}
