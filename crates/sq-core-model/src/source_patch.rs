// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+SourcePatch.swift (saved types, moved down; patching verbs: later tasks)

use serde::{Deserialize, Serialize};
use sq_core_time::Id;

/// Where one source stream (video or audio) goes.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourcePatchSlot {
    /// The patched track; `None` means the first track of the kind.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track: Option<Id>,
    /// Off: this stream is not placed.
    pub is_connected: bool,
}

impl Default for SourcePatchSlot {
    fn default() -> Self {
        SourcePatchSlot { track: None, is_connected: true }
    }
}

/// The source patch of one sequence: a slot for the source video and one for the source audio.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SourcePatch {
    /// Source video.
    pub video: SourcePatchSlot,
    /// Source audio.
    pub audio: SourcePatchSlot,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    #[test]
    fn round_trips() {
        assert_round_trip::<SourcePatch>(json!({
            "video": {"track": "00000000-0000-0000-0000-000000000005", "isConnected": false},
            "audio": {"isConnected": true}}));
    }

    #[test]
    fn default_connects_both_streams_to_the_first_tracks() {
        let d = SourcePatch::default();
        assert!(d.video.is_connected && d.audio.is_connected && d.video.track.is_none());
    }
}
