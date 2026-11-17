// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesEaseSelection.swift (saved type `EaseShape`; selection logic ported by task M-3)

use crate::keyframes_editing::{KeyframeSummary, PropertyID, PropertyTrack, SummaryMember, each_track};
use serde::{Deserialize, Deserializer, Serialize};
use sq_core_time::{EaseHandle, EaseSide, EasingCurve, Id, Interpolation, KeyframeTrack, KeyframeValue};
use std::collections::{BTreeMap, BTreeSet};

/// The temporal shape of one segment (left key's outgoing interpolation, its out-handle, the right key's in-handle)
/// in normalized segment space. A Hold Ahead reads as Hold (`interpolation` is always `as_ease`d).
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct EaseShape {
    interpolation: Interpolation,
    /// Out-handle of the left key.
    pub out: EaseHandle,
    /// In-handle of the right key.
    #[serde(rename = "in")]
    pub r#in: EaseHandle,
}

impl EaseShape {
    /// A shape; a Hold Ahead interpolation is stored as Hold.
    pub fn new(interpolation: Interpolation, out: EaseHandle, r#in: EaseHandle) -> EaseShape {
        EaseShape { interpolation: interpolation.as_ease(), out, r#in }
    }

    /// The left key's outgoing interpolation (never Hold Ahead).
    pub fn interpolation(&self) -> Interpolation {
        self.interpolation
    }

    /// Sets the interpolation (Swift `didSet`: Hold Ahead becomes Hold).
    pub fn set_interpolation(&mut self, interpolation: Interpolation) {
        self.interpolation = interpolation.as_ease();
    }
}

impl<'de> Deserialize<'de> for EaseShape {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<EaseShape, D::Error> {
        #[derive(Deserialize)]
        struct Raw {
            interpolation: Interpolation,
            out: EaseHandle,
            #[serde(rename = "in")]
            r#in: EaseHandle,
        }
        let r = Raw::deserialize(d)?;
        Ok(EaseShape::new(r.interpolation, r.out, r.r#in))
    }
}

impl EaseShape {
    /// Straight segment.
    pub const LINEAR: EaseShape =
        EaseShape { interpolation: Interpolation::Linear, out: EaseHandle::LINEAR, r#in: EaseHandle::LINEAR };
    /// Stepped segment.
    pub const HOLD: EaseShape =
        EaseShape { interpolation: Interpolation::Hold, out: EaseHandle::LINEAR, r#in: EaseHandle::LINEAR };

    /// What the segment actually does, as the evaluator sees it (`KeyframeTrack::segment_value`): hold ignores the
    /// handles; otherwise the handles decide whatever the left key's interpolation says (Premiere's Ease In leaves
    /// the left key linear and eases only the right key's in side). Straight handles are linear.
    pub fn effective(&self) -> EaseShape {
        if self.interpolation.is_hold() {
            return EaseShape::HOLD;
        }
        let s = EaseShape::new(Interpolation::Bezier, Self::clamped(self.out), Self::clamped(self.r#in));
        if s.out == EaseHandle::LINEAR && s.r#in == EaseHandle::LINEAR { EaseShape::LINEAR } else { s }
    }

    /// `is_approximately_equal_within` at the default tolerance of 1e-6.
    pub fn is_approximately_equal(&self, o: &EaseShape) -> bool {
        self.is_approximately_equal_within(o, 1e-6)
    }

    /// Whether the effective shapes agree within `tolerance` on every handle number.
    pub fn is_approximately_equal_within(&self, o: &EaseShape, tolerance: f64) -> bool {
        let (a, b) = (self.effective(), o.effective());
        a.interpolation == b.interpolation
            && [a.out.dx - b.out.dx, a.out.dy - b.out.dy, a.r#in.dx - b.r#in.dx, a.r#in.dy - b.r#in.dy]
                .iter()
                .all(|d| d.abs() <= tolerance)
    }

    /// The handle with `dx` limited to 0...1.
    #[doc(hidden)]
    pub fn clamped(h: EaseHandle) -> EaseHandle {
        EaseHandle { dx: h.dx.clamp(0.0, 1.0), dy: h.dy }
    }
}

/// One segment of a property track, named by its two keys. `side` is what may be written: `Both` when both keys are
/// selected, `Out` (left key's shape and out-handle) or `In` (right key's in-handle) when only that key is selected.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EaseSegment {
    /// The property the segment belongs to.
    pub property: PropertyID,
    /// Left key.
    pub from: Id,
    /// Right key.
    pub to: Id,
    /// What may be written.
    pub side: EaseSide,
}

impl EaseSegment {
    /// A segment with the given writable side.
    pub fn new(property: PropertyID, from: Id, to: Id, side: EaseSide) -> EaseSegment {
        EaseSegment { property, from, to, side }
    }
}

/// What the selected segments share.
#[derive(Clone, Debug, PartialEq)]
pub enum EaseReading {
    /// No segment.
    Empty,
    /// All segments have this effective shape.
    Common(EaseShape),
    /// Distinct effective shapes, in segment order.
    Mixed(Vec<EaseShape>),
}

/// The segments a key selection touches across all properties: per property, every segment whose two keys are both
/// selected; a property without a selected pair uses each selected key's outgoing segment (the incoming one for the
/// last key, unless the unselected key before it is Hold: that segment cannot ease without changing that key).
/// Only selected keys are ever written. Reads "common curve or mixed" and writes one curve to all of them.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EaseSelection {
    segments: Vec<EaseSegment>,
}

impl EaseSelection {
    /// `stepped`: properties that only switch from key to key (effect checkbox / choice): never eased, so skipped.
    pub fn new(
        summary: &KeyframeSummary,
        members: &BTreeSet<SummaryMember>,
        stepped: &BTreeSet<PropertyID>,
    ) -> EaseSelection {
        let mut by: BTreeMap<PropertyID, BTreeSet<Id>> = BTreeMap::new();
        for m in members.iter().filter(|m| !stepped.contains(&m.property)) {
            by.entry(m.property.clone()).or_default().insert(m.key_id);
        }
        let mut out = Vec::new();
        for (p, ids) in &by {
            let Some(track) = summary.tracks.get(p) else { continue };
            let keys = track.key_ids();
            if keys.len() < 2 {
                continue;
            }
            let pairs: Vec<usize> =
                (0..keys.len() - 1).filter(|&i| ids.contains(&keys[i]) && ids.contains(&keys[i + 1])).collect();
            if !pairs.is_empty() {
                out.extend(pairs.iter().map(|&i| EaseSegment::new(p.clone(), keys[i], keys[i + 1], EaseSide::Both)));
                continue;
            }
            // No pair here, so no two selected keys are neighbors: every lone key has its own segment.
            for i in (0..keys.len()).filter(|&i| ids.contains(&keys[i])) {
                if i + 1 < keys.len() {
                    out.push(EaseSegment::new(p.clone(), keys[i], keys[i + 1], EaseSide::Out));
                } else if !track.interpolation_of(keys[i - 1]).is_some_and(Interpolation::is_hold) {
                    out.push(EaseSegment::new(p.clone(), keys[i - 1], keys[i], EaseSide::In));
                }
            }
        }
        EaseSelection { segments: out }
    }

    /// The selected segments in property then time order.
    pub fn segments(&self) -> &[EaseSegment] {
        &self.segments
    }

    /// No segment is selected.
    pub fn is_empty(&self) -> bool {
        self.segments.is_empty()
    }

    /// The shape the segments share, or the distinct shapes.
    pub fn reading(&self, summary: &KeyframeSummary) -> EaseReading {
        let mut shapes: Vec<EaseShape> = Vec::new();
        for seg in &self.segments {
            let Some(s) = summary.tracks.get(&seg.property).and_then(|t| t.ease_shape(seg.from, seg.to)) else {
                continue;
            };
            let s = s.effective();
            if !shapes.iter().any(|x| x.is_approximately_equal(&s)) {
                shapes.push(s);
            }
        }
        match shapes.len() {
            0 => EaseReading::Empty,
            1 => EaseReading::Common(shapes[0]),
            _ => EaseReading::Mixed(shapes),
        }
    }

    /// Writes `shape` to every segment. Hold only changes the interpolation (the handles stay stored, like
    /// `toggle_hold`); linear resets both handles; bezier writes both handles (`dx` clamped to 0...1, `dy` kept).
    /// Returns segments written.
    pub fn apply(&self, shape: &EaseShape, summary: &mut KeyframeSummary) -> usize {
        let mut n = 0;
        for seg in &self.segments {
            let Some(t) = summary.tracks.get_mut(&seg.property) else { continue };
            if t.set_ease_shape(shape, seg.from, seg.to, seg.side) {
                n += 1;
            }
        }
        n
    }

    /// Hold or Hold Ahead on the left key of every segment that may write it (not a segment selected by its right
    /// key only: a hold has no in side). Unlike a `HOLD` shape this turns a Hold Ahead into a Hold and back. Returns
    /// segments written.
    pub fn set_hold_kind(&self, kind: Interpolation, summary: &mut KeyframeSummary) -> usize {
        if !kind.is_hold() {
            return 0;
        }
        let mut n = 0;
        for seg in self.segments.iter().filter(|s| s.side != EaseSide::In) {
            if let Some(t) = summary.tracks.get_mut(&seg.property) {
                t.set_hold_kind(kind, &BTreeSet::from([seg.from]));
                n += 1;
            }
        }
        n
    }
}

impl KeyframeSummary {
    /// The stored kind of a key: tells Hold and Hold Ahead apart, which an `EaseShape` does not.
    pub fn interpolation_of(&self, m: &SummaryMember) -> Option<Interpolation> {
        self.tracks.get(&m.property).and_then(|t| t.interpolation_of(m.key_id))
    }
}

/// Segment shapes of one track.
#[doc(hidden)]
pub trait KeyframeTrackEase {
    /// The shape of the segment `a` -> `b`; `None` if a key is missing.
    fn ease_shape(&self, a: Id, b: Id) -> Option<EaseShape>;

    /// `Out` writes only the left key (shape and out-handle), `In` only the right key's in-handle (Hold has no in
    /// side).
    fn set_ease_shape(&mut self, s: &EaseShape, a: Id, b: Id, side: EaseSide) -> bool;
}

impl<V: KeyframeValue> KeyframeTrackEase for KeyframeTrack<V> {
    fn ease_shape(&self, a: Id, b: Id) -> Option<EaseShape> {
        let (l, r) = (self.key(a)?, self.key(b)?);
        Some(EaseShape::new(l.interpolation, l.out_handle, r.in_handle))
    }

    fn set_ease_shape(&mut self, s: &EaseShape, a: Id, b: Id, side: EaseSide) -> bool {
        if self.index_of(a).is_none() || self.index_of(b).is_none() {
            return false;
        }
        let kind = s.interpolation();
        if side != EaseSide::In {
            self.update(a, |k| {
                // A Hold Ahead stays one.
                if !(kind == Interpolation::Hold && k.interpolation.is_hold()) {
                    k.interpolation = kind;
                }
                match kind {
                    Interpolation::Hold | Interpolation::HoldAhead => {}
                    Interpolation::Linear => k.out_handle = EaseHandle::LINEAR,
                    Interpolation::Bezier => k.out_handle = EaseShape::clamped(s.out),
                }
            });
        }
        if side != EaseSide::Out {
            self.update(b, |k| match kind {
                Interpolation::Hold | Interpolation::HoldAhead => {}
                Interpolation::Linear => k.in_handle = EaseHandle::LINEAR,
                Interpolation::Bezier => k.in_handle = EaseShape::clamped(s.r#in),
            });
        }
        true
    }
}

impl PropertyTrack {
    /// The shape of the segment `a` -> `b`; `None` if a key is missing.
    #[doc(hidden)]
    pub fn ease_shape(&self, a: Id, b: Id) -> Option<EaseShape> {
        each_track!(self, t => t.ease_shape(a, b))
    }

    /// See `KeyframeTrackEase::set_ease_shape`.
    #[doc(hidden)]
    pub fn set_ease_shape(&mut self, s: &EaseShape, a: Id, b: Id, side: EaseSide) -> bool {
        each_track!(self, t => t.set_ease_shape(s, a, b, side))
    }
}

/// An `EasingCurve` as a segment shape, and back.
pub trait EasingCurveShape {
    /// The curve as a segment shape (out of the left key, in of the right key).
    fn shape(&self) -> EaseShape;
    /// Payload format version for a PresetStore `.easing` item.
    const PRESET_PAYLOAD_VERSION: u32 = 1;
    /// Payload for a PresetStore `.easing` item (the item carries id and name).
    fn preset_payload(&self) -> Result<Vec<u8>, serde_json::Error>;
}

impl EasingCurveShape for EasingCurve {
    fn shape(&self) -> EaseShape {
        EaseShape::new(self.interpolation(), self.out_handle, self.in_handle)
    }

    fn preset_payload(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(&self.shape())
    }
}

/// A curve with the given shape (Swift `EasingCurve(id:shape:name:)`).
pub fn easing_curve_from_shape(id: Id, shape: &EaseShape, name: String) -> EasingCurve {
    EasingCurve::new(id, name, shape.interpolation(), shape.out, shape.r#in)
}

/// A curve from a PresetStore `.easing` payload (Swift `EasingCurve(presetPayload:name:id:)`).
pub fn easing_curve_from_preset_payload(data: &[u8], name: String, id: Id) -> Result<EasingCurve, serde_json::Error> {
    let shape: EaseShape = serde_json::from_slice(data)?;
    Ok(easing_curve_from_shape(id, &shape, name))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clip_color::test_util::{decode, round_trip};

    #[test]
    fn ease_shape_round_trips_with_the_in_key() {
        let e = round_trip::<EaseShape>(
            r#"{"interpolation":"bezier","out":{"dx":0.25,"dy":0.5},"in":{"dx":0.75,"dy":1.5}}"#,
        );
        assert_eq!((e.out.dx, e.r#in.dy), (0.25, 1.5));
    }

    #[test]
    fn hold_ahead_is_stored_and_read_as_hold() {
        let e = decode::<EaseShape>(r#"{"interpolation":"holdAhead","out":{"dx":0.5,"dy":0},"in":{"dx":0.5,"dy":0}}"#);
        assert_eq!(e.interpolation(), Interpolation::Hold);
        let mut f = EaseShape::new(Interpolation::Linear, EaseHandle::LINEAR, EaseHandle::LINEAR);
        f.set_interpolation(Interpolation::HoldAhead);
        assert_eq!(f.interpolation(), Interpolation::Hold);
    }

    #[test]
    fn ease_shape_needs_all_three_keys() {
        assert!(serde_json::from_str::<EaseShape>(r#"{"interpolation":"linear","out":{"dx":0,"dy":0}}"#).is_err());
    }

    // Selection, reading and apply (Swift KeyframeEaseSelectionTests).
    use crate::keyframes_editing::test_support::{id, key, scalar, t};
    use sq_core_time::Keyframe;

    fn vkey(n: u128, s: i64, v: f64, i: Interpolation) -> Keyframe<sq_core_time::Vec2> {
        let mut k = Keyframe::new(id(n), t(s), sq_core_time::Vec2::new(v, v));
        k.interpolation = i;
        k
    }

    fn kind(mut k: Keyframe<f64>, i: Interpolation) -> Keyframe<f64> {
        k.interpolation = i;
        k
    }

    fn fixture() -> (KeyframeSummary, Vec<Keyframe<sq_core_time::Vec2>>, Vec<Keyframe<f64>>) {
        let pos = vec![
            vkey(101, 0, 0.0, Interpolation::Linear),
            vkey(102, 2, 50.0, Interpolation::Linear),
            vkey(103, 4, 100.0, Interpolation::Linear),
        ];
        let scale = vec![key(1, 0, 100.0), key(2, 2, 120.0), key(3, 4, 80.0)];
        let s = KeyframeSummary::new(BTreeMap::from([
            ("position".into(), PropertyTrack::Vector(KeyframeTrack::with_keys(pos.clone()))),
            ("scale".into(), PropertyTrack::Scalar(KeyframeTrack::with_keys(scale.clone()))),
        ]));
        (s, pos, scale)
    }

    fn m(p: &str, id: Id) -> SummaryMember {
        SummaryMember::new(p.into(), id)
    }

    fn members(list: &[(&str, Id)]) -> BTreeSet<SummaryMember> {
        list.iter().map(|(p, id)| m(p, *id)).collect()
    }

    fn select(s: &KeyframeSummary, list: &[(&str, Id)]) -> EaseSelection {
        EaseSelection::new(s, &members(list), &BTreeSet::new())
    }

    fn snappy() -> EaseShape {
        EaseShape::new(Interpolation::Bezier, EaseHandle { dx: 0.2, dy: 0.9 }, EaseHandle { dx: 0.5, dy: -0.2 })
    }

    fn seg(p: &str, from: Id, to: Id, side: EaseSide) -> EaseSegment {
        EaseSegment::new(p.into(), from, to, side)
    }

    fn vector<'a>(s: &'a KeyframeSummary, p: &str) -> &'a KeyframeTrack<sq_core_time::Vec2> {
        match s.tracks.get(&p.into()) {
            Some(PropertyTrack::Vector(t)) => t,
            _ => panic!("vector track"),
        }
    }

    #[test]
    fn ease_selection_uses_fully_selected_segments_across_properties() {
        let (s, pos, scale) = fixture();
        let sel = select(
            &s,
            &[("position", pos[0].id), ("position", pos[1].id), ("scale", scale[0].id), ("scale", scale[1].id)],
        );
        assert_eq!(
            sel.segments(),
            [
                seg("position", pos[0].id, pos[1].id, EaseSide::Both),
                seg("scale", scale[0].id, scale[1].id, EaseSide::Both)
            ]
        );
    }

    #[test]
    fn ease_selection_three_keys_gives_two_segments() {
        let (s, pos, _) = fixture();
        let all: Vec<_> = pos.iter().map(|k| ("position", k.id)).collect();
        assert_eq!(select(&s, &all).segments().len(), 2);
    }

    #[test]
    fn lone_key_uses_the_outgoing_segment_and_the_last_key_the_incoming_one() {
        let (s, pos, _) = fixture();
        assert_eq!(
            select(&s, &[("position", pos[1].id)]).segments(),
            [seg("position", pos[1].id, pos[2].id, EaseSide::Out)]
        );
        assert_eq!(
            select(&s, &[("position", pos[2].id)]).segments(),
            [seg("position", pos[1].id, pos[2].id, EaseSide::In)]
        );
    }

    #[test]
    fn ease_reading_sees_an_ease_in_on_a_linear_key() {
        // Only B's in-handle changes, A stays linear. Playback eases, so the reading must too.
        let a = key(1, 0, 0.0);
        let mut b = key(2, 2, 5.0);
        b.in_handle = EaseHandle { dx: 1.0 / 3.0, dy: 0.0 };
        let s = KeyframeSummary::new(BTreeMap::from([("opacity".into(), scalar(vec![a.clone(), b]))]));
        let r = select(&s, &[("opacity", a.id), ("opacity", id(2))]).reading(&s);
        let want = EaseShape::new(Interpolation::Bezier, EaseHandle::LINEAR, EaseHandle { dx: 1.0 / 3.0, dy: 0.0 });
        assert_eq!(r, EaseReading::Common(want));
    }

    #[test]
    fn ease_reading_is_mixed_when_only_handles_differ_on_linear_keys() {
        let mut b = key(2, 2, 5.0);
        b.in_handle = EaseHandle { dx: 1.0 / 3.0, dy: 0.0 };
        let s =
            KeyframeSummary::new(BTreeMap::from([("opacity".into(), scalar(vec![key(1, 0, 0.0), b, key(3, 4, 0.0)]))]));
        let r = select(&s, &[("opacity", id(1)), ("opacity", id(2)), ("opacity", id(3))]).reading(&s);
        assert!(matches!(r, EaseReading::Mixed(shapes) if shapes.len() == 2));
    }

    #[test]
    fn a_lone_last_key_writes_only_its_own_in_handle() {
        let (mut s, pos, _) = fixture();
        let sel = select(&s, &[("position", pos[2].id)]);
        assert_eq!(sel.apply(&snappy(), &mut s), 1);
        let tr = vector(&s, "position");
        assert_eq!(tr.keys[1], pos[1]);
        assert_eq!(tr.keys[2].in_handle, snappy().r#in);
    }

    #[test]
    fn a_lone_key_writes_only_its_own_out_side() {
        let (mut s, pos, _) = fixture();
        select(&s, &[("position", pos[1].id)]).apply(&snappy(), &mut s);
        let tr = vector(&s, "position");
        assert_eq!(tr.keys[2], pos[2]);
        assert_eq!((tr.keys[1].out_handle, tr.keys[1].interpolation), (snappy().out, Interpolation::Bezier));
        assert_eq!(tr.keys[1].in_handle, pos[1].in_handle);
    }

    #[test]
    fn a_lone_last_key_after_an_unselected_hold_is_skipped() {
        let tracks = scalar(vec![key(1, 0, 0.0), kind(key(2, 2, 5.0), Interpolation::Hold), key(3, 4, 9.0)]);
        let mut s = KeyframeSummary::new(BTreeMap::from([("opacity".into(), tracks)]));
        let before = s.clone();
        let sel = select(&s, &[("opacity", id(3))]);
        assert!(sel.is_empty());
        assert_eq!(sel.apply(&snappy(), &mut s), 0);
        assert_eq!(s, before);
    }

    #[test]
    fn a_pair_wins_over_a_lone_key_in_the_same_property() {
        let (s, pos, _) = fixture();
        let sel = select(&s, &[("position", pos[0].id), ("position", pos[1].id)]);
        assert_eq!(sel.segments(), [seg("position", pos[0].id, pos[1].id, EaseSide::Both)]);
    }

    #[test]
    fn empty_for_a_single_key_track_or_no_selection() {
        let s = KeyframeSummary::new(BTreeMap::from([("opacity".into(), scalar(vec![key(1, 0, 1.0)]))]));
        assert!(select(&s, &[("opacity", id(1))]).is_empty());
        assert!(select(&s, &[]).is_empty());
        assert_eq!(select(&s, &[]).reading(&s), EaseReading::Empty);
    }

    #[test]
    fn reading_is_common_when_all_segments_are_linear() {
        let (s, pos, scale) = fixture();
        let mut all: Vec<_> = pos.iter().map(|k| ("position", k.id)).collect();
        all.extend(scale.iter().map(|k| ("scale", k.id)));
        assert_eq!(select(&s, &all).reading(&s), EaseReading::Common(EaseShape::LINEAR));
    }

    #[test]
    fn reading_is_mixed_with_the_distinct_shapes() {
        let (mut s, pos, scale) = fixture();
        let mut all: Vec<_> = pos.iter().map(|k| ("position", k.id)).collect();
        all.extend(scale.iter().map(|k| ("scale", k.id)));
        select(&s, &[("scale", scale[0].id), ("scale", scale[1].id)]).apply(&snappy(), &mut s);
        let EaseReading::Mixed(shapes) = select(&s, &all).reading(&s) else { panic!("expected mixed") };
        assert_eq!(shapes.len(), 2);
        assert!(shapes.contains(&EaseShape::LINEAR));
        assert!(shapes.iter().any(|x| x.is_approximately_equal(&snappy())));
    }

    #[test]
    fn a_bezier_with_linear_handles_reads_as_linear_and_a_hold_ignores_its_handles() {
        let mut a = kind(key(1, 0, 0.0), Interpolation::Bezier);
        let s = KeyframeSummary::new(BTreeMap::from([("o".into(), scalar(vec![a.clone(), key(2, 2, 5.0)]))]));
        assert_eq!(select(&s, &[("o", id(1)), ("o", id(2))]).reading(&s), EaseReading::Common(EaseShape::LINEAR));
        a.interpolation = Interpolation::Hold;
        a.out_handle = EaseHandle { dx: 0.1, dy: 0.7 };
        let s = KeyframeSummary::new(BTreeMap::from([("o".into(), scalar(vec![a, key(2, 2, 5.0)]))]));
        assert_eq!(select(&s, &[("o", id(1)), ("o", id(2))]).reading(&s), EaseReading::Common(EaseShape::HOLD));
    }

    #[test]
    fn apply_gives_identical_handles_on_position_and_scale() {
        let (mut s, pos, scale) = fixture();
        let sel = select(
            &s,
            &[("position", pos[0].id), ("position", pos[1].id), ("scale", scale[0].id), ("scale", scale[1].id)],
        );
        assert_eq!(sel.apply(&snappy(), &mut s), 2);
        let pt = vector(&s, "position");
        let Some(PropertyTrack::Scalar(st)) = s.tracks.get(&"scale".into()) else { panic!("scale") };
        assert_eq!(pt.keys[0].out_handle, st.keys[0].out_handle);
        assert_eq!(pt.keys[1].in_handle, st.keys[1].in_handle);
        assert_eq!((pt.keys[0].out_handle, pt.keys[1].in_handle), (snappy().out, snappy().r#in));
        assert!(pt.keys[0].interpolation == Interpolation::Bezier && st.keys[0].interpolation == Interpolation::Bezier);
        // Outside the segments nothing changes.
        assert_eq!((pt.keys[1].out_handle, pt.keys[1].interpolation), (EaseHandle::LINEAR, Interpolation::Linear));
        assert!(pt.keys[2] == pos[2] && st.keys[2] == scale[2]);
        assert_eq!(sel.reading(&s), EaseReading::Common(snappy()));
    }

    #[test]
    fn apply_keeps_overshoot_and_clamps_time_influence() {
        let (mut s, pos, _) = fixture();
        let sel = select(&s, &[("position", pos[0].id), ("position", pos[1].id)]);
        let wild =
            EaseShape::new(Interpolation::Bezier, EaseHandle { dx: 1.4, dy: 1.6 }, EaseHandle { dx: -0.2, dy: -0.5 });
        sel.apply(&wild, &mut s);
        let pt = vector(&s, "position");
        assert_eq!(pt.keys[0].out_handle, EaseHandle { dx: 1.0, dy: 1.6 });
        assert_eq!(pt.keys[1].in_handle, EaseHandle { dx: 0.0, dy: -0.5 });
    }

    #[test]
    fn apply_linear_and_hold() {
        let (mut s, pos, _) = fixture();
        let sel = select(&s, &[("position", pos[0].id), ("position", pos[1].id)]);
        sel.apply(&snappy(), &mut s);
        sel.apply(&EaseShape::HOLD, &mut s);
        let held = vector(&s, "position");
        assert_eq!(held.keys[0].interpolation, Interpolation::Hold);
        // Hold keeps the stored handles, like toggle_hold.
        assert_eq!(held.keys[0].out_handle, snappy().out);
        sel.apply(&EaseShape::LINEAR, &mut s);
        let lin = vector(&s, "position");
        assert_eq!(lin.keys[0].interpolation, Interpolation::Linear);
        assert!(lin.keys[0].out_handle == EaseHandle::LINEAR && lin.keys[1].in_handle == EaseHandle::LINEAR);
    }

    #[test]
    fn apply_on_an_empty_selection_changes_nothing() {
        let (mut s, _, _) = fixture();
        let before = s.clone();
        assert_eq!(select(&s, &[]).apply(&snappy(), &mut s), 0);
        assert_eq!(s, before);
    }

    #[test]
    fn set_hold_kind_turns_hold_ahead_and_hold_into_each_other() {
        let (mut s, pos, _) = fixture();
        let sel = select(&s, &[("position", pos[0].id), ("position", pos[1].id)]);
        assert_eq!(sel.set_hold_kind(Interpolation::HoldAhead, &mut s), 1);
        assert_eq!(vector(&s, "position").keys[0].interpolation, Interpolation::HoldAhead);
        assert_eq!(sel.set_hold_kind(Interpolation::Linear, &mut s), 0);
        // A selection by the right key only has no out side to write.
        let right = select(&s, &[("position", pos[2].id)]);
        assert_eq!(right.set_hold_kind(Interpolation::Hold, &mut s), 0);
    }

    #[test]
    fn curve_shape_and_preset_payload_round_trip() {
        let c = easing_curve_from_shape(id(7), &snappy(), "Snappy".into());
        assert_eq!(c.shape(), snappy());
        let want = EaseShape::new(
            Interpolation::Bezier,
            EaseHandle { dx: 1.0 / 3.0, dy: 0.0 },
            EaseHandle { dx: 1.0 / 3.0, dy: 0.0 },
        );
        assert_eq!(EasingCurve::ease_in_out().shape(), want);
        assert_eq!(EasingCurve::linear().shape(), EaseShape::LINEAR);
        assert_eq!(EasingCurve::hold().shape(), EaseShape::HOLD);
        let payload = c.preset_payload().expect("encodes");
        let back = easing_curve_from_preset_payload(&payload, "Renamed".into(), c.id).expect("decodes");
        assert_eq!((back.shape(), back.name.as_str(), back.id), (snappy(), "Renamed", c.id));
        assert!(easing_curve_from_preset_payload(b"x", "n".into(), id(1)).is_err());
    }

    #[test]
    fn stepped_properties_are_skipped_and_colors_ease() {
        let (base, pos, _) = fixture();
        let mut s = base;
        let on_off = vec![kind(key(21, 0, 0.0), Interpolation::Hold), kind(key(22, 2, 1.0), Interpolation::Hold)];
        s.tracks.insert("shadowOnly".into(), scalar(on_off));
        let list = [("position", pos[0].id), ("position", pos[1].id), ("shadowOnly", id(21)), ("shadowOnly", id(22))];
        let stepped = BTreeSet::from([PropertyID::new("shadowOnly")]);
        let sel = EaseSelection::new(&s, &members(&list), &stepped);
        assert_eq!(sel.segments(), [seg("position", pos[0].id, pos[1].id, EaseSide::Both)]);
        assert_eq!(sel.apply(&snappy(), &mut s), 1);
        assert_eq!(s.tracks[&PropertyID::new("shadowOnly")].interpolation_of(id(21)), Some(Interpolation::Hold));
        // The same selection without `stepped` would have eased it.
        assert_eq!(EaseSelection::new(&s, &members(&list), &BTreeSet::new()).segments().len(), 2);
    }
}
