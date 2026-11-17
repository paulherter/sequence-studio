//! Text helpers of the Export dialog: `%g`-style numbers, file-name cleaning and `Time.exportSeconds`.

use sq_core_time::Time;

/// Seconds as an `f64`, for dialog fields only (never stored). Swift `Time.exportSeconds`.
// Swift: Export/ExportDialogModel.swift:1089
pub trait ExportSeconds {
    /// `value / max(timescale, 1)`.
    fn export_seconds(self) -> f64;
}

impl ExportSeconds for Time {
    fn export_seconds(self) -> f64 {
        self.value() as f64 / self.timescale().max(1) as f64
    }
}

/// C `%.{sig}g`: `sig` significant digits, trailing zeros dropped, exponent form outside 1e-4...1e{sig}.
pub fn format_g(v: f64, sig: usize) -> String {
    if v == 0.0 || !v.is_finite() {
        return if v == 0.0 { "0".to_string() } else { v.to_string() };
    }
    let sig = sig.max(1);
    let sci = format!("{:.*e}", sig - 1, v);
    let (mantissa, exp) = sci.split_once('e').unwrap_or((&sci, "0"));
    let exp: i32 = exp.parse().unwrap_or(0);
    let trim = |s: &str| -> String {
        if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.').to_string() } else { s.to_string() }
    };
    if exp < -4 || exp >= sig as i32 {
        let sign = if exp < 0 { '-' } else { '+' };
        return format!("{}e{sign}{:02}", trim(mantissa), exp.abs());
    }
    let decimals = (sig as i32 - 1 - exp).max(0) as usize;
    trim(&format!("{v:.decimals$}"))
}

/// Unicode category Cf (format characters), which Foundation's `controlCharacters` set includes next to Cc.
fn is_format_char(c: char) -> bool {
    matches!(c as u32,
        0xAD | 0x600..=0x605 | 0x61C | 0x6DD | 0x70F | 0x180E | 0x200B..=0x200F | 0x202A..=0x202E
        | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB)
}

/// Space separators (Unicode Zs) plus tab: Foundation's `whitespaces`.
fn is_blank(c: char) -> bool {
    matches!(c as u32, 0x20 | 0x09 | 0xA0 | 0x1680 | 0x2000..=0x200A | 0x202F | 0x205F | 0x3000)
}

/// Characters a file name cannot carry, plus control characters; leading and trailing dots/blanks go too; at most 120
/// characters. Counts Unicode scalars, Swift counts grapheme clusters (see DECISIONS).
pub(crate) fn sanitize_file_name(s: &str) -> String {
    let cleaned: String = s
        .chars()
        .filter(|&c| {
            !("/\\:?*|\"<>%".contains(c) || c.is_control() || is_format_char(c) || matches!(c, '\u{2028}' | '\u{2029}'))
        })
        .collect();
    cleaned.trim_matches(|c: char| c == '.' || is_blank(c)).chars().take(120).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn g_format_matches_c() {
        assert_eq!(format_g(12.0, 3), "12");
        assert_eq!(format_g(12.34567, 3), "12.3");
        assert_eq!(format_g(23.976, 6), "23.976");
        assert_eq!(format_g(0.5, 3), "0.5");
        assert_eq!(format_g(1500.0, 3), "1.5e+03");
        assert_eq!(format_g(0.00001234, 3), "1.23e-05");
    }

    #[test]
    fn file_names_lose_illegal_characters_and_edges() {
        assert_eq!(sanitize_file_name("  ..My: Reel/1? "), "My Reel1");
        assert_eq!(sanitize_file_name("a\nb\u{200B}c"), "abc");
        assert_eq!(sanitize_file_name(&"x".repeat(200)).chars().count(), 120);
        assert_eq!(sanitize_file_name("???"), "");
    }

    #[test]
    fn export_seconds_guards_the_timescale() {
        assert_eq!(Time::new(3, 2).export_seconds(), 1.5);
    }
}
