// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: PRContainer.swift. The container reader (zip, gzip, fast XML, object table) lives in `sq-prproj-reader`; this
//! module adds the tick conversion, the safe number read and the node lookups the document reader and mapper use.

use sq_core_time::Time;
pub use sq_prproj_reader::{ImportError, Node, ObjectTable};

/// Premiere time unit: 254 016 000 000 ticks per second.
pub struct PRTicks;

impl PRTicks {
    /// Ticks per second.
    pub const PER_SECOND: i64 = 254_016_000_000;
    /// Ticks per 1/240000 s: every frame rate in use (24, 25, 30, 29.97, 59.94...) and 48 kHz are whole multiples of it,
    /// and Time sums stay far from i64 overflow (a raw 254016000000 timescale would not).
    const QUANTUM: i64 = Self::PER_SECOND / 240_000;
    /// Largest tick magnitude read as time (about 200 days); anything beyond is clamped.
    const MAX_TICKS: i64 = i64::MAX / 2;

    /// Ticks as rational time, rounded to 1/240000 s (exact for every common frame and sample rate).
    pub fn time(ticks: i64) -> Time {
        // Ticks of a corrupt file can be anything: clamp so the rounding below and later Time sums never overflow.
        let t = ticks.clamp(-Self::MAX_TICKS, Self::MAX_TICKS);
        let q =
            if t >= 0 { (t + Self::QUANTUM / 2) / Self::QUANTUM } else { -((-t + Self::QUANTUM / 2) / Self::QUANTUM) };
        Time::new(q, 240_000)
    }

    /// `a - b` that saturates instead of trapping.
    pub fn sub(a: i64, b: i64) -> i64 {
        match a.overflowing_sub(b) {
            (_, true) => {
                if a < 0 {
                    i64::MIN + 1
                } else {
                    i64::MAX
                }
            }
            (r, false) => r,
        }
    }

    /// Exact frame duration (8475667200 ticks = 1001/30000 s).
    pub fn frame_duration(ticks_per_frame: i64) -> Time {
        Time::new(ticks_per_frame, Self::PER_SECOND)
    }
}

/// `d` as an integer when it is finite and within +-1e15; `None` for NaN, infinity and anything larger.
pub fn safe_int(d: Option<f64>) -> Option<i64> {
    let d = d?;
    if d.is_finite() && d.abs() <= 1e15 { Some(d as i64) } else { None }
}

/// The lookups of Swift's `PRNode` that `sq-prproj-reader::Node` does not have.
pub trait NodeExt {
    /// Every child called like the last part of `path`, below the first-child chain of the earlier parts.
    fn children_at(&self, path: &str) -> Vec<&Node>;
    /// Text of the node at `path`.
    fn text_at(&self, path: &str) -> Option<&str>;
    /// Integer value of the node at `path`.
    fn int_at(&self, path: &str) -> Option<i64>;
    /// Depth-first search for the first descendant called `name`.
    fn descendant(&self, name: &str) -> Option<&Node>;
}

impl NodeExt for Node {
    fn children_at(&self, path: &str) -> Vec<&Node> {
        let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
        let Some((last, init)) = parts.split_last() else { return Vec::new() };
        let mut n = self;
        for part in init {
            match n.children.iter().find(|c| c.name == *part) {
                Some(c) => n = c,
                None => return Vec::new(),
            }
        }
        n.children.iter().filter(|c| c.name == *last).collect()
    }

    fn text_at(&self, path: &str) -> Option<&str> {
        self.child(path).map(|n| n.text.as_str())
    }

    fn int_at(&self, path: &str) -> Option<i64> {
        self.text_at(path).and_then(|t| t.parse().ok())
    }

    fn descendant(&self, name: &str) -> Option<&Node> {
        for c in &self.children {
            if c.name == name {
                return Some(c);
            }
            if let Some(d) = c.descendant(name) {
                return Some(d);
            }
        }
        None
    }
}

/// `Data(base64Encoded:options: .ignoreUnknownCharacters)`: characters outside the base64 alphabet are skipped.
pub(crate) fn decode_base64_lenient(s: &str) -> Option<Vec<u8>> {
    let clean: String = s.chars().filter(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '/' | '=')).collect();
    sq_core_time::base64::decode(&clean)
}

/// Little-endian UTF-16 code units of `b` (a trailing odd byte is ignored).
pub(crate) fn utf16le_units(b: &[u8]) -> Vec<u16> {
    b.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect()
}

/// Every top-level object called `name`.
pub fn all_named<'a>(table: &'a ObjectTable, name: &str) -> Vec<&'a Node> {
    table.root.children.iter().filter(|c| c.name == name).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ticks_round_to_the_quantum() {
        assert_eq!(PRTicks::time(PRTicks::PER_SECOND), Time::new(1, 1));
        assert_eq!(PRTicks::time(-PRTicks::PER_SECOND / 2), Time::new(-1, 2));
        assert_eq!(PRTicks::time(i64::MAX), PRTicks::time(i64::MAX / 2));
    }

    #[test]
    fn subtraction_saturates() {
        assert_eq!(PRTicks::sub(i64::MIN, 1), i64::MIN + 1);
        assert_eq!(PRTicks::sub(i64::MAX, -1), i64::MAX);
        assert_eq!(PRTicks::sub(5, 3), 2);
    }

    #[test]
    fn safe_int_rejects_non_finite_and_huge() {
        assert_eq!(safe_int(Some(12.9)), Some(12));
        assert_eq!(safe_int(Some(f64::NAN)), None);
        assert_eq!(safe_int(Some(2e15)), None);
        assert_eq!(safe_int(None), None);
    }
}
