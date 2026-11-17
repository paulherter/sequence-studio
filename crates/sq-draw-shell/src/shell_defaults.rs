// Swift: UserDefaults.standard, as the shell dialogs use it
//! The settings store a [`crate::ShellHost`] starts with (Swift `UserDefaults.standard`): in memory until the app injects
//! the real one through `ShellHost::defaults`.

use sq_uikit::appearance_palette::UiDefaults;
use std::collections::BTreeMap;

#[derive(Clone, Debug)]
enum Stored {
    Str(String),
    Int(i64),
    List(Vec<String>),
    Bytes(Vec<u8>),
}

/// Settings kept in memory only.
#[derive(Clone, Debug, Default)]
pub struct ShellDefaults(BTreeMap<String, Stored>);

impl UiDefaults for ShellDefaults {
    fn string(&self, key: &str) -> Option<String> {
        match self.0.get(key) {
            Some(Stored::Str(s)) => Some(s.clone()),
            _ => None,
        }
    }
    fn integer(&self, key: &str) -> Option<i64> {
        match self.0.get(key) {
            Some(Stored::Int(n)) => Some(*n),
            _ => None,
        }
    }
    fn string_array(&self, key: &str) -> Option<Vec<String>> {
        match self.0.get(key) {
            Some(Stored::List(l)) => Some(l.clone()),
            _ => None,
        }
    }
    fn data(&self, key: &str) -> Option<Vec<u8>> {
        match self.0.get(key) {
            Some(Stored::Bytes(b)) => Some(b.clone()),
            _ => None,
        }
    }
    fn set_string(&mut self, key: &str, value: &str) {
        self.0.insert(key.to_string(), Stored::Str(value.to_string()));
    }
    fn set_integer(&mut self, key: &str, value: i64) {
        self.0.insert(key.to_string(), Stored::Int(value));
    }
    fn set_string_array(&mut self, key: &str, value: &[String]) {
        self.0.insert(key.to_string(), Stored::List(value.to_vec()));
    }
    fn set_data(&mut self, key: &str, value: &[u8]) {
        self.0.insert(key.to_string(), Stored::Bytes(value.to_vec()));
    }
    fn remove(&mut self, key: &str) {
        self.0.remove(key);
    }
}
