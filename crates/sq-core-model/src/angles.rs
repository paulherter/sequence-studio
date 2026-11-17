// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Angles.swift (saved types, moved down; setup and playback logic: task M-4/M-5)

use crate::TrackKind;
use serde::{Deserialize, Serialize};

fn is_false(b: &bool) -> bool {
    !*b
}

/// Which angle an Angles clip piece plays.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AngleChoice {
    /// Zero-based angle number.
    pub index: i64,
    /// Sound follows the picture's angle; written only when true.
    #[serde(default, skip_serializing_if = "is_false")]
    pub follows_video: bool,
}

/// Angles of an Angles sequence: what a new Angles clip starts with.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AnglesSetup {
    /// The angle whose sound a new Angles clip uses (ignored with `audio_follows_video`).
    pub audio_angle: i64,
    /// Audio Follows Video for a new Angles clip.
    pub audio_follows_video: bool,
}

impl AnglesSetup {
    /// The choice a freshly placed clip of `kind` starts with: picture on angle 1, sound on the chosen angle.
    pub fn first_choice(&self, kind: TrackKind) -> AngleChoice {
        if kind == TrackKind::Video {
            AngleChoice { index: 0, follows_video: false }
        } else {
            AngleChoice {
                index: if self.audio_follows_video { 0 } else { self.audio_angle },
                follows_video: self.audio_follows_video,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    #[test]
    fn choice_writes_follows_video_only_when_true() {
        assert_round_trip::<AngleChoice>(json!({"index": 2}));
        assert_round_trip::<AngleChoice>(json!({"index": 2, "followsVideo": true}));
        let c: AngleChoice = serde_json::from_value(json!({"index": 1, "followsVideo": false})).unwrap();
        assert_eq!(serde_json::to_value(c).unwrap(), json!({"index": 1}));
    }

    #[test]
    fn setup_round_trips() {
        assert_round_trip::<AnglesSetup>(json!({"audioAngle": 1, "audioFollowsVideo": false}));
    }
}
