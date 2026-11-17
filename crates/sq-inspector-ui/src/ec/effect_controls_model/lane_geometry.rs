// Swift: EffectControlsModel.swift (Lane geometry)
//! Maps clip-local time to x in the keyframe lane and back.

use sq_core_time::Time;
use sq_uikit::keyframe_viewport::KeyframeViewport;

/// Maps clip-local time to x in the keyframe lane and back. Without a viewport the whole clip is visible.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct KeyframeLaneGeometry {
    pub width: f64,
    pub duration: Time,
    pub inset: f64,
    pub viewport: Option<KeyframeViewport>,
}

fn seconds_of(t: Time) -> f64 {
    t.value() as f64 / t.timescale() as f64
}

impl KeyframeLaneGeometry {
    /// Swift default `inset: 10`, `viewport: nil`.
    pub fn new(width: f64, duration: Time) -> KeyframeLaneGeometry {
        KeyframeLaneGeometry { width, duration, inset: 10.0, viewport: None }
    }

    pub fn with(width: f64, duration: Time, inset: f64, viewport: Option<KeyframeViewport>) -> KeyframeLaneGeometry {
        KeyframeLaneGeometry { width, duration, inset, viewport }
    }

    fn usable(&self) -> f64 {
        (self.width - 2.0 * self.inset).max(1.0)
    }

    fn duration_seconds(&self) -> f64 {
        seconds_of(self.duration)
    }

    pub fn view_start(&self) -> f64 {
        self.viewport.map_or(0.0, |v| v.start)
    }

    pub fn view_span(&self) -> f64 {
        self.viewport.map_or_else(|| self.duration_seconds(), |v| v.span.max(1e-9))
    }

    pub fn points_per_second(&self) -> f64 {
        if self.view_span() > 0.0 { self.usable() / self.view_span() } else { 0.0 }
    }

    pub fn x_seconds(&self, s: f64) -> f64 {
        if self.view_span() <= 0.0 {
            return self.inset;
        }
        self.inset + (s - self.view_start()) / self.view_span() * self.usable()
    }

    pub fn x(&self, local: Time) -> f64 {
        self.x_seconds(seconds_of(local))
    }

    /// Clip-local seconds at `x`, not clamped.
    pub fn seconds(&self, x: f64) -> f64 {
        self.view_start() + (x - self.inset) / self.usable() * self.view_span()
    }

    /// Nearest frame at `x`, clamped to 0...duration.
    pub fn time(&self, x: f64, frame_duration: Time) -> Time {
        if self.duration_seconds() <= 0.0 {
            return Time::ZERO;
        }
        let s = self.seconds(x);
        let fd = seconds_of(frame_duration);
        let t = Time::frames((s / fd).round() as i64, frame_duration);
        t.max(Time::ZERO).min(self.duration)
    }

    /// Nearest frame at `x`, not clamped: a key drag may go past either clip edge.
    pub fn unclamped_time(&self, x: f64, frame_duration: Time) -> Time {
        if self.duration_seconds() <= 0.0 {
            return Time::ZERO;
        }
        let fd = seconds_of(frame_duration);
        Time::frames((self.seconds(x) / fd).round() as i64, frame_duration)
    }

    pub fn nearest_index(&self, x: f64, times: &[Time], radius: f64) -> Option<usize> {
        let mut best: Option<(usize, f64)> = None;
        for (i, t) in times.iter().enumerate() {
            let d = (self.x(*t) - x).abs();
            if d <= radius && best.is_none_or(|b| d < b.1) {
                best = Some((i, d));
            }
        }
        best.map(|b| b.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_time_to_x_and_back_inside_the_inset() {
        let g = KeyframeLaneGeometry::new(220.0, Time::seconds(10));
        assert_eq!(g.x_seconds(0.0), 10.0);
        assert_eq!(g.x_seconds(10.0), 210.0);
        assert_eq!(g.seconds(110.0), 5.0);
    }

    #[test]
    fn time_snaps_to_frames_and_clamps_to_the_clip() {
        let fd = Time::new(1, 30);
        let g = KeyframeLaneGeometry::new(220.0, Time::seconds(10));
        assert_eq!(g.time(-50.0, fd), Time::ZERO);
        assert_eq!(g.time(900.0, fd), Time::seconds(10));
        assert!(g.unclamped_time(-50.0, fd).is_negative());
        assert_eq!(g.time(110.0, fd), Time::seconds(5));
    }

    #[test]
    fn nearest_index_respects_the_radius() {
        let g = KeyframeLaneGeometry::new(220.0, Time::seconds(10));
        let times = [Time::seconds(1), Time::seconds(5)];
        assert_eq!(g.nearest_index(111.0, &times, 4.0), Some(1));
        assert_eq!(g.nearest_index(60.0, &times, 4.0), None);
    }

    #[test]
    fn a_viewport_zooms_the_mapping() {
        let g = KeyframeLaneGeometry::with(220.0, Time::seconds(10), 10.0, Some(KeyframeViewport::new(2.0, 4.0)));
        assert_eq!(g.x_seconds(2.0), 10.0);
        assert_eq!(g.x_seconds(6.0), 210.0);
        assert_eq!(g.points_per_second(), 50.0);
    }
}
