//! Fixtures of the unit tests: an in-memory settings store the panels share with the test.

use sq_uikit::appearance_palette::UiDefaults;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

#[derive(Default)]
struct Store {
    strings: BTreeMap<String, String>,
    integers: BTreeMap<String, i64>,
    lists: BTreeMap<String, Vec<String>>,
    blobs: BTreeMap<String, Vec<u8>>,
}

/// Settings in memory; clones share one store, so a test can read what a panel saved.
#[derive(Clone, Default)]
pub(crate) struct MemoryDefaults(Rc<RefCell<Store>>);

impl UiDefaults for MemoryDefaults {
    fn string(&self, key: &str) -> Option<String> {
        self.0.borrow().strings.get(key).cloned()
    }
    fn integer(&self, key: &str) -> Option<i64> {
        self.0.borrow().integers.get(key).copied()
    }
    fn string_array(&self, key: &str) -> Option<Vec<String>> {
        self.0.borrow().lists.get(key).cloned()
    }
    fn data(&self, key: &str) -> Option<Vec<u8>> {
        self.0.borrow().blobs.get(key).cloned()
    }
    fn set_string(&mut self, key: &str, value: &str) {
        self.0.borrow_mut().strings.insert(key.to_string(), value.to_string());
    }
    fn set_integer(&mut self, key: &str, value: i64) {
        self.0.borrow_mut().integers.insert(key.to_string(), value);
    }
    fn set_string_array(&mut self, key: &str, value: &[String]) {
        self.0.borrow_mut().lists.insert(key.to_string(), value.to_vec());
    }
    fn set_data(&mut self, key: &str, value: &[u8]) {
        self.0.borrow_mut().blobs.insert(key.to_string(), value.to_vec());
    }
    fn remove(&mut self, key: &str) {
        let mut s = self.0.borrow_mut();
        s.strings.remove(key);
        s.integers.remove(key);
        s.lists.remove(key);
        s.blobs.remove(key);
    }
}
