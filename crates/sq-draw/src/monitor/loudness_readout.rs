// Swift: LoudnessReadout.swift
//! The program loudness readout on the monitor picture: short-term and integrated LUFS as one short line. Momentary alone is
//! not shown (it flickers; the meter panel has it).

use super::loudness_meter::{LoudnessReading, LoudnessScale, LoudnessTarget};

/// The readout line.
pub enum LoudnessReadout {}

impl LoudnessReadout {
    /// "S -14.0  I -16.2 LUFS", or `None` without a usable value.
    pub fn text(r: &LoudnessReading) -> Option<String> {
        let mut parts: Vec<String> = vec![];
        if let Some(s) = r.short_term_lufs.filter(|s| s.is_finite() && *s > -100.0) {
            parts.push(format!("S {}", LoudnessScale::text(Some(s))));
        }
        if let Some(i) = r.integrated_lufs.filter(|i| i.is_finite() && *i > -100.0) {
            parts.push(format!("I {}", LoudnessScale::text(Some(i))));
        }
        if parts.is_empty() { None } else { Some(format!("{} LUFS", parts.join("  "))) }
    }

    /// Short-term or integrated above the target by more than 1 LU, or the true peak above the ceiling.
    pub fn is_over(r: &LoudnessReading, target: &LoudnessTarget) -> bool {
        target.is_over_target(r.short_term_lufs)
            || target.is_over_target(r.integrated_lufs)
            || target.is_over_ceiling(r.true_peak_db)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_line_shows_short_term_and_integrated_only() {
        let r = LoudnessReading {
            momentary_lufs: Some(-9.0),
            short_term_lufs: Some(-14.0),
            integrated_lufs: Some(-16.25),
            ..Default::default()
        };
        assert_eq!(LoudnessReadout::text(&r).as_deref(), Some("S -14.0  I -16.2 LUFS"));
        assert_eq!(LoudnessReadout::text(&LoudnessReading { momentary_lufs: Some(-9.0), ..Default::default() }), None);
    }

    #[test]
    fn over_means_above_target_or_ceiling() {
        let t = LoudnessTarget::default();
        assert!(LoudnessReadout::is_over(&LoudnessReading { short_term_lufs: Some(-10.0), ..Default::default() }, &t));
        assert!(LoudnessReadout::is_over(&LoudnessReading { true_peak_db: 0.5, ..Default::default() }, &t));
        assert!(!LoudnessReadout::is_over(
            &LoudnessReading { short_term_lufs: Some(-14.0), true_peak_db: -3.0, ..Default::default() },
            &t
        ));
    }
}
