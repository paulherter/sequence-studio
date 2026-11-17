// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Marker.swift (saved types, moved down; filled by task S-2)

use serde::{Deserialize, Serialize};
use sq_core_time::{Id, Time};

/// Marker colors.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MarkerColor {
    /// Green, the default.
    #[default]
    Green,
    /// Red.
    Red,
    /// Purple.
    Purple,
    /// Orange.
    Orange,
    /// Yellow.
    Yellow,
    /// White.
    White,
    /// Blue.
    Blue,
    /// Cyan.
    Cyan,
}

/// `Time.zero` as a serde default.
pub(crate) fn zero_time() -> Time {
    Time::ZERO
}

/// A sequence, clip or source marker. Files written before color, comment and duration existed read with defaults.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Marker {
    /// Identity.
    pub id: Id,
    /// Position.
    pub time: Time,
    /// Shown name.
    #[serde(default)]
    pub name: String,
    /// Marker color.
    #[serde(default)]
    pub color: MarkerColor,
    /// Free text.
    #[serde(default)]
    pub comment: String,
    /// Zero = a point marker.
    #[serde(default = "zero_time")]
    pub duration: Time,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    #[test]
    fn full_marker_round_trips() {
        assert_round_trip::<Marker>(json!({
            "id": "00000000-0000-0000-0000-000000000001", "time": {"value": 3, "timescale": 2}, "name": "A",
            "color": "cyan", "comment": "c", "duration": {"value": 1, "timescale": 1}}));
    }

    #[test]
    fn old_marker_without_color_comment_duration_reads_with_defaults() {
        let m: Marker = serde_json::from_value(json!({
            "id": "00000000-0000-0000-0000-000000000001", "time": {"value": 3, "timescale": 2}}))
        .unwrap();
        assert_eq!(
            (m.name.as_str(), m.color, m.comment.as_str(), m.duration),
            ("", MarkerColor::Green, "", Time::ZERO)
        );
    }
}
