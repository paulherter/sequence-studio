// Swift: TimelinePanel+Ruler.swift
//! The ruler row, translated from `RulerView.draw`: In/Out band, cache strip, ticks with timecode labels, markers, the
//! "Tracks" corner over the header column, the bottom hairline and the playhead head.

use crate::geom::RectExt as _;
use crate::panel::TimelinePanel;
use crate::skin::TimelineSkin;
use sq_core_time::TimeRange;
use sq_draw::Canvas;
use sq_editor_session::{RulerScale, TimecodeFormat};
use sq_timeline_ui::{MarkerRange, TimelineGeometry};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{radius, type_size};

impl TimelinePanel {
    pub(crate) fn draw_ruler(&self, cv: &mut Canvas) {
        let h = TimelineGeometry::RULER_HEIGHT;
        let origin = TimelineGeometry::CONTENT_ORIGIN_X;
        let content = CGRect::new(origin, 0.0, (self.size.width - origin).max(0.0), h);
        cv.fill(CGRect::new(0.0, 0.0, self.size.width, h), self.theme.timeline());
        if !content.is_empty_rect() {
            cv.save_gstate();
            cv.clip_to(content);
            self.draw_ruler_in_out(cv, content);
            self.draw_cache_strip(cv, content);
            self.draw_ticks(cv, content);
            self.draw_markers(cv, content);
            cv.restore_gstate();
        }
        self.draw_tracks_corner(cv);
        cv.fill(CGRect::new(0.0, h - 1.0, self.size.width, 1.0), self.theme.track_row_line());
        self.draw_playhead_head(cv);
    }

    fn draw_tracks_corner(&self, cv: &mut Canvas) {
        let r = CGRect::new(
            TimelineGeometry::TOOL_COLUMN_WIDTH,
            0.0,
            TimelineGeometry::HEADER_WIDTH,
            TimelineGeometry::RULER_HEIGHT,
        );
        cv.fill(r, self.theme.panel());
        cv.fill(CGRect::new(r.max_x() - 1.0, 0.0, 1.0, r.height), self.theme.separator());
    }

    fn draw_ruler_in_out(&self, cv: &mut Canvas, clip: CGRect) {
        let Some(io) = self.timeline.in_out.filter(|io| !io.is_empty()) else { return };
        let (x0, x1) = (self.geometry.x(io.start), self.geometry.x(io.end()));
        if !(x1 > clip.min_x() && x0 < clip.max_x()) {
            return;
        }
        let h = TimelineGeometry::RULER_HEIGHT;
        let skin = self.skin();
        cv.fill_rounded(CGRect::new(x0, h - 4.0, x1 - x0, 4.0), f64::from(radius::SMALL) / 2.0, skin.accent_tint());
        if x0 >= clip.min_x() - 2.0 {
            cv.fill(CGRect::new(x0, h - 8.0, 2.0, 8.0), self.theme.accent());
        }
        if x1 <= clip.max_x() + 2.0 {
            cv.fill(CGRect::new(x1 - 2.0, h - 8.0, 2.0, 8.0), self.theme.accent());
        }
    }

    /// `RulerView.cacheBars`, copied (the Mac copy lives in the AppKit ruler): merged x spans of at least 3 pt.
    pub(crate) fn cache_bars(ranges: &[TimeRange], geometry: &TimelineGeometry) -> Vec<(f64, f64)> {
        let mut sorted: Vec<&TimeRange> = ranges.iter().collect();
        sorted.sort_by_key(|r| r.start);
        let mut bars: Vec<(f64, f64)> = Vec::new();
        for r in sorted {
            let (a, b) = (geometry.x(r.start), geometry.x(r.end()));
            if b < a {
                continue;
            }
            match bars.last_mut() {
                Some(last) if a - last.1 < 6.0 => last.1 = last.1.max(b),
                _ => bars.push((a, b)),
            }
        }
        bars.into_iter().filter(|b| b.1 - b.0 >= 3.0).collect()
    }

    fn draw_cache_strip(&self, cv: &mut Canvas, clip: CGRect) {
        for (lo, hi) in Self::cache_bars(&self.cached_ranges, &self.geometry) {
            let (x0, x1) = (lo.max(clip.min_x()), hi.min(clip.max_x()));
            if x1 > x0 {
                cv.fill(CGRect::new(x0, 0.0, x1 - x0, 2.0), self.skin().cache_strip());
            }
        }
    }

    /// `RulerView.ticks`: frame numbers of the visible ticks and whether each is a labeled major tick.
    pub(crate) fn ticks(&self, visible_min_x: f64, visible_max_x: f64, nominal_fps: i64) -> Vec<(i64, bool)> {
        let fd = self.geometry.frame_duration;
        let fd_sec = fd.value() as f64 / fd.timescale() as f64;
        let ppf = self.geometry.points_per_second * fd_sec;
        if ppf <= 0.0 {
            return Vec::new();
        }
        let scale = RulerScale::scale(ppf, nominal_fps, 96.0, 6.0);
        let first_frame =
            ((visible_min_x - TimelineGeometry::CONTENT_ORIGIN_X + self.geometry.scroll_x) / ppf).floor() as i64;
        let last_frame =
            ((visible_max_x - TimelineGeometry::CONTENT_ORIGIN_X + self.geometry.scroll_x) / ppf).ceil() as i64;
        let mut f = ((first_frame / scale.minor_frames) * scale.minor_frames).max(0);
        let mut out = Vec::new();
        while f <= last_frame {
            out.push((f, f % scale.major_frames == 0));
            f += scale.minor_frames;
        }
        out
    }

    /// `TimecodeFormat(frameDuration:)`: drop-frame wherever the rate has it (29.97 / 59.94), like the header.
    pub(crate) fn label_format(fd: sq_core_time::Time) -> TimecodeFormat {
        TimecodeFormat::new(fd, true)
    }

    fn draw_ticks(&self, cv: &mut Canvas, clip: CGRect) {
        let fd = self.geometry.frame_duration;
        let timecode = Self::label_format(fd);
        let h = TimelineGeometry::RULER_HEIGHT;
        let fs = f64::from(type_size::CAPTION);
        let line_height = cv.size_of("0", fs, 0).height;
        // A marker flag sits on its time; a label never runs under one (see `label_x`).
        let marker_xs: Vec<f64> = self.timeline.markers.iter().map(|m| self.geometry.x(m.time).round()).collect();
        let scale = RulerScale::scale(
            self.geometry.points_per_second * fd.value() as f64 / fd.timescale() as f64,
            timecode.nominal_fps,
            96.0,
            6.0,
        );
        for (frame, major) in self.ticks(clip.min_x() - 80.0, clip.max_x(), timecode.nominal_fps) {
            let x = self.geometry.x(fd * frame).round();
            // Spec 9: a major tick 9 pt with its time, a medium one halfway between majors 6 pt, a minor one 4 pt.
            let medium = !major && scale.major_frames % 2 == 0 && frame % (scale.major_frames / 2) == 0;
            let len = if major {
                9.0
            } else if medium {
                6.0
            } else {
                4.0
            };
            cv.fill(CGRect::new(x, h - len, 1.0, len), self.theme.hair2());
            if major {
                let text = timecode.string_for_frame(frame);
                let width = cv.size_of(&text, fs, 0).width;
                if let Some(label_x) = Self::label_x(x, width, &marker_xs) {
                    cv.draw_text(
                        &text,
                        CGPoint { x: label_x, y: ((h - line_height) / 2.0).round() },
                        fs,
                        self.theme.label3(),
                        f64::INFINITY,
                        0,
                    );
                }
            }
        }
    }

    /// Half the width of a marker flag, plus a 1 pt gap.
    const FLAG_CLEARANCE: f64 = 4.5;
    /// The furthest a label may move right of its tick to clear a flag.
    const MAX_LABEL_SHIFT: f64 = 12.0;

    /// Where the label of the tick at `x` (`width` wide) starts so that it never runs under a marker flag at one of
    /// `flag_xs`: right of the tick, else right of the flag in the way; `None` when it still collides after that (the
    /// label is left out, a flag is never struck through).
    pub(crate) fn label_x(x: f64, width: f64, flag_xs: &[f64]) -> Option<f64> {
        let hit = |lx: f64| {
            flag_xs.iter().copied().find(|f| lx < f + Self::FLAG_CLEARANCE && lx + width > f - Self::FLAG_CLEARANCE)
        };
        let natural = x + 3.5;
        let mut lx = natural;
        for _ in 0..=flag_xs.len() {
            match hit(lx) {
                // A label that has to move far from its tick would name the wrong time: leave it out instead.
                None => return (lx - natural <= Self::MAX_LABEL_SHIFT).then_some(lx),
                Some(f) => lx = f + Self::FLAG_CLEARANCE,
            }
        }
        None
    }

    fn draw_markers(&self, cv: &mut Canvas, clip: CGRect) {
        let h = TimelineGeometry::RULER_HEIGHT;
        for m in &self.timeline.markers {
            let x = self.geometry.x(m.time).round();
            if !(x <= clip.max_x() + 8.0 && x.max(self.geometry.x(m.time + m.duration)) >= clip.min_x() - 8.0) {
                continue;
            }
            let c = self.theme.label2(); // artifact .mk: gray t2
            if let Some(bar) = MarkerRange::bar_rect(m, &self.geometry, h)
                && bar.max_x() >= clip.min_x()
            {
                cv.fill(bar, c.with_alpha(0.55));
                cv.fill(CGRect::new(bar.max_x() - 1.0, bar.min_y() - 3.0, 2.0, bar.height + 3.0), c);
            }
            let top = h - 4.0 - 9.0;
            let p = |x: f64, y: f64| CGPoint { x, y };
            cv.fill_polygon(
                &[p(x - 3.5, top), p(x + 3.5, top), p(x + 3.5, top + 5.4), p(x, top + 9.0), p(x - 3.5, top + 5.4)],
                c,
            );
        }
    }

    fn draw_playhead_head(&self, cv: &mut Canvas) {
        let x = self.geometry.x(self.playhead);
        if !(x >= TimelineGeometry::CONTENT_ORIGIN_X - 7.0 && x <= self.size.width + 7.0) {
            return;
        }
        cv.save_gstate();
        cv.clip_to(CGRect::new(
            TimelineGeometry::CONTENT_ORIGIN_X,
            0.0,
            (self.size.width - TimelineGeometry::CONTENT_ORIGIN_X).max(0.0),
            TimelineGeometry::RULER_HEIGHT,
        ));
        let c = x.round();
        cv.fill(TimelineSkin::line_frame(c, 0.0, TimelineGeometry::RULER_HEIGHT), self.theme.playhead());
        self.skin().draw_head(cv, c, 0.0);
        cv.restore_gstate();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;

    #[test]
    fn ruler_labels_never_run_under_marker_flags() {
        // No flag: right of the tick.
        assert_eq!(TimelinePanel::label_x(100.0, 60.0, &[]), Some(103.5));
        // A flag on the tick: the label starts right of the flag.
        let lx = TimelinePanel::label_x(100.0, 60.0, &[100.0]).unwrap();
        assert!(lx >= 100.0 + TimelinePanel::FLAG_CLEARANCE);
        // A flag in the middle of the label: the label moves behind it, or is left out; it never overlaps.
        for flags in [vec![130.0], vec![130.0, 170.0], vec![105.0, 120.0, 150.0, 190.0]] {
            if let Some(lx) = TimelinePanel::label_x(100.0, 60.0, &flags) {
                for f in &flags {
                    assert!(lx >= f + 4.5 || lx + 60.0 <= f - 4.5, "label at {lx} under flag {f}");
                }
            }
        }
        // Flags every 20 pt leave no room: the label is left out.
        let dense: Vec<f64> = (0..20).map(|i| 110.0 + 20.0 * f64::from(i)).collect();
        assert_eq!(TimelinePanel::label_x(100.0, 60.0, &dense), None);
    }

    #[test]
    fn labels_use_drop_frame_at_ntsc_rates() {
        let f = TimelinePanel::label_format(Time::new(1001, 30000));
        assert_eq!(f.string_for_frame(1800), "00:01:00;02");
        let f = TimelinePanel::label_format(Time::new(1001, 60000));
        assert_eq!(f.string_for_frame(3600), "00:01:00;04");
        let f = TimelinePanel::label_format(Time::new(1, 25));
        assert_eq!(f.string_for_frame(1500), "00:01:00:00");
    }
}
