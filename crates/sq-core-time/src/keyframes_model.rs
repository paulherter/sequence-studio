// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesModel.swift, plus the legacy Hold fold of ProjectFile+V77.swift (it runs on every track decode).

use crate::codec::{EncodeContext, Seen};
use crate::keyframes_spatial::SpatialPath;
use crate::{Id, Time};
use serde::de::DeserializeOwned;
use serde::ser::SerializeStruct;
use serde::{Deserialize, Serialize, Serializer};
use std::collections::HashSet;
use std::fmt::Debug;
use std::ops::{Add, Mul, Sub};

/// A 2-D point or offset in `f64`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Vec2 {
    /// Horizontal.
    pub x: f64,
    /// Vertical.
    pub y: f64,
}

impl Vec2 {
    /// (0, 0).
    pub const ZERO: Vec2 = Vec2 { x: 0.0, y: 0.0 };

    /// `Vec2(x, y)`.
    pub const fn new(x: f64, y: f64) -> Vec2 {
        Vec2 { x, y }
    }

    /// Euclidean length.
    pub fn length(self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}

impl Add for Vec2 {
    type Output = Vec2;
    fn add(self, b: Vec2) -> Vec2 {
        Vec2::new(self.x + b.x, self.y + b.y)
    }
}

impl Sub for Vec2 {
    type Output = Vec2;
    fn sub(self, b: Vec2) -> Vec2 {
        Vec2::new(self.x - b.x, self.y - b.y)
    }
}

impl Mul<f64> for Vec2 {
    type Output = Vec2;
    fn mul(self, k: f64) -> Vec2 {
        Vec2::new(self.x * k, self.y * k)
    }
}

/// A value that can be keyframed.
pub trait KeyframeValue: Clone + PartialEq + Debug + Serialize + DeserializeOwned {
    /// `a + (b - a) * t`.
    fn lerp(a: &Self, b: &Self, t: f64) -> Self;
    /// `a + b`.
    fn plus(a: &Self, b: &Self) -> Self;
    /// `a - b`.
    fn minus(a: &Self, b: &Self) -> Self;
    /// Speed measure of a difference: signed for scalars, length for vectors.
    fn speed_magnitude(&self) -> f64;
    /// Value between two keys at eased progress `p` (spatial for `Vec2`). `p` may leave 0...1 (overshoot).
    fn interpolate(a: &Keyframe<Self>, b: &Keyframe<Self>, p: f64) -> Self {
        Self::lerp(&a.value, &b.value, p)
    }
}

impl KeyframeValue for f64 {
    fn lerp(a: &f64, b: &f64, t: f64) -> f64 {
        a + (b - a) * t
    }
    fn plus(a: &f64, b: &f64) -> f64 {
        a + b
    }
    fn minus(a: &f64, b: &f64) -> f64 {
        a - b
    }
    fn speed_magnitude(&self) -> f64 {
        *self
    }
}

impl KeyframeValue for Vec2 {
    fn lerp(a: &Vec2, b: &Vec2, t: f64) -> Vec2 {
        *a + (*b - *a) * t
    }
    fn plus(a: &Vec2, b: &Vec2) -> Vec2 {
        *a + *b
    }
    fn minus(a: &Vec2, b: &Vec2) -> Vec2 {
        *a - *b
    }
    fn speed_magnitude(&self) -> f64 {
        self.length()
    }
    fn interpolate(a: &Keyframe<Vec2>, b: &Keyframe<Vec2>, p: f64) -> Vec2 {
        if a.out_tangent == Vec2::ZERO && b.in_tangent == Vec2::ZERO {
            return Vec2::lerp(&a.value, &b.value, p);
        }
        SpatialPath::new(
            a.value,
            a.value + a.out_tangent,
            b.value + b.in_tangent,
            b.value,
            SpatialPath::DEFAULT_RESOLUTION,
        )
        .point_at_arc_fraction(p.clamp(0.0, 1.0))
    }
}

/// Shape of the outgoing segment. UI glyph: diamond / square / circle.
///
/// `Hold` shows the key's value up to the next key. `HoldAhead` is a Hold played backwards (what a reverse turns a
/// Hold into): the key shows its own value on its own time only and the next key's value right after it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Interpolation {
    /// Straight or eased by handles.
    Linear,
    /// Steps: the key's value up to the next key.
    Hold,
    /// Curve with ease handles.
    Bezier,
    /// Steps: the next key's value right after this key.
    HoldAhead,
}

impl Interpolation {
    /// A stepped segment (Hold or Hold Ahead): no movement, speed 0, no ease handles.
    pub fn is_hold(self) -> bool {
        self == Interpolation::Hold || self == Interpolation::HoldAhead
    }

    /// The same step as an ease shape: a curve only knows Hold.
    #[doc(hidden)]
    pub fn as_ease(self) -> Interpolation {
        if self == Interpolation::HoldAhead { Interpolation::Hold } else { self }
    }

    /// The shape that plays this one backwards: Hold and Hold Ahead swap, curves stay.
    #[doc(hidden)]
    pub fn mirrored(self) -> Interpolation {
        match self {
            Interpolation::Hold => Interpolation::HoldAhead,
            Interpolation::HoldAhead => Interpolation::Hold,
            Interpolation::Linear | Interpolation::Bezier => self,
        }
    }
}

/// Bezier handle in normalized segment space. `dx` in 0...1 (time influence), `dy` free (overshoot allowed).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct EaseHandle {
    /// Time influence.
    pub dx: f64,
    /// Value influence.
    pub dy: f64,
}

impl EaseHandle {
    /// Handle of a straight segment.
    pub const LINEAR: EaseHandle = EaseHandle { dx: 1.0 / 3.0, dy: 1.0 / 3.0 };
}

/// One key of a track. Times are clip-local.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(bound(deserialize = "V: KeyframeValue"))]
pub struct Keyframe<V> {
    /// Identity across edits.
    pub id: Id,
    /// Key time.
    pub time: Time,
    /// Key value.
    pub value: V,
    /// Shape of the outgoing segment.
    #[serde(default = "linear")]
    pub interpolation: Interpolation,
    /// Ease handle on the incoming side.
    #[serde(rename = "inHandle", default = "linear_handle")]
    pub in_handle: EaseHandle,
    /// Ease handle on the outgoing side.
    #[serde(rename = "outHandle", default = "linear_handle")]
    pub out_handle: EaseHandle,
    /// Spatial tangent (used by `Vec2` only); zero = straight.
    #[serde(rename = "inTangent", default = "zero")]
    pub in_tangent: Vec2,
    /// Spatial tangent (used by `Vec2` only); zero = straight.
    #[serde(rename = "outTangent", default = "zero")]
    pub out_tangent: Vec2,
}

fn linear() -> Interpolation {
    Interpolation::Linear
}
fn linear_handle() -> EaseHandle {
    EaseHandle::LINEAR
}
fn zero() -> Vec2 {
    Vec2::ZERO
}

impl<V> Keyframe<V> {
    /// A linear key with straight handles and no tangents.
    pub fn new(id: Id, time: Time, value: V) -> Keyframe<V> {
        Keyframe {
            id,
            time,
            value,
            interpolation: Interpolation::Linear,
            in_handle: EaseHandle::LINEAR,
            out_handle: EaseHandle::LINEAR,
            in_tangent: Vec2::ZERO,
            out_tangent: Vec2::ZERO,
        }
    }
}

/// Inside a project file scope (`EncodeContext`) fields at their defaults are left out (v36); a Hold Ahead marks v77.
impl<V: Serialize> Serialize for Keyframe<V> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let full = !EncodeContext::compact_keyframes();
        if self.interpolation == Interpolation::HoldAhead {
            EncodeContext::mark(Seen::HoldAhead);
        }
        let mut c = s.serialize_struct("Keyframe", 8)?;
        c.serialize_field("id", &self.id)?;
        c.serialize_field("time", &self.time)?;
        c.serialize_field("value", &self.value)?;
        if full || self.interpolation != Interpolation::Linear {
            c.serialize_field("interpolation", &self.interpolation)?;
        }
        if full || self.in_handle != EaseHandle::LINEAR {
            c.serialize_field("inHandle", &self.in_handle)?;
        }
        if full || self.out_handle != EaseHandle::LINEAR {
            c.serialize_field("outHandle", &self.out_handle)?;
        }
        if full || self.in_tangent != Vec2::ZERO {
            c.serialize_field("inTangent", &self.in_tangent)?;
        }
        if full || self.out_tangent != Vec2::ZERO {
            c.serialize_field("outTangent", &self.out_tangent)?;
        }
        c.end()
    }
}

/// Float math shared by the keyframe code.
#[doc(hidden)]
pub mod keyframe_math {
    use crate::{EaseHandle, Time};

    /// `t` in seconds.
    pub fn seconds(t: Time) -> f64 {
        t.value() as f64 / t.timescale() as f64
    }

    /// `n / d` via exact i128 cross-multiplication. `d` must be positive.
    pub fn ratio(n: Time, d: Time) -> f64 {
        let num = n.value() as i128 * d.timescale() as i128;
        let den = n.timescale() as i128 * d.value() as i128;
        num as f64 / den as f64
    }

    /// Cubic bezier (0,0) (x1,y1) (x2,y2) (1,1): x(s).
    pub fn bx(s: f64, x1: f64, x2: f64) -> f64 {
        let u = 1.0 - s;
        3.0 * u * u * s * x1 + 3.0 * u * s * s * x2 + s * s * s
    }

    /// dx/ds.
    pub fn dbx(s: f64, x1: f64, x2: f64) -> f64 {
        let u = 1.0 - s;
        3.0 * u * u * x1 + 6.0 * u * s * (x2 - x1) + 3.0 * s * s * (1.0 - x2)
    }

    /// Solves x(s) = t by Newton, bisection as fallback.
    pub fn solve(t: f64, x1: f64, x2: f64) -> f64 {
        if t <= 0.0 {
            return 0.0;
        }
        if t >= 1.0 {
            return 1.0;
        }
        let mut s = t;
        for _ in 0..8 {
            let err = bx(s, x1, x2) - t;
            if err.abs() < 1e-12 {
                return s;
            }
            let d = dbx(s, x1, x2);
            if d.abs() < 1e-9 {
                break;
            }
            let n = s - err / d;
            if !(0.0..=1.0).contains(&n) {
                break;
            }
            s = n;
        }
        if (bx(s, x1, x2) - t).abs() < 1e-10 {
            return s;
        }
        let (mut lo, mut hi) = (0.0, 1.0);
        for _ in 0..60 {
            let m = (lo + hi) / 2.0;
            if bx(m, x1, x2) < t {
                lo = m;
            } else {
                hi = m;
            }
        }
        (lo + hi) / 2.0
    }

    /// Eased progress for normalized time `t` on a bezier segment.
    pub fn bezier_progress(t: f64, out: EaseHandle, in_h: EaseHandle) -> f64 {
        let x1 = out.dx.clamp(0.0, 1.0);
        let x2 = 1.0 - in_h.dx.clamp(0.0, 1.0);
        let s = solve(t, x1, x2);
        bx(s, out.dy, 1.0 - in_h.dy)
    }
}

/// Keys sorted by time, unique times.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "KeyframeTrackFields<V>", bound(serialize = "V: Serialize", deserialize = "V: KeyframeValue"))]
pub struct KeyframeTrack<V> {
    /// Sorted by time, unique times and ids. Read freely; only the core crates write it directly.
    pub keys: Vec<Keyframe<V>>,
}

/// The coded shape of a track; decoding sorts and folds legacy Hold pairs.
#[derive(Deserialize)]
#[serde(bound(deserialize = "V: KeyframeValue"))]
struct KeyframeTrackFields<V> {
    keys: Vec<Keyframe<V>>,
}

impl<V: KeyframeValue> From<KeyframeTrackFields<V>> for KeyframeTrack<V> {
    fn from(f: KeyframeTrackFields<V>) -> Self {
        let mut t = KeyframeTrack::with_keys(f.keys);
        t.fold_legacy_hold_helpers();
        t
    }
}

impl<V> Default for KeyframeTrack<V> {
    fn default() -> Self {
        KeyframeTrack { keys: Vec::new() }
    }
}

impl<V: KeyframeValue> KeyframeTrack<V> {
    /// No keys.
    pub fn new() -> Self {
        Self::default()
    }

    /// Sorts; on identical times or ids the later element wins.
    pub fn with_keys(keys: Vec<Keyframe<V>>) -> Self {
        if keys.len() < 2 {
            return KeyframeTrack { keys };
        }
        // Fast path (long generated tracks): already strictly increasing with unique ids gives the same result.
        let increasing = keys.windows(2).all(|w| w[0].time < w[1].time);
        if increasing && keys.iter().map(|k| k.id).collect::<HashSet<_>>().len() == keys.len() {
            return KeyframeTrack { keys };
        }
        let mut t = KeyframeTrack::new();
        for k in keys {
            t.insert(k);
        }
        t
    }

    /// No keys.
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// The key with `id`.
    pub fn key(&self, id: Id) -> Option<&Keyframe<V>> {
        self.keys.iter().find(|k| k.id == id)
    }

    /// Position of the key with `id`.
    #[doc(hidden)]
    pub fn index_of(&self, id: Id) -> Option<usize> {
        self.keys.iter().position(|k| k.id == id)
    }

    /// Inserts; replaces any key with the same id or at the identical time.
    pub fn insert(&mut self, key: Keyframe<V>) {
        self.keys.retain(|k| k.id != key.id && k.time != key.time);
        let i = self.keys.iter().position(|k| k.time > key.time).unwrap_or(self.keys.len());
        self.keys.insert(i, key);
    }

    /// Removes the key with `id`.
    pub fn remove(&mut self, id: Id) {
        self.keys.retain(|k| k.id != id);
    }

    /// Moves a key (Swift `move`); a key at the destination time is replaced (the moved key wins).
    pub fn move_key(&mut self, id: Id, time: Time) {
        let Some(mut k) = self.key(id).cloned() else { return };
        k.time = time;
        self.insert(k);
    }

    /// Sets the value of the key with `id`.
    pub fn set(&mut self, id: Id, value: V) {
        if let Some(i) = self.index_of(id) {
            self.keys[i].value = value;
        }
    }

    /// Mutates a key in place; its time and id cannot change (use `move_key`).
    pub fn update(&mut self, id: Id, body: impl FnOnce(&mut Keyframe<V>)) {
        let Some(i) = self.index_of(id) else { return };
        let (t, kid) = (self.keys[i].time, self.keys[i].id);
        body(&mut self.keys[i]);
        self.keys[i].time = t;
        self.keys[i].id = kid;
    }

    /// Edits the keys as a list; the result is put in time order (later wins on one time).
    pub fn edit_keys<R>(&mut self, body: impl FnOnce(&mut Vec<Keyframe<V>>) -> R) -> R {
        let mut own = std::mem::take(&mut self.keys);
        let r = body(&mut own);
        self.keys = KeyframeTrack::with_keys(own).keys;
        r
    }

    /// The key after the key with `id`.
    pub fn next_key_of(&self, id: Id) -> Option<&Keyframe<V>> {
        self.index_of(id).and_then(|i| self.keys.get(i + 1))
    }

    /// The key before the key with `id`.
    pub fn previous_key_of(&self, id: Id) -> Option<&Keyframe<V>> {
        self.index_of(id).and_then(|i| i.checked_sub(1)).and_then(|i| self.keys.get(i))
    }

    /// First key after `t`.
    pub fn next_key_after(&self, t: Time) -> Option<&Keyframe<V>> {
        self.keys.iter().find(|k| k.time > t)
    }

    /// Last key before `t`.
    pub fn previous_key_before(&self, t: Time) -> Option<&Keyframe<V>> {
        self.keys.iter().rev().find(|k| k.time < t)
    }

    /// Value of one segment at normalized time `tn` in 0...1.
    #[doc(hidden)]
    pub fn segment_value(a: &Keyframe<V>, b: &Keyframe<V>, tn: f64) -> V {
        // Each key owns its handles: the curve uses a's out side and b's in side, whatever a's shape.
        if a.interpolation == Interpolation::Hold {
            return a.value.clone();
        }
        if a.interpolation == Interpolation::HoldAhead {
            return if tn > 0.0 { b.value.clone() } else { a.value.clone() };
        }
        if a.out_handle == EaseHandle::LINEAR && b.in_handle == EaseHandle::LINEAR {
            return V::interpolate(a, b, tn);
        }
        let p = keyframe_math::bezier_progress(tn, a.out_handle, b.in_handle);
        V::interpolate(a, b, p)
    }

    /// Index `i` of the segment holding `t` (`keys[i].time <= t < keys[i + 1].time`); `None` before the first key,
    /// from the last key on, or with fewer than two keys.
    #[doc(hidden)]
    pub fn segment_index(&self, t: Time) -> Option<usize> {
        let n = self.keys.len();
        if n < 2 || t < self.keys[0].time || t >= self.keys[n - 1].time {
            return None;
        }
        Some(self.bracket(t).0)
    }

    /// `(lo, hi)` with `keys[lo].time <= t < keys[hi].time`; needs `keys[0].time <= t < keys[last].time`.
    fn bracket(&self, t: Time) -> (usize, usize) {
        let (mut lo, mut hi) = (0, self.keys.len() - 1);
        while hi - lo > 1 {
            let m = (lo + hi) / 2;
            if self.keys[m].time <= t {
                lo = m;
            } else {
                hi = m;
            }
        }
        (lo, hi)
    }

    /// Value at `t`; clamped before the first and after the last key. `None` if empty.
    pub fn value(&self, t: Time) -> Option<V> {
        let (first, last) = (self.keys.first()?, self.keys.last()?);
        if t <= first.time {
            return Some(first.value.clone());
        }
        if t >= last.time {
            return Some(last.value.clone());
        }
        let (lo, hi) = self.bracket(t);
        let (a, b) = (&self.keys[lo], &self.keys[hi]);
        if t == a.time {
            return Some(a.value.clone());
        }
        Some(Self::segment_value(a, b, keyframe_math::ratio(t - a.time, b.time - a.time)))
    }

    /// Before v77 a reverse wrote a Hold Ahead as a Hold leader plus a hidden Hold helper one microsecond later on the
    /// next key's value. Folds every such pair into one Hold Ahead key (any decoded track, any file version).
    fn fold_legacy_hold_helpers(&mut self) {
        if self.keys.len() < 3 {
            return;
        }
        let step = Time::new(1, 1_000_000);
        let mut j = 1;
        while j + 1 < self.keys.len() {
            let (k, leader) = (&self.keys[j], &self.keys[j - 1]);
            if k.interpolation == Interpolation::Hold
                && leader.interpolation == Interpolation::Hold
                && k.time - leader.time <= step
                && k.value == self.keys[j + 1].value
                && k.in_handle == EaseHandle::LINEAR
                && k.out_handle == EaseHandle::LINEAR
                && k.in_tangent == Vec2::ZERO
                && k.out_tangent == Vec2::ZERO
            {
                self.keys[j - 1].interpolation = Interpolation::HoldAhead;
                self.keys.remove(j);
            }
            j += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(id: u128, t: i64, v: f64) -> Keyframe<f64> {
        Keyframe::new(Id::from_u128(id), Time::new(t, 30), v)
    }

    #[test]
    fn insert_sorts_and_replaces_same_time() {
        let mut tr = KeyframeTrack::with_keys(vec![key(1, 10, 1.0), key(2, 0, 0.0), key(3, 10, 5.0)]);
        assert_eq!(tr.keys.iter().map(|k| k.id).collect::<Vec<_>>(), vec![Id::from_u128(2), Id::from_u128(3)]);
        tr.move_key(Id::from_u128(2), Time::new(10, 30));
        assert_eq!(tr.keys.len(), 1);
    }

    #[test]
    fn value_clamps_and_interpolates() {
        let mut tr = KeyframeTrack::with_keys(vec![key(1, 0, 0.0), key(2, 30, 10.0)]);
        assert_eq!(tr.value(Time::new(-1, 1)), Some(0.0));
        assert_eq!(tr.value(Time::new(15, 30)), Some(5.0));
        assert_eq!(tr.value(Time::new(2, 1)), Some(10.0));
        tr.update(Id::from_u128(1), |k| k.interpolation = Interpolation::HoldAhead);
        assert_eq!(tr.value(Time::new(1, 30)), Some(10.0));
        assert_eq!(tr.segment_index(Time::new(1, 30)), Some(0));
    }

    #[test]
    fn legacy_hold_pairs_fold_into_hold_ahead() {
        let mut leader = key(1, 0, 0.0);
        leader.interpolation = Interpolation::Hold;
        let mut helper = Keyframe::new(Id::from_u128(2), Time::new(1, 1_000_000), 7.0);
        helper.interpolation = Interpolation::Hold;
        let mut tr = KeyframeTrack::with_keys(vec![leader, helper, key(3, 30, 7.0)]);
        tr.fold_legacy_hold_helpers();
        assert_eq!(tr.keys.len(), 2);
        assert_eq!(tr.keys[0].interpolation, Interpolation::HoldAhead);
    }
}
