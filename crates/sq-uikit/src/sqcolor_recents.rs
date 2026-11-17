// Swift: SQColorRecents.swift
//! Recently used colors of the picker, newest first. Persisted in the defaults key `sq.color.recents` as hex strings
//! (`RRGGBB`, or `RRGGBBAA` when not opaque). The board's row holds six swatches.

use crate::appearance_palette::UiDefaults;
use crate::sqcolor_value::SQColorValue;

pub const DEFAULTS_KEY: &str = "sq.color.recents";
pub const MAX_COUNT: usize = 6;

/// `hex` moved to the front, duplicates removed, capped at `max`. Invalid strings are ignored.
pub fn adding(hex: &str, list: &[String], max: usize) -> Vec<String> {
    let Some(key) = normalized(hex) else { return list.to_vec() };
    let mut out = vec![key.clone()];
    out.extend(list.iter().filter(|s| **s != key).cloned());
    out.truncate(max);
    out
}

/// Uppercase `RRGGBB` / `RRGGBBAA` without `#`, or `None` when `hex` is not a color.
pub fn normalized(hex: &str) -> Option<String> {
    SQColorValue::parse_hex(hex, 1.0).map(|v| key_for(&v))
}

/// The stored form of a color.
pub fn key_for(v: &SQColorValue) -> String {
    if v.a < 1.0 { format!("{}{:02X}", v.hex(), (v.a * 255.0).round() as i64) } else { v.hex() }
}

/// The saved list (invalid entries dropped, at most `MAX_COUNT`).
pub fn load(defaults: &dyn UiDefaults) -> Vec<String> {
    let raw = defaults.string_array(DEFAULTS_KEY).unwrap_or_default();
    raw.iter().filter_map(|s| normalized(s)).take(MAX_COUNT).collect()
}

/// Puts `v` at the front of the saved list.
pub fn remember(v: &SQColorValue, defaults: &mut dyn UiDefaults) {
    let list = adding(&key_for(v), &load(defaults), MAX_COUNT);
    defaults.set_string_array(DEFAULTS_KEY, &list);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::appearance_palette::MemoryDefaults;

    fn strings(l: &[&str]) -> Vec<String> {
        l.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn adds_to_front_and_dedupes() {
        let l = adding("ff0000", &strings(&["00FF00", "FF0000", "0000FF"]), MAX_COUNT);
        assert_eq!(l, strings(&["FF0000", "00FF00", "0000FF"]));
    }

    #[test]
    fn caps_at_six() {
        let mut l: Vec<String> = vec![];
        for h in ["111111", "222222", "333333", "444444", "555555", "666666", "777777"] {
            l = adding(h, &l, MAX_COUNT);
        }
        assert_eq!(l.len(), MAX_COUNT);
        assert_eq!(l.first().map(String::as_str), Some("777777"));
        assert!(!l.contains(&"111111".to_string()));
    }

    #[test]
    fn ignores_invalid_and_keeps_alpha() {
        assert_eq!(adding("zzz", &strings(&["FFFFFF"]), MAX_COUNT), strings(&["FFFFFF"]));
        assert_eq!(normalized("#f00").as_deref(), Some("FF0000"));
        assert_eq!(key_for(&SQColorValue::from_rgb(1.0, 0.0, 0.0, 0.5)), "FF000080");
    }

    #[test]
    fn persists_in_defaults() {
        let mut d = MemoryDefaults::default();
        remember(&SQColorValue::from_rgb(1.0, 0.0, 0.0, 1.0), &mut d);
        remember(&SQColorValue::from_rgb(0.0, 0.0, 1.0, 1.0), &mut d);
        assert_eq!(load(&d), strings(&["0000FF", "FF0000"]));
        assert_eq!(d.string_array("sq.color.recents"), Some(strings(&["0000FF", "FF0000"])));
    }
}
