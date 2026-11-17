// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Grouping.swift (saved type, moved down; make, ungroup and expand logic: later tasks)

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sq_core_time::Id;
use std::collections::BTreeMap;

/// Set on a sequence that is the inside of a Group: which outer track each inner track came from.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineGroup {
    /// Inner track id to source track id. Swift writes a dictionary with `UUID` keys as a flat array
    /// `[key, value, key, value, ...]`.
    #[serde(with = "id_pairs")]
    pub source_tracks: BTreeMap<Id, Id>,
}

/// Swift's coding of `[UUID: UUID]`: a flat array of alternating keys and values.
mod id_pairs {
    use super::*;

    pub(super) fn serialize<S: Serializer>(map: &BTreeMap<Id, Id>, s: S) -> Result<S::Ok, S::Error> {
        s.collect_seq(map.iter().flat_map(|(k, v)| [k, v]))
    }

    pub(super) fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<BTreeMap<Id, Id>, D::Error> {
        let flat = Vec::<Id>::deserialize(d)?;
        let (pairs, rest) = flat.as_chunks::<2>();
        if !rest.is_empty() {
            return Err(serde::de::Error::custom("odd number of items in a UUID dictionary"));
        }
        Ok(pairs.iter().map(|[k, v]| (*k, *v)).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    #[test]
    fn source_tracks_use_swifts_flat_pair_array() {
        assert_round_trip::<TimelineGroup>(json!({"sourceTracks": [
            "00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002",
            "00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000004"]}));
        assert_round_trip::<TimelineGroup>(json!({"sourceTracks": []}));
    }

    #[test]
    fn odd_pair_array_is_an_error() {
        let odd = json!({"sourceTracks": ["00000000-0000-0000-0000-000000000001"]});
        assert!(serde_json::from_value::<TimelineGroup>(odd).is_err());
    }
}
