// Swift: MonitorPanel+Overlays.swift
//! SafeMarginsView translated to the canvas: aspect frame, platform zone and its UI mock, the 90 % / 80 % margins and
//! the center cross, rulers and guides. The canvas has no even-odd fill or dashes: the dimmed band is four rects around
//! the clear one and the dashed edge is drawn as segments.

use crate::cg::RectExt;
use crate::monitor_panel::MonitorPanel;
use sq_core_edit::platform_uimock::PlatformUIMockKind;
use sq_draw::Color;
use sq_draw::canvas::Canvas;
use sq_draw::monitor::monitor_guides::{Axis, MonitorGuides};
use sq_draw::monitor::monitor_modes::MonitorMode;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqicon::SQIcon;

/// The guide a press picked up: its axis and index.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct GuideAxisDrag {
    pub axis: Axis,
    pub index: usize,
}

/// What a press at a point grabs: an existing guide (move it) or a ruler strip (pull a new guide out).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum GuideTarget {
    Guide(Axis, usize),
    NewVertical,
    NewHorizontal,
}

/// `outer` minus `inner` (the even-odd band) as up to four rects.
pub(crate) fn fill_band(c: &mut Canvas, o: CGRect, inner: CGRect, color: Color) {
    let Some(i) = inner.intersection(&o) else {
        c.fill(o, color);
        return;
    };
    c.fill(CGRect::new(o.min_x(), o.min_y(), o.width, i.min_y() - o.min_y()), color);
    c.fill(CGRect::new(o.min_x(), i.max_y(), o.width, o.max_y() - i.max_y()), color);
    c.fill(CGRect::new(o.min_x(), i.min_y(), i.min_x() - o.min_x(), i.height), color);
    c.fill(CGRect::new(i.max_x(), i.min_y(), o.max_x() - i.max_x(), i.height), color);
}

/// A 1 pt rect outline dashed `dash` on, `gap` off (`setLineDash([4, 3])`).
pub(crate) fn dashed_rect(c: &mut Canvas, r: CGRect, dash: f64, gap: f64, color: Color) {
    let mut run = |a: CGPoint, b: CGPoint| {
        let len = (b.x - a.x).hypot(b.y - a.y);
        if len <= 0.0 {
            return;
        }
        let ux = (b.x - a.x) / len;
        let uy = (b.y - a.y) / len;
        let mut s = 0.0;
        while s < len {
            let e = (s + dash).min(len);
            c.stroke_line(
                CGPoint::new(a.x + ux * s, a.y + uy * s),
                CGPoint::new(a.x + ux * e, a.y + uy * e),
                1.0,
                color,
            );
            s = e + gap;
        }
    };
    run(CGPoint::new(r.min_x(), r.min_y()), CGPoint::new(r.max_x(), r.min_y()));
    run(CGPoint::new(r.max_x(), r.min_y()), CGPoint::new(r.max_x(), r.max_y()));
    run(CGPoint::new(r.max_x(), r.max_y()), CGPoint::new(r.min_x(), r.max_y()));
    run(CGPoint::new(r.min_x(), r.max_y()), CGPoint::new(r.min_x(), r.min_y()));
}

impl MonitorPanel {
    pub(crate) const RULER_THICKNESS: f64 = 14.0;
    pub(crate) const GUIDE_GRAB: f64 = 4.0;

    pub(crate) fn draw_overlays(&self, c: &mut Canvas, r: CGRect) {
        if r.width <= 4.0 {
            return;
        }
        let t = self.theme;
        if let Some(f) = self.model.aspect_frame().rect(r) {
            // Dim the picture outside the frame so the crop reads at a glance; the frame edge is a thin guide line.
            fill_band(c, r, f, t.guide().with_alpha(0.18));
            c.stroke_rounded(f, 0.0, 1.0, t.guide());
        }
        if self.model.mode == MonitorMode::Program
            && self.model.safe_zone() != crate::safe_zone_choice::SafeZoneChoice::Off
            && let Some(z) = self.platform_zone
        {
            // Dim what the platform's own buttons, name and caption cover; the clear rectangle is where content stays visible.
            let safe = CGRect::new(
                r.min_x() + z.x * r.width,
                r.min_y() + z.y * r.height,
                z.width * r.width,
                z.height * r.height,
            );
            fill_band(c, r, safe, t.guide().with_alpha(0.18));
            dashed_rect(c, safe, 4.0, 3.0, t.guide());
            self.draw_mock(c, r);
        }
        if self.model.safe_margins() {
            for k in self.model.safe_margin_sizes().fractions() {
                let w = r.width * k;
                let h = r.height * k;
                c.stroke_rounded(CGRect::new(r.mid_x() - w / 2.0, r.mid_y() - h / 2.0, w, h), 0.0, 1.0, t.guide());
            }
            c.stroke_line(
                CGPoint::new(r.mid_x() - 8.0, r.mid_y()),
                CGPoint::new(r.mid_x() + 8.0, r.mid_y()),
                1.0,
                t.guide(),
            );
            c.stroke_line(
                CGPoint::new(r.mid_x(), r.mid_y() - 8.0),
                CGPoint::new(r.mid_x(), r.mid_y() + 8.0),
                1.0,
                t.guide(),
            );
        }
        self.draw_guides(c, r);
    }

    pub(crate) fn draw_guides(&self, c: &mut Canvas, r: CGRect) {
        let t = self.theme;
        if self.model.shows_rulers() {
            let th = Self::RULER_THICKNESS;
            let field = t.well().with_alpha(0.85);
            c.fill(CGRect::new(r.min_x(), r.min_y(), r.width, th), field);
            c.fill(CGRect::new(r.min_x(), r.min_y() + th, th, r.height - th), field);
            let steps = (1.0 / MonitorGuides::MINOR_STEP).round() as i64;
            for i in 0..=steps {
                let f = i as f64 * MonitorGuides::MINOR_STEP;
                let major = i % 2 == 0;
                let len = if major { th * 0.6 } else { th * 0.3 };
                let x = (r.min_x() + f * r.width).round();
                let y = (r.min_y() + f * r.height).round();
                c.fill(CGRect::new(x, r.min_y() + th - len, 1.0, len), t.label3());
                if i > 0 {
                    c.fill(CGRect::new(r.min_x() + th - len, y, len, 1.0), t.label3());
                }
                if major && i > 0 && i < steps {
                    c.draw_text(
                        &format!("{}", (f * 100.0).round() as i64),
                        CGPoint::new(x + 2.0, r.min_y()),
                        10.0,
                        t.label3(),
                        f64::INFINITY,
                        0,
                    );
                }
            }
        }
        for v in self.model.guides.vertical() {
            c.fill(CGRect::new((r.min_x() + v * r.width).round(), r.min_y(), 1.0, r.height), t.accent());
        }
        for h in self.model.guides.horizontal() {
            c.fill(CGRect::new(r.min_x(), (r.min_y() + h * r.height).round(), r.width, 1.0), t.accent());
        }
    }

    fn mock_glyph(kind: PlatformUIMockKind) -> Option<SQIcon> {
        match kind {
            PlatformUIMockKind::Avatar => Some(SQIcon::User),
            PlatformUIMockKind::Like => Some(SQIcon::Heart),
            PlatformUIMockKind::Comment => Some(SQIcon::Discord),
            PlatformUIMockKind::Share => Some(SQIcon::Share),
            PlatformUIMockKind::Save => Some(SQIcon::BookmarkFilled),
            _ => None,
        }
    }

    /// Light placeholder shapes of the platform's own UI; geometry from `PlatformUIMock`, color from one token.
    fn draw_mock(&self, c: &mut Canvas, r: CGRect) {
        if !self.model.shows_platform_mock() {
            return;
        }
        let ink = self.theme.platform_mock();
        for e in &self.platform_mock {
            let box_ = CGRect::new(
                r.min_x() + e.rect.x * r.width,
                r.min_y() + e.rect.y * r.height,
                e.rect.width * r.width,
                e.rect.height * r.height,
            );
            if e.is_round_button() {
                c.fill_ellipse(box_, ink.with_alpha(0.22));
                if let Some(name) = Self::mock_glyph(e.kind) {
                    let s = box_.width * 0.42;
                    c.draw_icon(name, CGPoint::new(box_.mid_x() - s / 2.0, box_.mid_y() - s / 2.0), s, ink, None);
                }
            } else if e.kind == PlatformUIMockKind::ProgressBar {
                c.fill(box_, ink.with_alpha(0.5));
            } else {
                c.fill_rounded(
                    box_,
                    box_.height / 2.0,
                    ink.with_alpha(if e.kind == PlatformUIMockKind::AccountName { 0.55 } else { 0.32 }),
                );
            }
        }
    }

    // MARK: Guides (SafeMarginsView's mouse handling)

    pub(crate) fn guide_target(&self, p: CGPoint) -> Option<GuideTarget> {
        let r = self.canvas_rect;
        if !(r.width > 4.0
            && !self.model.overlays_hidden()
            && (self.model.shows_rulers() || !self.model.guides.is_empty()))
        {
            return None;
        }
        let g = &self.model.guides;
        if r.inset_by(-Self::GUIDE_GRAB, -Self::GUIDE_GRAB).contains(p) {
            for (i, f) in g.vertical().iter().enumerate() {
                if (p.x - (r.min_x() + f * r.width)).abs() <= Self::GUIDE_GRAB {
                    return Some(GuideTarget::Guide(Axis::Vertical, i));
                }
            }
            for (i, f) in g.horizontal().iter().enumerate() {
                if (p.y - (r.min_y() + f * r.height)).abs() <= Self::GUIDE_GRAB {
                    return Some(GuideTarget::Guide(Axis::Horizontal, i));
                }
            }
        }
        if !self.model.shows_rulers() {
            return None;
        }
        let t = Self::RULER_THICKNESS;
        if CGRect::new(r.min_x(), r.min_y(), r.width, t).contains(p) {
            return Some(GuideTarget::NewHorizontal);
        }
        if CGRect::new(r.min_x(), r.min_y(), t, r.height).contains(p) {
            return Some(GuideTarget::NewVertical);
        }
        None
    }

    pub(crate) fn begin_guide_drag(&mut self, p: CGPoint) {
        let Some(target) = self.guide_target(p) else { return };
        self.active_guide = Some(match target {
            GuideTarget::Guide(axis, index) => GuideAxisDrag { axis, index },
            GuideTarget::NewVertical => {
                let f = self.guide_axis_fraction(Axis::Vertical, p);
                GuideAxisDrag { axis: Axis::Vertical, index: self.model.guides.add(Axis::Vertical, f) }
            }
            GuideTarget::NewHorizontal => {
                let f = self.guide_axis_fraction(Axis::Horizontal, p);
                GuideAxisDrag { axis: Axis::Horizontal, index: self.model.guides.add(Axis::Horizontal, f) }
            }
        });
    }

    pub(crate) fn drag_guide(&mut self, p: CGPoint) {
        let Some(g) = self.active_guide else { return };
        let f = self.guide_axis_fraction(g.axis, p);
        self.model.guides.move_guide(g.axis, g.index, f);
    }

    pub(crate) fn end_guide_drag(&mut self, p: CGPoint) {
        let Some(g) = self.active_guide.take() else { return };
        let r = self.canvas_rect;
        let f = self.guide_axis_fraction(g.axis, p);
        // Dropped back into the ruler or outside the picture: the guide is gone.
        let t = Self::RULER_THICKNESS / (if g.axis == Axis::Vertical { r.width } else { r.height }).max(1.0);
        if f < t * 0.5 || f > 1.02 || !r.inset_by(-40.0, -40.0).contains(p) {
            self.model.guides.remove(g.axis, g.index);
        }
    }
}
