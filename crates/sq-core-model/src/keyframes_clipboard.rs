// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesClipboard.swift (ported by task M-3). The clipboard lives in memory only, so it has no serde code.

use crate::keyframes_editing::{PropertyID, PropertyTrack};
use crate::keyframes_pair::KeyframesPair;
use crate::{AnimatedProperty, EffectColor, MaskPath};
use sq_core_time::{EaseHandle, Id, IdSource, Interpolation, Keyframe, KeyframeTrack, KeyframeValue, Time, Vec2};
use std::collections::{BTreeMap, BTreeSet};
use std::ops::RangeInclusive;

/// One copied key: the time is relative to the earliest copied key.
#[derive(Clone, Debug, PartialEq)]
pub struct KeyframeClipboardKey<V> {
    /// Time after the earliest copied key.
    pub relative_time: Time,
    /// Key value.
    pub value: V,
    /// Shape of the outgoing segment.
    pub interpolation: Interpolation,
    /// Ease handle on the incoming side.
    pub in_handle: EaseHandle,
    /// Ease handle on the outgoing side.
    pub out_handle: EaseHandle,
    /// Spatial tangent in.
    pub in_tangent: Vec2,
    /// Spatial tangent out.
    pub out_tangent: Vec2,
}

impl<V: Clone> KeyframeClipboardKey<V> {
    fn new(k: &Keyframe<V>, origin: Time) -> Self {
        KeyframeClipboardKey {
            relative_time: k.time - origin,
            value: k.value.clone(),
            interpolation: k.interpolation,
            in_handle: k.in_handle,
            out_handle: k.out_handle,
            in_tangent: k.in_tangent,
            out_tangent: k.out_tangent,
        }
    }

    /// A key with a fresh id at `origin + relative_time`.
    fn keyframe(&self, origin: Time, id: Id) -> Keyframe<V> {
        Keyframe {
            id,
            time: origin + self.relative_time,
            value: self.value.clone(),
            interpolation: self.interpolation,
            in_handle: self.in_handle,
            out_handle: self.out_handle,
            in_tangent: self.in_tangent,
            out_tangent: self.out_tangent,
        }
    }
}

/// The copied keys of one property, by value type.
#[derive(Clone, Debug, PartialEq)]
pub enum KeyframeClipboardTrack {
    /// Number keys.
    Scalar(Vec<KeyframeClipboardKey<f64>>),
    /// Point keys.
    Vector(Vec<KeyframeClipboardKey<Vec2>>),
    /// Color keys.
    Color(Vec<KeyframeClipboardKey<EffectColor>>),
    /// Mask path keys.
    Path(Vec<KeyframeClipboardKey<MaskPath>>),
}

/// Copied keyframes of several properties as relative times plus easing.
#[derive(Clone, Debug, PartialEq)]
pub struct KeyframeClipboard {
    tracks: BTreeMap<PropertyID, KeyframeClipboardTrack>,
}

fn keys_of<V: KeyframeValue>(t: &KeyframeTrack<V>, ids: &BTreeSet<Id>, origin: Time) -> Vec<KeyframeClipboardKey<V>> {
    t.keys.iter().filter(|k| ids.contains(&k.id)).map(|k| KeyframeClipboardKey::new(k, origin)).collect()
}

/// The keys inside `range` (when given) as keys with fresh ids.
fn pasted<V: Clone>(
    ks: &[KeyframeClipboardKey<V>],
    at: Time,
    within: Option<&RangeInclusive<Time>>,
    ids: &mut dyn IdSource,
) -> Vec<Keyframe<V>> {
    ks.iter()
        .filter(|k| within.is_none_or(|r| r.contains(&(at + k.relative_time))))
        .map(|k| k.keyframe(at, ids.next_id()))
        .collect()
}

fn pasted_track<V: KeyframeValue>(
    ks: &[KeyframeClipboardKey<V>],
    mut tr: KeyframeTrack<V>,
    at: Time,
    within: Option<&RangeInclusive<Time>>,
    ids: &mut dyn IdSource,
) -> KeyframeTrack<V> {
    for k in pasted(ks, at, within, ids) {
        tr.insert(k);
    }
    tr
}

impl KeyframeClipboard {
    pub(crate) fn from_tracks(tracks: BTreeMap<PropertyID, KeyframeClipboardTrack>) -> KeyframeClipboard {
        KeyframeClipboard { tracks }
    }

    /// The copied tracks by property.
    pub fn tracks(&self) -> &BTreeMap<PropertyID, KeyframeClipboardTrack> {
        &self.tracks
    }

    /// Copies the selected keys (per property). `None` if nothing is selected.
    pub fn copy(
        source: &BTreeMap<PropertyID, PropertyTrack>,
        selection: &BTreeMap<PropertyID, BTreeSet<Id>>,
    ) -> Option<KeyframeClipboard> {
        let mut earliest: Option<Time> = None;
        for (p, ids) in selection {
            for (id, time) in source.get(p).map(PropertyTrack::times).unwrap_or_default() {
                if ids.contains(&id) {
                    earliest = Some(earliest.map_or(time, |e| e.min(time)));
                }
            }
        }
        let origin = earliest?;
        let mut out = BTreeMap::new();
        for (p, ids) in selection {
            let track = match source.get(p) {
                Some(PropertyTrack::Scalar(t)) => KeyframeClipboardTrack::Scalar(keys_of(t, ids, origin)),
                Some(PropertyTrack::Vector(t)) => KeyframeClipboardTrack::Vector(keys_of(t, ids, origin)),
                Some(PropertyTrack::Color(t)) => KeyframeClipboardTrack::Color(keys_of(t, ids, origin)),
                Some(PropertyTrack::Path(t)) => KeyframeClipboardTrack::Path(keys_of(t, ids, origin)),
                None => continue,
            };
            if !track.is_empty() {
                out.insert(p.clone(), track);
            }
        }
        if out.is_empty() { None } else { Some(KeyframeClipboard::from_tracks(out)) }
    }

    /// The vector keys copied for `property` pasted into the two members of an X/Y pair row
    /// (`KeyframesPair::paste`), with the times and the range of `paste`. False without vector keys for it.
    pub fn paste_pair(
        &self,
        property: &PropertyID,
        x: &mut AnimatedProperty<f64>,
        y: &mut AnimatedProperty<f64>,
        at: Time,
        within: Option<&RangeInclusive<Time>>,
        ids: &mut dyn IdSource,
    ) -> bool {
        let Some(KeyframeClipboardTrack::Vector(ks)) = self.tracks.get(property) else { return false };
        let keys = pasted(ks, at, within, ids);
        KeyframesPair::paste(&keys, x, y, ids);
        true
    }

    /// Keys outside `within` (clip-local, e.g. the clip's extent) are dropped. Pastes so the earliest copied key
    /// lands at `at`; keys at identical times are replaced. A missing target property gets a new track. Returns
    /// false and changes nothing if any target property has a different value type.
    pub fn paste(
        &self,
        target: &mut BTreeMap<PropertyID, PropertyTrack>,
        at: Time,
        within: Option<&RangeInclusive<Time>>,
        ids: &mut dyn IdSource,
    ) -> bool {
        for (p, clip) in &self.tracks {
            let fits = matches!(
                (clip, target.get(p)),
                (_, None)
                    | (KeyframeClipboardTrack::Scalar(_), Some(PropertyTrack::Scalar(_)))
                    | (KeyframeClipboardTrack::Vector(_), Some(PropertyTrack::Vector(_)))
                    | (KeyframeClipboardTrack::Color(_), Some(PropertyTrack::Color(_)))
                    | (KeyframeClipboardTrack::Path(_), Some(PropertyTrack::Path(_)))
            );
            if !fits {
                return false;
            }
        }
        for (p, clip) in &self.tracks {
            let merged = match (clip, target.get(p)) {
                (KeyframeClipboardTrack::Scalar(ks), existing) => {
                    let tr = match existing {
                        Some(PropertyTrack::Scalar(e)) => e.clone(),
                        _ => KeyframeTrack::new(),
                    };
                    PropertyTrack::Scalar(pasted_track(ks, tr, at, within, ids))
                }
                (KeyframeClipboardTrack::Vector(ks), existing) => {
                    let tr = match existing {
                        Some(PropertyTrack::Vector(e)) => e.clone(),
                        _ => KeyframeTrack::new(),
                    };
                    PropertyTrack::Vector(pasted_track(ks, tr, at, within, ids))
                }
                (KeyframeClipboardTrack::Color(ks), existing) => {
                    let tr = match existing {
                        Some(PropertyTrack::Color(e)) => e.clone(),
                        _ => KeyframeTrack::new(),
                    };
                    PropertyTrack::Color(pasted_track(ks, tr, at, within, ids))
                }
                (KeyframeClipboardTrack::Path(ks), existing) => {
                    let tr = match existing {
                        Some(PropertyTrack::Path(e)) => e.clone(),
                        _ => KeyframeTrack::new(),
                    };
                    PropertyTrack::Path(pasted_track(ks, tr, at, within, ids))
                }
            };
            target.insert(p.clone(), merged);
        }
        true
    }
}

impl KeyframeClipboardTrack {
    /// Number of copied keys.
    pub fn len(&self) -> usize {
        match self {
            KeyframeClipboardTrack::Scalar(k) => k.len(),
            KeyframeClipboardTrack::Vector(k) => k.len(),
            KeyframeClipboardTrack::Color(k) => k.len(),
            KeyframeClipboardTrack::Path(k) => k.len(),
        }
    }

    /// No key copied.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keyframes_editing::test_support::{FreshIds, id, key, t};

    fn sample() -> (BTreeMap<PropertyID, PropertyTrack>, BTreeMap<PropertyID, BTreeSet<Id>>) {
        let mut a = key(1, 1, 10.0);
        a.interpolation = Interpolation::Bezier;
        a.out_handle = EaseHandle { dx: 0.5, dy: 0.2 };
        let b = key(3, 3, 20.0);
        let c = Keyframe::new(id(11), t(2), Vec2::new(5.0, 6.0));
        let d = Keyframe::new(id(12), t(9), Vec2::new(7.0, 8.0));
        let tracks = BTreeMap::from([
            ("opacity".into(), PropertyTrack::Scalar(KeyframeTrack::with_keys(vec![a, b]))),
            ("position".into(), PropertyTrack::Vector(KeyframeTrack::with_keys(vec![c, d]))),
        ]);
        let sel = BTreeMap::from([
            ("opacity".into(), BTreeSet::from([id(1), id(3)])),
            ("position".into(), BTreeSet::from([id(11)])),
        ]);
        (tracks, sel)
    }

    #[test]
    fn kf_copy_paste_relative_and_easing_kept() {
        let (tracks, sel) = sample();
        let clip = KeyframeClipboard::copy(&tracks, &sel).expect("copied");
        let mut target = BTreeMap::new();
        let mut ids = FreshIds::new();
        assert!(clip.paste(&mut target, t(10), None, &mut ids));
        let (Some(PropertyTrack::Scalar(o)), Some(PropertyTrack::Vector(p))) =
            (target.get(&"opacity".into()), target.get(&"position".into()))
        else {
            panic!("missing");
        };
        // The earliest copied key (t=1) lands at 10.
        assert_eq!(o.keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![t(10), t(12)]);
        assert_eq!(o.keys[0].out_handle, EaseHandle { dx: 0.5, dy: 0.2 });
        assert_eq!(o.keys[0].interpolation, Interpolation::Bezier);
        assert_eq!(p.keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![t(11)]);
        assert_eq!(p.keys[0].value, Vec2::new(5.0, 6.0));
        assert_ne!(o.keys[0].id, id(1));
    }

    #[test]
    fn kf_paste_replaces_keys_at_identical_times() {
        let (tracks, sel) = sample();
        let clip = KeyframeClipboard::copy(&tracks, &sel).expect("copied");
        let existing = KeyframeTrack::with_keys(vec![key(20, 10, -1.0), key(21, 11, -2.0)]);
        let mut target = BTreeMap::from([("opacity".into(), PropertyTrack::Scalar(existing))]);
        assert!(clip.paste(&mut target, t(10), None, &mut FreshIds::new()));
        let Some(PropertyTrack::Scalar(o)) = target.get(&"opacity".into()) else { panic!("missing") };
        assert_eq!(o.keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![t(10), t(11), t(12)]);
        assert_eq!(o.keys[0].value, 10.0);
        assert_eq!(o.keys[1].value, -2.0);
    }

    #[test]
    fn kf_paste_rejects_type_mismatch_atomically() {
        let (tracks, sel) = sample();
        let clip = KeyframeClipboard::copy(&tracks, &sel).expect("copied");
        let wrong: BTreeMap<PropertyID, PropertyTrack> = BTreeMap::from([
            ("position".into(), PropertyTrack::Scalar(KeyframeTrack::with_keys(vec![key(30, 0, 1.0)]))),
            ("opacity".into(), PropertyTrack::Scalar(KeyframeTrack::new())),
        ]);
        let mut target = wrong.clone();
        assert!(!clip.paste(&mut target, t(0), None, &mut FreshIds::new()));
        assert_eq!(target, wrong);
    }

    #[test]
    fn kf_copy_empty_selection_is_none() {
        let (tracks, _) = sample();
        assert!(KeyframeClipboard::copy(&tracks, &BTreeMap::new()).is_none());
    }

    #[test]
    fn paste_drops_keys_outside_the_range() {
        let (tracks, sel) = sample();
        let clip = KeyframeClipboard::copy(&tracks, &sel).expect("copied");
        let mut target = BTreeMap::new();
        let range = t(0)..=t(11);
        assert!(clip.paste(&mut target, t(10), Some(&range), &mut FreshIds::new()));
        let Some(PropertyTrack::Scalar(o)) = target.get(&"opacity".into()) else { panic!("missing") };
        assert_eq!(o.keys.len(), 1);
    }
}
