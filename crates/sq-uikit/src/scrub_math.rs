// Swift: ScrubMath.swift
//! Pure math behind `ScrubField`: drag delta to value, clamping, grid rounding, text parsing and formatting.

use sq_core_model::trim_spaces;

use sq_core_time::text::graphemes;

use std::ops::RangeInclusive;

/// Tracks one burst of arrow-key steps so a run of presses (auto-repeat included) is one gesture, hence one undo step.
/// `step()` is true when the press opens a new burst, `end()` is true when it closed an open one.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct StepBurst {
    is_open: bool,
}

impl StepBurst {
    /// Idle time after which a burst ends without a key-up (seconds).
    pub const IDLE: f64 = 0.5;

    /// A closed burst.
    pub fn new() -> StepBurst {
        StepBurst::default()
    }

    /// Whether a burst is open.
    pub fn is_open(&self) -> bool {
        self.is_open
    }

    /// A key press: true when it opens a new burst.
    pub fn step(&mut self) -> bool {
        let opened = !self.is_open;
        self.is_open = true;
        opened
    }

    /// The end of the burst: true when it closed an open one.
    pub fn end(&mut self) -> bool {
        let was_open = self.is_open;
        self.is_open = false;
        was_open
    }
}

/// Pure math behind `ScrubField`.
pub enum ScrubMath {}

impl ScrubMath {
    /// Shift = coarse x10, Option = fine x0.1, both cancel out.
    pub fn multiplier(shift: bool, option: bool) -> f64 {
        match (shift, option) {
            (true, false) => 10.0,
            (false, true) => 0.1,
            _ => 1.0,
        }
    }

    /// `v` limited to `range`; a non-finite `v` becomes 0 limited to `range`.
    pub fn clamp(v: f64, range: &RangeInclusive<f64>) -> f64 {
        let (lo, hi) = (*range.start(), *range.end());
        if !v.is_finite() {
            return f64::min(f64::max(0.0, lo), hi);
        }
        f64::min(f64::max(v, lo), hi)
    }

    /// Removes binary noise (0.30000000000000004 -> 0.3) relative to a grid size.
    fn clean(v: f64, grid: f64) -> f64 {
        if !(grid > 0.0 && v.is_finite()) {
            return v;
        }
        let decimals = ((-grid.log10()).ceil() as i64).saturating_add(2).clamp(0, 10);
        let f = 10.0_f64.powf(decimals as f64);
        (v * f).round() / f
    }

    /// `start + round(deltaPixels) * step * multiplier`, clamped. Fractional pixel deltas (trackpad)
    /// snap to whole steps of the effective grid; an off-grid start stays stable at delta 0.
    pub fn value(
        start: f64,
        delta_pixels: f64,
        step: f64,
        shift: bool,
        option: bool,
        range: &RangeInclusive<f64>,
    ) -> f64 {
        let grid = step * Self::multiplier(shift, option);
        if !(grid > 0.0 && delta_pixels.is_finite()) {
            return Self::clamp(start, range);
        }
        let result = start + delta_pixels.round() * grid;
        Self::clean(Self::clamp(result, range), grid)
    }

    /// One arrow-key step (direction +1 / -1) with the same modifiers.
    pub fn stepped(v: f64, direction: i64, step: f64, shift: bool, option: bool, range: &RangeInclusive<f64>) -> f64 {
        Self::value(v, direction as f64, step, shift, option, range)
    }

    /// Double-click reset: the clamped default, or `None` when there is none or the value is already there (no undo step).
    pub fn reset_target(current: f64, default: Option<f64>, range: &RangeInclusive<f64>) -> Option<f64> {
        let d = default?;
        let v = Self::clamp(d, range);
        if v == current { None } else { Some(v) }
    }

    // Scroll wheel (DECISIONS 2026-10-03 "Interaction rules": only with Option held, so panels still scroll)

    /// The wheel changes the value only with Option held while the field is hovered or focused.
    pub fn wheel_accepts(option: bool, hovered: bool, focused: bool) -> bool {
        option && (hovered || focused)
    }

    /// Option is the gate, so the wheel's own modifiers are Shift = coarse x10, Command = fine x0.1.
    pub fn wheel_multiplier(shift: bool, command: bool) -> f64 {
        match (shift, command) {
            (true, false) => 10.0,
            (false, true) => 0.1,
            _ => 1.0,
        }
    }

    /// `v + notches * step * wheelMultiplier`, clamped and grid-cleaned.
    pub fn wheel_value(
        v: f64,
        notches: i64,
        step: f64,
        shift: bool,
        command: bool,
        range: &RangeInclusive<f64>,
    ) -> f64 {
        let grid = step * Self::wheel_multiplier(shift, command);
        if grid.is_nan() || grid <= 0.0 {
            return Self::clamp(v, range);
        }
        Self::clean(Self::clamp(v + notches as f64 * grid, range), grid)
    }

    /// The scroll delta that counts: vertical, or horizontal when a mouse wheel turned sideways (Shift held);
    /// scrolling up / left-to-right increases.
    pub fn wheel_delta(delta_x: f64, delta_y: f64) -> f64 {
        if delta_y != 0.0 { delta_y } else { -delta_x }
    }

    /// Drops the last `n` Characters of `s`.
    fn drop_last_graphemes(s: &str, n: usize) -> String {
        let all: Vec<&str> = graphemes(s).collect();
        all[..all.len().saturating_sub(n)].concat()
    }

    /// Parses user text: optional sign (also U+2212), comma or dot decimal, optional unit suffix (case-insensitive).
    /// Returns `None` for anything else (including nan/inf and foreign units).
    pub fn parse(text: &str, unit: &str) -> Option<f64> {
        let mut s = trim_spaces(text, true).to_string();
        let u = trim_spaces(unit, false);
        if !u.is_empty() && s.to_lowercase().ends_with(&u.to_lowercase()) {
            s = trim_spaces(&Self::drop_last_graphemes(&s, graphemes(u).count()), false).to_string();
        }
        if s.is_empty() {
            return None;
        }
        s = s.replace('\u{2212}', "-").replace(',', ".");
        let body = if s.starts_with('-') || s.starts_with('+') { &s[1..] } else { &s[..] };
        // Only digits and at most one dot: rejects "nan", "inf", "1e5", "1.2.3".
        if body.is_empty()
            || !body.chars().all(|c| c.is_ascii_digit() || c == '.')
            || body.chars().filter(|&c| c == '.').count() > 1
            || !body.chars().any(|c| c.is_ascii_digit())
        {
            return None;
        }
        s.parse::<f64>().ok().filter(|v| v.is_finite())
    }

    /// `s` without any occurrence of `u`, compared case-insensitively.
    fn remove_case_insensitive(s: &str, u: &str) -> String {
        let (s, u): (Vec<char>, Vec<char>) = (s.chars().collect(), u.chars().collect());
        let same = |a: char, b: char| a.to_lowercase().eq(b.to_lowercase());
        let mut out = String::new();
        let mut i = 0;
        while i < s.len() {
            if i + u.len() <= s.len() && s[i..i + u.len()].iter().zip(&u).all(|(&a, &b)| same(a, b)) {
                i += u.len();
            } else {
                out.push(s[i]);
                i += 1;
            }
        }
        out
    }

    /// Typed text with simple maths, for committing a field: `+ - * / ( )` and numbers only (hand-written parser, no
    /// expression engine). A leading `+`, `*` or `/` applies to `current` (`+10`, `*2`, `/2`); a leading `-` does too
    /// when `negative_allowed` is false (the field cannot hold negatives anyway), otherwise `-5` stays the plain
    /// number (type `+-5` to subtract). The rest of the text is one expression (`*2+1` is `current * 3`).
    /// Anything invalid, division by zero or a non-finite result gives `None`. The unit (and spaces) may appear anywhere.
    pub fn evaluate(text: &str, unit: &str, current: f64, negative_allowed: bool) -> Option<f64> {
        let mut s = trim_spaces(text, true).to_string();
        let u = trim_spaces(unit, false);
        if !u.is_empty() {
            s = Self::remove_case_insensitive(&s, u);
        }
        let s: String = s
            .replace('\u{2212}', "-")
            .replace('\u{00D7}', "*")
            .replace('\u{00F7}', "/")
            .replace(',', ".")
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect();
        let first = s.chars().next()?;
        let relative = "+*/".contains(first) || (first == '-' && !negative_allowed);
        let chars: Vec<char> = if relative { s.chars().skip(1).collect() } else { s.chars().collect() };
        if relative && chars.is_empty() {
            return None;
        }
        let mut evaluator = ExpressionParser { chars, pos: 0, depth: 0 };
        let rhs = evaluator.parse_all()?;
        let result = if relative {
            match first {
                '+' => current + rhs,
                '-' => current - rhs,
                '*' => current * rhs,
                _ => {
                    if rhs == 0.0 {
                        return None;
                    }
                    current / rhs
                }
            }
        } else {
            rhs
        };
        result.is_finite().then_some(result)
    }

    /// Fixed decimals plus unit. Degree sign hugs the number (90°), other units get a space (42 %, 3 dB).
    pub fn format(v: f64, decimals: i64, unit: &str) -> String {
        let places = usize::try_from(decimals.max(0)).unwrap_or(0);
        let mut s = if v.is_nan() { "nan".to_string() } else { format!("{v:.places$}") };
        if s.parse::<f64>().is_ok_and(|d| d == 0.0) {
            s = s.trim_start_matches('-').to_string(); // no "-0.0"
        }
        if unit.is_empty() {
            return s;
        }
        format!("{s} {unit}")
    }
}

/// Turns wheel deltas into whole notches: one per mouse-wheel line, one per `POINTS_PER_NOTCH` trackpad points;
/// the remainder carries over to the next event.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct WheelAccumulator {
    remainder: f64,
}

impl WheelAccumulator {
    /// Trackpad points that make one notch.
    pub const POINTS_PER_NOTCH: f64 = 8.0;

    /// An empty accumulator.
    pub fn new() -> WheelAccumulator {
        WheelAccumulator::default()
    }

    /// Adds a wheel delta and returns the whole notches it completes.
    pub fn add(&mut self, delta: f64, precise: bool) -> i64 {
        if !delta.is_finite() {
            return 0;
        }
        let unit = if precise { Self::POINTS_PER_NOTCH } else { 1.0 };
        self.remainder += delta / unit;
        let n = self.remainder.trunc();
        self.remainder -= n;
        n as i64
    }

    /// Drops the carried remainder.
    pub fn reset(&mut self) {
        self.remainder = 0.0;
    }
}

/// Recursive-descent parser for numbers, `+ - * /` and parentheses.
struct ExpressionParser {
    chars: Vec<char>,
    pos: usize,
    depth: usize,
}

impl ExpressionParser {
    fn parse_all(&mut self) -> Option<f64> {
        let v = self.expr()?;
        (self.pos == self.chars.len() && v.is_finite()).then_some(v)
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn expr(&mut self) -> Option<f64> {
        let mut v = self.term()?;
        while let Some(c) = self.peek().filter(|&c| c == '+' || c == '-') {
            self.pos += 1;
            let r = self.term()?;
            v = if c == '+' { v + r } else { v - r };
        }
        Some(v)
    }

    fn term(&mut self) -> Option<f64> {
        let mut v = self.factor()?;
        while let Some(c) = self.peek().filter(|&c| c == '*' || c == '/') {
            self.pos += 1;
            let r = self.factor()?;
            if c == '/' {
                if r == 0.0 {
                    return None;
                }
                v /= r;
            } else {
                v *= r;
            }
        }
        Some(v)
    }

    fn factor(&mut self) -> Option<f64> {
        self.depth += 1;
        let result = self.factor_body();
        self.depth -= 1;
        result
    }

    fn factor_body(&mut self) -> Option<f64> {
        let c = self.peek().filter(|_| self.depth < 32)?;
        if c == '-' || c == '+' {
            self.pos += 1;
            let v = self.factor()?;
            return Some(if c == '-' { -v } else { v });
        }
        if c == '(' {
            self.pos += 1;
            let v = self.expr()?;
            if self.peek() != Some(')') {
                return None;
            }
            self.pos += 1;
            return Some(v);
        }
        let start = self.pos;
        let mut dots = 0;
        while let Some(d) = self.peek().filter(|d| d.is_ascii_digit() || *d == '.') {
            if d == '.' {
                dots += 1;
            }
            self.pos += 1;
        }
        let body: String = self.chars[start..self.pos].iter().collect();
        if dots > 1 || !body.chars().any(|c| c.is_ascii_digit()) {
            return None;
        }
        body.parse::<f64>().ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn val(start: f64, delta: f64, step: f64, shift: bool, option: bool, range: &RangeInclusive<f64>) -> f64 {
        ScrubMath::value(start, delta, step, shift, option, range)
    }

    #[test]
    fn multipliers() {
        assert_eq!(ScrubMath::multiplier(false, false), 1.0);
        assert_eq!(ScrubMath::multiplier(true, false), 10.0);
        assert_eq!(ScrubMath::multiplier(false, true), 0.1);
        assert_eq!(ScrubMath::multiplier(true, true), 1.0);
    }

    #[test]
    fn drag_delta() {
        let r = -100.0..=100.0;
        assert_eq!(val(10.0, 5.0, 1.0, false, false, &r), 15.0);
        assert_eq!(val(10.0, -5.0, 1.0, false, false, &r), 5.0);
        assert_eq!(val(0.0, 3.0, 1.0, true, false, &r), 30.0);
        assert_eq!(val(0.0, 3.0, 1.0, false, true, &r), 0.3);
        assert_eq!(val(0.0, 7.0, 0.5, false, false, &r), 3.5);
    }

    #[test]
    fn clamping() {
        let r = 0.0..=100.0;
        assert_eq!(val(95.0, 50.0, 1.0, false, false, &r), 100.0);
        assert_eq!(val(5.0, -50.0, 1.0, false, false, &r), 0.0);
        assert_eq!(ScrubMath::clamp(-3.0, &r), 0.0);
        assert_eq!(ScrubMath::clamp(f64::NAN, &r), 0.0);
    }

    #[test]
    fn rounding_to_grid() {
        let r = -1000.0..=1000.0;
        // Fractional pixel deltas (trackpad) still land on the step grid.
        assert_eq!(val(0.0, 2.4, 1.0, false, false, &r), 2.0);
        assert_eq!(val(0.0, 2.6, 1.0, false, false, &r), 3.0);
        assert_eq!(val(0.0, 3.0, 0.1, false, false, &r), 0.3);
        assert_eq!(val(0.1, 2.0, 0.1, false, false, &r), 0.3);
        assert_eq!(val(0.0, 4.0, 1.0, false, true, &r), 0.4);
        // Off-grid start is stable at delta 0.
        assert_eq!(val(12.34, 0.0, 1.0, false, false, &r), 12.34);
    }

    #[test]
    fn parsing_accepts() {
        assert_eq!(ScrubMath::parse("42", "%"), Some(42.0));
        assert_eq!(ScrubMath::parse("42 %", "%"), Some(42.0));
        assert_eq!(ScrubMath::parse("42%", "%"), Some(42.0));
        assert_eq!(ScrubMath::parse("1,5", "s"), Some(1.5));
        assert_eq!(ScrubMath::parse(" -3,25 dB ", "dB"), Some(-3.25));
        assert_eq!(ScrubMath::parse("\u{2212}6 dB", "dB"), Some(-6.0));
        assert_eq!(ScrubMath::parse("90°", "°"), Some(90.0));
        assert_eq!(ScrubMath::parse("12 DB", "dB"), Some(12.0));
        assert_eq!(ScrubMath::parse("+5", ""), Some(5.0));
        assert_eq!(ScrubMath::parse("1.5", ""), Some(1.5));
    }

    fn ev(t: &str, unit: &str, cur: f64, neg: bool) -> Option<f64> {
        ScrubMath::evaluate(t, unit, cur, neg)
    }

    #[test]
    fn simple_maths() {
        let e = |t: &str| ev(t, "", 100.0, true);
        assert_eq!(e("42"), Some(42.0));
        assert_eq!(e("10+5"), Some(15.0));
        assert_eq!(e("1080/2"), Some(540.0));
        assert_eq!(e("2+3*4"), Some(14.0));
        assert_eq!(e("(2+3)*4"), Some(20.0));
        assert_eq!(e("1,5*2"), Some(3.0));
        assert_eq!(e("-5"), Some(-5.0)); // negative field: plain number
        assert_eq!(ev("-5", "", 100.0, false), Some(95.0)); // cannot be negative: relative
        assert_eq!(e("+10"), Some(110.0));
        assert_eq!(e("+-5"), Some(95.0));
        assert_eq!(e("*2"), Some(200.0));
        assert_eq!(e("/4"), Some(25.0));
        assert_eq!(e("*2+1"), Some(300.0));
        assert_eq!(ev("+10%", "%", 100.0, true), Some(110.0));
        assert_eq!(ev("50% + 5%", "%", 100.0, true), Some(55.0));
        assert_eq!(ev("2 s", "s", 100.0, true), Some(2.0));
        assert_eq!(e("-3 - -2"), Some(-1.0));
    }

    #[test]
    fn simple_maths_rejects() {
        let deep = format!("{}1{}", "(".repeat(100), ")".repeat(100));
        for bad in [
            "", "+", "*", "abc", "1/0", "/0", "2**3", "(2", "2)", "1+", "1..2", "1e5", "nan", "inf", "sqrt(4)", "2^3",
            "1;2", "$(x)", &deep,
        ] {
            assert_eq!(ScrubMath::evaluate(bad, "", 1.0, true), None, "{bad}");
        }
    }

    #[test]
    fn parsing_rejects() {
        assert_eq!(ScrubMath::parse("", "%"), None);
        assert_eq!(ScrubMath::parse("abc", "%"), None);
        assert_eq!(ScrubMath::parse("1,2,3", ""), None);
        assert_eq!(ScrubMath::parse("nan", ""), None);
        assert_eq!(ScrubMath::parse("inf", ""), None);
        assert_eq!(ScrubMath::parse("5 px", "%"), None);
    }

    #[test]
    fn formatting() {
        assert_eq!(ScrubMath::format(42.0, 0, "%"), "42 %");
        assert_eq!(ScrubMath::format(1.5, 2, "s"), "1.50 s");
        assert_eq!(ScrubMath::format(-3.5, 1, ""), "-3.5");
        assert_eq!(ScrubMath::format(90.0, 0, "°"), "90 °");
        assert_eq!(ScrubMath::format(-0.0001, 1, ""), "0.0");
    }

    #[test]
    fn arrow_step() {
        let r = 0.0..=10.0;
        assert_eq!(ScrubMath::stepped(5.0, 1, 1.0, false, false, &r), 6.0);
        assert_eq!(ScrubMath::stepped(5.0, -1, 1.0, true, false, &r), 0.0);
        assert_eq!(ScrubMath::stepped(5.0, 1, 1.0, false, true, &r), 5.1);
    }

    #[test]
    fn step_burst_opens_once_and_closes_once() {
        let mut b = StepBurst::new();
        assert!(b.step());
        assert!(!b.step());
        assert!(b.end());
        assert!(!b.end());
    }

    #[test]
    fn wheel_accumulates_notches_and_resets() {
        let mut w = WheelAccumulator::new();
        assert_eq!(w.add(3.0, true), 0);
        assert_eq!(w.add(6.0, true), 1);
        assert_eq!(w.add(f64::NAN, true), 0);
        assert_eq!(w.add(2.0, false), 2);
        w.reset();
        assert_eq!(w, WheelAccumulator::new());
        assert_eq!(ScrubMath::wheel_delta(2.0, 0.0), -2.0);
        assert!(ScrubMath::wheel_accepts(true, false, true) && !ScrubMath::wheel_accepts(false, true, true));
        assert_eq!(ScrubMath::wheel_value(5.0, 3, 1.0, true, false, &(0.0..=100.0)), 35.0);
        assert_eq!(ScrubMath::reset_target(5.0, Some(5.0), &(0.0..=10.0)), None);
        assert_eq!(ScrubMath::reset_target(5.0, Some(50.0), &(0.0..=10.0)), Some(10.0));
    }
}
