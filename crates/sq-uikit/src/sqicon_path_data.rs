//! Port of `SQUIKit/Sources/SQUIKit/SQIconPathData.swift`.
//! `SQIcon.svgSource` (the icon's SVG text from the bundle resources) is part of the g3 module `sqicon_resources`.

use crate::controls_grid::{CGPoint, CGRect};
use std::collections::HashMap;
use std::f64::consts::PI;

/// Where SVG path data goes: the canvas outline of the shared toolkit (SQDrawKit `IconOutline`). Curves stay curves
/// here; the sink flattens them if it must.
pub trait SQIconPathSink {
    fn sink_move(&mut self, p: CGPoint);
    fn sink_line(&mut self, p: CGPoint);
    fn sink_curve(&mut self, to: CGPoint, control1: CGPoint, control2: CGPoint);
    fn sink_quad(&mut self, to: CGPoint, control: CGPoint);
    fn sink_close(&mut self);
}

/// SVG path data (all commands, relative and absolute, arcs converted to cubic curves).
pub struct SQIconPathData;

struct Scanner<'a> {
    chars: &'a [u8],
    i: usize,
}

impl<'a> Scanner<'a> {
    fn new(chars: &'a [u8]) -> Scanner<'a> {
        Scanner { chars, i: 0 }
    }

    fn skip_separators(&mut self) {
        while self.i < self.chars.len() && matches!(self.chars[self.i], 32 | 44 | 10 | 9 | 13) {
            self.i += 1;
        }
    }

    fn number(&mut self) -> Option<f64> {
        self.skip_separators();
        let start = self.i;
        let mut seen_dot = false;
        let mut seen_digit = false;
        if self.i < self.chars.len() && matches!(self.chars[self.i], 43 | 45) {
            self.i += 1;
        }
        while self.i < self.chars.len() {
            let c = self.chars[self.i];
            if c.is_ascii_digit() {
                seen_digit = true;
                self.i += 1;
            } else if c == 46 && !seen_dot {
                seen_dot = true;
                self.i += 1;
            } else if (c == 101 || c == 69) && seen_digit {
                self.i += 1;
                if self.i < self.chars.len() && matches!(self.chars[self.i], 43 | 45) {
                    self.i += 1;
                }
            } else {
                break;
            }
        }
        let parsed = if seen_digit {
            std::str::from_utf8(&self.chars[start..self.i]).ok().and_then(|s| s.parse::<f64>().ok())
        } else {
            None
        };
        if parsed.is_none() {
            self.i = start;
        }
        parsed
    }

    fn flag(&mut self) -> Option<bool> {
        self.skip_separators();
        if self.i < self.chars.len() && matches!(self.chars[self.i], 48 | 49) {
            let v = self.chars[self.i] == 49;
            self.i += 1;
            return Some(v);
        }
        None
    }

    fn command(&mut self) -> Option<u8> {
        self.skip_separators();
        if self.i >= self.chars.len() {
            return None;
        }
        let c = self.chars[self.i];
        if c.is_ascii_alphabetic() {
            self.i += 1;
            return Some(c);
        }
        None
    }

    fn at_end(&mut self) -> bool {
        self.skip_separators();
        self.i >= self.chars.len()
    }
}

impl SQIconPathData {
    /// Every number of `s` (separators: space, comma, newline, tab).
    pub fn numbers(s: &str) -> Vec<f64> {
        let mut scanner = Scanner::new(s.as_bytes());
        let mut out = Vec::new();
        while let Some(v) = scanner.number() {
            out.push(v);
        }
        out
    }

    pub fn append<P: SQIconPathSink + ?Sized>(d: &str, path: &mut P) {
        let mut sc = Scanner::new(d.as_bytes());
        let mut cur = CGPoint::ZERO;
        let mut start = CGPoint::ZERO;
        let mut last_cubic: Option<CGPoint> = None;
        let mut last_quad: Option<CGPoint> = None;
        let mut cmd: u8 = 0;
        while !sc.at_end() {
            if let Some(c) = sc.command() {
                cmd = c;
            } else if cmd == 0 {
                return;
            } else if cmd == 77 {
                cmd = 76;
            } else if cmd == 109 {
                cmd = 108;
            }
            let rel = cmd >= 97;
            let upper = if rel { cmd - 32 } else { cmd };
            let ox = if rel { cur.x } else { 0.0 };
            let oy = if rel { cur.y } else { 0.0 };
            let mut new_cubic: Option<CGPoint> = None;
            let mut new_quad: Option<CGPoint> = None;
            match upper {
                77 => {
                    // M
                    let (Some(x), Some(y)) = (sc.number(), sc.number()) else { return };
                    cur = CGPoint::new(ox + x, oy + y);
                    start = cur;
                    path.sink_move(cur);
                }
                76 => {
                    // L
                    let (Some(x), Some(y)) = (sc.number(), sc.number()) else { return };
                    cur = CGPoint::new(ox + x, oy + y);
                    path.sink_line(cur);
                }
                72 => {
                    // H
                    let Some(x) = sc.number() else { return };
                    cur = CGPoint::new(ox + x, cur.y);
                    path.sink_line(cur);
                }
                86 => {
                    // V
                    let Some(y) = sc.number() else { return };
                    cur = CGPoint::new(cur.x, oy + y);
                    path.sink_line(cur);
                }
                67 => {
                    // C
                    let (Some(x1), Some(y1), Some(x2), Some(y2), Some(x), Some(y)) =
                        (sc.number(), sc.number(), sc.number(), sc.number(), sc.number(), sc.number())
                    else {
                        return;
                    };
                    let c2 = CGPoint::new(ox + x2, oy + y2);
                    path.sink_curve(CGPoint::new(ox + x, oy + y), CGPoint::new(ox + x1, oy + y1), c2);
                    cur = CGPoint::new(ox + x, oy + y);
                    new_cubic = Some(c2);
                }
                83 => {
                    // S
                    let (Some(x2), Some(y2), Some(x), Some(y)) = (sc.number(), sc.number(), sc.number(), sc.number())
                    else {
                        return;
                    };
                    let c1 = last_cubic.map_or(cur, |l| CGPoint::new(2.0 * cur.x - l.x, 2.0 * cur.y - l.y));
                    let c2 = CGPoint::new(ox + x2, oy + y2);
                    path.sink_curve(CGPoint::new(ox + x, oy + y), c1, c2);
                    cur = CGPoint::new(ox + x, oy + y);
                    new_cubic = Some(c2);
                }
                81 => {
                    // Q
                    let (Some(x1), Some(y1), Some(x), Some(y)) = (sc.number(), sc.number(), sc.number(), sc.number())
                    else {
                        return;
                    };
                    let q = CGPoint::new(ox + x1, oy + y1);
                    path.sink_quad(CGPoint::new(ox + x, oy + y), q);
                    cur = CGPoint::new(ox + x, oy + y);
                    new_quad = Some(q);
                }
                84 => {
                    // T
                    let (Some(x), Some(y)) = (sc.number(), sc.number()) else { return };
                    let q = last_quad.map_or(cur, |l| CGPoint::new(2.0 * cur.x - l.x, 2.0 * cur.y - l.y));
                    path.sink_quad(CGPoint::new(ox + x, oy + y), q);
                    cur = CGPoint::new(ox + x, oy + y);
                    new_quad = Some(q);
                }
                65 => {
                    // A
                    let (Some(rx), Some(ry), Some(rot)) = (sc.number(), sc.number(), sc.number()) else { return };
                    let (Some(large), Some(sweep)) = (sc.flag(), sc.flag()) else { return };
                    let (Some(x), Some(y)) = (sc.number(), sc.number()) else { return };
                    let end = CGPoint::new(ox + x, oy + y);
                    Self::add_arc(path, cur, end, rx, ry, rot, large, sweep);
                    cur = end;
                }
                90 => {
                    // Z
                    path.sink_close();
                    cur = start;
                }
                _ => return,
            }
            last_cubic = new_cubic;
            last_quad = new_quad;
        }
    }

    // SVG implementation notes F.6.5: endpoint to center parameterization, then cubic segments of at most 90 degrees.
    #[allow(clippy::too_many_arguments)]
    fn add_arc<P: SQIconPathSink + ?Sized>(
        path: &mut P,
        p0: CGPoint,
        p1: CGPoint,
        rx_in: f64,
        ry_in: f64,
        rotation: f64,
        large: bool,
        sweep: bool,
    ) {
        let mut rx = rx_in.abs();
        let mut ry = ry_in.abs();
        if p0 == p1 {
            return;
        }
        if rx == 0.0 || ry == 0.0 {
            path.sink_line(p1);
            return;
        }
        let phi = rotation * PI / 180.0;
        let (cos_p, sin_p) = (phi.cos(), phi.sin());
        let dx = (p0.x - p1.x) / 2.0;
        let dy = (p0.y - p1.y) / 2.0;
        let x1p = cos_p * dx + sin_p * dy;
        let y1p = -sin_p * dx + cos_p * dy;
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
        if lambda > 1.0 {
            let s = lambda.sqrt();
            rx *= s;
            ry *= s;
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
        let mut coef = if den == 0.0 { 0.0 } else { (num / den).max(0.0).sqrt() };
        if large == sweep {
            coef = -coef;
        }
        let cxp = coef * rx * y1p / ry;
        let cyp = -coef * ry * x1p / rx;
        let cx = cos_p * cxp - sin_p * cyp + (p0.x + p1.x) / 2.0;
        let cy = sin_p * cxp + cos_p * cyp + (p0.y + p1.y) / 2.0;
        let angle = |ux: f64, uy: f64, vx: f64, vy: f64| (ux * vy - uy * vx).atan2(ux * vx + uy * vy);
        let theta1 = angle(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry);
        let mut delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
        if !sweep && delta > 0.0 {
            delta -= 2.0 * PI;
        }
        if sweep && delta < 0.0 {
            delta += 2.0 * PI;
        }
        let segments = ((delta.abs() / (PI / 2.0) - 1e-9).ceil() as i64).max(1);
        let step = delta / segments as f64;
        let t = 4.0 / 3.0 * (step / 4.0).tan();
        let mut a = theta1;
        for _ in 0..segments {
            let b = a + step;
            let (cos_a, sin_a, cos_b, sin_b) = (a.cos(), a.sin(), b.cos(), b.sin());
            let map = |ex: f64, ey: f64| {
                CGPoint::new(cx + cos_p * rx * ex - sin_p * ry * ey, cy + sin_p * rx * ex + cos_p * ry * ey)
            };
            path.sink_curve(
                map(cos_b, sin_b),
                map(cos_a - t * sin_a, sin_a + t * cos_a),
                map(cos_b + t * sin_b, sin_b - t * cos_b),
            );
            a = b;
        }
    }
}

pub struct SQIconWeight;

impl SQIconWeight {
    /// Thinnest icon line in points (device-pixel friendly on 2x).
    pub const MIN_LINE: f64 = 1.0;
}

/// The SVG elements of an icon file into a path sink, without an XML parser. Same element set and meaning as the Mac
/// parser: path, circle, ellipse, rect (rx/ry), line, polyline, polygon. Returns, per element, whether it is filled and/or
/// stroked.
pub struct SQIconSVG;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SQIconShape {
    pub fill: bool,
    pub stroke: bool,
}

/// The root `<svg>` of an icon file: width of its grid (viewBox) and, for stroked drawings, the line width in grid units.
#[derive(Clone, Debug, PartialEq)]
pub struct SQIconDocument {
    pub grid: f64,
    pub line_width: f64,
    pub fill: String,
    pub stroke: String,
}

impl Default for SQIconDocument {
    fn default() -> SQIconDocument {
        SQIconDocument { grid: 24.0, line_width: 1.0, fill: "black".to_string(), stroke: "none".to_string() }
    }
}

/// One tag of an SVG file: its name and attributes.
pub type SQIconElement = (String, HashMap<String, String>);

impl SQIconSVG {
    pub fn document(svg: &str) -> SQIconDocument {
        let mut d = SQIconDocument::default();
        let elements = Self::elements(svg);
        let Some((_, a)) = elements.iter().find(|e| e.0 == "svg") else { return d };
        let box_ = SQIconPathData::numbers(a.get("viewBox").map_or("", String::as_str));
        if box_.len() == 4 && box_[2] > 0.0 {
            d.grid = box_[2];
        }
        d.line_width = a.get("stroke-width").and_then(|s| s.parse::<f64>().ok()).unwrap_or(1.0);
        d.fill = a.get("fill").cloned().unwrap_or_else(|| "black".to_string());
        d.stroke = a.get("stroke").cloned().unwrap_or_else(|| "none".to_string());
        d
    }

    /// Elements in document order: name and attributes. Only self-contained tags matter for the icon files.
    pub fn elements(svg: &str) -> Vec<SQIconElement> {
        let mut out: Vec<SQIconElement> = Vec::new();
        let mut rest = svg;
        while let Some(open) = rest.find('<') {
            let Some(close_rel) = rest[open..].find('>') else { break };
            let close = open + close_rel;
            let tag = &rest[open + 1..close];
            rest = &rest[close + 1..];
            if !tag.chars().next().is_some_and(char::is_alphabetic) {
                continue;
            }
            let name: String = tag.chars().take_while(|c| c.is_alphabetic() || *c == '-').collect();
            let mut attrs: HashMap<String, String> = HashMap::new();
            let mut s = &tag[name.len()..];
            while let Some(eq) = s.find('=') {
                let key = s[..eq].trim().to_string();
                s = s[eq + 1..].trim_start_matches(' ');
                let Some(q) = s.chars().next().filter(|c| *c == '"' || *c == '\'') else { break };
                s = &s[1..];
                let Some(end) = s.find(q) else { break };
                attrs.insert(key, s[..end].to_string());
                s = &s[end + 1..];
            }
            out.push((name, attrs));
        }
        out
    }

    /// Feeds every drawable element of `svg` into a fresh sink from `make` and reports it with its paint flags.
    pub fn shapes<P: SQIconPathSink>(svg: &str, mut make: impl FnMut() -> P) -> Vec<(P, SQIconShape)> {
        let mut out: Vec<(P, SQIconShape)> = Vec::new();
        let doc = Self::document(svg);
        for (name, a) in Self::elements(svg) {
            let num = |k: &str| a.get(k).and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0);
            let mut p = make();
            match name.as_str() {
                "path" => SQIconPathData::append(a.get("d").map_or("", String::as_str), &mut p),
                "circle" => Self::ellipse(&mut p, num("cx"), num("cy"), num("r"), num("r")),
                "ellipse" => Self::ellipse(&mut p, num("cx"), num("cy"), num("rx"), num("ry")),
                "rect" => {
                    let mut rx = a.get("rx").and_then(|s| s.parse::<f64>().ok());
                    let mut ry = a.get("ry").and_then(|s| s.parse::<f64>().ok());
                    if rx.is_none() {
                        rx = ry;
                    }
                    if ry.is_none() {
                        ry = rx;
                    }
                    Self::rect(
                        &mut p,
                        CGRect::new(num("x"), num("y"), num("width"), num("height")),
                        rx.unwrap_or(0.0),
                        ry.unwrap_or(0.0),
                    );
                }
                "line" => {
                    p.sink_move(CGPoint::new(num("x1"), num("y1")));
                    p.sink_line(CGPoint::new(num("x2"), num("y2")));
                }
                "polyline" | "polygon" => {
                    let v = SQIconPathData::numbers(a.get("points").map_or("", String::as_str));
                    let mut i = 0;
                    while i + 1 < v.len() {
                        let q = CGPoint::new(v[i], v[i + 1]);
                        if i == 0 {
                            p.sink_move(q);
                        } else {
                            p.sink_line(q);
                        }
                        i += 2;
                    }
                    if name == "polygon" {
                        p.sink_close();
                    }
                }
                _ => continue,
            }
            let fill = a.get("fill").unwrap_or(&doc.fill) != "none";
            let stroke = a.get("stroke").unwrap_or(&doc.stroke) != "none";
            out.push((p, SQIconShape { fill, stroke }));
        }
        out
    }

    /// Four quarter arcs as cubics (what `CGPath.addEllipse` emits).
    fn ellipse<P: SQIconPathSink + ?Sized>(p: &mut P, cx: f64, cy: f64, rx: f64, ry: f64) {
        let k = 0.5522847498;
        p.sink_move(CGPoint::new(cx + rx, cy));
        p.sink_curve(CGPoint::new(cx, cy + ry), CGPoint::new(cx + rx, cy + k * ry), CGPoint::new(cx + k * rx, cy + ry));
        p.sink_curve(CGPoint::new(cx - rx, cy), CGPoint::new(cx - k * rx, cy + ry), CGPoint::new(cx - rx, cy + k * ry));
        p.sink_curve(CGPoint::new(cx, cy - ry), CGPoint::new(cx - rx, cy - k * ry), CGPoint::new(cx - k * rx, cy - ry));
        p.sink_curve(CGPoint::new(cx + rx, cy), CGPoint::new(cx + k * rx, cy - ry), CGPoint::new(cx + rx, cy - k * ry));
        p.sink_close();
    }

    /// A rect with corner radii clamped to half the sides (what `CGPath.addRoundedRect` draws).
    fn rect<P: SQIconPathSink + ?Sized>(p: &mut P, r: CGRect, rx_in: f64, ry_in: f64) {
        let rx = rx_in.min(r.width / 2.0);
        let ry = ry_in.min(r.height / 2.0);
        if !(rx > 0.0 && ry > 0.0) {
            p.sink_move(CGPoint::new(r.min_x(), r.min_y()));
            p.sink_line(CGPoint::new(r.max_x(), r.min_y()));
            p.sink_line(CGPoint::new(r.max_x(), r.max_y()));
            p.sink_line(CGPoint::new(r.min_x(), r.max_y()));
            p.sink_close();
            return;
        }
        let k = 0.5522847498;
        p.sink_move(CGPoint::new(r.min_x() + rx, r.min_y()));
        p.sink_line(CGPoint::new(r.max_x() - rx, r.min_y()));
        p.sink_curve(
            CGPoint::new(r.max_x(), r.min_y() + ry),
            CGPoint::new(r.max_x() - rx + k * rx, r.min_y()),
            CGPoint::new(r.max_x(), r.min_y() + ry - k * ry),
        );
        p.sink_line(CGPoint::new(r.max_x(), r.max_y() - ry));
        p.sink_curve(
            CGPoint::new(r.max_x() - rx, r.max_y()),
            CGPoint::new(r.max_x(), r.max_y() - ry + k * ry),
            CGPoint::new(r.max_x() - rx + k * rx, r.max_y()),
        );
        p.sink_line(CGPoint::new(r.min_x() + rx, r.max_y()));
        p.sink_curve(
            CGPoint::new(r.min_x(), r.max_y() - ry),
            CGPoint::new(r.min_x() + rx - k * rx, r.max_y()),
            CGPoint::new(r.min_x(), r.max_y() - ry + k * ry),
        );
        p.sink_line(CGPoint::new(r.min_x(), r.min_y() + ry));
        p.sink_curve(
            CGPoint::new(r.min_x() + rx, r.min_y()),
            CGPoint::new(r.min_x(), r.min_y() + ry - k * ry),
            CGPoint::new(r.min_x() + rx - k * rx, r.min_y()),
        );
        p.sink_close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, PartialEq)]
    enum Op {
        Move(f64, f64),
        Line(f64, f64),
        Curve([f64; 6]),
        Quad([f64; 4]),
        Close,
    }

    #[derive(Default)]
    struct Rec(Vec<Op>);

    impl SQIconPathSink for Rec {
        fn sink_move(&mut self, p: CGPoint) {
            self.0.push(Op::Move(p.x, p.y));
        }
        fn sink_line(&mut self, p: CGPoint) {
            self.0.push(Op::Line(p.x, p.y));
        }
        fn sink_curve(&mut self, to: CGPoint, c1: CGPoint, c2: CGPoint) {
            self.0.push(Op::Curve([to.x, to.y, c1.x, c1.y, c2.x, c2.y]));
        }
        fn sink_quad(&mut self, to: CGPoint, c: CGPoint) {
            self.0.push(Op::Quad([to.x, to.y, c.x, c.y]));
        }
        fn sink_close(&mut self) {
            self.0.push(Op::Close);
        }
    }

    fn ops(d: &str) -> Vec<Op> {
        let mut r = Rec::default();
        SQIconPathData::append(d, &mut r);
        r.0
    }

    #[test]
    fn numbers_split_on_separators_signs_and_dots() {
        assert_eq!(SQIconPathData::numbers("1,2 -3.5.5 1e2 +4"), vec![1.0, 2.0, -3.5, 0.5, 100.0, 4.0]);
        assert!(SQIconPathData::numbers("abc").is_empty());
    }

    #[test]
    fn lines_relative_commands_and_implicit_lineto() {
        assert_eq!(
            ops("M1 2 3 4 h2 v-1 z"),
            vec![Op::Move(1.0, 2.0), Op::Line(3.0, 4.0), Op::Line(5.0, 4.0), Op::Line(5.0, 3.0), Op::Close]
        );
        assert_eq!(ops("m1 1 l2 2"), vec![Op::Move(1.0, 1.0), Op::Line(3.0, 3.0)]);
    }

    #[test]
    fn smooth_curves_reflect_the_previous_control_point() {
        let o = ops("M0 0 C1 1 2 1 3 0 S5 -1 6 0");
        assert_eq!(o[2], Op::Curve([6.0, 0.0, 4.0, -1.0, 5.0, -1.0]));
        let q = ops("M0 0 Q1 1 2 0 T4 0");
        assert_eq!(q[2], Op::Quad([4.0, 0.0, 3.0, -1.0]));
    }

    #[test]
    fn a_quarter_arc_is_one_cubic() {
        let o = ops("M0 0 A1 1 0 0 1 1 1");
        let Op::Curve(c) = o[1] else { panic!("expected a curve") };
        let k = 4.0 / 3.0 * (PI / 8.0).tan();
        let want = [1.0, 1.0, k, 0.0, 1.0, 1.0 - k];
        for (g, w) in c.iter().zip(want) {
            assert!((g - w).abs() < 1e-9, "{c:?}");
        }
        assert_eq!(o.len(), 2);
        // A half circle needs two segments; a zero radius is a line; the same point draws nothing.
        assert_eq!(ops("M0 0 A1 1 0 0 1 2 0").len(), 3);
        assert_eq!(ops("M0 0 A0 1 0 0 1 2 0")[1], Op::Line(2.0, 0.0));
        assert_eq!(ops("M0 0 A1 1 0 0 1 0 0").len(), 1);
    }

    #[test]
    fn bad_input_stops_the_path() {
        assert_eq!(ops("M1 2 L3"), vec![Op::Move(1.0, 2.0)]);
        assert!(ops("5 5").is_empty());
        assert_eq!(ops("M1 2 X3 4"), vec![Op::Move(1.0, 2.0)]);
    }

    #[test]
    fn svg_document_and_elements() {
        let svg = r#"<?xml version="1.0"?><svg viewBox="0 0 256 256" fill='none' stroke="currentColor" stroke-width="16">
            <path d="M1 1L2 2"/><circle cx="4" cy="4" r="2" fill="red"/><!-- c --><g></g></svg>"#;
        let d = SQIconSVG::document(svg);
        assert_eq!((d.grid, d.line_width, d.fill.as_str(), d.stroke.as_str()), (256.0, 16.0, "none", "currentColor"));
        let names: Vec<String> = SQIconSVG::elements(svg).into_iter().map(|e| e.0).collect();
        assert_eq!(names, ["svg", "path", "circle", "g"]);
        assert_eq!(SQIconSVG::document("<svg/>"), SQIconDocument { fill: "black".into(), ..SQIconDocument::default() });
    }

    #[test]
    fn shapes_report_paint_flags_per_element() {
        let svg = r#"<svg viewBox="0 0 24 24" fill="none" stroke="black"><rect x="0" y="0" width="4" height="4" rx="1"/><line x1="0" y1="0" x2="1" y2="1" stroke="none" fill="red"/><polygon points="0,0 1,0 1,1"/><title>x</title></svg>"#;
        let shapes = SQIconSVG::shapes(svg, Rec::default);
        assert_eq!(shapes.len(), 3);
        assert_eq!(shapes[0].1, SQIconShape { fill: false, stroke: true });
        assert_eq!(shapes[1].1, SQIconShape { fill: true, stroke: false });
        assert_eq!(shapes[2].0.0, vec![Op::Move(0.0, 0.0), Op::Line(1.0, 0.0), Op::Line(1.0, 1.0), Op::Close]);
        // Rounded rect: 4 lines (incl. start), 4 corners, close.
        assert_eq!(shapes[0].0.0.len(), 10);
    }

    #[test]
    fn rect_without_radius_is_four_lines_and_a_circle_is_four_curves() {
        let mut r = Rec::default();
        SQIconSVG::rect(&mut r, CGRect::new(1.0, 2.0, 3.0, 4.0), 0.0, 0.0);
        assert_eq!(r.0.len(), 5);
        let mut c = Rec::default();
        SQIconSVG::ellipse(&mut c, 0.0, 0.0, 2.0, 2.0);
        assert_eq!(c.0.iter().filter(|o| matches!(o, Op::Curve(_))).count(), 4);
    }
}
