// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesSpringBake.swift (ported by task M-3)

use crate::keyframes_ease_selection::EaseSelection;
use crate::keyframes_editing::{KeyframeSummary, PropertyTrack, each_track};
use sq_core_time::{EaseHandle, Id, IdSource, Interpolation, KeyframeTrack, KeyframeValue, SpringEasing};

/// Samples per second of a baked spring.
const SAMPLES_PER_SECOND: i64 = 30;

/// Baking a spring into plain keys.
pub trait KeyframeSpringBake {
    /// Replaces the segment `a` -> `b` by linear keys sampling the spring (the file format has no spring). `a` and
    /// `b` keep their ids and values; `a` turns linear and both handles of the segment are reset so the baked keys
    /// are not reshaped. False when `a` and `b` are not neighbors.
    fn bake_spring(&mut self, spring: &SpringEasing, a: Id, b: Id, ids: &mut dyn IdSource) -> bool;
}

impl<V: KeyframeValue> KeyframeSpringBake for KeyframeTrack<V> {
    fn bake_spring(&mut self, spring: &SpringEasing, a: Id, b: Id, ids: &mut dyn IdSource) -> bool {
        let Some(i) = self.keys.iter().position(|k| k.id == a) else { return false };
        if i + 1 >= self.keys.len() || self.keys[i + 1].id != b {
            return false;
        }
        let (l, r) = (self.keys[i].clone(), self.keys[i + 1].clone());
        let baked = spring.baked_keys(ids, &l.value, &r.value, l.time, r.time, SAMPLES_PER_SECOND);
        self.update(a, |k| {
            k.interpolation = Interpolation::Linear;
            k.out_handle = EaseHandle::LINEAR;
        });
        self.update(b, |k| k.in_handle = EaseHandle::LINEAR);
        let inner = baked.len().saturating_sub(2);
        for k in baked.into_iter().skip(1).take(inner) {
            self.insert(k);
        }
        true
    }
}

impl PropertyTrack {
    /// See `KeyframeSpringBake::bake_spring`.
    #[doc(hidden)]
    pub fn bake_spring(&mut self, spring: &SpringEasing, a: Id, b: Id, ids: &mut dyn IdSource) -> bool {
        each_track!(self, t => t.bake_spring(spring, a, b, ids))
    }
}

impl EaseSelection {
    /// Bakes the spring into every selected segment. Returns segments baked.
    pub fn bake(&self, spring: &SpringEasing, summary: &mut KeyframeSummary, ids: &mut dyn IdSource) -> usize {
        let mut n = 0;
        for seg in self.segments() {
            if summary.tracks.get_mut(&seg.property).is_some_and(|t| t.bake_spring(spring, seg.from, seg.to, ids)) {
                n += 1;
            }
        }
        n
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keyframes_editing::SummaryMember;
    use crate::keyframes_editing::test_support::{FreshIds, key, scalar, t};
    use std::collections::{BTreeMap, BTreeSet};

    #[test]
    fn bake_replaces_a_segment_with_linear_keys_and_keeps_the_ends() {
        let mut tr = KeyframeTrack::with_keys(vec![key(1, 0, 0.0), key(2, 1, 10.0)]);
        tr.update(Id::from_u128(1), |k| k.interpolation = Interpolation::Bezier);
        let spring = SpringEasing::new(0.3);
        assert!(tr.bake_spring(&spring, Id::from_u128(1), Id::from_u128(2), &mut FreshIds::new()));
        assert!(tr.keys.len() > 3);
        assert_eq!(tr.keys[0].interpolation, Interpolation::Linear);
        assert_eq!((tr.keys[0].value, tr.keys[0].time), (0.0, t(0)));
        let last = &tr.keys[tr.keys.len() - 1];
        assert_eq!((last.id, last.value, last.time), (Id::from_u128(2), 10.0, t(1)));
        // Not neighbors, or unknown keys: nothing happens.
        assert!(!tr.bake_spring(&spring, Id::from_u128(2), Id::from_u128(1), &mut FreshIds::new()));
    }

    #[test]
    fn selection_bake_counts_segments() {
        let mut s = KeyframeSummary::new(BTreeMap::from([("a".into(), scalar(vec![key(1, 0, 0.0), key(2, 1, 1.0)]))]));
        let members = BTreeSet::from([
            SummaryMember::new("a".into(), Id::from_u128(1)),
            SummaryMember::new("a".into(), Id::from_u128(2)),
        ]);
        let sel = EaseSelection::new(&s, &members, &BTreeSet::new());
        assert_eq!(sel.bake(&SpringEasing::new(0.5), &mut s, &mut FreshIds::new()), 1);
    }
}
