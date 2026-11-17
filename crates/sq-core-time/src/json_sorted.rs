// SPDX-License-Identifier: GPL-3.0-or-later
//! JSON values with sorted object keys.
//!
//! serde_json's `Value` sorts keys only while its `preserve_order` feature is off. Cargo turns that feature on for the
//! whole build as soon as one crate asks for it (`telemetry-parser`, through the Gyroflow engine), so files written
//! through `to_value` would change their key order between a crate test and the app. Every writer whose bytes must be
//! stable (project files, presets, templates) goes through [`to_value`] instead.

use serde::Serialize;
use serde_json::Value;

/// `serde_json::to_value(value)` with every object's keys in alphabetical order.
pub fn to_value<T: Serialize>(value: T) -> Result<Value, serde_json::Error> {
    serde_json::to_value(value).map(sorted)
}

/// `value` with every object's keys in alphabetical order.
pub fn sorted(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut entries: Vec<(String, Value)> = map.into_iter().collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            Value::Object(entries.into_iter().map(|(k, v)| (k, sorted(v))).collect())
        }
        Value::Array(items) => Value::Array(items.into_iter().map(sorted).collect()),
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_are_sorted_at_every_depth() {
        let v = serde_json::json!({"b": {"z": 1, "a": [{"y": 1, "x": 2}]}, "a": 0});
        let text = serde_json::to_string(&sorted(v)).unwrap_or_default();
        assert_eq!(text, r#"{"a":0,"b":{"a":[{"x":2,"y":1}],"z":1}}"#);
    }
}
