// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesEasing.swift, plus the four built-in curves declared in EasingSpring.swift.

use crate::{EaseHandle, Id, IdSource, Interpolation, Keyframe, KeyframeTrack, KeyframeValue};
use serde::{Deserialize, Deserializer, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Which side of a key an easing touches.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EaseSide {
    /// Shape, out-handle and in-handle.
    Both,
    /// The in-handle only.
    In,
    /// The shape and the out-handle.
    Out,
}

/// A reusable easing: outgoing shape plus both handles. Never a Hold Ahead (stored as Hold): that is a key's own
/// property, and a curve reaches places the project version gate does not see.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct EasingCurve {
    /// Identity in the library.
    pub id: Id,
    /// Shown name.
    pub name: String,
    #[serde(deserialize_with = "as_ease")]
    interpolation: Interpolation,
    /// Out-handle applied to a key.
    #[serde(rename = "outHandle")]
    pub out_handle: EaseHandle,
    /// In-handle applied to a key.
    #[serde(rename = "inHandle")]
    pub in_handle: EaseHandle,
}

fn as_ease<'de, D: Deserializer<'de>>(d: D) -> Result<Interpolation, D::Error> {
    Interpolation::deserialize(d).map(Interpolation::as_ease)
}

impl EasingCurve {
    /// A curve; a Hold Ahead shape is stored as Hold.
    pub fn new(
        id: Id,
        name: String,
        interpolation: Interpolation,
        out_handle: EaseHandle,
        in_handle: EaseHandle,
    ) -> Self {
        EasingCurve { id, name, interpolation: interpolation.as_ease(), out_handle, in_handle }
    }

    /// Curve taken from a key's own shape and handles.
    pub fn from_key<V>(id: Id, key: &Keyframe<V>, name: String) -> Self {
        Self::new(id, name, key.interpolation, key.out_handle, key.in_handle)
    }

    /// The outgoing shape (never Hold Ahead).
    pub fn interpolation(&self) -> Interpolation {
        self.interpolation
    }

    /// Sets the shape; Hold Ahead becomes Hold (Swift `didSet`).
    pub fn set_interpolation(&mut self, i: Interpolation) {
        self.interpolation = i.as_ease();
    }

    /// Applies to one key. `In` touches only the in-handle, `Out` the shape and out-handle.
    pub fn apply<V>(&self, key: &mut Keyframe<V>, side: EaseSide) {
        if side != EaseSide::In {
            // A Hold Ahead stays one.
            if !(self.interpolation == Interpolation::Hold && key.interpolation.is_hold()) {
                key.interpolation = self.interpolation;
            }
            key.out_handle = self.out_handle;
        }
        if side != EaseSide::Out {
            key.in_handle = self.in_handle;
        }
    }

    fn built_in(n: u64, name: &str, i: Interpolation, out: EaseHandle, in_h: EaseHandle) -> Self {
        Self::new(Id::fixed(n), name.to_string(), i, out, in_h)
    }

    /// "Steady".
    pub fn linear() -> Self {
        Self::built_in(1, "Steady", Interpolation::Linear, EaseHandle::LINEAR, EaseHandle::LINEAR)
    }
    /// "Hold".
    pub fn hold() -> Self {
        Self::built_in(2, "Hold", Interpolation::Hold, EaseHandle::LINEAR, EaseHandle::LINEAR)
    }
    /// "Ease-in-out 33%".
    pub fn ease_in_out() -> Self {
        Self::built_in(3, "Ease-in-out 33%", Interpolation::Bezier, h(1.0 / 3.0, 0.0), h(1.0 / 3.0, 0.0))
    }
    /// "Ease-in 33%".
    pub fn ease_in() -> Self {
        Self::built_in(4, "Ease-in 33%", Interpolation::Bezier, EaseHandle::LINEAR, h(1.0 / 3.0, 0.0))
    }
    /// "Ease-out 33%".
    pub fn ease_out() -> Self {
        Self::built_in(5, "Ease-out 33%", Interpolation::Bezier, h(1.0 / 3.0, 0.0), EaseHandle::LINEAR)
    }
    /// "Fast start".
    pub fn fast_start() -> Self {
        Self::built_in(6, "Fast start", Interpolation::Bezier, h(0.1, 0.6), h(0.6, 0.0))
    }
    /// "Fast end".
    pub fn fast_end() -> Self {
        Self::built_in(7, "Fast end", Interpolation::Bezier, h(0.6, 0.0), h(0.1, 0.6))
    }
    /// "Classic": Premiere's default bezier, 16.7 % influence on both handles, flat tangents.
    pub fn premiere_default() -> Self {
        Self::built_in(11, "Classic", Interpolation::Bezier, h(0.167, 0.0), h(0.167, 0.0))
    }
    /// "Ease-out 100%": decelerating arrival with 100 % influence.
    pub fn ease_out_100() -> Self {
        Self::built_in(9, "Ease-out 100%", Interpolation::Bezier, EaseHandle::LINEAR, h(1.0, 0.0))
    }
    /// "Ease-in 100%": accelerating departure with 100 % influence.
    pub fn ease_in_100() -> Self {
        Self::built_in(10, "Ease-in 100%", Interpolation::Bezier, h(1.0, 0.0), EaseHandle::LINEAR)
    }
    /// "Soft landing": leaves at a brisk pace and settles gently into the next key.
    pub fn soft_landing() -> Self {
        Self::built_in(12, "Soft landing", Interpolation::Bezier, h(0.2, 0.5), h(0.5, 0.0))
    }

    /// Every built-in curve in menu order.
    pub fn built_ins() -> Vec<EasingCurve> {
        vec![
            Self::linear(),
            Self::hold(),
            Self::ease_in_out(),
            Self::ease_in(),
            Self::ease_out(),
            Self::fast_start(),
            Self::fast_end(),
            Self::premiere_default(),
            Self::ease_out_100(),
            Self::ease_in_100(),
            Self::soft_landing(),
        ]
    }
}

fn h(dx: f64, dy: f64) -> EaseHandle {
    EaseHandle { dx, dy }
}

/// Built-in curves plus the user's saved ones.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct EasingLibrary {
    #[serde(rename = "userCurves")]
    user_curves: Vec<EasingCurve>,
}

impl EasingLibrary {
    /// The user's saved curves.
    pub fn user_curves(&self) -> &[EasingCurve] {
        &self.user_curves
    }

    /// Built-ins, then user curves.
    pub fn all(&self) -> Vec<EasingCurve> {
        let mut v = EasingCurve::built_ins();
        v.extend(self.user_curves.iter().cloned());
        v
    }

    /// Adds a user curve.
    pub fn add(&mut self, curve: EasingCurve) {
        self.user_curves.push(curve);
    }

    /// "Save curve" from a key. Returns the new curve's id.
    pub fn save_curve<V>(&mut self, ids: &mut dyn IdSource, key: &Keyframe<V>, name: String) -> Id {
        let c = EasingCurve::from_key(ids.next_id(), key, name);
        let id = c.id;
        self.user_curves.push(c);
        id
    }

    /// Renames a user curve.
    pub fn rename(&mut self, id: Id, name: String) {
        if let Some(c) = self.user_curves.iter_mut().find(|c| c.id == id) {
            c.name = name;
        }
    }

    /// Removes a user curve; built-ins cannot be removed.
    pub fn remove(&mut self, id: Id) {
        self.user_curves.retain(|c| c.id != id);
    }
}

impl<V: KeyframeValue> KeyframeTrack<V> {
    /// Applies the curve to the given keys only; unselected keys are never modified.
    pub fn apply(&mut self, curve: &EasingCurve, ids: &BTreeSet<Id>, side: EaseSide) {
        for &id in ids {
            self.update(id, |k| curve.apply(k, side));
        }
    }

    /// If all given keys are hold, they leave hold; otherwise all become hold (`kinds`: see `set_hold`).
    pub fn toggle_hold(&mut self, ids: &BTreeSet<Id>, kinds: &BTreeMap<Id, Interpolation>) {
        let mut sel = self.keys.iter().filter(|k| ids.contains(&k.id)).peekable();
        if sel.peek().is_none() {
            return;
        }
        let all_hold = sel.all(|k| k.interpolation.is_hold());
        self.set_hold(ids, !all_hold, kinds);
    }

    /// Hold only changes the interpolation; handles stay stored. Leaving hold restores bezier when the segment's
    /// handles (own out, next key's in) are not linear, else linear. `kinds` maps a key to the hold kind it had before
    /// it left hold (kept by the caller); a key without an entry becomes a Hold.
    pub fn set_hold(&mut self, ids: &BTreeSet<Id>, hold: bool, kinds: &BTreeMap<Id, Interpolation>) {
        for i in 0..self.keys.len() {
            if !ids.contains(&self.keys[i].id) {
                continue;
            }
            if hold {
                if !self.keys[i].interpolation.is_hold() {
                    let ahead = kinds.get(&self.keys[i].id) == Some(&Interpolation::HoldAhead);
                    self.keys[i].interpolation = if ahead { Interpolation::HoldAhead } else { Interpolation::Hold };
                }
            } else if self.keys[i].interpolation.is_hold() {
                let next = self.keys.get(i + 1).map_or(EaseHandle::LINEAR, |k| k.in_handle);
                let curved = self.keys[i].out_handle != EaseHandle::LINEAR || next != EaseHandle::LINEAR;
                self.keys[i].interpolation = if curved { Interpolation::Bezier } else { Interpolation::Linear };
            }
        }
    }

    /// Menu entries Hold and Hold Ahead: the given keys become exactly `kind`; any other kind is ignored.
    pub fn set_hold_kind(&mut self, kind: Interpolation, ids: &BTreeSet<Id>) {
        if !kind.is_hold() {
            return;
        }
        for k in self.keys.iter_mut().filter(|k| ids.contains(&k.id)) {
            k.interpolation = kind;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Time;

    #[test]
    fn curves_never_store_hold_ahead_and_keep_a_keys_hold_ahead() {
        let mut c = EasingCurve::hold();
        c.set_interpolation(Interpolation::HoldAhead);
        assert_eq!(c.interpolation(), Interpolation::Hold);
        let mut k = Keyframe::new(Id::from_u128(1), Time::ZERO, 0.0);
        k.interpolation = Interpolation::HoldAhead;
        c.apply(&mut k, EaseSide::Both);
        assert_eq!(k.interpolation, Interpolation::HoldAhead);
        assert_eq!(EasingCurve::premiere_default().id.to_string(), "00000000-0000-0000-0000-000000000011");
    }

    #[test]
    fn leaving_hold_restores_bezier_when_handles_curve() {
        let mut a = Keyframe::new(Id::from_u128(1), Time::ZERO, 0.0);
        a.out_handle = h(0.5, 0.0);
        let b = Keyframe::new(Id::from_u128(2), Time::new(1, 1), 1.0);
        let mut tr = KeyframeTrack::with_keys(vec![a, b]);
        let ids = BTreeSet::from([Id::from_u128(1)]);
        tr.toggle_hold(&ids, &BTreeMap::new());
        assert_eq!(tr.keys[0].interpolation, Interpolation::Hold);
        tr.toggle_hold(&ids, &BTreeMap::new());
        assert_eq!(tr.keys[0].interpolation, Interpolation::Bezier);
    }
}
