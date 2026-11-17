//! Typed reads and writes over the `UiDefaults` store of sq-uikit (Swift `UserDefaults`), which only knows strings,
//! integers, lists and bytes. The mapping is fixed here so every ES10 file stores the same way:
//! a flag is the integer 0 / 1, a number with a fraction is its decimal text.

use sq_uikit::appearance_palette::UiDefaults;

/// `object(forKey:)`, `bool(forKey:)` and `double(forKey:)` on top of [`UiDefaults`].
pub trait DefaultsExt: UiDefaults {
    /// True when anything is stored under `key` (Swift `object(forKey:) != nil`).
    fn has(&self, key: &str) -> bool {
        self.integer(key).is_some()
            || self.string(key).is_some()
            || self.data(key).is_some()
            || self.string_array(key).is_some()
    }

    /// The stored flag; `None` when unset.
    fn flag(&self, key: &str) -> Option<bool> {
        self.integer(key).map(|v| v != 0)
    }

    /// The stored flag; false when unset (Swift `bool(forKey:)`).
    fn bool_value(&self, key: &str) -> bool {
        self.flag(key).unwrap_or(false)
    }

    /// The flag, or `default` when unset (Swift `object(forKey:) == nil ? default : bool(forKey:)`).
    fn bool_or(&self, key: &str, default: bool) -> bool {
        self.flag(key).unwrap_or(default)
    }

    /// Stores a flag.
    fn set_flag(&mut self, key: &str, value: bool) {
        self.set_integer(key, i64::from(value));
    }

    /// The stored number; `None` when unset or not a number.
    fn number(&self, key: &str) -> Option<f64> {
        match self.string(key) {
            Some(text) => text.trim().parse().ok(),
            None => self.integer(key).map(|v| v as f64),
        }
    }

    /// Stores a number.
    fn set_number(&mut self, key: &str, value: f64) {
        self.set_string(key, &value.to_string());
    }
}

impl<T: UiDefaults + ?Sized> DefaultsExt for T {}

/// An in-memory store for the tests of this group.
#[cfg(test)]
#[derive(Default)]
pub(crate) struct TestDefaults {
    strings: std::collections::BTreeMap<String, String>,
    integers: std::collections::BTreeMap<String, i64>,
    lists: std::collections::BTreeMap<String, Vec<String>>,
    blobs: std::collections::BTreeMap<String, Vec<u8>>,
}

#[cfg(test)]
impl UiDefaults for TestDefaults {
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
        self.remove(key);
        self.strings.insert(key.to_string(), value.to_string());
    }
    fn set_integer(&mut self, key: &str, value: i64) {
        self.remove(key);
        self.integers.insert(key.to_string(), value);
    }
    fn set_string_array(&mut self, key: &str, value: &[String]) {
        self.remove(key);
        self.lists.insert(key.to_string(), value.to_vec());
    }
    fn set_data(&mut self, key: &str, value: &[u8]) {
        self.remove(key);
        self.blobs.insert(key.to_string(), value.to_vec());
    }
    fn remove(&mut self, key: &str) {
        self.strings.remove(key);
        self.integers.remove(key);
        self.lists.remove(key);
        self.blobs.remove(key);
    }
}
