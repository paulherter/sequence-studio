// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: DeliveryTarget.swift (saved types, moved down; safe zones and Project edit: later tasks)

use serde::{Deserialize, Serialize};

/// Where a sequence is delivered.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DeliveryPlatform {
    /// TikTok.
    Tiktok,
    /// Instagram Reels.
    Reels,
    /// YouTube Shorts.
    Shorts,
    /// Square or portrait feed posts.
    SocialFeed,
    /// YouTube.
    Youtube,
}

// Both loudness groups of Swift (`vertical`, `horizontal`) use the Dialogue target (`AudioTag.dialogue.targetLUFS`)
// and -1 dB true peak, so a missing key reads the same for every platform.
fn default_target_lufs() -> f64 {
    -14.0
}

fn default_true_peak_db() -> f64 {
    -1.0
}

/// Platform and loudness target a sequence is made for.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeliveryTarget {
    /// The platform.
    pub platform: DeliveryPlatform,
    /// Integrated loudness target in LUFS.
    #[serde(rename = "targetLUFS", default = "default_target_lufs")]
    pub target_lufs: f64,
    /// True-peak ceiling in dB.
    #[serde(rename = "truePeakDB", default = "default_true_peak_db")]
    pub true_peak_db: f64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    #[test]
    fn round_trips() {
        assert_round_trip::<DeliveryTarget>(json!({"platform": "socialFeed", "targetLUFS": -16.0, "truePeakDB": -2.0}));
    }

    #[test]
    fn missing_levels_read_as_the_platform_default() {
        let t: DeliveryTarget = serde_json::from_value(json!({"platform": "youtube"})).unwrap();
        assert_eq!((t.target_lufs, t.true_peak_db), (-14.0, -1.0));
    }
}
