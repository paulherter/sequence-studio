// Swift: UserDefaults bool keys of the inspector sections (`sq.inspector.open.*`, `sq.textBlock.open.*`)
//! The open or folded state of inspector sections, remembered between launches in the injected settings store.

use sq_uikit::appearance_palette::UiDefaults;

/// The stored open state of `key`; `None` when the key was never written.
pub fn read_open(d: &dyn UiDefaults, key: &str) -> Option<bool> {
    d.integer(key).map(|v| v != 0)
}

/// Stores the open state of `key` (a Swift `Bool`, kept as 0 / 1).
pub fn write_open(d: &mut dyn UiDefaults, key: &str, open: bool) {
    d.set_integer(key, i64::from(open));
}

/// A settings store two panels can share in tests, like one `UserDefaults.standard`.
#[cfg(test)]
#[derive(Clone, Default)]
pub(crate) struct SharedDefaults(pub std::rc::Rc<std::cell::RefCell<std::collections::BTreeMap<String, i64>>>);

#[cfg(test)]
impl UiDefaults for SharedDefaults {
    fn string(&self, _: &str) -> Option<String> {
        None
    }
    fn integer(&self, key: &str) -> Option<i64> {
        self.0.borrow().get(key).copied()
    }
    fn string_array(&self, _: &str) -> Option<Vec<String>> {
        None
    }
    fn data(&self, _: &str) -> Option<Vec<u8>> {
        None
    }
    fn set_string(&mut self, _: &str, _: &str) {}
    fn set_integer(&mut self, key: &str, value: i64) {
        self.0.borrow_mut().insert(key.to_string(), value);
    }
    fn set_string_array(&mut self, _: &str, _: &[String]) {}
    fn set_data(&mut self, _: &str, _: &[u8]) {}
    fn remove(&mut self, key: &str) {
        self.0.borrow_mut().remove(key);
    }
}

/// One boxed settings store several parts of a panel read and write (the Swift `UserDefaults.standard`).
#[derive(Clone)]
pub struct SharedUiDefaults(std::rc::Rc<std::cell::RefCell<Box<dyn UiDefaults>>>);

impl SharedUiDefaults {
    /// Wraps `inner`; clone the handle for each part.
    pub fn new(inner: Box<dyn UiDefaults>) -> SharedUiDefaults {
        SharedUiDefaults(std::rc::Rc::new(std::cell::RefCell::new(inner)))
    }
}

impl UiDefaults for SharedUiDefaults {
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
