//! The stored defaults (Swift `UserDefaults`) as the shell reads and writes them. The app hands the shell its store in
//! [`ShellHost::settings`]; a write of the shell lands there and also leaves as [`ShellEvent::Setting`] so the app can
//! persist it. The store is the typed `UiDefaults` mirror; a flag is the integer 0 / 1, a list of numbers is comma
//! separated text, a list of paths is one path per line.

use crate::shell_host::{SettingValue, ShellEvent, ShellHost};
use sq_core_audio::live_ducking::DefaultsStore;
use sq_library::library_folder_store::SettingsStore;
use sq_uikit::appearance_palette::UiDefaults;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

/// The shell's store, shared with the adapters the session wants.
pub type SharedDefaults = Rc<RefCell<dyn UiDefaults>>;

/// A store in memory (the default of a host that has none, and the tests).
#[derive(Default)]
pub struct MemoryDefaults {
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

/// The typed `UiDefaults` handle of the shell's shared store (`ShellHost::defaults`): the dialogs that read and write
/// `UserDefaults` directly and the setting helpers see one store.
// shortcut: writes through this handle do not emit `ShellEvent::Setting`; only `store_setting` tells the app. Upgrade: emit here once the app persists from events only.
pub struct SharedView(pub SharedDefaults);

impl UiDefaults for SharedView {
    fn string(&self, key: &str) -> Option<String> {
        self.0.borrow().string(key)
    }
    fn integer(&self, key: &str) -> Option<i64> {
        self.0.borrow().integer(key)
    }
    fn string_array(&self, key: &str) -> Option<Vec<String>> {
        self.0.borrow().string_array(key)
    }
    fn data(&self, key: &str) -> Option<Vec<u8>> {
        self.0.borrow().data(key)
    }
    fn set_string(&mut self, key: &str, value: &str) {
        self.0.borrow_mut().set_string(key, value);
    }
    fn set_integer(&mut self, key: &str, value: i64) {
        self.0.borrow_mut().set_integer(key, value);
    }
    fn set_string_array(&mut self, key: &str, value: &[String]) {
        self.0.borrow_mut().set_string_array(key, value);
    }
    fn set_data(&mut self, key: &str, value: &[u8]) {
        self.0.borrow_mut().set_data(key, value);
    }
    fn remove(&mut self, key: &str) {
        self.0.borrow_mut().remove(key);
    }
}

/// The store as the `SettingsStore` of the library and the session (Jump Cut overlap, Quick Apply recents). Those read
/// numbers as UTF-8 text, so an integer or a string under the key answers as its text.
pub struct BytesView(pub SharedDefaults);

impl SettingsStore for BytesView {
    fn data(&self, key: &str) -> Option<Vec<u8>> {
        let d = self.0.borrow();
        d.data(key)
            .or_else(|| d.string(key).map(String::into_bytes))
            .or_else(|| d.integer(key).map(|n| n.to_string().into_bytes()))
    }
    fn set_data(&mut self, key: &str, value: Vec<u8>) {
        self.0.borrow_mut().set_data(key, &value);
    }
    fn remove(&mut self, key: &str) {
        self.0.borrow_mut().remove(key);
    }
}

/// The store as the `DefaultsStore` of Live Ducking (a number is decimal text, or an integer).
pub struct NumbersView(pub SharedDefaults);

impl DefaultsStore for NumbersView {
    fn number(&self, key: &str) -> Option<f64> {
        let d = self.0.borrow();
        match d.string(key) {
            Some(text) => text.trim().parse().ok(),
            None => d.integer(key).map(|v| v as f64),
        }
    }
    fn set_number(&mut self, key: &str, value: f64) {
        self.0.borrow_mut().set_string(key, &value.to_string());
    }
    fn remove(&mut self, key: &str) {
        self.0.borrow_mut().remove(key);
    }
}

impl ShellHost {
    /// `defaults.set(value, forKey: key)`: kept in the store and handed to the app.
    pub(crate) fn store_setting(&mut self, key: &str, value: SettingValue) {
        match &value {
            SettingValue::Text(t) => self.settings.borrow_mut().set_string(key, t),
            SettingValue::Flag(f) => self.settings.borrow_mut().set_integer(key, i64::from(*f)),
        }
        self.emit(ShellEvent::Setting { key: key.to_string(), value });
    }

    /// `defaults.string(forKey:)`.
    pub(crate) fn setting_string(&self, key: &str) -> Option<String> {
        // shortcut: reads the host store first, then `flow_env.settings` (audio/analysis/anonymize flows still write there).
        // Upgrade: one store once the app loads only the host store.
        self.settings.borrow().string(key).or_else(|| String::from_utf8(self.flow_env.settings.data(key)?).ok())
    }

    /// `defaults.bool(forKey:)`: false when unset.
    pub(crate) fn setting_flag(&self, key: &str) -> bool {
        self.settings.borrow().integer(key).is_some_and(|v| v != 0)
    }

    /// `defaults.array(forKey:) as? [Double]`: comma separated text.
    pub(crate) fn setting_numbers(&self, key: &str) -> Option<Vec<f64>> {
        let text = self.setting_string(key)?;
        if text.is_empty() {
            return Some(Vec::new());
        }
        text.split(',').map(|p| p.trim().parse::<f64>().ok()).collect()
    }

    /// The `SettingsStore` view of the shell's store.
    pub(crate) fn bytes_view(&self) -> BytesView {
        BytesView(Rc::clone(&self.settings))
    }
}

/// The text form of a list of numbers ([`ShellHost::setting_numbers`] reads it back).
pub(crate) fn numbers_text(values: &[f64]) -> String {
    values.iter().map(|v| v.to_string()).collect::<Vec<_>>().join(",")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shared() -> SharedDefaults {
        Rc::new(RefCell::new(MemoryDefaults::default()))
    }

    #[test]
    fn numbers_round_trip_through_the_text_form() {
        let mut h = test_host();
        h.store_setting("k", SettingValue::Text(numbers_text(&[115.0, 130.5])));
        assert_eq!(h.setting_numbers("k"), Some(vec![115.0, 130.5]));
        h.store_setting("e", SettingValue::Text(String::new()));
        assert_eq!(h.setting_numbers("e"), Some(Vec::new()));
        assert_eq!(h.setting_numbers("none"), None);
    }

    #[test]
    fn a_flag_is_stored_and_announced() {
        let mut h = test_host();
        assert!(!h.setting_flag("b"));
        h.store_setting("b", SettingValue::Flag(true));
        assert!(h.setting_flag("b"));
        assert!(h.take_events().contains(&ShellEvent::Setting { key: "b".into(), value: SettingValue::Flag(true) }));
    }

    #[test]
    fn the_bytes_view_answers_integers_and_strings_as_text() {
        let d = shared();
        d.borrow_mut().set_integer("n", 12);
        d.borrow_mut().set_string("s", "x");
        let v = BytesView(Rc::clone(&d));
        assert_eq!(v.data("n"), Some(b"12".to_vec()));
        assert_eq!(v.data("s"), Some(b"x".to_vec()));
        assert_eq!(NumbersView(d).number("n"), Some(12.0));
    }

    fn test_host() -> ShellHost {
        crate::test_support::shell()
    }
}
