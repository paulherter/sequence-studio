// Swift: TimelineCursorMap.swift
//! Which cursor shows where, per tool. Pure: the view turns these regions into cursor rects.
//! Regions mirror `TimelineInteraction::mouse_down` (same zones, same tool rules), never overlap, and are clipped to the
//! visible content area, so they stay right at every zoom and scroll position.

use crate::rect_math::intersection;
use crate::timeline_geometry::TimelineGeometry;
use sq_core_model::Timeline;
use sq_editor_session::TimelineTool;
use sq_uikit::keyframe_graph_geometry::Rect;

/// The cursor of a region.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TimelineCursorKind {
    /// Trim the start edge.
    TrimIn,
    /// Trim the end edge.
    TrimOut,
    /// Ripple the start edge.
    RippleIn,
    /// Ripple the end edge.
    RippleOut,
    /// Rate-stretch the start edge.
    RateIn,
    /// Rate-stretch the end edge.
    RateOut,
    /// Roll.
    Roll,
    /// Slip.
    Slip,
    /// Slide.
    Slide,
    /// Blade.
    Razor,
    /// Hand.
    Hand,
    /// Zoom.
    Zoom,
    /// Track Select Forward (A): an arrow with a bar, over the whole track area.
    TrackSelect,
    /// Selection tool with Option held over a clip body: Option-drag copies.
    Copy,
}

/// A rectangle with its cursor.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CursorRegion {
    /// Where the cursor applies.
    pub rect: Rect,
    /// The cursor.
    pub kind: TimelineCursorKind,
}

/// Cursor regions of the timeline.
pub struct TimelineCursorMap;

impl TimelineCursorMap {
    /// `content` is the visible track area in view coordinates (right of the headers, below the ruler).
    pub fn regions(
        timeline: &Timeline,
        geometry: &TimelineGeometry,
        tool: TimelineTool,
        content: &Rect,
        command: bool,
        option: bool,
    ) -> Vec<CursorRegion> {
        use TimelineCursorKind as K;
        let rows = geometry.rows(timeline);
        let mut out: Vec<CursorRegion> = Vec::new();
        if rows.is_empty() || content.width <= 0.0 || content.height <= 0.0 {
            return out;
        }
        let add = |r: Rect, kind: K, out: &mut Vec<CursorRegion>| {
            if let Some(c) = intersection(&r, content)
                && c.width >= 0.5
                && c.height >= 0.5
            {
                out.push(CursorRegion { rect: c, kind });
            }
        };
        match tool {
            TimelineTool::Razor | TimelineTool::Hand | TimelineTool::Zoom | TimelineTool::TrackSelectForward => {
                let top = rows[0].y;
                let bottom = rows[rows.len() - 1].max_y();
                let kind = match tool {
                    TimelineTool::Razor => K::Razor,
                    TimelineTool::Zoom => K::Zoom,
                    TimelineTool::TrackSelectForward => K::TrackSelect,
                    _ => K::Hand,
                };
                add(Rect::new(content.min_x(), top, content.width, bottom - top), kind, &mut out);
            }
            TimelineTool::Mask | TimelineTool::Type | TimelineTool::Position => {}
            TimelineTool::Selection
            | TimelineTool::RippleEdit
            | TimelineTool::RateStretch
            | TimelineTool::RollEdit
            | TimelineTool::Slip
            | TimelineTool::Slide => {
                for row in &rows {
                    let Some(track) = timeline.track(row.track) else { continue };
                    for clip in track.clips() {
                        let x0 = geometry.x(clip.timeline().start);
                        let x1 = geometry.x(clip.timeline().end());
                        if x1 < content.min_x() {
                            continue;
                        }
                        if x0 > content.max_x() {
                            break;
                        }
                        let w = x1 - x0;
                        if w <= 0.0 {
                            continue;
                        }
                        let slab = |a: f64, b: f64| Rect::new(a, row.y, b - a, row.height);
                        let h = TimelineGeometry::trim_handle_width(w);
                        match tool {
                            TimelineTool::Selection => {
                                // Cmd on an edge = ripple trim, Option over the body = copy drag (the cursor follows the
                                // keys while hovering).
                                add(slab(x0, x0 + h), if command { K::RippleIn } else { K::TrimIn }, &mut out);
                                add(slab(x1 - h, x1), if command { K::RippleOut } else { K::TrimOut }, &mut out);
                                if option && !command && x1 - x0 > 2.0 * h {
                                    add(slab(x0 + h, x1 - h), K::Copy, &mut out);
                                }
                            }
                            TimelineTool::RippleEdit => {
                                // The reducer picks the nearest edge even over the body.
                                add(slab(x0, (x0 + x1) / 2.0), K::RippleIn, &mut out);
                                add(slab((x0 + x1) / 2.0, x1), K::RippleOut, &mut out);
                            }
                            TimelineTool::RateStretch => {
                                add(slab(x0, (x0 + x1) / 2.0), K::RateIn, &mut out);
                                add(slab((x0 + x1) / 2.0, x1), K::RateOut, &mut out);
                            }
                            TimelineTool::RollEdit => add(slab(x0, x1), K::Roll, &mut out),
                            TimelineTool::Slip => add(slab(x0, x1), K::Slip, &mut out),
                            TimelineTool::Slide => add(slab(x0, x1), K::Slide, &mut out),
                            _ => {}
                        }
                    }
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rect_math::intersection;
    use crate::test_support::*;
    use TimelineCursorKind as K;
    use sq_core_model::{Clip, TrackKind};
    use sq_core_time::TimeRange;

    fn tl() -> Timeline {
        let c =
            Clip::new(uid(), "c", uid(), TrackKind::Video, TimeRange::new(sq_core_time::Time::ZERO, FD * 48), FD * 10);
        timeline(vec![track(TrackKind::Video, vec![c]), track(TrackKind::Audio, vec![])])
    }

    fn content() -> Rect {
        Rect::new(160.0, 22.0, 1000.0, 300.0)
    }

    fn regions(tool: TimelineTool, ppf: f64) -> Vec<CursorRegion> {
        let g = TimelineGeometry::with_points_per_frame(FD, ppf);
        TimelineCursorMap::regions(&tl(), &g, tool, &content(), false, false)
    }

    fn kinds(r: &[CursorRegion]) -> Vec<TimelineCursorKind> {
        r.iter().map(|x| x.kind).collect()
    }

    #[test]
    fn selection_shows_trim_cursors_on_both_edges() {
        let r = regions(TimelineTool::Selection, 4.0);
        assert_eq!(kinds(&r), vec![K::TrimIn, K::TrimOut]);
        assert!(r[0].rect.width == 6.0 && r[1].rect.width == 6.0);
        let g = geo4();
        assert_eq!(r[0].rect.min_x(), g.x(FD * 10));
        assert_eq!(r[1].rect.max_x(), g.x(FD * 58));
    }

    #[test]
    fn command_on_an_edge_shows_ripple_and_option_over_the_body_shows_copy() {
        let g = geo4();
        let t = tl();
        let at = |tool, command, option| TimelineCursorMap::regions(&t, &g, tool, &content(), command, option);
        assert_eq!(kinds(&at(TimelineTool::Selection, true, false)), vec![K::RippleIn, K::RippleOut]);
        let opt = at(TimelineTool::Selection, false, true);
        assert_eq!(kinds(&opt), vec![K::TrimIn, K::TrimOut, K::Copy]);
        let body = opt[2].rect;
        assert!(body.min_x() == opt[0].rect.max_x() && body.max_x() == opt[1].rect.min_x());
        assert_eq!(kinds(&at(TimelineTool::Selection, true, true)), vec![K::RippleIn, K::RippleOut]);
        assert_eq!(kinds(&at(TimelineTool::Razor, true, true)), vec![K::Razor]);
    }

    #[test]
    fn regions_agree_with_hit_test_at_many_zooms() {
        let t = tl();
        for ppf in [0.05, 0.3, 1.0, 4.0, 40.0, 300.0] {
            let g = TimelineGeometry::with_points_per_frame(FD, ppf);
            let rows = g.rows(&t);
            let y = rows[0].y + rows[0].height / 2.0;
            let regions = TimelineCursorMap::regions(&t, &g, TimelineTool::Selection, &content(), false, false);
            let mut x = 170.0;
            while x < 1100.0 {
                let p = pt(x, y);
                let kind = regions
                    .iter()
                    .find(|r| {
                        p.x >= r.rect.min_x() && p.x < r.rect.max_x() && p.y >= r.rect.min_y() && p.y < r.rect.max_y()
                    })
                    .map(|r| r.kind);
                match g.hit_test(p, &t) {
                    crate::TimelineHit::Clip(_, crate::ClipZone::Head) => {
                        assert_eq!(kind, Some(K::TrimIn), "x {x} ppf {ppf}")
                    }
                    crate::TimelineHit::Clip(_, crate::ClipZone::Tail) => {
                        assert_eq!(kind, Some(K::TrimOut), "x {x} ppf {ppf}")
                    }
                    _ => assert_eq!(kind, None, "x {x} ppf {ppf}"),
                }
                x += 1.5;
            }
        }
    }

    #[test]
    fn ripple_roll_slip_slide_razor_hand() {
        assert_eq!(kinds(&regions(TimelineTool::RippleEdit, 4.0)), vec![K::RippleIn, K::RippleOut]);
        assert_eq!(kinds(&regions(TimelineTool::RollEdit, 4.0)), vec![K::Roll]);
        assert_eq!(kinds(&regions(TimelineTool::Slip, 4.0)), vec![K::Slip]);
        assert_eq!(kinds(&regions(TimelineTool::Slide, 4.0)), vec![K::Slide]);
        assert_eq!(kinds(&regions(TimelineTool::Razor, 4.0)), vec![K::Razor]);
        assert_eq!(kinds(&regions(TimelineTool::Hand, 4.0)), vec![K::Hand]);
        assert_eq!(kinds(&regions(TimelineTool::TrackSelectForward, 4.0)), vec![K::TrackSelect]);
        assert!(regions(TimelineTool::Type, 4.0).is_empty());
    }

    #[test]
    fn regions_do_not_overlap_and_stay_inside_content() {
        let c = content();
        for tool in TimelineTool::ALL {
            let r = regions(tool, 0.5);
            for (i, a) in r.iter().enumerate() {
                assert!(a.rect.min_x() >= c.min_x() && a.rect.max_x() <= c.max_x());
                assert!(a.rect.min_y() >= c.min_y() && a.rect.max_y() <= c.max_y());
                for b in &r[i + 1..] {
                    let i = intersection(&a.rect, &b.rect);
                    assert!(i.is_none_or(|i| i.width <= 0.001 || i.height <= 0.001));
                }
            }
        }
    }

    #[test]
    fn offscreen_clips_produce_nothing() {
        let mut g = geo4();
        g.scroll_x = 5000.0;
        assert!(TimelineCursorMap::regions(&tl(), &g, TimelineTool::Selection, &content(), false, false).is_empty());
    }
}
