// Swift: SilenceSettings.swift
//! Settings of "Remove Silences...": what counts as a pause and how much of it stays.

use std::ops::RangeInclusive;

use sq_core_time::Time;
use sq_library::library_folder_store::SettingsStore;

use super::settings::{get_f64, get_i64, set_f64, set_i64};

/// Settings of "Remove Silences...": what counts as a pause and how much of it stays.
// Swift: SilenceSettings.swift:7
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SilenceSettings {
    /// Audio quieter than this (peak, dB) is silence.
    // Swift: SilenceSettings.swift:7
    pub threshold_db: f64,
    /// A pause must last at least this many milliseconds.
    // Swift: SilenceSettings.swift:9
    pub minimum_ms: i64,
    /// Milliseconds of every pause that stay at both ends (so cuts do not sound clipped).
    // Swift: SilenceSettings.swift:11
    pub padding_ms: i64,
}

const KEY_DB: &str = "sq.silence.thresholdDB";
const KEY_MIN: &str = "sq.silence.minMs";
const KEY_PAD: &str = "sq.silence.padMs";

impl SilenceSettings {
    // Swift: SilenceSettings.swift:12
    pub const STANDARD: SilenceSettings = SilenceSettings { threshold_db: -35.0, minimum_ms: 350, padding_ms: 70 };

    // Swift: SilenceSettings.swift:14
    pub fn new(threshold_db: f64, minimum_ms: i64, padding_ms: i64) -> SilenceSettings {
        SilenceSettings { threshold_db, minimum_ms, padding_ms }
    }

    /// Slider range of the threshold in dB.
    // Swift: SilenceSettings.swift:20
    pub const THRESHOLD_RANGE: RangeInclusive<f64> = -60.0..=-10.0;
    /// Slider range of the minimum length in ms.
    // Swift: SilenceSettings.swift:21
    pub const MINIMUM_RANGE: RangeInclusive<f64> = 100.0..=2000.0;
    /// Slider range of the padding in ms.
    // Swift: SilenceSettings.swift:22
    pub const PADDING_RANGE: RangeInclusive<f64> = 0.0..=500.0;

    /// The values a slider position applies, rounded to 1 dB, 50 ms and 10 ms (the fields show these, never more).
    // Swift: SilenceSettings.swift:25
    pub fn snapped(threshold_db: f64, minimum_ms: f64, padding_ms: f64) -> SilenceSettings {
        SilenceSettings {
            threshold_db: threshold_db.round(),
            minimum_ms: ((minimum_ms / 50.0).round() * 50.0) as i64,
            padding_ms: ((padding_ms / 10.0).round() * 10.0) as i64,
        }
    }

    // Swift: SilenceSettings.swift:29
    pub fn minimum(&self) -> Time {
        Time::new(self.minimum_ms.max(0), 1000)
    }

    // Swift: SilenceSettings.swift:31
    pub fn padding(&self) -> Time {
        Time::new(self.padding_ms.max(0), 1000)
    }

    /// Last values used, or the defaults.
    // Swift: SilenceSettings.swift:36
    pub fn remembered(d: &dyn SettingsStore) -> SilenceSettings {
        let Some(db) = get_f64(d, KEY_DB) else { return Self::STANDARD };
        SilenceSettings {
            threshold_db: db,
            minimum_ms: get_i64(d, KEY_MIN).unwrap_or(0),
            padding_ms: get_i64(d, KEY_PAD).unwrap_or(0),
        }
    }

    // Swift: SilenceSettings.swift:40
    pub fn remember(&self, d: &mut dyn SettingsStore) {
        set_f64(d, KEY_DB, self.threshold_db);
        set_i64(d, KEY_MIN, self.minimum_ms);
        set_i64(d, KEY_PAD, self.padding_ms);
    }

    /// "12 silences, 8.4 s will be removed" for the dialog's preview line.
    // Swift: SilenceSettings.swift:46
    pub fn preview_text(count: i64, removed: Time) -> String {
        if count <= 0 {
            return "No silences found.".to_string();
        }
        let sec = removed.value() as f64 / removed.timescale() as f64;
        format!("{count} {}, {sec:.1} s will be removed.", if count == 1 { "silence" } else { "silences" })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_library::library_folder_store::MemorySettings;

    #[test]
    fn snaps_to_the_field_steps() {
        let s = SilenceSettings::snapped(-34.6, 372.0, 64.0);
        assert_eq!(s, SilenceSettings::new(-35.0, 350, 60));
    }

    #[test]
    fn remembers_and_defaults() {
        let mut d = MemorySettings::default();
        assert_eq!(SilenceSettings::remembered(&d), SilenceSettings::STANDARD);
        let s = SilenceSettings::new(-40.0, 500, 100);
        s.remember(&mut d);
        assert_eq!(SilenceSettings::remembered(&d), s);
    }

    #[test]
    fn time_values_and_preview() {
        assert_eq!(SilenceSettings::STANDARD.minimum(), Time::new(350, 1000));
        assert_eq!(SilenceSettings::new(0.0, -5, 70).minimum(), Time::new(0, 1000));
        assert_eq!(SilenceSettings::preview_text(0, Time::ZERO), "No silences found.");
        assert_eq!(SilenceSettings::preview_text(1, Time::new(84, 10)), "1 silence, 8.4 s will be removed.");
        assert_eq!(SilenceSettings::preview_text(12, Time::new(84, 10)), "12 silences, 8.4 s will be removed.");
    }
}
