//! The in-memory settings store a monitor model uses until the host injects the real one (Swift `UserDefaults.standard`).

use sq_uikit::appearance_palette::UiDefaults;
use std::collections::BTreeMap;

/// Settings kept in memory only; the default store of [`crate::monitor_panel_model::MonitorPanelModel::new`] and of tests.
#[derive(Clone, Debug, Default)]
pub struct MemoryDefaults {
    numbers: BTreeMap<String, f64>,
    flags: BTreeMap<String, bool>,
    strings: BTreeMap<String, String>,
    integers: BTreeMap<String, i64>,
    lists: BTreeMap<String, Vec<String>>,
    blobs: BTreeMap<String, Vec<u8>>,
}

impl UiDefaults for MemoryDefaults {
    fn string(&self, key: &str) -> Option<String> {
        self.strings.get(key).cloned()
    }
    fn integer(&self, key: &str) -> Option<i64> {
        self.integers.get(key).copied()
    }
    fn string_array(&self, key: &str) -> Option<Vec<String>> {
        self.lists.get(key).cloned()
    }
    fn data(&self, key: &str) -> Option<Vec<u8>> {
        self.blobs.get(key).cloned()
    }
    fn set_string(&mut self, key: &str, value: &str) {
        self.strings.insert(key.to_string(), value.to_string());
    }
    fn set_integer(&mut self, key: &str, value: i64) {
        self.integers.insert(key.to_string(), value);
    }
    fn set_string_array(&mut self, key: &str, value: &[String]) {
        self.lists.insert(key.to_string(), value.to_vec());
    }
    fn set_data(&mut self, key: &str, value: &[u8]) {
        self.blobs.insert(key.to_string(), value.to_vec());
    }
    fn remove(&mut self, key: &str) {
        self.strings.remove(key);
        self.integers.remove(key);
        self.lists.remove(key);
        self.blobs.remove(key);
    }
}

impl sq_audiofx::monitor_gain::MonitorDefaults for MemoryDefaults {
    fn number(&self, key: &str) -> Option<f64> {
        self.numbers.get(key).copied()
    }
    fn flag(&self, key: &str) -> bool {
        self.flags.get(key).copied().unwrap_or(false)
    }
    fn set_number(&mut self, key: &str, value: f64) {
        self.numbers.insert(key.to_string(), value);
    }
    fn set_flag(&mut self, key: &str, value: bool) {
        self.flags.insert(key.to_string(), value);
    }
    fn store_id(&self) -> usize {
        std::ptr::from_ref(self) as usize
    }
}
