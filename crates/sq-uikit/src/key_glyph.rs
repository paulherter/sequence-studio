// Swift: KeyGlyph.swift
//! How a keyframe is drawn: the shape follows the easing of both sides of the key.

use crate::controls_grid::{CGPoint, CGRect};
use sq_core_time::{EaseHandle, Id, Interpolation, KeyframeTrack, KeyframeValue, Time};

/// How the curve arrives at / leaves a key (per side).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum KeyHalf {
    Linear,
    /// Ease / bezier: half hourglass (triangle pointing at the center).
    Eased,
    Hold,
    /// Hold Ahead: the next key's value from right after this key (drawn apart from Hold).
    HoldAhead,
}

/// The two halves of a key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct KeyGlyph {
    pub incoming: KeyHalf,
    pub outgoing: KeyHalf,
}

/// The glyph of one key of a track.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeyGlyphEntry {
    pub id: Id,
    pub time: Time,
    pub glyph: KeyGlyph,
}

fn is_linear(h: EaseHandle) -> bool {
    (h.dx - EaseHandle::LINEAR.dx).abs() < 1e-6 && (h.dy - EaseHandle::LINEAR.dy).abs() < 1e-6
}

impl KeyGlyph {
    /// Both sides linear.
    pub const LINEAR: KeyGlyph = KeyGlyph { incoming: KeyHalf::Linear, outgoing: KeyHalf::Linear };

    /// A glyph from its two halves.
    pub fn new(incoming: KeyHalf, outgoing: KeyHalf) -> KeyGlyph {
        KeyGlyph { incoming, outgoing }
    }

    #[doc(hidden)]
    pub fn half(interpolation: Interpolation, handle: EaseHandle) -> KeyHalf {
        match interpolation {
            Interpolation::Hold => KeyHalf::Hold,
            Interpolation::HoldAhead => KeyHalf::HoldAhead,
            Interpolation::Linear => KeyHalf::Linear,
            Interpolation::Bezier => {
                if is_linear(handle) {
                    KeyHalf::Linear
                } else {
                    KeyHalf::Eased
                }
            }
        }
    }

    /// Glyph of every key. A side without a neighboring segment (first key's left, last key's right) mirrors the other.
    pub fn glyphs<V: KeyframeValue>(track: &KeyframeTrack<V>) -> Vec<KeyGlyphEntry> {
        let keys = &track.keys;
        keys.iter()
            .enumerate()
            .map(|(i, k)| {
                // Rendering ignores `interpolation` except for hold, so the glyph reads the handles the same way:
                // a key eased on one side shows as eased whatever its neighbor's shape is.
                let out = (i + 1 < keys.len()).then(|| Self::half(k.interpolation, k.out_handle));
                let inc = (i > 0).then(|| {
                    let prev = keys[i - 1].interpolation;
                    if prev == Interpolation::HoldAhead {
                        KeyHalf::HoldAhead
                    } else if prev.is_hold() {
                        KeyHalf::Hold
                    } else if is_linear(k.in_handle) {
                        KeyHalf::Linear
                    } else {
                        KeyHalf::Eased
                    }
                });
                let glyph = KeyGlyph {
                    incoming: inc.or(out).unwrap_or(KeyHalf::Linear),
                    outgoing: out.or(inc).unwrap_or(KeyHalf::Linear),
                };
                KeyGlyphEntry { id: k.id, time: k.time, glyph }
            })
            .collect()
    }

    /// Summary glyph of several keys at one time: per side hold if all are hold, eased if any is eased, else linear.
    pub fn merged(glyphs: &[KeyGlyph]) -> KeyGlyph {
        fn side(halves: &[KeyHalf]) -> KeyHalf {
            if !halves.is_empty() && halves.iter().all(|h| *h == KeyHalf::HoldAhead) {
                return KeyHalf::HoldAhead;
            }
            if !halves.is_empty() && halves.iter().all(|h| *h == KeyHalf::Hold || *h == KeyHalf::HoldAhead) {
                return KeyHalf::Hold;
            }
            if halves.contains(&KeyHalf::Eased) { KeyHalf::Eased } else { KeyHalf::Linear }
        }
        let incoming: Vec<KeyHalf> = glyphs.iter().map(|g| g.incoming).collect();
        let outgoing: Vec<KeyHalf> = glyphs.iter().map(|g| g.outgoing).collect();
        KeyGlyph { incoming: side(&incoming), outgoing: side(&outgoing) }
    }

    /// The one solid shape a key is drawn as (hold beats easing beats linear).
    pub fn shape(&self) -> KeyShape {
        let has = |h: KeyHalf| self.incoming == h || self.outgoing == h;
        if has(KeyHalf::HoldAhead) {
            KeyShape::Ahead
        } else if has(KeyHalf::Hold) {
            KeyShape::Square
        } else if has(KeyHalf::Eased) {
            KeyShape::Circle
        } else {
            KeyShape::Diamond
        }
    }
}

/// Premiere-like key shapes, each drawn as ONE solid filled closed shape: linear = diamond, any easing = circle,
/// hold = square. No half shapes, no strokes between parts.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum KeyShape {
    Diamond,
    Circle,
    Square,
    /// Hold Ahead: a square with its right side pointed (looks ahead to the next key).
    Ahead,
}

impl KeyShape {
    /// Every shape, in legend order.
    pub const LEGEND: [KeyShape; 4] = [KeyShape::Diamond, KeyShape::Circle, KeyShape::Square, KeyShape::Ahead];

    /// Name shown in the key tooltip and the legend (shape-to-name mapping in one place).
    pub fn title(self) -> &'static str {
        match self {
            KeyShape::Diamond => "Linear",
            KeyShape::Circle => "Eased",
            KeyShape::Square => "Hold",
            KeyShape::Ahead => "Hold Ahead",
        }
    }

    /// Bounding box of the shape centered on `c`; `size` is the full width/height. The circle and square are a bit
    /// smaller than the diamond's tips so all three look the same size.
    pub fn bounds(self, c: CGPoint, size: f64) -> CGRect {
        let s = if self == KeyShape::Diamond { size } else { size * 0.82 };
        CGRect::new(c.x - s / 2.0, c.y - s / 2.0, s, s)
    }

    /// Corner points (diamond, square); empty for the circle.
    pub fn corners(self, c: CGPoint, size: f64) -> Vec<CGPoint> {
        let r = self.bounds(c, size);
        let p = CGPoint::new;
        match self {
            KeyShape::Diamond => {
                vec![p(r.mid_x(), r.min_y()), p(r.max_x(), r.mid_y()), p(r.mid_x(), r.max_y()), p(r.min_x(), r.mid_y())]
            }
            KeyShape::Ahead => vec![
                p(r.min_x(), r.min_y()),
                p(r.mid_x() + r.width * 0.15, r.min_y()),
                p(r.max_x(), r.mid_y()),
                p(r.mid_x() + r.width * 0.15, r.max_y()),
                p(r.min_x(), r.max_y()),
            ],
            KeyShape::Square => {
                vec![p(r.min_x(), r.min_y()), p(r.max_x(), r.min_y()), p(r.max_x(), r.max_y()), p(r.min_x(), r.max_y())]
            }
            KeyShape::Circle => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::keyframes_premiere::KeyInterpolationChoice;
    use sq_core_time::{EaseSide, IdSource, Keyframe, SequentialIds};
    use std::collections::{BTreeSet, HashSet};

    fn track() -> (KeyframeTrack<f64>, Vec<Id>) {
        let mut ids = SequentialIds::default();
        let ks: Vec<Keyframe<f64>> = [(0, 0.0), (2, 5.0), (4, 9.0)]
            .iter()
            .map(|&(t, v)| Keyframe::new(ids.next_id(), Time::new(t, 1), v))
            .collect();
        let order = ks.iter().map(|k| k.id).collect();
        (KeyframeTrack { keys: ks }, order)
    }

    #[test]
    fn every_shape_has_unique_name() {
        let names: HashSet<&str> = KeyShape::LEGEND.iter().map(|s| s.title()).collect();
        assert!(names.len() == KeyShape::LEGEND.len() && names.len() == 4);
        assert_eq!(KeyGlyph::LINEAR.shape().title(), "Linear");
    }

    #[test]
    fn ease_in_on_key_with_linear_neighbour_reads_as_circle() {
        let (mut tr, ids) = track();
        tr.apply(&KeyInterpolationChoice::EaseIn.curve(), &BTreeSet::from([ids[1]]), EaseSide::In);
        let g = KeyGlyph::glyphs(&tr);
        assert_eq!(g[1].glyph.incoming, KeyHalf::Eased);
        assert_eq!(g[1].glyph.shape(), KeyShape::Circle);
    }

    #[test]
    fn ease_out_shows_on_the_outgoing_side() {
        let (mut tr, ids) = track();
        tr.apply(&KeyInterpolationChoice::EaseOut.curve(), &BTreeSet::from([ids[0]]), EaseSide::Out);
        let g = KeyGlyph::glyphs(&tr);
        assert_eq!(g[0].glyph.outgoing, KeyHalf::Eased);
        assert_eq!(g[1].glyph.incoming, KeyHalf::Linear); // the neighbor's in side did not change
    }

    #[test]
    fn bezier_is_a_circle_hold_is_a_square_linear_is_a_diamond() {
        let (mut tr, ids) = track();
        let all: BTreeSet<Id> = ids.iter().copied().collect();
        tr.apply(&KeyInterpolationChoice::Bezier.curve(), &all, EaseSide::Both);
        assert!(KeyGlyph::glyphs(&tr).iter().all(|g| g.glyph.shape() == KeyShape::Circle));
        tr.apply(&KeyInterpolationChoice::Hold.curve(), &BTreeSet::from([ids[0]]), EaseSide::Out);
        assert_eq!(KeyGlyph::glyphs(&tr)[0].glyph.shape(), KeyShape::Square);
        tr.apply(&KeyInterpolationChoice::Linear.curve(), &all, EaseSide::Both);
        assert!(KeyGlyph::glyphs(&tr).iter().all(|g| g.glyph.shape() == KeyShape::Diamond));
    }

    #[test]
    fn merged_glyph_follows_hold_then_eased_then_linear() {
        let hold = KeyGlyph::new(KeyHalf::Hold, KeyHalf::HoldAhead);
        let eased = KeyGlyph::new(KeyHalf::Eased, KeyHalf::Linear);
        assert_eq!(KeyGlyph::merged(&[hold, hold]), KeyGlyph::new(KeyHalf::Hold, KeyHalf::HoldAhead));
        assert_eq!(KeyGlyph::merged(&[hold, eased]), KeyGlyph::new(KeyHalf::Eased, KeyHalf::Linear));
        assert_eq!(KeyGlyph::merged(&[]), KeyGlyph::LINEAR);
    }

    #[test]
    fn shape_bounds_and_corners() {
        let c = CGPoint::new(10.0, 10.0);
        assert_eq!(KeyShape::Diamond.bounds(c, 10.0), CGRect::new(5.0, 5.0, 10.0, 10.0));
        assert_eq!(KeyShape::Square.corners(c, 10.0).len(), 4);
        assert_eq!(KeyShape::Ahead.corners(c, 10.0).len(), 5);
        assert!(KeyShape::Circle.corners(c, 10.0).is_empty());
    }
}
