// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesEditing.swift (ported by task M-3)

use crate::{EffectColor, MaskPath};
use serde::{Deserialize, Serialize};
use sq_core_time::{EaseSide, EasingCurve, Id, Interpolation, KeyframeTrack, KeyframeValue, Time, Vec2};
use std::collections::{BTreeMap, BTreeSet};
use std::ops::RangeInclusive;

/// Runs `$body` with `$t` bound to the track of any `PropertyTrack` variant (Swift's four-way `switch self`).
macro_rules! each_track {
    ($track:expr, $t:ident => $body:expr) => {
        match $track {
            $crate::keyframes_editing::PropertyTrack::Scalar($t) => $body,
            $crate::keyframes_editing::PropertyTrack::Vector($t) => $body,
            $crate::keyframes_editing::PropertyTrack::Color($t) => $body,
            $crate::keyframes_editing::PropertyTrack::Path($t) => $body,
        }
    };
}
pub(crate) use each_track;

/// Relative multi-key editing on one track (UX.md delta rule).
pub trait KeyframeTrackEditing<V> {
    /// The property now shows `v` at `t`. Reference is the selected key's value if one sits at `t`, else the
    /// interpolated value. Every selected key of this track moves by `v - reference`. Returns false (nothing
    /// changed) when no selected key belongs to this track.
    fn set_value(&mut self, v: &V, at: Time, selected: &BTreeSet<Id>) -> bool;

    /// Moves the keys by exactly `delta` and re-sorts. The caller keeps them off the time of a non-selected key
    /// (`KeyframeSummary::move_key`); if one lands there anyway, the moved key wins.
    fn move_keys(&mut self, ids: &BTreeSet<Id>, by: Time);
}

impl<V: KeyframeValue> KeyframeTrackEditing<V> for KeyframeTrack<V> {
    fn set_value(&mut self, v: &V, at: Time, selected: &BTreeSet<Id>) -> bool {
        let targets: Vec<(Id, Time, V)> =
            self.keys.iter().filter(|k| selected.contains(&k.id)).map(|k| (k.id, k.time, k.value.clone())).collect();
        if targets.is_empty() {
            return false;
        }
        let reference = targets
            .iter()
            .find(|k| k.1 == at)
            .map(|k| k.2.clone())
            .or_else(|| self.value(at))
            .unwrap_or_else(|| v.clone());
        let delta = V::minus(v, &reference);
        for (id, _, value) in &targets {
            self.set(*id, V::plus(value, &delta));
        }
        true
    }

    fn move_keys(&mut self, ids: &BTreeSet<Id>, by: Time) {
        let moving: Vec<_> = self
            .keys
            .iter()
            .filter(|k| ids.contains(&k.id))
            .map(|k| {
                let mut m = k.clone();
                m.time = k.time + by;
                m
            })
            .collect();
        let landing: BTreeSet<Time> = moving.iter().map(|m| m.time).collect();
        self.keys.retain(|k| !ids.contains(&k.id) && !landing.contains(&k.time));
        for m in moving {
            self.insert(m);
        }
    }
}

/// The name of an animated property (`"opacity"`, an effect parameter key, ...).
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PropertyID(pub String);

impl PropertyID {
    /// An id from its raw text.
    pub fn new(raw: &str) -> PropertyID {
        PropertyID(raw.to_string())
    }
}

impl From<&str> for PropertyID {
    fn from(raw: &str) -> PropertyID {
        PropertyID::new(raw)
    }
}

/// A track of any supported value type.
#[derive(Clone, Debug, PartialEq)]
pub enum PropertyTrack {
    /// A number.
    Scalar(KeyframeTrack<f64>),
    /// A point or pair.
    Vector(KeyframeTrack<Vec2>),
    /// Effect color parameter (v24).
    Color(KeyframeTrack<EffectColor>),
    /// A mask's Path (whole shape per key). Moves, eases, holds, copies like the others; it has no value or speed graph.
    Path(KeyframeTrack<MaskPath>),
}

impl PropertyTrack {
    /// Ids of all keys in time order.
    pub fn key_ids(&self) -> Vec<Id> {
        each_track!(self, t => t.keys.iter().map(|k| k.id).collect())
    }

    /// The keys a lane shows and navigation steps through: `(id, time)` in time order.
    pub fn times(&self) -> Vec<(Id, Time)> {
        each_track!(self, t => t.keys.iter().map(|k| (k.id, k.time)).collect())
    }

    /// Interpolation of one key (`None` when the id is not on this track).
    pub fn interpolation_of(&self, id: Id) -> Option<Interpolation> {
        each_track!(self, t => t.key(id).map(|k| k.interpolation))
    }

    /// Applies `curve` to the given keys.
    pub fn apply(&mut self, curve: &EasingCurve, to: &BTreeSet<Id>, side: EaseSide) {
        each_track!(self, t => t.apply(curve, to, side))
    }

    /// Toggles hold on the given keys.
    pub fn toggle_hold(&mut self, ids: &BTreeSet<Id>) {
        each_track!(self, t => t.toggle_hold(ids, &BTreeMap::new()))
    }

    /// `KeyframeTrackEditing::set_value` for a scalar track; false for any other type.
    pub fn set_scalar(&mut self, v: f64, at: Time, selected: &BTreeSet<Id>) -> bool {
        match self {
            PropertyTrack::Scalar(t) => t.set_value(&v, at, selected),
            _ => false,
        }
    }

    /// `KeyframeTrackEditing::set_value` for a vector track; false for any other type.
    pub fn set_vector(&mut self, v: Vec2, at: Time, selected: &BTreeSet<Id>) -> bool {
        match self {
            PropertyTrack::Vector(t) => t.set_value(&v, at, selected),
            _ => false,
        }
    }

    /// `KeyframeTrackEditing::move_keys` for any value type.
    #[doc(hidden)]
    pub fn move_keys(&mut self, ids: &BTreeSet<Id>, by: Time) {
        each_track!(self, t => t.move_keys(ids, by))
    }

    /// Sets or clears hold on the given keys (`kinds`: which hold a key that becomes one again was before it left).
    #[doc(hidden)]
    pub fn set_hold(&mut self, ids: &BTreeSet<Id>, hold: bool, kinds: &BTreeMap<Id, Interpolation>) {
        each_track!(self, t => t.set_hold(ids, hold, kinds))
    }

    /// Makes the given keys exactly `kind` (Hold or Hold Ahead).
    #[doc(hidden)]
    pub fn set_hold_kind(&mut self, kind: Interpolation, ids: &BTreeSet<Id>) {
        each_track!(self, t => t.set_hold_kind(kind, ids))
    }

    /// True if every given key is hold (and at least no key is non-hold).
    #[doc(hidden)]
    pub fn hold_state(&self, ids: &BTreeSet<Id>) -> bool {
        self.times()
            .iter()
            .filter(|(id, _)| ids.contains(id))
            .all(|(id, _)| self.interpolation_of(*id).is_some_and(Interpolation::is_hold))
    }
}

/// One key of one property in a summary row.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SummaryMember {
    /// The property.
    pub property: PropertyID,
    /// The key on that property's track.
    pub key_id: Id,
}

impl SummaryMember {
    /// A member.
    pub fn new(property: PropertyID, key_id: Id) -> SummaryMember {
        SummaryMember { property, key_id }
    }
}

/// All keys of several properties sharing one time.
#[derive(Clone, Debug, PartialEq)]
pub struct SummaryKey {
    /// The shared time.
    pub time: Time,
    /// The keys at that time.
    pub members: BTreeSet<SummaryMember>,
}

/// Collapsed-row view over the tracks of a group or effect.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct KeyframeSummary {
    /// The tracks by property.
    pub tracks: BTreeMap<PropertyID, PropertyTrack>,
}

/// The ids of `members` per property.
pub(crate) fn by_property(members: &BTreeSet<SummaryMember>) -> BTreeMap<PropertyID, BTreeSet<Id>> {
    let mut out: BTreeMap<PropertyID, BTreeSet<Id>> = BTreeMap::new();
    for m in members {
        out.entry(m.property.clone()).or_default().insert(m.key_id);
    }
    out
}

impl KeyframeSummary {
    /// A summary over `tracks`.
    pub fn new(tracks: BTreeMap<PropertyID, PropertyTrack>) -> KeyframeSummary {
        KeyframeSummary { tracks }
    }

    /// Groups by identical time, sorted; `properties` restricts to some children (`None` = all).
    pub fn groups(&self, properties: Option<&BTreeSet<PropertyID>>) -> Vec<SummaryKey> {
        let mut by_time: BTreeMap<Time, BTreeSet<SummaryMember>> = BTreeMap::new();
        for (p, tr) in &self.tracks {
            if properties.is_some_and(|set| !set.contains(p)) {
                continue;
            }
            for (id, time) in tr.times() {
                by_time.entry(time).or_default().insert(SummaryMember::new(p.clone(), id));
            }
        }
        by_time.into_iter().map(|(time, members)| SummaryKey { time, members }).collect()
    }

    /// Selecting a summary key = all members at that time.
    pub fn members_at(&self, time: Time, properties: Option<&BTreeSet<PropertyID>>) -> BTreeSet<SummaryMember> {
        self.groups(properties).into_iter().find(|g| g.time == time).map(|g| g.members).unwrap_or_default()
    }

    /// Moves the members in time by `delta` (clamped to `limits`, the allowed delta range). Keys pass their
    /// non-selected neighbors (the track re-sorts, nobody is replaced). Landing exactly on the time of another key
    /// would merge two keys, so the move snaps one `frame` further in the direction of travel instead (the other way
    /// when `limits` stop it). Returns the delta actually applied. (Swift `move`.)
    pub fn move_key(
        &mut self,
        members: &BTreeSet<SummaryMember>,
        delta: Time,
        frame: Time,
        limits: Option<&RangeInclusive<Time>>,
    ) -> Time {
        let sel = by_property(members);
        if sel.is_empty() || delta == Time::ZERO || frame <= Time::ZERO {
            return Time::ZERO;
        }
        let clamp = |d: Time| limits.map_or(d, |l| d.max(*l.start()).min(*l.end()));
        let allowed = |d: Time| limits.is_none_or(|l| l.contains(&d));
        // Times of the keys that stay put, per property.
        let mut fixed: BTreeMap<&PropertyID, BTreeSet<Time>> = BTreeMap::new();
        for (p, ids) in &sel {
            let stay = self
                .tracks
                .get(p)
                .map(|t| t.times())
                .unwrap_or_default()
                .into_iter()
                .filter(|(id, _)| !ids.contains(id))
                .map(|(_, time)| time)
                .collect();
            fixed.insert(p, stay);
        }
        let collides = |d: Time| {
            sel.iter().any(|(p, ids)| {
                let (Some(t), Some(stay)) = (self.tracks.get(p), fixed.get(p)) else { return false };
                if stay.is_empty() {
                    return false;
                }
                t.times().iter().any(|(id, time)| ids.contains(id) && stay.contains(&(*time + d)))
            })
        };
        let mut d = clamp(delta);
        if collides(d) {
            let step = if delta > Time::ZERO { frame } else { Time::ZERO - frame };
            let search = |start: Time, step: Time| -> Option<Time> {
                let mut c = start + step;
                for _ in 0..10_000 {
                    if !allowed(c) {
                        break;
                    }
                    if !collides(c) {
                        return Some(c);
                    }
                    c += step;
                }
                None
            };
            let Some(found) = search(d, step).or_else(|| search(d, Time::ZERO - step)) else { return Time::ZERO };
            d = found;
        }
        if d == Time::ZERO {
            return Time::ZERO;
        }
        for (p, ids) in &sel {
            if let Some(t) = self.tracks.get_mut(p) {
                t.move_keys(ids, d);
            }
        }
        d
    }

    /// Applies `curve` to the members.
    pub fn apply(&mut self, curve: &EasingCurve, members: &BTreeSet<SummaryMember>, side: EaseSide) {
        for (p, ids) in by_property(members) {
            if let Some(t) = self.tracks.get_mut(&p) {
                t.apply(curve, &ids, side);
            }
        }
    }

    /// Toggles hold on the members with one decision across all properties so the group stays consistent.
    /// `kinds`: which hold a key that becomes one again was before it left (`KeyframeTrack::set_hold`).
    pub fn toggle_hold(&mut self, members: &BTreeSet<SummaryMember>, kinds: &BTreeMap<Id, Interpolation>) {
        let sel = by_property(members);
        let all_hold = sel.iter().all(|(p, ids)| self.tracks.get(p).is_none_or(|t| t.hold_state(ids)));
        for (p, ids) in &sel {
            if let Some(t) = self.tracks.get_mut(p) {
                t.set_hold(ids, !all_hold, kinds);
            }
        }
    }
}

/// Builders shared by the keyframe tests.
#[cfg(test)]
pub(crate) mod test_support {
    use super::PropertyTrack;
    use sq_core_time::{Id, IdSource, Keyframe, KeyframeTrack, Time};

    /// New ids from 1000 up, clear of the small ids the tests give their keys.
    pub(crate) struct FreshIds(u128);

    impl FreshIds {
        pub(crate) fn new() -> FreshIds {
            FreshIds(1000)
        }
    }

    impl IdSource for FreshIds {
        fn next_id(&mut self) -> Id {
            self.0 += 1;
            Id::from_u128(self.0)
        }
    }

    pub(crate) fn t(s: i64) -> Time {
        Time::new(s, 1)
    }

    pub(crate) fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    pub(crate) fn key(n: u128, s: i64, v: f64) -> Keyframe<f64> {
        Keyframe::new(id(n), t(s), v)
    }

    pub(crate) fn scalar(keys: Vec<Keyframe<f64>>) -> PropertyTrack {
        PropertyTrack::Scalar(KeyframeTrack::with_keys(keys))
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{id, key, scalar, t};
    use super::*;
    use sq_core_time::Keyframe;

    #[test]
    fn set_value_moves_every_selected_key_by_the_same_delta() {
        let mut tr = KeyframeTrack::with_keys(vec![key(1, 0, 10.0), key(2, 10, 20.0), key(3, 20, 30.0)]);
        let sel = BTreeSet::from([id(1), id(2)]);
        // Reference is the key at t=10 (20); the property shows 25: delta +5.
        assert!(tr.set_value(&25.0, t(10), &sel));
        assert_eq!(tr.keys.iter().map(|k| k.value).collect::<Vec<_>>(), vec![15.0, 25.0, 30.0]);
        assert!(!tr.set_value(&1.0, t(0), &BTreeSet::from([id(9)])));
    }

    #[test]
    fn move_keys_lets_the_moved_key_win_on_a_collision() {
        let mut tr = KeyframeTrack::with_keys(vec![key(1, 0, 0.0), key(2, 5, 1.0)]);
        tr.move_keys(&BTreeSet::from([id(1)]), t(5));
        assert_eq!(tr.keys.len(), 1);
        assert_eq!(tr.keys[0].id, id(1));
    }

    #[test]
    fn summary_groups_by_time_and_selects_members() {
        let s = KeyframeSummary::new(BTreeMap::from([
            ("a".into(), scalar(vec![key(1, 0, 0.0), key(2, 10, 1.0)])),
            ("b".into(), scalar(vec![key(3, 10, 5.0)])),
        ]));
        let groups = s.groups(None);
        assert_eq!(groups.iter().map(|g| g.time).collect::<Vec<_>>(), vec![t(0), t(10)]);
        assert_eq!(s.members_at(t(10), None).len(), 2);
        let only_b = BTreeSet::from([PropertyID::new("b")]);
        assert_eq!(s.members_at(t(10), Some(&only_b)).len(), 1);
        assert!(s.members_at(t(3), None).is_empty());
    }

    #[test]
    fn move_key_snaps_a_frame_past_a_collision_and_honors_limits() {
        let mut s = KeyframeSummary::new(BTreeMap::from([(
            "a".into(),
            scalar(vec![key(1, 0, 0.0), key(2, 10, 1.0), key(3, 20, 2.0)]),
        )]));
        let sel = BTreeSet::from([SummaryMember::new("a".into(), id(1))]);
        // Landing on the key at 10 is not allowed: one frame further.
        let applied = s.move_key(&sel, t(10), t(1), None);
        assert_eq!(applied, t(11));
        // Limits that stop the forward search make it try the other way.
        let mut s2 =
            KeyframeSummary::new(BTreeMap::from([("a".into(), scalar(vec![key(1, 0, 0.0), key(2, 10, 1.0)]))]));
        let limits = t(0)..=t(10);
        assert_eq!(s2.move_key(&sel, t(10), t(1), Some(&limits)), t(9));
        assert_eq!(s2.move_key(&sel, Time::ZERO, t(1), None), Time::ZERO);
    }

    #[test]
    fn toggle_hold_makes_one_decision_for_the_group() {
        let mut s = KeyframeSummary::new(BTreeMap::from([
            ("a".into(), scalar(vec![key(1, 0, 0.0), key(2, 10, 1.0)])),
            ("b".into(), scalar(vec![key(3, 0, 0.0), key(4, 10, 1.0)])),
        ]));
        let members = s.members_at(t(0), None);
        s.toggle_hold(&members, &BTreeMap::new());
        assert!(s.tracks.values().all(|tr| tr.hold_state(&BTreeSet::from([tr.key_ids()[0]]))));
        s.toggle_hold(&members, &BTreeMap::new());
        assert!(s.tracks.values().all(|tr| !tr.hold_state(&BTreeSet::from([tr.key_ids()[0]]))));
    }

    // Swift KeyframeSummaryTests: opacity keys at 0 and 4, position key at 0, rotation key at 1.
    const OP: &str = "opacity";
    const POS: &str = "position";

    fn fixture() -> KeyframeSummary {
        KeyframeSummary::new(BTreeMap::from([
            (OP.into(), scalar(vec![key(1, 0, 0.0), key(2, 4, 1.0)])),
            (
                POS.into(),
                PropertyTrack::Vector(KeyframeTrack::with_keys(vec![Keyframe::new(id(3), t(0), Vec2::new(1.0, 1.0))])),
            ),
            ("rotation".into(), scalar(vec![key(4, 1, 5.0)])),
        ]))
    }

    fn opacity_times(s: &KeyframeSummary) -> Vec<Time> {
        s.tracks[&PropertyID::new(OP)].times().iter().map(|(_, time)| *time).collect()
    }

    const FRAME: Time = Time::new(1, 30);

    #[test]
    fn kf_summary_groups_by_time() {
        let s = fixture();
        let g = s.groups(None);
        assert_eq!(g.iter().map(|k| k.time).collect::<Vec<_>>(), vec![t(0), t(1), t(4)]);
        assert_eq!(
            g[0].members,
            BTreeSet::from([SummaryMember::new(OP.into(), id(1)), SummaryMember::new(POS.into(), id(3))])
        );
        assert_eq!(s.groups(Some(&BTreeSet::from([PropertyID::new("rotation")]))).len(), 1);
        assert_eq!(s.members_at(t(0), None).len(), 2);
        assert_eq!(s.members_at(t(0), Some(&BTreeSet::from([PropertyID::new(OP)]))).len(), 1);
    }

    #[test]
    fn kf_summary_move_keeps_the_group_aligned() {
        let mut s = fixture();
        let sel = s.members_at(t(0), None);
        assert_eq!(s.move_key(&sel, t(2), FRAME, None), t(2));
        assert_eq!(opacity_times(&s), vec![t(2), t(4)]);
        assert_eq!(s.tracks[&PropertyID::new(POS)].times()[0].1, t(2));
    }

    #[test]
    fn kf_summary_move_passes_non_selected_neighbours_and_keeps_both_keys() {
        let mut s = fixture();
        let sel = s.members_at(t(0), None);
        // Opacity has a neighbor at 4: the group moves past it to 10, nobody is replaced.
        assert_eq!(s.move_key(&sel, t(10), FRAME, None), t(10));
        assert_eq!(s.tracks[&PropertyID::new(OP)].key_ids(), vec![id(2), id(1)]);
        assert_eq!(opacity_times(&s), vec![t(4), t(10)]);
        let mut b = fixture();
        let sel = b.members_at(t(4), None);
        assert_eq!(b.move_key(&sel, t(-6), FRAME, None), t(-6));
        assert_eq!(b.tracks[&PropertyID::new(OP)].key_ids(), vec![id(2), id(1)]);
        assert_eq!(opacity_times(&b), vec![t(-2), t(0)]);
    }

    #[test]
    fn kf_summary_move_onto_the_same_time_snaps_one_frame_instead_of_deleting() {
        let mut s = fixture();
        let sel = s.members_at(t(0), None);
        // Would land exactly on the key at 4.
        assert_eq!(s.move_key(&sel, t(4), FRAME, None), t(4) + FRAME);
        assert_eq!(opacity_times(&s), vec![t(4), t(4) + FRAME]);
        let mut g = fixture();
        let sel = g.members_at(t(4), None);
        // Downwards: one frame before.
        assert_eq!(g.move_key(&sel, t(-4), FRAME, None), t(-4) - FRAME);
        assert_eq!(opacity_times(&g), vec![t(0) - FRAME, t(0)]);
    }

    #[test]
    fn kf_summary_move_respects_delta_limits() {
        let mut s = fixture();
        let sel = s.members_at(t(0), None);
        assert_eq!(s.move_key(&sel, t(100), FRAME, Some(&(t(-5)..=t(7)))), t(7));
        let mut g = fixture();
        let sel = g.members_at(t(0), None);
        // Landing on 4 would nudge to 4 + frame, outside the limits: the other direction is tried.
        assert_eq!(g.move_key(&sel, t(4), FRAME, Some(&(t(-5)..=t(4)))), t(4) - FRAME);
    }

    #[test]
    fn kf_summary_move_with_every_key_selected_keeps_the_relative_order() {
        let mut s = fixture();
        let all: BTreeSet<_> = s
            .tracks
            .iter()
            .flat_map(|(p, tr)| tr.key_ids().into_iter().map(move |k| SummaryMember::new(p.clone(), k)))
            .collect();
        assert_eq!(s.move_key(&all, t(3), FRAME, None), t(3));
        assert_eq!(opacity_times(&s), vec![t(3), t(7)]);
        assert_eq!(s.move_key(&BTreeSet::new(), t(3), FRAME, None), Time::ZERO);
    }

    #[test]
    fn kf_summary_ease_acts_on_all_members() {
        let mut s = fixture();
        let sel = s.members_at(t(0), None);
        s.apply(&EasingCurve::ease_in_out(), &sel, EaseSide::Both);
        let PropertyTrack::Scalar(o) = &s.tracks[&PropertyID::new(OP)] else { panic!("scalar") };
        assert_eq!(o.keys[0].out_handle, EasingCurve::ease_in_out().out_handle);
        let PropertyTrack::Vector(p) = &s.tracks[&PropertyID::new(POS)] else { panic!("vector") };
        assert_eq!(p.keys[0].interpolation, Interpolation::Bezier);
        s.toggle_hold(&sel, &BTreeMap::new());
        assert_eq!(s.tracks[&PropertyID::new(OP)].interpolation_of(id(1)), Some(Interpolation::Hold));
    }

    #[test]
    fn set_scalar_and_set_vector_only_touch_their_own_type() {
        let mut p = scalar(vec![key(1, 0, 1.0), key(2, 2, 3.0)]);
        assert!(p.set_scalar(5.0, t(0), &BTreeSet::from([id(1), id(2)])));
        assert_eq!(p.times().len(), 2);
        assert!(!p.set_vector(Vec2::ZERO, t(0), &BTreeSet::from([id(1)])));
        let PropertyTrack::Scalar(tr) = &p else { panic!("scalar") };
        assert_eq!(tr.keys.iter().map(|k| k.value).collect::<Vec<_>>(), vec![5.0, 7.0]);
    }
}
