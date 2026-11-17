// Swift: ScopeGraticule.swift
//! Pure graticule geometry in unit plot coordinates: origin top-left, y down, (0,0)...(1,1) = the plot rect.
//! Matches the GPU texture mappings documented on `ScopeCounts` (sq-render).

/// Which scope the view shows (picker order).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScopeKind {
    /// Luma waveform.
    Waveform,
    /// RGB parade.
    Parade,
    /// Vectorscope.
    Vectorscope,
    /// Histogram.
    Histogram,
}

impl ScopeKind {
    /// Every scope, in picker order.
    pub const ALL: [ScopeKind; 4] =
        [ScopeKind::Waveform, ScopeKind::Parade, ScopeKind::Vectorscope, ScopeKind::Histogram];

    /// The raw value of the picker order.
    pub fn raw_value(self) -> i64 {
        match self {
            ScopeKind::Waveform => 0,
            ScopeKind::Parade => 1,
            ScopeKind::Vectorscope => 2,
            ScopeKind::Histogram => 3,
        }
    }

    /// Picker title.
    pub fn title(self) -> &'static str {
        match self {
            ScopeKind::Waveform => "Waveform",
            ScopeKind::Parade => "Parade",
            ScopeKind::Vectorscope => "Vectorscope",
            ScopeKind::Histogram => "Histogram",
        }
    }
}

/// One IRE graticule line.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct IreLine {
    /// The level in IRE.
    pub ire: i64,
    /// Plot y: 0 IRE = bottom (1), 100 IRE = top (0).
    pub y: f64,
}

impl IreLine {
    /// Every 50 IRE.
    pub fn is_major(&self) -> bool {
        self.ire % 50 == 0
    }
}

/// A vectorscope graticule target.
#[derive(Clone, Debug, PartialEq)]
pub struct Target {
    /// Label.
    pub name: &'static str,
    /// R'G'B' of the bar.
    pub rgb: [f64; 3],
    /// Unit plot coordinates.
    pub center: [f64; 2],
}

/// A rectangle in the plot's view (`ScopeGraticule.Rect`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GraticuleRect {
    /// Left.
    pub x: f64,
    /// Top.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

/// Graticule geometry.
pub enum ScopeGraticule {}

impl ScopeGraticule {
    /// Skin-tone line: hue angle from +Cb counter-clockwise.
    pub const SKIN_TONE_ANGLE_DEGREES: f64 = 123.0;
    /// Vertical guides of the histogram (fractions of the plot width).
    pub const HISTOGRAM_VERTICALS: [f64; 5] = [0.0, 0.25, 0.5, 0.75, 1.0];

    /// 0, 10 ... 100 IRE. 0 IRE = bottom (y 1), 100 IRE = top (y 0).
    pub fn ire_lines() -> Vec<IreLine> {
        (0..=10).map(|i| IreLine { ire: i * 10, y: 1.0 - (i * 10) as f64 / 100.0 }).collect()
    }

    /// Vectorscope unit coords of a BT.709 full-range R'G'B' signal: Cb -> x, Cr -> y up; the circle (radius 0.5) spans Cb/Cr +-0.5.
    pub fn vectorscope_point(r: f64, g: f64, b: f64) -> [f64; 2] {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        [0.5 + (b - y) / 1.8556, 0.5 - (r - y) / 1.5748]
    }

    /// Graticule targets R, Mg, B, Cy, G, Yl at the given bar amplitude (0.75 or 1).
    pub fn vectorscope_targets(a: f64) -> Vec<Target> {
        let defs: [(&'static str, f64, f64, f64); 6] = [
            ("R", 1.0, 0.0, 0.0),
            ("Mg", 1.0, 0.0, 1.0),
            ("B", 0.0, 0.0, 1.0),
            ("Cy", 0.0, 1.0, 1.0),
            ("G", 0.0, 1.0, 0.0),
            ("Yl", 1.0, 1.0, 0.0),
        ];
        defs.iter()
            .map(|d| {
                let rgb = [d.1 * a, d.2 * a, d.3 * a];
                Target { name: d.0, rgb, center: Self::vectorscope_point(rgb[0], rgb[1], rgb[2]) }
            })
            .collect()
    }

    /// End of the skin-tone line on the circle (it starts at the center).
    pub fn skin_tone_line_end() -> [f64; 2] {
        let a = Self::SKIN_TONE_ANGLE_DEGREES * std::f64::consts::PI / 180.0;
        [0.5 + 0.5 * a.cos(), 0.5 - 0.5 * a.sin()]
    }

    /// Plot rect inside a view of `size` (width, height). Waveforms/parade keep a left margin for IRE labels; the vectorscope is the largest centered square.
    pub fn plot_rect(kind: ScopeKind, size: (f64, f64), label_margin: f64) -> GraticuleRect {
        match kind {
            ScopeKind::Waveform | ScopeKind::Parade => {
                GraticuleRect { x: label_margin, y: 0.0, width: (size.0 - label_margin).max(0.0), height: size.1 }
            }
            ScopeKind::Vectorscope => {
                let s = size.0.min(size.1).max(0.0);
                GraticuleRect { x: (size.0 - s) / 2.0, y: (size.1 - s) / 2.0, width: s, height: s }
            }
            ScopeKind::Histogram => GraticuleRect { x: 0.0, y: 0.0, width: size.0, height: size.1 },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ire_lines() {
        let l = ScopeGraticule::ire_lines();
        assert_eq!(l.iter().map(|x| x.ire).collect::<Vec<_>>(), (0..=10).map(|i| i * 10).collect::<Vec<_>>());
        assert!(l[0].y == 1.0 && l[10].y == 0.0);
        assert!((l[5].y - 0.5).abs() < 1e-12);
        assert_eq!(l.iter().filter(|x| x.is_major()).map(|x| x.ire).collect::<Vec<_>>(), vec![0, 50, 100]);
    }

    #[test]
    fn vectorscope_targets_match_bt709() {
        let t = ScopeGraticule::vectorscope_targets(0.75);
        assert_eq!(t.iter().map(|x| x.name).collect::<Vec<_>>(), vec!["R", "Mg", "B", "Cy", "G", "Yl"]);
        // 100% red: Cr = +0.5 (straight up), Cb = -0.2126/1.8556.
        let r = &ScopeGraticule::vectorscope_targets(1.0)[0];
        assert!((r.center[1] - 0.0).abs() < 1e-9);
        assert!((r.center[0] - (0.5 - 0.2126 / 1.8556)).abs() < 1e-9);
        // 75 % is three quarters of the way from the center.
        assert!(((0.5 - t[0].center[1]) - 0.75 * 0.5).abs() < 1e-9);
        // Blue is right of center, Yellow is left of center.
        assert!(t[2].center[0] > 0.5 && t[5].center[0] < 0.5);
    }

    #[test]
    fn skin_tone_line() {
        assert_eq!(ScopeGraticule::SKIN_TONE_ANGLE_DEGREES, 123.0);
        let e = ScopeGraticule::skin_tone_line_end();
        assert!(e[0] < 0.5 && e[1] < 0.5);
        assert!((((e[0] - 0.5) * (e[0] - 0.5) + (e[1] - 0.5) * (e[1] - 0.5)).sqrt() - 0.5).abs() < 1e-9);
        let angle = |p: [f64; 2]| (0.5 - p[1]).atan2(p[0] - 0.5) * 180.0 / std::f64::consts::PI;
        let t = ScopeGraticule::vectorscope_targets(1.0);
        assert!(angle(t[0].center) < 123.0 && angle(t[5].center) > 123.0);
    }

    #[test]
    fn plot_rects() {
        let v = ScopeGraticule::plot_rect(ScopeKind::Vectorscope, (300.0, 200.0), 28.0);
        assert!(v.width == v.height && v.height == 200.0 && v.x == 50.0);
        let w = ScopeGraticule::plot_rect(ScopeKind::Waveform, (300.0, 200.0), 28.0);
        assert!(w.x == 28.0 && w.width == 272.0 && w.height == 200.0);
        let h = ScopeGraticule::plot_rect(ScopeKind::Histogram, (300.0, 200.0), 28.0);
        assert!(h.x == 0.0 && h.width == 300.0);
    }

    #[test]
    fn histogram_verticals() {
        assert_eq!(ScopeGraticule::HISTOGRAM_VERTICALS, [0.0, 0.25, 0.5, 0.75, 1.0]);
    }
}
