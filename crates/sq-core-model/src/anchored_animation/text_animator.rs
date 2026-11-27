// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextAnimatorModel.swift (the saved type `TextAnimator` and its enums; unit timing and per-unit states: graphics crate)

use super::SegmentShape;
use serde::{Deserialize, Serialize};
use sq_core_time::Time;

/// What one animator step moves: a grapheme (whitespace excluded), a whitespace-separated word, or a laid-out line.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TextAnimatorUnit {
    /// One grapheme.
    Character,
    /// One word.
    Word,
    /// One line.
    Line,
}

/// What the animator does to a unit.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TextAnimatorEffect {
    /// Opacity.
    Fade,
    /// Scale pop.
    Pop,
    /// Slide in from a direction.
    Slide,
    /// Units appear one by one.
    Typewriter,
    /// Blur resolves.
    Blur,
    /// Loop: units wave.
    Wave,
    /// Loop: units pulse.
    Pulse,
}

impl TextAnimatorEffect {
    /// Wave and pulse repeat inside one unit's window.
    pub fn is_loop(self) -> bool {
        matches!(self, TextAnimatorEffect::Wave | TextAnimatorEffect::Pulse)
    }
}

/// In which order the units play.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TextAnimatorOrder {
    /// First to last.
    Forward,
    /// Last to first.
    Reverse,
    /// From the middle outwards.
    Center,
}

/// Where a slide comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TextSlideDirection {
    /// From above.
    Up,
    /// From below.
    Down,
    /// From the left.
    Left,
    /// From the right.
    Right,
}

/// The blinking cursor of a typewriter animator: a glyph right after the last revealed character. It stays solid while the
/// text is typed, blinks afterwards and goes `hold_after` after the last character appeared.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextCursor {
    /// The glyph drawn (one character), `|` by default.
    pub glyph: String,
    /// Length of one on or off half of the blink.
    pub blink: Time,
    /// `#rrggbb`; `None` = the text's own color.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// How long the cursor stays after the last character appeared.
    pub hold_after: Time,
}

impl TextCursor {
    /// Default glyph.
    pub const GLYPH: &'static str = "|";

    /// `|`, 530 ms blink, text color, held 600 ms.
    pub fn standard() -> TextCursor {
        TextCursor { glyph: Self::GLYPH.into(), blink: Time::new(53, 100), color: None, hold_after: Time::new(3, 5) }
    }

    /// The color as 0...1 RGB; `None` for the text's own color or a malformed value.
    pub fn rgb(&self) -> Option<[f64; 3]> {
        let h = self.color.as_deref()?.strip_prefix('#')?;
        if h.len() != 6 || !h.is_ascii() {
            return None;
        }
        let c = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).ok().map(|v| f64::from(v) / 255.0);
        Some([c(0)?, c(2)?, c(4)?])
    }
}

/// In/out animation that plays per character, word or line with a stagger between the units. Rides on a
/// `KeyframeTemplate`, so it travels wherever a template does.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "TextAnimatorWire")]
pub struct TextAnimator {
    /// What it does.
    pub effect: TextAnimatorEffect,
    /// What it moves.
    pub unit: TextAnimatorUnit,
    /// Play order.
    pub order: TextAnimatorOrder,
    /// Easing of one unit's animation.
    pub easing: SegmentShape,
    /// Length of one unit's animation.
    pub duration: Time,
    /// Delay between two consecutive units (by rank).
    pub stagger: Time,
    /// Slide distance in sequence pixels.
    pub distance: f64,
    /// Slide direction.
    pub direction: TextSlideDirection,
    /// Start blur of the blur effect, sequence pixels.
    pub blur_radius: f64,
    /// Cycles of a loop effect (wave, pulse) inside one unit's window; the window is `duration * loops`. 1 for the rest.
    #[serde(skip_serializing_if = "is_one")]
    pub loops: i64,
    /// Pop: the peak scale (1.08 = 108 %). `None` keeps the peak of the easing curve (the panel's look).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub overshoot: Option<f64>,
    /// Typewriter only: the blinking cursor. Dropped when the effect changes to another one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<TextCursor>,
}

fn is_one(v: &i64) -> bool {
    *v == 1
}

/// The coded shape: everything but effect, unit, duration and stagger has a default, then the values are clamped.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TextAnimatorWire {
    effect: TextAnimatorEffect,
    unit: TextAnimatorUnit,
    #[serde(default = "forward")]
    order: TextAnimatorOrder,
    #[serde(default = "ease_out")]
    easing: SegmentShape,
    duration: Time,
    stagger: Time,
    #[serde(default = "forty")]
    distance: f64,
    #[serde(default = "up")]
    direction: TextSlideDirection,
    #[serde(default = "twelve")]
    blur_radius: f64,
    #[serde(default = "one")]
    loops: i64,
    #[serde(default)]
    overshoot: Option<f64>,
    #[serde(default)]
    cursor: Option<TextCursor>,
}

fn forward() -> TextAnimatorOrder {
    TextAnimatorOrder::Forward
}
fn ease_out() -> SegmentShape {
    SegmentShape::EaseOut
}
fn forty() -> f64 {
    40.0
}
fn up() -> TextSlideDirection {
    TextSlideDirection::Up
}
fn twelve() -> f64 {
    12.0
}
fn one() -> i64 {
    1
}

impl From<TextAnimatorWire> for TextAnimator {
    fn from(w: TextAnimatorWire) -> TextAnimator {
        TextAnimator {
            effect: w.effect,
            unit: w.unit,
            order: w.order,
            easing: w.easing,
            duration: TextAnimator::sanitized(w.duration),
            stagger: TextAnimator::sanitized(w.stagger),
            distance: w.distance,
            direction: w.direction,
            blur_radius: w.blur_radius.max(0.0),
            loops: w.loops.clamp(1, 50),
            overshoot: w.overshoot.filter(|v| v.is_finite()).map(|v| v.clamp(1.0, 3.0)),
            cursor: w.cursor.filter(|_| w.effect == TextAnimatorEffect::Typewriter).map(|c| TextCursor {
                glyph: if c.glyph.is_empty() { TextCursor::GLYPH.into() } else { c.glyph },
                blink: TextAnimator::sanitized(c.blink).max(Time::new(1, 100)),
                hold_after: TextAnimator::sanitized(c.hold_after),
                ..c
            }),
        }
    }
}

impl TextAnimator {
    /// Upper bound of `duration` and `stagger` (also applied when decoding): 60 s.
    pub const MAX_TIME: Time = Time::new(60, 1);

    /// An animator with the Swift defaults (forward, ease out, 40 px up, blur 12 px, one loop); the values are clamped like
    /// the Swift initializer does.
    pub fn new(effect: TextAnimatorEffect, unit: TextAnimatorUnit, duration: Time, stagger: Time) -> TextAnimator {
        TextAnimatorWire {
            effect,
            unit,
            order: forward(),
            easing: ease_out(),
            duration,
            stagger,
            distance: forty(),
            direction: up(),
            blur_radius: twelve(),
            loops: 1,
            overshoot: None,
            cursor: None,
        }
        .into()
    }

    /// Clamps to 0...`MAX_TIME`; a timescale above 1 MHz (unreduced, pathological fractions) is moved to the nearest
    /// microsecond, so `rank * stagger` and sums with clip times stay far from i64 overflow. Normal timescales stay exact.
    pub fn sanitized(t: Time) -> Time {
        if t <= Time::ZERO {
            return Time::ZERO;
        }
        if t >= Self::MAX_TIME {
            return Self::MAX_TIME;
        }
        if t.timescale() <= 1_000_000 {
            return t;
        }
        let (value, scale) = (i128::from(t.value()), i128::from(t.timescale()));
        let us = (value * 2_000_000 + scale) / (scale * 2);
        Time::new(us as i64, 1_000_000)
    }
}

impl TextAnimator {
    /// Default stagger by unit: letters follow each other fast, lines slowly.
    pub fn default_stagger(unit: TextAnimatorUnit) -> Time {
        match unit {
            TextAnimatorUnit::Character => Time::new(3, 100),
            TextAnimatorUnit::Word => Time::new(2, 25),
            TextAnimatorUnit::Line => Time::new(3, 20),
        }
    }

    /// What a new animator starts as (the Text panel's Effect row): by word, 300 ms per unit, 80 ms stagger.
    pub fn starting(effect: TextAnimatorEffect) -> TextAnimator {
        let mut a = TextAnimator::new(
            effect,
            TextAnimatorUnit::Word,
            Time::new(3, 10),
            Self::default_stagger(TextAnimatorUnit::Word),
        );
        a.set_effect(effect);
        a
    }

    /// Changes the effect; pop gets the overshoot easing, leaving pop drops it again.
    pub fn set_effect(&mut self, effect: TextAnimatorEffect) {
        if effect == TextAnimatorEffect::Pop {
            self.easing = SegmentShape::Overshoot;
        } else if self.easing == SegmentShape::Overshoot {
            self.easing = SegmentShape::EaseOut;
        }
        if effect != TextAnimatorEffect::Typewriter {
            self.cursor = None;
        }
        self.effect = effect;
    }

    /// Changes the unit; an untouched stagger follows the unit.
    pub fn set_unit(&mut self, unit: TextAnimatorUnit) {
        if self.unit == unit {
            return;
        }
        if self.stagger == Self::default_stagger(self.unit) {
            self.stagger = Self::default_stagger(unit);
        }
        self.unit = unit;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn missing_keys_take_the_swift_defaults_and_loops_one_is_not_written() {
        let a: TextAnimator = serde_json::from_value(json!({
            "effect": "fade", "unit": "word",
            "duration": {"value": 1, "timescale": 2}, "stagger": {"value": 1, "timescale": 10}
        }))
        .unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(
            (a.order, a.easing, a.direction),
            (TextAnimatorOrder::Forward, SegmentShape::EaseOut, TextSlideDirection::Up)
        );
        assert_eq!((a.distance, a.blur_radius, a.loops), (40.0, 12.0, 1));
        let back = serde_json::to_value(&a).unwrap_or_default();
        assert!(back.get("loops").is_none());
        assert_eq!(back["effect"], "fade");
        assert_eq!(serde_json::from_value::<TextAnimator>(back).ok(), Some(a));
    }

    #[test]
    fn decoding_clamps_times_blur_and_loops() {
        let a: TextAnimator = serde_json::from_value(json!({
            "effect": "wave", "unit": "character", "blurRadius": -3, "loops": 99,
            "duration": {"value": 500, "timescale": 1}, "stagger": {"value": -1, "timescale": 10}
        }))
        .unwrap_or_else(|e| panic!("{e}"));
        assert_eq!((a.duration, a.stagger), (TextAnimator::MAX_TIME, Time::ZERO));
        assert_eq!((a.blur_radius, a.loops), (0.0, 50));
        assert!(a.effect.is_loop() && !TextAnimatorEffect::Slide.is_loop());
        assert_eq!(serde_json::to_value(&a).unwrap_or_default()["loops"], 50);
    }

    #[test]
    fn starting_animators_and_unit_changes_follow_the_panel_rules() {
        let mut a = TextAnimator::starting(TextAnimatorEffect::Pop);
        assert_eq!(
            (a.unit, a.duration, a.stagger, a.easing),
            (TextAnimatorUnit::Word, Time::new(3, 10), Time::new(2, 25), SegmentShape::Overshoot)
        );
        a.set_effect(TextAnimatorEffect::Fade);
        assert_eq!(a.easing, SegmentShape::EaseOut);
        a.set_unit(TextAnimatorUnit::Line);
        assert_eq!(a.stagger, Time::new(3, 20));
        a.stagger = Time::new(1, 10);
        a.set_unit(TextAnimatorUnit::Character);
        assert_eq!(a.stagger, Time::new(1, 10));
    }

    #[test]
    fn a_cursor_belongs_to_the_typewriter_and_round_trips() {
        let mut a = TextAnimator::starting(TextAnimatorEffect::Typewriter);
        a.cursor = Some(TextCursor { color: Some("#ff8000".into()), ..TextCursor::standard() });
        let back: TextAnimator =
            serde_json::from_value(serde_json::to_value(&a).unwrap_or_default()).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(back, a);
        assert_eq!(a.cursor.as_ref().and_then(TextCursor::rgb).map(|c| (c[0], c[2])), Some((1.0, 0.0)));
        a.set_effect(TextAnimatorEffect::Fade);
        assert!(a.cursor.is_none());
        assert!(serde_json::to_value(&a).unwrap_or_default().get("cursor").is_none());
    }

    #[test]
    fn a_huge_timescale_moves_to_the_nearest_microsecond() {
        assert_eq!(TextAnimator::sanitized(Time::new(1, 3_000_000)), Time::new(0, 1_000_000));
        assert_eq!(TextAnimator::sanitized(Time::new(2_999_999, 4_000_000)), Time::new(750_000, 1_000_000));
        assert_eq!(TextAnimator::sanitized(Time::new(1, 30)), Time::new(1, 30));
        let n = TextAnimator::new(TextAnimatorEffect::Pop, TextAnimatorUnit::Line, Time::new(1, 4), Time::new(1, 8));
        assert_eq!((n.distance, n.loops, n.order), (40.0, 1, TextAnimatorOrder::Forward));
    }
}
