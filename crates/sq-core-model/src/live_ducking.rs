// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: LiveDucking.swift (saved types, moved down; the ducking engine, presets and preferences: later tasks)

use serde::{Deserialize, Serialize};

/// Attack, hold and recovery of live ducking, in milliseconds.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DuckTiming {
    /// Look-ahead before speech starts.
    pub lookahead_ms: f64,
    /// Time to reach the ducked level.
    pub attack_ms: f64,
    /// Time the level is held after speech stops.
    pub hold_ms: f64,
    /// Time to come back up.
    pub recovery_ms: f64,
    /// Shortest pause that lets the level come back.
    pub min_pause_ms: f64,
}

/// Project-wide live ducking settings.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectLiveDucking {
    /// Switched on.
    pub is_on: bool,
    /// Amount in dB.
    #[serde(rename = "amountDB")]
    pub amount_db: f64,
    /// Timing; `None` = classic.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timing: Option<DuckTiming>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    #[test]
    fn round_trips_without_and_with_timing() {
        assert_round_trip::<ProjectLiveDucking>(json!({"isOn": true, "amountDB": 12.5}));
        assert_round_trip::<ProjectLiveDucking>(json!({
            "isOn": false, "amountDB": 9.0, "timing": {"lookaheadMs": 15.0, "attackMs": 10.0, "holdMs": 150.0,
                                                          "recoveryMs": 750.0, "minPauseMs": 0.0}}));
    }
}
