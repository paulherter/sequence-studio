// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesPairEase.swift (ported by task M-3)

use crate::keyframes_editing::{KeyframeSummary, PropertyTrack, SummaryMember, by_property, each_track};
use crate::keyframes_premiere::KeyInterpolationChoice;
use sq_core_time::{EasingCurve, Id, Interpolation, KeyframeTrack, KeyframeValue};
use std::collections::BTreeSet;

/// Ease for a pair of adjacent selected keys: sets both sides of the segment in one go (out of the first key, in of
/// the second). `In` eases the arrival, `Out` the departure.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PairEase {
    /// Ease the arrival.
    In,
    /// Ease the departure.
    Out,
    /// Ease both.
    InOut,
}

impl PairEase {
    fn eases_out(self) -> bool {
        self != PairEase::In
    }

    fn eases_in(self) -> bool {
        self != PairEase::Out
    }
}

/// Pair ease on one track.
pub trait KeyframeTrackPairEase {
    /// True if two neighboring keys are both in `ids`.
    fn has_adjacent_pair(&self, ids: &BTreeSet<Id>) -> bool;

    /// Eases every segment whose two keys are both selected. Other keys are untouched. Returns segments changed.
    fn apply_pair_ease(&mut self, ease: PairEase, to: &BTreeSet<Id>) -> usize;

    /// Ids of selected keys that belong to an adjacent selected pair.
    fn paired_key_ids(&self, ids: &BTreeSet<Id>) -> BTreeSet<Id>;
}

impl<V: KeyframeValue> KeyframeTrackPairEase for KeyframeTrack<V> {
    fn has_adjacent_pair(&self, ids: &BTreeSet<Id>) -> bool {
        self.keys.windows(2).any(|w| ids.contains(&w[0].id) && ids.contains(&w[1].id))
    }

    fn apply_pair_ease(&mut self, ease: PairEase, to: &BTreeSet<Id>) -> usize {
        let flat = EasingCurve::ease_in_out().out_handle;
        self.edit_keys(|keys| {
            let mut n = 0;
            for i in 0..keys.len().saturating_sub(1) {
                if !(to.contains(&keys[i].id) && to.contains(&keys[i + 1].id)) {
                    continue;
                }
                // Only the side the ease targets is written; the other side keeps whatever it had.
                if ease.eases_out() {
                    keys[i].out_handle = flat;
                    if keys[i].interpolation == Interpolation::Linear {
                        // Hold stays Hold.
                        keys[i].interpolation = Interpolation::Bezier;
                    }
                }
                if ease.eases_in() {
                    keys[i + 1].in_handle = flat;
                }
                n += 1;
            }
            n
        })
    }

    fn paired_key_ids(&self, ids: &BTreeSet<Id>) -> BTreeSet<Id> {
        let mut out = BTreeSet::new();
        for w in self.keys.windows(2) {
            if ids.contains(&w[0].id) && ids.contains(&w[1].id) {
                out.insert(w[0].id);
                out.insert(w[1].id);
            }
        }
        out
    }
}

impl PropertyTrack {
    /// See `KeyframeTrackPairEase::has_adjacent_pair`.
    #[doc(hidden)]
    pub fn has_adjacent_pair(&self, ids: &BTreeSet<Id>) -> bool {
        each_track!(self, t => t.has_adjacent_pair(ids))
    }

    /// See `KeyframeTrackPairEase::paired_key_ids`.
    #[doc(hidden)]
    pub fn paired_key_ids(&self, ids: &BTreeSet<Id>) -> BTreeSet<Id> {
        each_track!(self, t => t.paired_key_ids(ids))
    }

    /// See `KeyframeTrackPairEase::apply_pair_ease`.
    #[doc(hidden)]
    pub fn apply_pair_ease(&mut self, ease: PairEase, to: &BTreeSet<Id>) -> usize {
        each_track!(self, t => t.apply_pair_ease(ease, to))
    }
}

impl KeyframeSummary {
    /// Whether any property holds two adjacent selected keys.
    pub fn has_adjacent_pair(&self, members: &BTreeSet<SummaryMember>) -> bool {
        by_property(members).iter().any(|(p, ids)| self.tracks.get(p).is_some_and(|t| t.has_adjacent_pair(ids)))
    }

    /// Pair ease on every property of the selection. Returns segments changed (0 = nothing adjacent selected).
    pub fn apply_pair_ease(&mut self, ease: PairEase, to: &BTreeSet<SummaryMember>) -> usize {
        let mut n = 0;
        for (p, ids) in by_property(to) {
            if let Some(t) = self.tracks.get_mut(&p) {
                n += t.apply_pair_ease(ease, &ids);
            }
        }
        n
    }

    /// Per property: keys in an adjacent selected pair get pair semantics (for Ease In / Out / In & Out); every
    /// other selected key gets the normal one-sided `choice` curve. Other choices apply as before.
    pub fn apply_choice(&mut self, choice: KeyInterpolationChoice, to: &BTreeSet<SummaryMember>) {
        for (p, ids) in by_property(to) {
            let Some(t) = self.tracks.get_mut(&p) else { continue };
            let mut rest = ids.clone();
            if let Some(pair) = choice.pair_ease() {
                let paired = t.paired_key_ids(&ids);
                if !paired.is_empty() {
                    t.apply_pair_ease(pair, &paired);
                    rest = rest.difference(&paired).copied().collect();
                }
            }
            if !rest.is_empty() {
                t.apply_choice(choice, &rest);
            }
        }
    }
}

impl KeyInterpolationChoice {
    /// The pair variant of the three ease entries (`None` for the others).
    pub fn pair_ease(self) -> Option<PairEase> {
        match self {
            KeyInterpolationChoice::EaseIn => Some(PairEase::In),
            KeyInterpolationChoice::EaseOut => Some(PairEase::Out),
            KeyInterpolationChoice::EasyEase => Some(PairEase::InOut),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keyframes_editing::test_support::{id, key, scalar};
    use std::collections::BTreeMap;

    fn ids(ns: &[u128]) -> BTreeSet<Id> {
        ns.iter().map(|&n| id(n)).collect()
    }

    fn three() -> KeyframeTrack<f64> {
        KeyframeTrack::with_keys(vec![key(1, 0, 0.0), key(2, 1, 1.0), key(3, 2, 2.0)])
    }

    #[test]
    fn pair_ease_writes_only_the_targeted_side_of_selected_pairs() {
        let flat = EasingCurve::ease_in_out().out_handle;
        let mut tr = three();
        assert!(tr.has_adjacent_pair(&ids(&[1, 2])));
        assert!(!tr.has_adjacent_pair(&ids(&[1, 3])));
        assert_eq!(tr.apply_pair_ease(PairEase::Out, &ids(&[1, 2])), 1);
        assert_eq!(tr.keys[0].out_handle, flat);
        assert_eq!(tr.keys[0].interpolation, Interpolation::Bezier);
        assert_eq!(tr.keys[1].in_handle, sq_core_time::EaseHandle::LINEAR);
        assert_eq!(tr.apply_pair_ease(PairEase::In, &ids(&[2, 3])), 1);
        assert_eq!(tr.keys[2].in_handle, flat);
        assert_eq!(tr.keys[1].out_handle, sq_core_time::EaseHandle::LINEAR);
        assert_eq!(tr.apply_pair_ease(PairEase::InOut, &ids(&[1, 3])), 0);
    }

    #[test]
    fn pair_ease_keeps_a_hold_a_hold() {
        let mut tr = three();
        tr.update(id(1), |k| k.interpolation = Interpolation::Hold);
        tr.apply_pair_ease(PairEase::InOut, &ids(&[1, 2]));
        assert_eq!(tr.keys[0].interpolation, Interpolation::Hold);
    }

    #[test]
    fn paired_key_ids_lists_only_keys_in_a_pair() {
        assert_eq!(three().paired_key_ids(&ids(&[1, 2, 9])), ids(&[1, 2]));
    }

    #[test]
    fn summary_choice_uses_pair_semantics_for_pairs_and_one_sided_curves_for_the_rest() {
        let mut s = KeyframeSummary::new(BTreeMap::from([(
            "a".into(),
            scalar(vec![key(1, 0, 0.0), key(2, 1, 1.0), key(3, 2, 2.0), key(4, 3, 3.0)]),
        )]));
        let members: BTreeSet<_> = [1, 2, 4].iter().map(|&n| SummaryMember::new("a".into(), id(n))).collect();
        assert!(s.has_adjacent_pair(&members));
        s.apply_choice(KeyInterpolationChoice::EasyEase, &members);
        let Some(PropertyTrack::Scalar(t)) = s.tracks.get(&"a".into()) else { panic!("track") };
        let flat = EasingCurve::ease_in_out().out_handle;
        // Pair 1-2: out of key 1 and in of key 2. Key 4 alone: the one-sided Smooth curve, both sides.
        assert_eq!((t.keys[0].out_handle, t.keys[1].in_handle), (flat, flat));
        assert_eq!(t.keys[3].in_handle, EasingCurve::ease_in_out().in_handle);
        assert_eq!(t.keys[2].in_handle, sq_core_time::EaseHandle::LINEAR);
    }
}
