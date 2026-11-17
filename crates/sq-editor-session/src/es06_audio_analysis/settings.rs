//! Typed reads and writes over the byte-valued `SettingsStore` (Swift `UserDefaults` get/set of numbers and strings).
//! Numbers are stored as their decimal text, strings as UTF-8; a missing or unreadable value reads as `None`.

use sq_library::library_folder_store::SettingsStore;

pub(crate) fn get_string(d: &dyn SettingsStore, key: &str) -> Option<String> {
    d.data(key).and_then(|b| String::from_utf8(b).ok())
}

pub(crate) fn get_f64(d: &dyn SettingsStore, key: &str) -> Option<f64> {
    get_string(d, key).and_then(|s| s.trim().parse().ok())
}

pub(crate) fn get_i64(d: &dyn SettingsStore, key: &str) -> Option<i64> {
    get_string(d, key).and_then(|s| s.trim().parse::<f64>().ok()).map(|v| v as i64)
}

pub(crate) fn set_f64(d: &mut dyn SettingsStore, key: &str, v: f64) {
    d.set_data(key, v.to_string().into_bytes());
}

pub(crate) fn set_i64(d: &mut dyn SettingsStore, key: &str, v: i64) {
    d.set_data(key, v.to_string().into_bytes());
}

pub(crate) fn set_string(d: &mut dyn SettingsStore, key: &str, v: &str) {
    d.set_data(key, v.as_bytes().to_vec());
}
