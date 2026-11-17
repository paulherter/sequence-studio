// Swift: RotationText.swift
//! Rotation as Premiere shows it: whole turns plus degrees ("1x 30.0°") from 360° up, plain degrees below.
//! The stored value stays plain degrees (unbounded). Typing "1x30", "1x 30", "-1x30" or any plain number or sum works;
//! the sign of the turns applies to the whole angle ("-1x30" = -390°).

use crate::scrub_math::ScrubMath;

/// Shows `degrees` as turns plus degrees.
pub fn format(degrees: f64) -> String {
    if !degrees.is_finite() {
        return "0.0 \u{00B0}".to_string();
    }
    let rounded = (degrees.abs() * 10.0).round() / 10.0;
    let sign = if degrees < 0.0 && rounded > 0.0 { "-" } else { "" };
    let turns = (rounded / 360.0).floor(); // Double: huge values must not trap an Int conversion
    let rest = (rounded - turns * 360.0).max(0.0);
    let r = format!("{rest:.1}");
    if turns == 0.0 { format!("{sign}{r} \u{00B0}") } else { format!("{sign}{turns:.0}x {r} \u{00B0}") }
}

/// `None` for text that is neither a turns form nor valid maths. `current` serves relative input (`+10`, `*2`).
pub fn parse(text: &str, current: f64) -> Option<f64> {
    let cleaned: String = text
        .replace('\u{00B0}', "")
        .replace('\u{2212}', "-")
        .replace(',', ".")
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>()
        .to_lowercase();
    let parts: Vec<&str> = cleaned.split('x').collect();
    if parts.len() == 2 && !parts[0].is_empty() {
        let head = parts[0];
        let tail = if parts[1].is_empty() { "0" } else { parts[1] };
        let t: f64 = head.parse().ok().filter(|t: &f64| t.is_finite() && *t == t.round())?;
        let d: f64 = tail.parse().ok().filter(|d: &f64| d.is_finite())?;
        let sign = if head.starts_with('-') { -1.0 } else { 1.0 };
        let v = sign * (t.abs() * 360.0 + d.abs());
        return if v.is_finite() { Some(v) } else { None };
    }
    ScrubMath::evaluate(text, "\u{00B0}", current, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_turns_and_degrees() {
        assert_eq!(format(30.0), "30.0 \u{00B0}");
        assert_eq!(format(0.0), "0.0 \u{00B0}");
        assert_eq!(format(-30.0), "-30.0 \u{00B0}");
        assert_eq!(format(390.0), "1x 30.0 \u{00B0}");
        assert_eq!(format(720.0), "2x 0.0 \u{00B0}");
        assert_eq!(format(-390.0), "-1x 30.0 \u{00B0}");
        assert_eq!(format(359.97), "1x 0.0 \u{00B0}");
    }

    #[test]
    fn huge_values_do_not_trap() {
        assert!(!format(1e23).is_empty());
        assert!(!format(-f64::MAX).is_empty());
        let _ = parse("99999999999999999999x", 0.0);
        assert_eq!(parse("1e400x", 0.0), None);
    }

    #[test]
    fn parses_turns_and_plain_input() {
        assert_eq!(parse("1x30", 0.0), Some(390.0));
        assert_eq!(parse("1x 30.5\u{00B0}", 0.0), Some(390.5));
        assert_eq!(parse("-1x30", 0.0), Some(-390.0));
        assert_eq!(parse("2x", 0.0), Some(720.0));
        assert_eq!(parse("390", 0.0), Some(390.0));
        assert_eq!(parse("+10", 20.0), Some(30.0));
        assert_eq!(parse("1.5x3", 0.0), None);
        assert_eq!(parse("abc", 0.0), None);
        assert_eq!(parse(&format(1234.5), 0.0), Some(1234.5));
    }
}
