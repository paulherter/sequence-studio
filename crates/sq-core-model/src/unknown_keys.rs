//! Keys a file has that this build does not know. A newer build may write more keys on a project, sequence, clip or media
//! item; they are kept as read and written back, so saving with this build never drops a newer file's data.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// The unknown keys of one object, as the raw JSON values the file had.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct UnknownKeys(BTreeMap<String, Value>);

impl UnknownKeys {
    /// No unknown keys, usable in a `const`.
    pub const fn new() -> UnknownKeys {
        UnknownKeys(BTreeMap::new())
    }

    /// True when the object had no unknown key (the usual case: nothing is written).
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Keeps the entries of `object` that are not in `known`.
    pub fn from_object_except(object: &serde_json::Map<String, Value>, known: &[&str]) -> UnknownKeys {
        UnknownKeys(
            object.iter().filter(|(k, _)| !known.contains(&k.as_str())).map(|(k, v)| (k.clone(), v.clone())).collect(),
        )
    }

    /// Writes the entries into `object` (an entry the object already has is not replaced).
    pub fn put_into(&self, object: &mut serde_json::Map<String, Value>) {
        for (k, v) in &self.0 {
            object.entry(k.clone()).or_insert_with(|| v.clone());
        }
    }

    /// The raw value of `key`.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.0.get(key)
    }

    /// The key names.
    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.0.keys().map(String::as_str)
    }
}

/// What the file a project was read from holds that the typed model has no place for, as a sparse JSON tree built and
/// applied by `sq-core-file` (`decode` builds it, `encode` merges it back by object identity). It is a property of the
/// file, not of the project's content, so it never takes part in equality.
#[derive(Clone, Debug, Default)]
pub struct FileExtras(pub Option<std::sync::Arc<Value>>);

impl PartialEq for FileExtras {
    fn eq(&self, _: &FileExtras) -> bool {
        true
    }
}
