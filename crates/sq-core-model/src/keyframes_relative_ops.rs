// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesRelativeOps.swift (ported by task M-3)

use crate::keyframes_editing::{PropertyTrack, each_track};
use sq_core_time::{Id, IdSource, KeyframeTrack, KeyframeValue, Time};
use std::collections::BTreeSet;

/// Scale of selected scalar keys.
pub trait ScalarKeyScaling {
    /// Scales the values of the selected keys about `pivot` (value space) by `factor`.
    /// Returns false when no selected key belongs to this track.
    fn scale_values(&mut self, ids: &BTreeSet<Id>, factor: f64, pivot: f64) -> bool;

    /// Scales about the mean of the selected values, so a group of keys keeps its center and grows or shrinks.
    fn scale_values_about_mean(&mut self, ids: &BTreeSet<Id>, factor: f64) -> bool;
}

impl ScalarKeyScaling for KeyframeTrack<f64> {
    fn scale_values(&mut self, ids: &BTreeSet<Id>, factor: f64, pivot: f64) -> bool {
        let targets: Vec<(Id, f64)> =
            self.keys.iter().filter(|k| ids.contains(&k.id)).map(|k| (k.id, k.value)).collect();
        if targets.is_empty() {
            return false;
        }
        for (id, value) in targets {
            self.set(id, pivot + (value - pivot) * factor);
        }
        true
    }

    fn scale_values_about_mean(&mut self, ids: &BTreeSet<Id>, factor: f64) -> bool {
        let values: Vec<f64> = self.keys.iter().filter(|k| ids.contains(&k.id)).map(|k| k.value).collect();
        if values.is_empty() {
            return false;
        }
        let mean = values.iter().fold(0.0, |a, v| a + v) / values.len() as f64;
        self.scale_values(ids, factor, mean)
    }
}

/// Duplicating selected keys in time.
pub trait KeyDuplication {
    /// Copies the selected keys `offset` later (earlier when negative) with fresh ids and the same easing. A copy
    /// landing on a time held by another key replaces that key. Returns the ids of the copies.
    fn duplicate_keys(&mut self, ids: &BTreeSet<Id>, offset: Time, src: &mut dyn IdSource) -> BTreeSet<Id>;
}

impl<V: KeyframeValue> KeyDuplication for KeyframeTrack<V> {
    fn duplicate_keys(&mut self, ids: &BTreeSet<Id>, offset: Time, src: &mut dyn IdSource) -> BTreeSet<Id> {
        let copies: Vec<_> = self
            .keys
            .iter()
            .filter(|k| ids.contains(&k.id))
            .map(|k| {
                let mut c = k.clone();
                c.id = src.next_id();
                c.time = k.time + offset;
                c
            })
            .collect();
        let made = copies.iter().map(|c| c.id).collect();
        for c in copies {
            self.insert(c);
        }
        made
    }
}

impl PropertyTrack {
    /// `KeyDuplication::duplicate_keys` for any value type.
    pub fn duplicate_keys(&mut self, ids: &BTreeSet<Id>, offset: Time, src: &mut dyn IdSource) -> BTreeSet<Id> {
        each_track!(self, t => t.duplicate_keys(ids, offset, src))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keyframes_editing::test_support::{FreshIds, id, key, t};

    fn ids(ns: &[u128]) -> BTreeSet<Id> {
        ns.iter().map(|&n| id(n)).collect()
    }

    #[test]
    fn scale_values_about_a_pivot_and_about_the_mean() {
        let mut tr = KeyframeTrack::with_keys(vec![key(1, 0, 10.0), key(2, 1, 20.0), key(3, 2, 99.0)]);
        assert!(tr.scale_values(&ids(&[1, 2]), 2.0, 0.0));
        assert_eq!(tr.keys.iter().map(|k| k.value).collect::<Vec<_>>(), vec![20.0, 40.0, 99.0]);
        // Mean of 20 and 40 is 30: both move away from it, the mean stays.
        assert!(tr.scale_values_about_mean(&ids(&[1, 2]), 0.5));
        assert_eq!(tr.keys.iter().map(|k| k.value).collect::<Vec<_>>(), vec![25.0, 35.0, 99.0]);
        assert!(!tr.scale_values(&ids(&[9]), 2.0, 0.0));
        assert!(!tr.scale_values_about_mean(&BTreeSet::new(), 2.0));
    }

    #[test]
    fn duplicate_keys_makes_copies_with_new_ids_and_replaces_on_collision() {
        let mut tr = KeyframeTrack::with_keys(vec![key(1, 0, 1.0), key(2, 5, 2.0)]);
        let copies = tr.duplicate_keys(&ids(&[1]), t(5), &mut FreshIds::new());
        assert_eq!(copies.len(), 1);
        assert_eq!(tr.keys.len(), 2);
        // The copy at 5 replaced the original key 2.
        assert_eq!(tr.keys[1].value, 1.0);
        assert!(copies.contains(&tr.keys[1].id));
    }
}
