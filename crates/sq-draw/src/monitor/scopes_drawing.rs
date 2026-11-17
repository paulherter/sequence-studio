// Swift: ScopesDrawing.swift
//! The Scopes panel (Mac SQMonitorUI `ScopesView`, `ScopeOverlayView`) translated to the portable canvas: the same box
//! layout and the same graticule drawing.
//! shortcut: `ScopeImage` (the CPU form of the Mac's `ScopeRenderer` fragment shader: counts to the picture of one scope)
//! is not ported; it reads `ScopeCounts`, which lives in sq-render, and sq-draw must not depend on sq-render.
//! Port it where both are visible (the monitor panel crate).

use super::scope_graticule::{ScopeGraticule, ScopeKind};
use crate::canvas::Canvas;
use crate::draw_list::Color;
use crate::theme::DrawTheme;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};

/// Layout of the Scopes panel (design board Panels "Scopes"): body inset 12 at the sides and 10 above and below, 8
/// between a popup and its scope and between two scopes; the first scope box is 170 high when two are shown.
pub enum ScopeBoxLayout {}

impl ScopeBoxLayout {
    /// Theme.Spacing.md
    pub const SIDE: f64 = 12.0;
    /// Theme.Spacing.sm (design: popup row padding-top 8)
    pub const TOP: f64 = 8.0;
    /// Theme.Spacing.sm
    pub const GAP: f64 = 8.0;
    /// Height of the first box when two scopes show.
    pub const FIRST_BOX: f64 = 170.0;
    /// The least height a second scope is worth showing at.
    pub const MIN_SECOND_BOX: f64 = 120.0;
    /// Board: the vectorscope disc is 190 across and its gamut ring sits at 46 % of that (92 % of the disc).
    pub const VECTOR_DISC: f64 = 190.0;
    /// The ring's share of the disc.
    pub const VECTOR_RING: f64 = 0.92;
    /// Color page row (version 9): 2 pt between the scopes, each under a caption.
    pub const ROW_GAP: f64 = 2.0;

    /// The dark disc around a vectorscope ring `p`.
    pub fn vector_disc_of_ring(p: CGRect) -> CGRect {
        p.inset_by(-p.width * (1.0 / Self::VECTOR_RING - 1.0) / 2.0, -p.height * (1.0 / Self::VECTOR_RING - 1.0) / 2.0)
    }

    /// Board label positions inside the disc: R top-center, Mg right, B bottom-right, Cy bottom-left, G left, Yl top-left.
    pub fn vector_label_origins(
        d: CGRect,
        text_height: f64,
        width_of: impl Fn(&str) -> f64,
    ) -> Vec<(&'static str, CGPoint)> {
        vec![
            ("R", CGPoint { x: d.min_x() + d.width * 0.5, y: d.min_y() + 12.0 }),
            ("Mg", CGPoint { x: d.max_x() - 16.0 - width_of("Mg"), y: d.min_y() + d.height * 0.44 }),
            ("B", CGPoint { x: d.max_x() - 50.0 - width_of("B"), y: d.max_y() - 14.0 - text_height }),
            ("Cy", CGPoint { x: d.min_x() + 40.0, y: d.max_y() - 16.0 - text_height }),
            ("G", CGPoint { x: d.min_x() + 14.0, y: d.min_y() + d.height * 0.5 }),
            ("Yl", CGPoint { x: d.min_x() + 40.0, y: d.min_y() + 22.0 }),
        ]
    }

    /// The caption of a scope.
    pub fn caption(k: ScopeKind) -> &'static str {
        match k {
            ScopeKind::Waveform => "Waveform",
            ScopeKind::Parade => "RGB parade",
            ScopeKind::Vectorscope => "Vectorscope",
            ScopeKind::Histogram => "Histogram",
        }
    }

    /// The popup titles: the scope and what it measures.
    pub fn title(k: ScopeKind) -> &'static str {
        match k {
            ScopeKind::Waveform => "Waveform \u{00B7} Luma",
            ScopeKind::Parade => "Parade \u{00B7} RGB",
            ScopeKind::Vectorscope => "Vectorscope",
            ScopeKind::Histogram => "Histogram",
        }
    }

    /// The plot inside a scope box of `size`: waveform leaves 26 at the left for its labels, the histogram 16 below;
    /// the vectorscope is the largest centered circle with room for its labels.
    pub fn plot(k: ScopeKind, size: CGSize) -> CGRect {
        let (w, h) = (size.width, size.height);
        match k {
            ScopeKind::Waveform => CGRect::new(26.0, 8.0, (w - 32.0).max(0.0), (h - 16.0).max(0.0)),
            ScopeKind::Parade => CGRect::new(6.0, 8.0, (w - 12.0).max(0.0), (h - 16.0).max(0.0)),
            ScopeKind::Histogram => CGRect::new(6.0, 6.0, (w - 12.0).max(0.0), (h - 22.0).max(0.0)),
            ScopeKind::Vectorscope => {
                let d = Self::VECTOR_DISC.min(w).min(h).max(0.0) * Self::VECTOR_RING;
                CGRect::new(((w - d) / 2.0).round(), ((h - d) / 2.0).round(), d, d)
            }
        }
    }

    /// Whether a second scope fits under the first in a panel `height` high with popups `popup` high.
    pub fn shows_two(height: f64, popup: f64) -> bool {
        height >= 2.0 * Self::TOP + 2.0 * popup + 3.0 * Self::GAP + Self::FIRST_BOX + Self::MIN_SECOND_BOX
    }
}

/// The graticule over a scope box (ScopeOverlayView.draw): IRE lines and labels, parade dividers, the vectorscope disc,
/// rings, cross, skin tone line and color labels, the histogram verticals and axis labels.
pub enum ScopeOverlay {}

impl ScopeOverlay {
    /// Draws the graticule of `kind` into `box_`.
    pub fn draw(c: &mut Canvas, kind: ScopeKind, box_: CGRect, t: &DrawTheme) {
        let bounds = CGSize::new(box_.width, box_.height);
        let mut p = ScopeBoxLayout::plot(kind, bounds);
        p.x += box_.min_x();
        p.y += box_.min_y();
        let pt = |x: f64, y: f64| CGPoint { x: p.min_x() + x * p.width, y: p.min_y() + y * p.height };
        let line = Color::WHITE.with_alpha(0.075);
        let major = Color::WHITE.with_alpha(0.12);
        let font = 10.0; // Theme.Typography.caption
        let text_h = c.size_of("R", font, 0).height;
        match kind {
            ScopeKind::Waveform | ScopeKind::Parade => {
                for ire in [100, 75, 50, 25, 0] {
                    let y = pt(0.0, 1.0 - ire as f64 / 100.0).y;
                    c.fill(CGRect::new(p.min_x(), (y - 0.5).max(p.min_y()).min(p.max_y() - 1.0), p.width, 1.0), line);
                    if kind != ScopeKind::Waveform {
                        continue;
                    }
                    // Board label tops: 4 pt from the top, 27 %, 48 %, 70 % of the box, 4 pt from the bottom.
                    let top = match ire {
                        100 => 4.0,
                        75 => bounds.height * 0.27,
                        50 => bounds.height * 0.48,
                        25 => bounds.height * 0.70,
                        _ => bounds.height - 4.0 - text_h,
                    };
                    c.draw_text(
                        &ire.to_string(),
                        CGPoint { x: box_.min_x() + 6.0, y: box_.min_y() + top },
                        font,
                        t.label3(),
                        f64::INFINITY,
                        0,
                    );
                }
                if kind == ScopeKind::Parade {
                    for i in 1..=2 {
                        c.fill(CGRect::new(p.min_x() + p.width * i as f64 / 3.0 - 0.5, p.min_y(), 1.0, p.height), line);
                    }
                }
            }
            ScopeKind::Vectorscope => {
                // Board: a dark disc, the gamut ring at 46 % of its diameter, an inner ring at 23 %, the cross, labels only.
                let disc = ScopeBoxLayout::vector_disc_of_ring(p);
                c.fill_ellipse(disc, Color::hex(0x0A0A0A, 1.0)); // Theme.Colors.scopeBox
                c.stroke_ellipse(p.inset_by(0.5, 0.5), 1.0, major);
                c.stroke_ellipse(
                    CGRect::new(p.mid_x() - p.width / 4.0, p.mid_y() - p.height / 4.0, p.width / 2.0, p.height / 2.0),
                    1.0,
                    major,
                );
                let e = ScopeGraticule::skin_tone_line_end();
                c.stroke_line(pt(0.5, 0.5), pt(e[0], e[1]), 2.0, t.label3());
                let labels = ScopeBoxLayout::vector_label_origins(disc, text_h.ceil(), |s| c.size_of(s, font, 0).width);
                for (name, origin) in labels {
                    c.draw_text(name, origin, font, t.label3(), f64::INFINITY, 0);
                }
            }
            ScopeKind::Histogram => {
                for v in ScopeGraticule::HISTOGRAM_VERTICALS {
                    let x = pt(v, 0.0).x;
                    c.fill(
                        CGRect::new((x - 0.5).max(p.min_x()).min(p.max_x() - 1.0), p.min_y(), 1.0, p.height),
                        if v == 0.0 || v == 1.0 { major } else { line },
                    );
                }
                for (v, label) in [(0.0, "0"), (0.5, "50"), (1.0, "100")] {
                    let size = c.size_of(label, font, 0);
                    let x = pt(v, 0.0).x;
                    c.draw_text(
                        label,
                        CGPoint {
                            x: (x - size.width / 2.0).max(p.min_x()).min(p.max_x() - size.width),
                            y: p.max_y() + ((box_.max_y() - p.max_y() - size.height) / 2.0).round(),
                        },
                        font,
                        t.label3(),
                        f64::INFINITY,
                        0,
                    );
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn box_layout_matches_mac_board() {
        let s = CGSize::new(300.0, 170.0);
        assert_eq!(ScopeBoxLayout::plot(ScopeKind::Waveform, s), CGRect::new(26.0, 8.0, 268.0, 154.0));
        assert_eq!(ScopeBoxLayout::plot(ScopeKind::Histogram, s), CGRect::new(6.0, 6.0, 288.0, 148.0));
        let v = ScopeBoxLayout::plot(ScopeKind::Vectorscope, s);
        assert!((v.width - 170.0 * 0.92).abs() < 0.001 && v.mid_x().round() == 150.0);
        assert!(ScopeBoxLayout::shows_two(378.0, 22.0));
        assert!(!ScopeBoxLayout::shows_two(300.0, 22.0));
    }

    #[test]
    fn overlay_draws_every_kind() {
        for k in ScopeKind::ALL {
            let mut c = Canvas::with_size(300.0, 200.0, None, 1.0);
            ScopeOverlay::draw(&mut c, k, CGRect::new(0.0, 0.0, 300.0, 200.0), &DrawTheme::default());
            assert!(!c.list.quads().is_empty(), "{k:?}");
        }
    }
}
