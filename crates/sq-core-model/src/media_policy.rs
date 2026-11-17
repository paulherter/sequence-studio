// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MediaPolicy.swift (saved types, moved down; folder sync and import disposition live in sq-core-project)

use serde::{Deserialize, Serialize};

/// What import does with a file outside the project folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OutsideMediaMode {
    /// Ask each time.
    Ask,
    /// Copy into the project.
    Copy,
    /// Move into the project.
    Move,
    /// Leave where it is.
    Leave,
}

/// Project media policy; every key is optional and `None` falls back to the app defaults.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaPolicy {
    /// What to do with files outside the project folder.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outside: Option<OutsideMediaMode>,
    /// Copy Library items into the project folder.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub copy_library_items: Option<bool>,
    /// Watch the project folder for new files.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub watch_folder: Option<bool>,
    /// Relative paths the folder sync skips.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ignored: Option<Vec<String>>,
}

/// App-wide defaults (Settings > Media) that a project's `MediaPolicy` overrides.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MediaPolicyDefaults {
    /// What to do with files outside the project folder.
    pub outside: OutsideMediaMode,
    /// Copy Library items into the project folder.
    pub copy_library_items: bool,
    /// Watch the project folder for new files.
    pub watch_folder: bool,
}

impl Default for MediaPolicyDefaults {
    fn default() -> MediaPolicyDefaults {
        MediaPolicyDefaults { outside: OutsideMediaMode::Ask, copy_library_items: true, watch_folder: true }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    #[test]
    fn defaults_ask_copy_and_watch() {
        let d = MediaPolicyDefaults::default();
        assert_eq!((d.outside, d.copy_library_items, d.watch_folder), (OutsideMediaMode::Ask, true, true));
    }

    #[test]
    fn round_trips_empty_and_full() {
        assert_round_trip::<MediaPolicy>(json!({}));
        assert_round_trip::<MediaPolicy>(json!({
            "outside": "copy", "copyLibraryItems": true, "watchFolder": false, "ignored": ["a/b.mov"]}));
    }
}
