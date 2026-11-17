//! Pure maths of the export preview.

use sq_core_time::{Time, TimeRange};
use sq_export::core::settings::ExportSettings;
use sq_uikit::keyframe_graph_geometry::Rect;

/// Pure maths of the export preview (the Mac `ExportPreviewModel` and the shared `ShellExportPreview`).
// Swift: Export/ExportPreviewMath.swift:5
pub enum ExportPreviewMath {}

impl ExportPreviewMath {
    /// Frame index under a 0...1 position of the scrub bar (clamped; 0 for an empty source).
    // Swift: Export/ExportPreviewMath.swift:8
    pub fn index(fraction: f64, count: i64) -> i64 {
        if count <= 1 {
            return 0;
        }
        (fraction.clamp(0.0, 1.0) * (count - 1) as f64).round() as i64
    }

    /// Frame index of a 0...1 position inside the exported range, as `playhead_fraction` gives it: the frame that is on
    /// screen at that time (`fraction * count`, rounded down), not the nearest of `count - 1` steps (that one lands a
    /// frame early on every frame past the middle). The tiny bias keeps an exact frame start from rounding down.
    pub fn playhead_index(fraction: f64, count: i64) -> i64 {
        if count <= 1 {
            return 0;
        }
        ((fraction.clamp(0.0, 1.0) * count as f64 + 1e-6).floor() as i64).min(count - 1)
    }

    /// The 0...1 scrub position of the playhead inside the exported `range` (clamped; 0 for an empty range): the
    /// preview opens on the frame the editor shows, not on the first one.
    pub fn playhead_fraction(playhead: Time, range: TimeRange) -> f64 {
        let secs = |t: Time| t.value() as f64 / t.timescale() as f64;
        let len = secs(range.duration);
        if len <= 0.0 {
            return 0.0;
        }
        ((secs(playhead) - secs(range.start)) / len).clamp(0.0, 1.0)
    }

    /// The 0...1 scrub position of a frame index.
    // Swift: Export/ExportPreviewMath.swift:12
    pub fn fraction(index: i64, count: i64) -> f64 {
        if count <= 1 {
            return 0.0;
        }
        (index as f64 / (count - 1) as f64).clamp(0.0, 1.0)
    }

    /// The preview renders what the export would, but small (longest side <= `max_side`, even, never scaled up) and
    /// without audio. The Swift default for `max_side` is 640.
    // Swift: Export/ExportPreviewMath.swift:19
    pub fn preview_settings(s: &ExportSettings, max_side: i64) -> ExportSettings {
        let mut p = s.clone();
        let (w, h) = (s.video.width.max(2), s.video.height.max(2));
        let longest = w.max(h);
        if longest > max_side {
            p.video.width = ((w * max_side / longest) & !1).max(2);
            p.video.height = ((h * max_side / longest) & !1).max(2);
        } else {
            p.video.width = w & !1;
            p.video.height = h & !1;
        }
        p.audio.enabled = false;
        p.audio.loudness = None;
        p
    }

    /// The picture rect inside the viewer box: the output's aspect (16:9 when unknown), fitted and centered.
    // Swift: Export/ExportPreviewMath.swift:36
    pub fn picture_rect(bx: Rect, width: i64, height: i64) -> Rect {
        let aspect = if height > 0 && width > 0 { width as f64 / height as f64 } else { 16.0 / 9.0 };
        let (mut w, mut h) = (bx.width, bx.width / aspect);
        if h > bx.height {
            h = bx.height;
            w = h * aspect;
        }
        Rect {
            x: bx.x + ((bx.width - w) / 2.0).round(),
            y: bx.y + ((bx.height - h) / 2.0).round(),
            width: w.round(),
            height: h.round(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_playhead_opens_on_its_own_frame_not_the_one_before() {
        // Frame 80 of 100 starts at 80/100 of the range.
        let fraction =
            ExportPreviewMath::playhead_fraction(Time::new(80, 25), TimeRange::new(Time::ZERO, Time::new(100, 25)));
        assert_eq!(ExportPreviewMath::playhead_index(fraction, 100), 80);
        assert_eq!(ExportPreviewMath::index(fraction, 100), 79, "the scrub bar rounds over count - 1 steps");
        assert_eq!(ExportPreviewMath::playhead_index(1.0, 100), 99);
        assert_eq!(ExportPreviewMath::playhead_index(0.5, 501), 250);
        assert_eq!(ExportPreviewMath::playhead_index(0.7, 1), 0);
    }

    #[test]
    fn scrub_index_and_fraction_clamp() {
        assert_eq!(ExportPreviewMath::index(0.5, 11), 5);
        assert_eq!(ExportPreviewMath::index(2.0, 11), 10);
        assert_eq!(ExportPreviewMath::index(0.7, 1), 0);
        assert_eq!(ExportPreviewMath::fraction(5, 11), 0.5);
        assert_eq!(ExportPreviewMath::fraction(5, 0), 0.0);
    }

    #[test]
    fn the_playhead_sets_the_start_position_inside_the_range() {
        let range = TimeRange::new(Time::seconds(10), Time::seconds(20));
        assert_eq!(ExportPreviewMath::playhead_fraction(Time::seconds(15), range), 0.25);
        assert_eq!(ExportPreviewMath::playhead_fraction(Time::seconds(2), range), 0.0, "before the range");
        assert_eq!(ExportPreviewMath::playhead_fraction(Time::seconds(99), range), 1.0, "after the range");
        assert_eq!(ExportPreviewMath::playhead_fraction(Time::seconds(1), TimeRange::new(Time::ZERO, Time::ZERO)), 0.0);
    }

    #[test]
    fn preview_is_small_even_silent_and_never_scaled_up() {
        let mut s = ExportSettings::default();
        s.video.width = 1920;
        s.video.height = 1080;
        let p = ExportPreviewMath::preview_settings(&s, 640);
        assert_eq!((p.video.width, p.video.height), (640, 360));
        assert!(!p.audio.enabled && p.audio.loudness.is_none());
        s.video.width = 301;
        s.video.height = 101;
        let p = ExportPreviewMath::preview_settings(&s, 640);
        assert_eq!((p.video.width, p.video.height), (300, 100));
    }

    #[test]
    fn picture_fits_and_centers_in_the_box() {
        let r = ExportPreviewMath::picture_rect(Rect { x: 10.0, y: 20.0, width: 400.0, height: 400.0 }, 1080, 1920);
        assert_eq!((r.height, r.width), (400.0, 225.0));
        assert_eq!(r.x, 10.0 + 88.0);
        let r = ExportPreviewMath::picture_rect(Rect { x: 0.0, y: 0.0, width: 320.0, height: 180.0 }, 0, 0);
        assert_eq!((r.width, r.height), (320.0, 180.0));
    }
}
