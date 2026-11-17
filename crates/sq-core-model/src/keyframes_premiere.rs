// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesPremiere.swift (ported by task M-3)

use crate::keyframes_clipboard::{KeyframeClipboard, KeyframeClipboardTrack};
use crate::keyframes_editing::{KeyframeSummary, PropertyID, PropertyTrack, SummaryMember, by_property};
use sq_core_time::ease_names::ease_name;
use sq_core_time::{
    EaseHandle, EaseSide, EasingCurve, Id, IdSource, Interpolation, Keyframe, KeyframeTrack, KeyframeValue, Time, Vec2,
};
use std::any::Any;
use std::collections::{BTreeMap, BTreeSet};
use std::ops::RangeInclusive;

/// The temporal interpolation entries of Premiere's keyframe right-click menu, mapped to our model.
/// Ease In / Ease Out change one side of the key only; Easy Ease and Bezier both; Hold is the outgoing side.
/// Hold Ahead (our own entry, directly under Hold) is the mirrored hold: the next key's value from right after the key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum KeyInterpolationChoice {
    /// Straight.
    Linear,
    /// Handles on the straight line, to be bent.
    Bezier,
    /// Straight speed, smooth spatial path.
    AutoBezier,
    /// Smooth speed, smooth spatial path.
    ContinuousBezier,
    /// Ease the arrival.
    EaseIn,
    /// Ease the departure.
    EaseOut,
    /// Ease both.
    EasyEase,
    /// Step.
    Hold,
    /// Mirrored step.
    HoldAhead,
}

impl KeyInterpolationChoice {
    /// Every entry in menu order.
    pub const ALL: [KeyInterpolationChoice; 9] = [
        KeyInterpolationChoice::Linear,
        KeyInterpolationChoice::Bezier,
        KeyInterpolationChoice::AutoBezier,
        KeyInterpolationChoice::ContinuousBezier,
        KeyInterpolationChoice::EaseIn,
        KeyInterpolationChoice::EaseOut,
        KeyInterpolationChoice::EasyEase,
        KeyInterpolationChoice::Hold,
        KeyInterpolationChoice::HoldAhead,
    ];

    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            KeyInterpolationChoice::Linear => "linear",
            KeyInterpolationChoice::Bezier => "bezier",
            KeyInterpolationChoice::AutoBezier => "autoBezier",
            KeyInterpolationChoice::ContinuousBezier => "continuousBezier",
            KeyInterpolationChoice::EaseIn => "easeIn",
            KeyInterpolationChoice::EaseOut => "easeOut",
            KeyInterpolationChoice::EasyEase => "easyEase",
            KeyInterpolationChoice::Hold => "hold",
            KeyInterpolationChoice::HoldAhead => "holdAhead",
        }
    }

    /// The entry with this raw value.
    pub fn from_raw(raw: &str) -> Option<KeyInterpolationChoice> {
        Self::ALL.into_iter().find(|c| c.raw_value() == raw)
    }

    /// The menu title.
    pub fn title(self) -> &'static str {
        match self {
            KeyInterpolationChoice::Linear => ease_name::STEADY,
            KeyInterpolationChoice::Bezier => "Bezier",
            KeyInterpolationChoice::AutoBezier => "Auto Bezier",
            KeyInterpolationChoice::ContinuousBezier => "Continuous Bezier",
            KeyInterpolationChoice::EaseIn => ease_name::SMOOTH_IN,
            KeyInterpolationChoice::EaseOut => ease_name::SMOOTH_OUT,
            KeyInterpolationChoice::EasyEase => ease_name::SMOOTH,
            KeyInterpolationChoice::Hold => ease_name::HOLD,
            KeyInterpolationChoice::HoldAhead => ease_name::HOLD_AHEAD,
        }
    }

    /// Hold and Hold Ahead set the key's kind itself (`KeyframeTrack::set_hold_kind`), so one can be turned into the
    /// other; `None` for every other entry.
    pub fn hold_kind(self) -> Option<Interpolation> {
        match self {
            KeyInterpolationChoice::Hold => Some(Interpolation::Hold),
            KeyInterpolationChoice::HoldAhead => Some(Interpolation::HoldAhead),
            _ => None,
        }
    }

    /// Menu wording for the Temporal Interpolation submenu: the same names as the one-click list (`ease_name`), so
    /// one curve never reads two ways in two menus of the same right-click.
    pub fn full_title(self) -> &'static str {
        self.title()
    }

    /// Which side of a key the entry writes.
    pub fn side(self) -> EaseSide {
        match self {
            KeyInterpolationChoice::EaseIn => EaseSide::In,
            KeyInterpolationChoice::EaseOut | KeyInterpolationChoice::Hold | KeyInterpolationChoice::HoldAhead => {
                EaseSide::Out
            }
            _ => EaseSide::Both,
        }
    }

    /// Auto and Continuous Bezier also smooth the spatial path of Position keys.
    pub fn smooths_spatial_path(self) -> bool {
        self == KeyInterpolationChoice::AutoBezier || self == KeyInterpolationChoice::ContinuousBezier
    }

    /// The curve of the entry. Hold Ahead has none of its own (a curve only knows Hold): apply the choice with
    /// `PropertyTrack::apply_choice`, which writes the kind.
    pub fn curve(self) -> EasingCurve {
        match self {
            KeyInterpolationChoice::Linear => EasingCurve::linear(),
            // Straight speed, the path is what gets smoothed.
            KeyInterpolationChoice::Bezier | KeyInterpolationChoice::AutoBezier => bezier_handles(),
            KeyInterpolationChoice::ContinuousBezier | KeyInterpolationChoice::EasyEase => EasingCurve::ease_in_out(),
            KeyInterpolationChoice::EaseIn => EasingCurve::ease_in(),
            KeyInterpolationChoice::EaseOut => EasingCurve::ease_out(),
            KeyInterpolationChoice::Hold | KeyInterpolationChoice::HoldAhead => EasingCurve::hold(),
        }
    }
}

/// Bezier handles that start on the straight line (so the motion is unchanged until the user bends them) but are
/// not the linear default, so the key reads as a Bezier key.
pub fn bezier_handles() -> EasingCurve {
    let h = EaseHandle { dx: 0.4, dy: 0.4 };
    EasingCurve::new(Id::fixed(8), "Bezier".to_string(), Interpolation::Bezier, h, h)
}

impl PropertyTrack {
    /// Applies a menu choice to the given keys.
    pub fn apply_choice(&mut self, choice: KeyInterpolationChoice, to: &BTreeSet<Id>) {
        if let Some(kind) = choice.hold_kind() {
            self.set_hold_kind(kind, to);
            return;
        }
        self.apply(&choice.curve(), to, choice.side());
        if choice.smooths_spatial_path()
            && let PropertyTrack::Vector(t) = self
        {
            t.smooth_tangents(to);
        }
    }

    /// Copies of the given keys with fresh ids (same time), for Option-drag duplicates.
    #[doc(hidden)]
    pub fn insert_duplicates(&mut self, ids: &BTreeSet<Id>, original: &PropertyTrack, src: &mut dyn IdSource) {
        match (self, original) {
            (PropertyTrack::Scalar(t), PropertyTrack::Scalar(o)) => t.insert_duplicates(ids, o, src),
            (PropertyTrack::Vector(t), PropertyTrack::Vector(o)) => t.insert_duplicates(ids, o, src),
            (PropertyTrack::Color(t), PropertyTrack::Color(o)) => t.insert_duplicates(ids, o, src),
            (PropertyTrack::Path(t), PropertyTrack::Path(o)) => t.insert_duplicates(ids, o, src),
            _ => {}
        }
    }
}

/// Option-drag duplicates and smooth-by-default inserts.
pub trait KeyframeTrackPremiere<V> {
    /// Copies of `original`'s keys with these ids, under fresh ids on their old times (none where a key sits now).
    fn insert_duplicates(&mut self, ids: &BTreeSet<Id>, original: &KeyframeTrack<V>, src: &mut dyn IdSource);

    /// `insert`, smooth by default when this is a Position track (`smooth_spatial`).
    fn insert_key(&mut self, key: Keyframe<V>, smooth_spatial: bool)
    where
        V: 'static;
}

impl<V: KeyframeValue> KeyframeTrackPremiere<V> for KeyframeTrack<V> {
    fn insert_duplicates(&mut self, ids: &BTreeSet<Id>, original: &KeyframeTrack<V>, src: &mut dyn IdSource) {
        let taken: BTreeSet<Time> = self.keys.iter().map(|k| k.time).collect();
        for k in original.keys.iter().filter(|k| ids.contains(&k.id) && !taken.contains(&k.time)) {
            let mut c = k.clone();
            c.id = src.next_id();
            self.insert(c);
        }
    }

    fn insert_key(&mut self, key: Keyframe<V>, smooth_spatial: bool)
    where
        V: 'static,
    {
        // Smoothing only exists for Vec2 tracks; the cast stands in for Swift's `as? KeyframeTrack<Vec2>`.
        let mut key = Some(key);
        if smooth_spatial
            && let (Some(t), Some(Some(k))) = (
                (self as &mut dyn Any).downcast_mut::<KeyframeTrack<Vec2>>(),
                (&mut key as &mut dyn Any).downcast_mut::<Option<Keyframe<Vec2>>>().map(Option::take),
            )
        {
            t.insert_smooth(k);
            return;
        }
        if let Some(k) = key {
            self.insert(k);
        }
    }
}

/// Smooth spatial paths (Auto / Continuous Bezier).
pub trait SpatialSmoothing {
    /// Sets Catmull-Rom style tangents on the given keys so the path runs through them smoothly: both tangents point
    /// along the line from the previous to the next key, a third of the neighbor distance long. First and last key
    /// keep a zero tangent on their outer side (the path leaves / arrives straight).
    fn smooth_tangents(&mut self, ids: &BTreeSet<Id>);

    /// Spatial Linear: the path leaves and arrives straight at the given keys.
    fn straighten_tangents(&mut self, ids: &BTreeSet<Id>);

    /// Inserts a new Position key that is smooth by default (Premiere): its own tangents are computed, and
    /// neighbors that still have no tangents (never hand-shaped) are re-smoothed because their surroundings changed.
    fn insert_smooth(&mut self, key: Keyframe<Vec2>);
}

fn smooth_tangent(keys: &mut [Keyframe<Vec2>], i: usize) {
    if i == 0 || i + 1 >= keys.len() {
        return;
    }
    let (prev, here, next) = (keys[i - 1].value, keys[i].value, keys[i + 1].value);
    let chord = next - prev;
    let len = chord.length();
    if len <= 1e-12 {
        keys[i].in_tangent = Vec2::ZERO;
        keys[i].out_tangent = Vec2::ZERO;
        return;
    }
    let dir = chord * (1.0 / len);
    keys[i].out_tangent = dir * ((next - here).length() / 3.0);
    keys[i].in_tangent = dir * (-(here - prev).length() / 3.0);
}

impl SpatialSmoothing for KeyframeTrack<Vec2> {
    fn smooth_tangents(&mut self, ids: &BTreeSet<Id>) {
        self.edit_keys(|keys| {
            for i in 0..keys.len() {
                if ids.contains(&keys[i].id) {
                    smooth_tangent(keys, i);
                }
            }
        });
    }

    fn straighten_tangents(&mut self, ids: &BTreeSet<Id>) {
        self.edit_keys(|keys| {
            for k in keys.iter_mut().filter(|k| ids.contains(&k.id)) {
                k.in_tangent = Vec2::ZERO;
                k.out_tangent = Vec2::ZERO;
            }
        });
    }

    fn insert_smooth(&mut self, key: Keyframe<Vec2>) {
        let key_id = key.id;
        self.insert(key);
        let shown = self.keys.clone();
        let Some(i) = shown.iter().position(|k| k.id == key_id) else { return };
        let mut ids = BTreeSet::from([key_id]);
        for j in [i.checked_sub(1), Some(i + 1)].into_iter().flatten() {
            if let Some(k) = shown.get(j)
                && k.in_tangent == Vec2::ZERO
                && k.out_tangent == Vec2::ZERO
            {
                ids.insert(k.id);
            }
        }
        self.smooth_tangents(&ids);
    }
}

impl KeyframeSummary {
    /// Option-drag: like `move_key`, but a copy of every moved key stays at its original time (unless a key lands
    /// there). The originals keep their ids (so the selection follows them). Returns the delta applied.
    pub fn move_duplicating(
        &mut self,
        members: &BTreeSet<SummaryMember>,
        delta: Time,
        frame: Time,
        limits: Option<&RangeInclusive<Time>>,
        src: &mut dyn IdSource,
    ) -> Time {
        let before = self.tracks.clone();
        let applied = self.move_key(members, delta, frame, limits);
        if applied == Time::ZERO {
            return applied;
        }
        for (p, ids) in by_property(members) {
            let Some(orig) = before.get(&p) else { continue };
            if let Some(t) = self.tracks.get_mut(&p) {
                t.insert_duplicates(&ids, orig, src);
            }
        }
        applied
    }

    /// Smooths the spatial path at the selected keys of vector (Position-like) tracks (`smooth_tangents`). The Swift
    /// doc comment says "Linear" but the code smooths; `straighten_spatial` is the linear one.
    pub fn smooth_spatial(&mut self, members: &BTreeSet<SummaryMember>) {
        for m in members {
            if let Some(PropertyTrack::Vector(t)) = self.tracks.get_mut(&m.property) {
                t.smooth_tangents(&BTreeSet::from([m.key_id]));
            }
        }
    }

    /// True when the selection holds a key of a vector (Position-like) track.
    pub fn has_vector_key(&self, members: &BTreeSet<SummaryMember>) -> bool {
        members.iter().any(|m| matches!(self.tracks.get(&m.property), Some(PropertyTrack::Vector(_))))
    }

    /// Zero spatial tangents on the selected keys of vector tracks.
    pub fn straighten_spatial(&mut self, members: &BTreeSet<SummaryMember>) {
        for m in members {
            if let Some(PropertyTrack::Vector(t)) = self.tracks.get_mut(&m.property) {
                t.straighten_tangents(&BTreeSet::from([m.key_id]));
            }
        }
    }
}

impl KeyframeClipboard {
    /// A clipboard holding exactly one property can be pasted onto another property of the same value type
    /// (Premiere pastes onto the selected property). `None` when it holds several, or the types differ.
    pub fn retargeted(
        &self,
        property: &PropertyID,
        is_vector: bool,
        is_color: bool,
        is_path: bool,
    ) -> Option<KeyframeClipboard> {
        if self.tracks().len() != 1 {
            return None;
        }
        let t = self.tracks().values().next()?;
        let (vector, color) = (is_vector && !is_path, is_color && !is_path);
        let fits = match t {
            KeyframeClipboardTrack::Scalar(_) => !vector && !color && !is_path,
            KeyframeClipboardTrack::Vector(_) => vector && !color && !is_path,
            KeyframeClipboardTrack::Color(_) => !vector && color && !is_path,
            KeyframeClipboardTrack::Path(_) => is_path,
        };
        fits.then(|| KeyframeClipboard::from_tracks(BTreeMap::from([(property.clone(), t.clone())])))
    }

    /// Number of copied keys.
    pub fn key_count(&self) -> usize {
        self.tracks().values().map(KeyframeClipboardTrack::len).sum()
    }

    /// The copied properties.
    pub fn property_ids(&self) -> BTreeSet<PropertyID> {
        self.tracks().keys().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keyframes_editing::test_support::{FreshIds, id, key, scalar, t};

    fn pos(n: u128, s: i64, x: f64, y: f64) -> Keyframe<Vec2> {
        Keyframe::new(id(n), t(s), Vec2::new(x, y))
    }

    #[test]
    fn menu_entries_map_to_sides_curves_and_hold_kinds() {
        use KeyInterpolationChoice::*;
        assert_eq!(EaseIn.side(), EaseSide::In);
        assert_eq!(Hold.side(), EaseSide::Out);
        assert_eq!(EasyEase.side(), EaseSide::Both);
        assert_eq!(HoldAhead.hold_kind(), Some(Interpolation::HoldAhead));
        assert_eq!(Linear.title(), "Linear");
        assert_eq!(Bezier.curve().id.to_string(), "00000000-0000-0000-0000-000000000008");
        assert_eq!(KeyInterpolationChoice::from_raw("autoBezier"), Some(AutoBezier));
        assert!(AutoBezier.smooths_spatial_path() && !EaseIn.smooths_spatial_path());
    }

    #[test]
    fn hold_ahead_choice_writes_the_kind_and_a_curve_choice_writes_handles() {
        let mut p = scalar(vec![key(1, 0, 0.0), key(2, 1, 1.0)]);
        let ids = BTreeSet::from([id(1)]);
        p.apply_choice(KeyInterpolationChoice::HoldAhead, &ids);
        assert_eq!(p.interpolation_of(id(1)), Some(Interpolation::HoldAhead));
        p.apply_choice(KeyInterpolationChoice::Bezier, &ids);
        assert_eq!(p.interpolation_of(id(1)), Some(Interpolation::Bezier));
        let mut q = scalar(vec![key(1, 0, 0.0), key(2, 1, 1.0)]);
        q.apply_choice(KeyInterpolationChoice::Bezier, &ids);
        assert_eq!(q.interpolation_of(id(1)), Some(Interpolation::Bezier));
    }

    #[test]
    fn smooth_tangents_run_along_the_neighbor_chord() {
        let mut tr = KeyframeTrack::with_keys(vec![pos(1, 0, 0.0, 0.0), pos(2, 1, 3.0, 0.0), pos(3, 2, 3.0, 4.0)]);
        tr.smooth_tangents(&BTreeSet::from([id(1), id(2)]));
        // The first key has no previous neighbor: untouched.
        assert_eq!(tr.keys[0].out_tangent, Vec2::ZERO);
        let dir = Vec2::new(3.0, 4.0) * (1.0 / 5.0);
        assert_eq!(tr.keys[1].out_tangent, dir * (4.0 / 3.0));
        assert_eq!(tr.keys[1].in_tangent, dir * (-3.0 / 3.0));
        tr.straighten_tangents(&BTreeSet::from([id(2)]));
        assert_eq!((tr.keys[1].in_tangent, tr.keys[1].out_tangent), (Vec2::ZERO, Vec2::ZERO));
    }

    #[test]
    fn insert_key_smooths_only_vector_tracks_when_asked() {
        let mut v = KeyframeTrack::with_keys(vec![pos(1, 0, 0.0, 0.0), pos(3, 2, 4.0, 4.0)]);
        v.insert_key(pos(2, 1, 4.0, 0.0), true);
        assert_ne!(v.keys[1].out_tangent, Vec2::ZERO);
        let mut plain = KeyframeTrack::with_keys(vec![pos(1, 0, 0.0, 0.0), pos(3, 2, 4.0, 4.0)]);
        plain.insert_key(pos(2, 1, 4.0, 0.0), false);
        assert_eq!(plain.keys[1].out_tangent, Vec2::ZERO);
        let mut s = KeyframeTrack::with_keys(vec![key(1, 0, 0.0)]);
        s.insert_key(key(2, 1, 1.0), true);
        assert_eq!(s.keys.len(), 2);
    }

    #[test]
    fn duplicates_get_fresh_ids_and_skip_taken_times() {
        let original = KeyframeTrack::with_keys(vec![key(1, 0, 0.0), key(2, 1, 1.0)]);
        let mut now = KeyframeTrack::with_keys(vec![key(1, 5, 0.0), key(3, 1, 9.0)]);
        now.insert_duplicates(&BTreeSet::from([id(1), id(2)]), &original, &mut FreshIds::new());
        // Time 1 is taken by another key; time 0 gets a copy under a new id.
        assert_eq!(now.keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![t(0), t(1), t(5)]);
        assert_ne!(now.keys[0].id, id(1));
        assert_eq!(now.keys[1].value, 9.0);
    }

    #[test]
    fn retargeting_needs_one_property_of_the_same_type() {
        let sel = BTreeMap::from([("a".into(), BTreeSet::from([id(1)]))]);
        let tracks = BTreeMap::from([("a".into(), scalar(vec![key(1, 0, 0.0)]))]);
        let cb = KeyframeClipboard::copy(&tracks, &sel).expect("copied");
        let target: PropertyID = "b".into();
        let moved = cb.retargeted(&target, false, false, false).expect("scalar fits scalar");
        assert_eq!(moved.property_ids(), BTreeSet::from([target.clone()]));
        assert_eq!(moved.key_count(), 1);
        assert!(cb.retargeted(&target, true, false, false).is_none());
        assert!(cb.retargeted(&target, false, false, true).is_none());
    }

    #[test]
    fn move_duplicating_leaves_a_copy_at_the_old_time() {
        let mut s = KeyframeSummary::new(BTreeMap::from([("a".into(), scalar(vec![key(1, 0, 0.0), key(2, 10, 1.0)]))]));
        let members = BTreeSet::from([SummaryMember::new("a".into(), id(1))]);
        let applied = s.move_duplicating(&members, t(3), t(1), None, &mut FreshIds::new());
        assert_eq!(applied, t(3));
        let Some(PropertyTrack::Scalar(tr)) = s.tracks.get(&"a".into()) else { panic!("track") };
        assert_eq!(tr.keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![t(0), t(3), t(10)]);
        assert_eq!(tr.keys[1].id, id(1));
        assert_ne!(tr.keys[0].id, id(1));
    }

    // Swift KeyframePremiereTests.
    fn pk(n: u128, s: i64, x: f64, y: f64) -> Keyframe<Vec2> {
        pos(n, s, x, y)
    }

    #[test]
    fn ease_in_touches_only_the_in_handle_and_bezier_stays_visually_linear() {
        let mut tr = scalar(vec![key(1, 0, 0.0), key(2, 2, 5.0), key(3, 4, 9.0)]);
        tr.apply_choice(KeyInterpolationChoice::EaseIn, &BTreeSet::from([id(2)]));
        let PropertyTrack::Scalar(t0) = &tr else { panic!("scalar") };
        assert_eq!(t0.keys[1].in_handle.dy, 0.0);
        assert_eq!(t0.keys[1].out_handle, EaseHandle::LINEAR);
        assert!(t0.keys[0] == key(1, 0, 0.0) && t0.keys[2] == key(3, 4, 9.0));
        let mut b = KeyframeTrack::with_keys(vec![key(1, 0, 0.0), key(2, 2, 10.0)]);
        b.apply(&KeyInterpolationChoice::Bezier.curve(), &BTreeSet::from([id(1), id(2)]), EaseSide::Both);
        assert!((b.value(t(1)).unwrap_or(f64::NAN) - 5.0).abs() < 1e-6);
    }

    #[test]
    fn menu_titles_follow_the_premiere_names() {
        let titles: Vec<_> = KeyInterpolationChoice::ALL.iter().map(|c| c.title()).collect();
        assert_eq!(
            titles,
            [
                "Linear",
                "Bezier",
                "Auto Bezier",
                "Continuous Bezier",
                "Ease In",
                "Ease Out",
                "Ease In & Out",
                "Hold",
                "Hold Ahead"
            ]
        );
    }

    #[test]
    fn auto_bezier_makes_a_smooth_position_path() {
        let mut tr = PropertyTrack::Vector(KeyframeTrack::with_keys(vec![
            pk(1, 0, 0.0, 0.0),
            pk(2, 2, 100.0, 100.0),
            pk(3, 4, 200.0, 0.0),
        ]));
        tr.apply_choice(KeyInterpolationChoice::AutoBezier, &BTreeSet::from([id(2)]));
        let PropertyTrack::Vector(v) = &tr else { panic!("vector") };
        let mid = &v.keys[1];
        assert_eq!(mid.interpolation, Interpolation::Bezier);
        assert!(mid.out_tangent != Vec2::ZERO && mid.in_tangent != Vec2::ZERO);
        // Continuous through the key: the tangents are opposite.
        assert!(
            (mid.in_tangent.x + mid.out_tangent.x).abs() < 1e-9 && (mid.in_tangent.y + mid.out_tangent.y).abs() < 1e-9
        );
        // The segment bulges off the chord.
        let p = v.value(t(1)).unwrap_or(Vec2::ZERO);
        assert!((p.x - p.y).abs() > 1.0);
        assert_eq!(v.value(t(2)), Some(Vec2::new(100.0, 100.0)));
    }

    #[test]
    fn auto_bezier_on_a_scalar_keeps_the_straight_speed_and_continuous_bezier_eases_time() {
        let mut a = scalar(vec![key(1, 0, 0.0), key(2, 2, 10.0)]);
        a.apply_choice(KeyInterpolationChoice::AutoBezier, &BTreeSet::from([id(1), id(2)]));
        let PropertyTrack::Scalar(t0) = &a else { panic!("scalar") };
        assert!((t0.value(t(1)).unwrap_or(f64::NAN) - 5.0).abs() < 1e-6);
        let mut c = scalar(vec![key(1, 0, 0.0), key(2, 2, 10.0)]);
        c.apply_choice(KeyInterpolationChoice::ContinuousBezier, &BTreeSet::from([id(1), id(2)]));
        let PropertyTrack::Scalar(t1) = &c else { panic!("scalar") };
        assert!(t1.keys[0].out_handle.dy == 0.0 && t1.keys[1].in_handle.dy == 0.0);
    }

    #[test]
    fn insert_smooth_gives_a_new_middle_key_tangents_and_keeps_hand_placed_ones() {
        let mut tr = KeyframeTrack::with_keys(vec![pk(1, 0, 0.0, 0.0), pk(2, 4, 200.0, 0.0)]);
        tr.insert_smooth(pk(3, 2, 100.0, 100.0));
        assert!(tr.keys[1].out_tangent != Vec2::ZERO && tr.keys[1].in_tangent != Vec2::ZERO);
        // Endpoints stay straight on their outer side.
        assert_eq!(tr.keys[0].out_tangent, Vec2::ZERO);
        let mut a = pk(1, 0, 0.0, 0.0);
        a.out_tangent = Vec2::new(7.0, 7.0);
        let mut hand = KeyframeTrack::with_keys(vec![a, pk(2, 4, 200.0, 0.0)]);
        hand.insert_smooth(pk(3, 2, 100.0, 100.0));
        assert_eq!(hand.keys[0].out_tangent, Vec2::new(7.0, 7.0));
        let mut first = KeyframeTrack::<Vec2>::new();
        first.insert_smooth(pk(1, 0, 0.0, 0.0));
        first.insert_smooth(pk(2, 2, 100.0, 100.0));
        assert!(first.keys.iter().all(|k| k.in_tangent == Vec2::ZERO && k.out_tangent == Vec2::ZERO));
    }

    #[test]
    fn straighten_spatial_zeroes_selected_vector_keys_only() {
        let ks = vec![pk(1, 0, 0.0, 0.0), pk(2, 2, 100.0, 100.0), pk(3, 4, 200.0, 0.0), pk(4, 6, 300.0, 100.0)];
        let mut v = KeyframeTrack::with_keys(ks);
        v.smooth_tangents(&BTreeSet::from([id(1), id(2), id(3), id(4)]));
        let mut s = KeyframeSummary::new(BTreeMap::from([
            ("position".into(), PropertyTrack::Vector(v)),
            ("opacity".into(), scalar(vec![key(11, 0, 0.0), key(12, 2, 1.0)])),
        ]));
        let on = BTreeSet::from([
            SummaryMember::new("position".into(), id(2)),
            SummaryMember::new("opacity".into(), id(99)),
        ]);
        assert!(s.has_vector_key(&on));
        s.straighten_spatial(&on);
        let Some(PropertyTrack::Vector(out)) = s.tracks.get(&"position".into()) else { panic!("vector") };
        assert!(out.keys[1].in_tangent == Vec2::ZERO && out.keys[1].out_tangent == Vec2::ZERO);
        // Not selected: untouched.
        assert_ne!(out.keys[2].out_tangent, Vec2::ZERO);
    }

    #[test]
    fn move_duplicating_onto_an_occupied_time_snaps_one_frame_and_keeps_every_key() {
        let frame = Time::new(1, 30);
        let mut s = KeyframeSummary::new(BTreeMap::from([("o".into(), scalar(vec![key(1, 1, 1.0), key(2, 3, 3.0)]))]));
        let members = BTreeSet::from([SummaryMember::new("o".into(), id(1))]);
        let applied = s.move_duplicating(&members, t(2), frame, None, &mut FreshIds::new());
        assert_eq!(applied, t(2) + frame);
        let Some(PropertyTrack::Scalar(tr)) = s.tracks.get(&"o".into()) else { panic!("scalar") };
        assert_eq!(tr.keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![t(1), t(3), t(3) + frame]);
        assert_eq!(tr.keys[1].value, 3.0);
        assert_eq!(tr.keys[2].id, id(1));
    }
}
