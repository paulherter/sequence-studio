// Helpers that reproduce the JSON Swift's synthesized Codable writes and reads.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize};

/// The payload of a Swift enum case with one unnamed associated value: `{"_0": value}`.
#[derive(Serialize, Deserialize)]
pub(crate) struct Wrap<T> {
    #[serde(rename = "_0")]
    pub v: T,
}

/// Swift `try? decodeIfPresent`: a value of the wrong type reads as absent.
pub(crate) fn lenient<'de, D, T>(d: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: DeserializeOwned,
{
    let v = Option::<serde_json::Value>::deserialize(d)?;
    Ok(v.and_then(|v| serde_json::from_value(v).ok()))
}

/// For `skip_serializing_if` on a stored-optional flag (key absent when false).
pub(crate) fn is_false(b: &bool) -> bool {
    !*b
}
