// Swift: TimelineEditorForms.swift
//! Values the host's form dialogs for timeline editors read back (portable, so the Windows shell forms share them).
//!
//! Not ported here: `TimelineMenus.swift` (the right-click menus). It is `EditorSession` and `TimelineHost` glue: every row
//! calls a session method or a host request, and it needs the panel (`fade_handle_hit`, `volume_key`, `speed_key_hit`,
//! `context_select`, `caption word` items). It follows once the panel and the host exist (see `PANEL-FIELDS-DT3-4.md`);
//! the row specs it builds from are already in `sq-timeline-ui` (`TimelineContextMenu`, `TimelineSideMenus`).

use sq_core_color::ColorMatteColor;
use sq_core_time::Time;

pub struct TimelineEditorForms;

impl TimelineEditorForms {
    /// The Mac Color Matte sheet's duration range in seconds (`ColorMatteDialog.durationSeconds`).
    pub const MATTE_SECONDS: (f64, f64) = (0.1, 3600.0);

    /// "#RRGGBB", "RRGGBB" or "#RGB" (case-insensitive, spaces ignored); `None` for anything else.
    pub fn matte_color(hex: &str) -> Option<ColorMatteColor> {
        let mut s: String = hex.chars().filter(|c| !c.is_whitespace()).collect();
        if s.starts_with('#') {
            s.remove(0);
        }
        if s.chars().count() == 3 {
            s = s.chars().flat_map(|c| [c, c]).collect();
        }
        if s.chars().count() != 6 {
            return None;
        }
        let v = u32::from_str_radix(&s, 16).ok()?;
        Some(ColorMatteColor { r: (v >> 16 & 0xFF) as u8, g: (v >> 8 & 0xFF) as u8, b: (v & 0xFF) as u8 })
    }

    /// "#RRGGBB" in upper case.
    pub fn hex(c: ColorMatteColor) -> String {
        format!("#{:02X}{:02X}{:02X}", c.r, c.g, c.b)
    }

    /// Seconds typed in the duration field, clamped to `MATTE_SECONDS`, as whole milliseconds (the session snaps to a
    /// frame, like the Mac sheet).
    pub fn matte_duration(seconds: f64) -> Time {
        let (lo, hi) = Self::MATTE_SECONDS;
        let s = (if seconds.is_finite() { seconds } else { 5.0 }).max(lo).min(hi);
        Time::new((s * 1000.0).round() as i64, 1000)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(r: u8, g: u8, b: u8) -> Option<ColorMatteColor> {
        Some(ColorMatteColor { r, g, b })
    }

    #[test]
    fn hex_parses_long_short_and_spaced_forms() {
        assert_eq!(TimelineEditorForms::matte_color("#FF8000"), c(255, 128, 0));
        assert_eq!(TimelineEditorForms::matte_color("ff8000"), c(255, 128, 0));
        assert_eq!(TimelineEditorForms::matte_color(" # f 80 "), c(255, 136, 0));
        assert_eq!(TimelineEditorForms::matte_color("#abc"), c(0xAA, 0xBB, 0xCC));
        assert_eq!(TimelineEditorForms::matte_color("#12345"), None);
        assert_eq!(TimelineEditorForms::matte_color("#GGGGGG"), None);
        assert_eq!(TimelineEditorForms::matte_color(""), None);
    }

    #[test]
    fn hex_prints_upper_case_and_round_trips() {
        let col = ColorMatteColor { r: 1, g: 171, b: 255 };
        assert_eq!(TimelineEditorForms::hex(col), "#01ABFF");
        assert_eq!(TimelineEditorForms::matte_color(&TimelineEditorForms::hex(col)), Some(col));
    }

    #[test]
    fn duration_clamps_and_rounds_to_milliseconds() {
        assert_eq!(TimelineEditorForms::matte_duration(2.5), Time::new(2500, 1000));
        assert_eq!(TimelineEditorForms::matte_duration(0.0), Time::new(100, 1000));
        assert_eq!(TimelineEditorForms::matte_duration(1e9), Time::new(3_600_000, 1000));
        assert_eq!(TimelineEditorForms::matte_duration(f64::NAN), Time::new(5000, 1000));
        assert_eq!(TimelineEditorForms::matte_duration(f64::INFINITY), Time::new(5000, 1000));
    }
}
