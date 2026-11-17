// Swift: SQColorValue.swift
//! Color value of the picker: HSB plus alpha, all 0...1. Pure; converts to sRGB and hex.

use crate::timecode::trim_blanks;

/// HSB plus alpha, each clamped to 0...1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SQColorValue {
    pub h: f64,
    pub s: f64,
    pub b: f64,
    pub a: f64,
}

impl SQColorValue {
    /// Clamps every component to 0...1.
    pub fn new(h: f64, s: f64, b: f64, a: f64) -> Self {
        let c = |v: f64| v.clamp(0.0, 1.0);
        SQColorValue { h: c(h), s: c(s), b: c(b), a: c(a) }
    }

    /// From sRGB components 0...1.
    pub fn from_rgb(r: f64, g: f64, b: f64, a: f64) -> Self {
        let mx = r.max(g).max(b);
        let mn = r.min(g).min(b);
        let d = mx - mn;
        let mut h = 0.0;
        if d > 0.0 {
            if mx == r {
                h = ((g - b) / d) % 6.0;
            } else if mx == g {
                h = (b - r) / d + 2.0;
            } else {
                h = (r - g) / d + 4.0;
            }
            h /= 6.0;
            if h < 0.0 {
                h += 1.0;
            }
        }
        Self::new(h, if mx == 0.0 { 0.0 } else { d / mx }, mx, a)
    }

    /// sRGB components 0...1.
    pub fn rgb(&self) -> (f64, f64, f64) {
        let hh = (if self.h >= 1.0 { 0.0 } else { self.h }) * 6.0;
        let i = hh as i64;
        let f = hh - i as f64;
        let b = self.b;
        let p = b * (1.0 - self.s);
        let q = b * (1.0 - self.s * f);
        let t = b * (1.0 - self.s * (1.0 - f));
        match i {
            0 => (b, t, p),
            1 => (q, b, p),
            2 => (p, b, t),
            3 => (p, q, b),
            4 => (t, p, b),
            _ => (b, p, q),
        }
    }

    /// `RRGGBB` (alpha omitted) uppercase.
    pub fn hex(&self) -> String {
        let (r, g, b) = self.rgb();
        let b8 = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as i64;
        format!("{:02X}{:02X}{:02X}", b8(r), b8(g), b8(b))
    }

    /// Parses `RGB`, `RRGGBB` or `RRGGBBAA`, with optional leading `#`. Alpha defaults to `keeping_alpha`.
    pub fn parse_hex(text: &str, keeping_alpha: f64) -> Option<SQColorValue> {
        let mut t = trim_blanks(text);
        if let Some(rest) = t.strip_prefix('#') {
            t = rest;
        }
        if ![3, 6, 8].contains(&t.chars().count()) || !t.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        let t: String = if t.len() == 3 { t.chars().flat_map(|c| [c, c]).collect() } else { t.to_string() };
        let v = u64::from_str_radix(&t, 16).ok()?;
        let has_a = t.len() == 8;
        let r = ((v >> if has_a { 24 } else { 16 }) & 0xFF) as f64 / 255.0;
        let g = ((v >> if has_a { 16 } else { 8 }) & 0xFF) as f64 / 255.0;
        let b = ((v >> if has_a { 8 } else { 0 }) & 0xFF) as f64 / 255.0;
        Some(Self::from_rgb(r, g, b, if has_a { (v & 0xFF) as f64 / 255.0 } else { keeping_alpha }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rgb_hsb_round_trip() {
        for (r, g, b) in [(1.0, 0.0, 0.0), (0.2, 0.6, 0.9), (0.5, 0.5, 0.5), (0.0, 0.0, 0.0), (1.0, 1.0, 0.1)] {
            let c = SQColorValue::from_rgb(r, g, b, 1.0).rgb();
            assert!((c.0 - r).abs() < 1e-9 && (c.1 - g).abs() < 1e-9 && (c.2 - b).abs() < 1e-9);
        }
    }

    #[test]
    fn hex_format_and_parse() {
        assert_eq!(SQColorValue::from_rgb(1.0, 0.5, 0.0, 1.0).hex(), "FF8000");
        assert_eq!(SQColorValue::parse_hex("#ff8000", 1.0).map(|c| c.hex()).as_deref(), Some("FF8000"));
        assert_eq!(SQColorValue::parse_hex("f80", 1.0).map(|c| c.hex()).as_deref(), Some("FF8800"));
        assert!(SQColorValue::parse_hex("FF800080", 1.0).map_or(0.0, |c| c.a) > 0.49);
        assert!(SQColorValue::parse_hex("12", 1.0).is_none());
        assert!(SQColorValue::parse_hex("GG0000", 1.0).is_none());
        assert_eq!(SQColorValue::parse_hex("ff0000", 0.3).map(|c| c.a), Some(0.3));
    }

    #[test]
    fn clamps_inputs() {
        let v = SQColorValue::new(2.0, -1.0, 5.0, 9.0);
        assert!(v.h == 1.0 && v.s == 0.0 && v.b == 1.0 && v.a == 1.0);
    }
}
