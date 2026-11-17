// SPDX-License-Identifier: GPL-3.0-or-later
//! Stale-safe whole-clip writes. A panel edits its own copy of a clip, which can lag behind the session by an edit
//! another panel made in the same event. The panel therefore sends the copy it started from (`base`) with its result
//! (`edited`), and the session applies only what the panel changed onto the clip it holds now (`live`).

use crate::Clip;
use serde_json::{Map, Value};
use std::collections::{BTreeSet, HashMap};

impl Clip {
    /// Three-way merge of a whole-clip write: `live` with only the fields where `edited` differs from `base` taken from
    /// `edited`. When `live == base` (the normal case) the result is exactly `edited`.
    ///
    /// The merge runs on the JSON of the three clips. Objects merge key by key, and so do arrays whose elements all
    /// carry a unique `"id"` (effects, keys, masks, layers): edited's order, what edited removed gone, what only live
    /// has kept at its live index. Any other value is edited's when edited changed it, else live's; a rational time
    /// (`value` + `timescale`) counts as one such value. Where the clip does not survive the JSON round trip (a NaN
    /// reads back as null), the result is `edited`.
    pub fn rebased(base: &Clip, edited: &Clip, live: &Clip) -> Clip {
        if live == base {
            return edited.clone();
        }
        if edited == base {
            return live.clone();
        }
        merged(base, edited, live).unwrap_or_else(|| edited.clone())
    }
}

fn merged(base: &Clip, edited: &Clip, live: &Clip) -> Option<Clip> {
    let (b, e, l) =
        (serde_json::to_value(base).ok()?, serde_json::to_value(edited).ok()?, serde_json::to_value(live).ok()?);
    let mut clip: Clip = serde_json::from_value(merge(Some(&b), Some(&e), Some(&l))?).ok()?;
    // Read from old files only and never written (`#[serde(skip)]`), so the JSON above cannot carry it.
    clip.footage_color.legacy_effects.clone_from(&live.footage_color.legacy_effects);
    Some(clip)
}

/// One value of the three clips; `None` = the key is absent. `None` out = the key stays absent.
fn merge(base: Option<&Value>, edited: Option<&Value>, live: Option<&Value>) -> Option<Value> {
    if edited == base {
        return live.cloned();
    }
    if live == base || edited == live {
        return edited.cloned();
    }
    match (base, edited, live) {
        (Some(Value::Object(b)), Some(Value::Object(e)), Some(Value::Object(l))) if !is_time(e) => {
            let keys: BTreeSet<&String> = b.keys().chain(e.keys()).chain(l.keys()).collect();
            let merged: Map<String, Value> =
                keys.into_iter().filter_map(|k| merge(b.get(k), e.get(k), l.get(k)).map(|v| (k.clone(), v))).collect();
            Some(Value::Object(merged))
        }
        (Some(Value::Array(b)), Some(Value::Array(e)), Some(Value::Array(l))) => {
            merge_by_id(b, e, l).map(Value::Array).or_else(|| edited.cloned())
        }
        _ => edited.cloned(),
    }
}

/// A rational time is one value: its two halves are never taken from different sides.
fn is_time(o: &Map<String, Value>) -> bool {
    o.len() == 2 && o.contains_key("value") && o.contains_key("timescale")
}

/// `None` when any of the three arrays is not a list of objects with unique string ids.
fn merge_by_id(base: &[Value], edited: &[Value], live: &[Value]) -> Option<Vec<Value>> {
    let (b, e, l) = (by_id(base)?, by_id(edited)?, by_id(live)?);
    let mut out = Vec::with_capacity(edited.len());
    for item in edited {
        let id = id_of(item)?;
        match (b.get(id), l.get(id)) {
            (Some(bi), Some(li)) => out.extend(merge(Some(bi), Some(item), Some(li))),
            // Live removed it: an untouched copy stays removed, one the edit changed stays.
            (Some(bi), None) => out.extend((item != *bi).then(|| item.clone())),
            (None, _) => out.push(item.clone()),
        }
    }
    for (index, item) in live.iter().enumerate() {
        let id = id_of(item)?;
        if !e.contains_key(id) && !b.contains_key(id) {
            out.insert(index.min(out.len()), item.clone());
        }
    }
    Some(out)
}

fn id_of(item: &Value) -> Option<&str> {
    item.get("id")?.as_str()
}

fn by_id(items: &[Value]) -> Option<HashMap<&str, &Value>> {
    let map: HashMap<&str, &Value> = items.iter().map(|v| Some((id_of(v)?, v))).collect::<Option<_>>()?;
    (map.len() == items.len()).then_some(map)
}

#[cfg(test)]
mod tests {
    use crate::{
        AngleChoice, AnimatedProperty, AnimationZones, AudioTag, Clip, ClipAttachment, ClipEffect, ClipMask, ClipSpeed,
        ColorEffect, FadeMarks, GeneratorRef, GraphicsDocument, GraphicsLayer, LabelColor, Marker, MarkerColor,
        MaskPath, MaskShapeKind, MaskVertex, SpeedKeys, TrackKind, ZoneMiddle,
    };
    use sq_core_time::{Id, Keyframe, KeyframeTrack, Time, TimeRange, Vec2};

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    fn base_clip() -> Clip {
        let source = TimeRange { start: Time::ZERO, duration: Time::new(10, 1) };
        Clip::new(id(1), "Clip", id(2), TrackKind::Video, source, Time::new(3, 1))
    }

    fn radius(c: &Clip, index: usize) -> Option<f64> {
        c.effects.get(index)?.parameters.get(ClipEffect::RADIUS_KEY).map(|p| p.value)
    }

    fn with_two_effects() -> Clip {
        let mut c = base_clip();
        c.effects = vec![ClipEffect::rounded_corners(id(10), 4.0), ClipEffect::rounded_corners(id(11), 8.0)];
        c
    }

    /// Every optional part of a clip set, except the one that is not coded (`legacy_effects`).
    fn filled() -> Clip {
        let mut c = with_two_effects();
        c.link = Some(id(3));
        c.bundle = Some(id(4));
        c.media_duration = Some(Time::new(20, 1));
        c.generator = Some(GeneratorRef { kind: "text".to_string(), payload: vec![1, 2, 3], payload_version: 2 });
        c.label = Some(LabelColor::Violet);
        c.is_still = true;
        c.audio_gain_db = -3.5;
        c.audio_tag = Some(AudioTag::Dialogue);
        c.duck_key_ids = vec![id(20), id(21)];
        c.audio_fades = FadeMarks { head: vec![id(22)], tail: vec![id(23)] };
        c.reversed = true;
        c.keeps_pitch = false;
        c.speed_keys = Some(SpeedKeys::constant(ClipSpeed::NORMAL, false, Time::new(4, 1), Time::new(1, 2)));
        c.hold_frame = Some(Time::new(5, 3));
        c.motion_enabled = false;
        c.opacity_enabled = false;
        c.animation.opacity.value = 0.5;
        c.animation.opacity.track = KeyframeTrack::with_keys(vec![
            Keyframe::new(id(30), Time::ZERO, 0.0),
            Keyframe::new(id(31), Time::new(2, 1), 1.0),
        ]);
        c.animation.position = AnimatedProperty::new(Vec2::new(1.0, 2.0));
        let vertex = MaskVertex {
            point: Vec2::new(0.1, 0.2),
            in_tangent: Vec2::new(0.0, 0.0),
            out_tangent: Vec2::new(0.0, 0.0),
        };
        c.mask_store =
            Some(vec![ClipMask::new(id(40), "Mask", MaskShapeKind::Rectangle, MaskPath { vertices: vec![vertex] })]);
        let layer = GraphicsLayer::text(
            id(41),
            GeneratorRef { kind: "text".to_string(), payload: vec![9], payload_version: 1 },
            "T",
        );
        c.graphics_store = Some(GraphicsDocument { layers: vec![layer], groups: Vec::new() });
        c.grade_link = Some(id(5));
        c.zones =
            Some(AnimationZones::new(Time::new(1, 1), Time::new(1, 2), ZoneMiddle::Stretch, Some(Time::new(6, 1))));
        c.markers = Some(vec![Marker {
            id: id(42),
            time: Time::new(1, 4),
            name: "m".to_string(),
            color: MarkerColor::default(),
            comment: "note".to_string(),
            duration: Time::ZERO,
        }]);
        c.attachment = Some(ClipAttachment::new(id(6), Time::new(2, 1)));
        c.angle = Some(AngleChoice { index: 2, follows_video: true });
        c
    }

    #[test]
    fn a_rename_in_live_and_an_opacity_edit_both_stay() {
        let base = base_clip();
        let mut edited = base.clone();
        edited.animation.opacity.value = 0.25;
        let mut live = base.clone();
        live.name = "Renamed".to_string();
        live.generator = Some(GeneratorRef { kind: "text".to_string(), payload: vec![7], payload_version: 1 });
        let out = Clip::rebased(&base, &edited, &live);
        assert_eq!(out.animation.opacity.value, 0.25);
        assert_eq!(out.name, "Renamed");
        assert_eq!(out.generator, live.generator);
    }

    #[test]
    fn two_effects_changed_one_per_side_both_stay() {
        let base = with_two_effects();
        let mut edited = base.clone();
        edited.effects[0].parameters.insert(ClipEffect::RADIUS_KEY.to_string(), AnimatedProperty::new(5.0));
        let mut live = base.clone();
        live.effects[1].parameters.insert(ClipEffect::RADIUS_KEY.to_string(), AnimatedProperty::new(9.0));
        let out = Clip::rebased(&base, &edited, &live);
        assert_eq!((radius(&out, 0), radius(&out, 1)), (Some(5.0), Some(9.0)));
    }

    #[test]
    fn the_same_field_changed_on_both_sides_takes_the_edit() {
        let base = base_clip();
        let mut edited = base.clone();
        edited.animation.opacity.value = 0.2;
        let mut live = base.clone();
        live.animation.opacity.value = 0.7;
        live.name = "Renamed".to_string();
        let out = Clip::rebased(&base, &edited, &live);
        assert_eq!((out.animation.opacity.value, out.name.as_str()), (0.2, "Renamed"));
    }

    #[test]
    fn an_effect_added_in_live_stays_and_one_removed_by_the_edit_is_gone() {
        let base = with_two_effects();
        let mut edited = base.clone();
        edited.effects.remove(0);
        let mut live = base.clone();
        live.effects.push(ClipEffect::rounded_corners(id(12), 2.0));
        let out = Clip::rebased(&base, &edited, &live);
        let ids: Vec<Id> = out.effects.iter().map(|e| e.id).collect();
        assert_eq!(ids, vec![id(11), id(12)]);
    }

    #[test]
    fn a_live_only_effect_keeps_its_live_position() {
        let base = with_two_effects();
        let mut edited = base.clone();
        edited.animation.opacity.value = 0.5;
        let mut live = base.clone();
        live.effects.insert(1, ClipEffect::rounded_corners(id(12), 2.0));
        let out = Clip::rebased(&base, &edited, &live);
        let ids: Vec<Id> = out.effects.iter().map(|e| e.id).collect();
        assert_eq!((ids, out.animation.opacity.value), (vec![id(10), id(12), id(11)], 0.5));
    }

    #[test]
    fn keys_merge_by_id_and_an_untouched_live_clip_gives_exactly_the_edit() {
        let base = filled();
        let mut edited = base.clone();
        edited.animation.opacity.track.keys[1].value = 0.9;
        let mut live = base.clone();
        live.animation.opacity.track.keys[0].value = 0.1;
        let out = Clip::rebased(&base, &edited, &live);
        let values: Vec<f64> = out.animation.opacity.track.keys.iter().map(|k| k.value).collect();
        assert_eq!(values, vec![0.1, 0.9]);
        assert_eq!(Clip::rebased(&base, &edited, &base), edited);
        assert_eq!(Clip::rebased(&base, &base, &live), live);
    }

    #[test]
    fn a_fully_filled_clip_survives_the_json_round_trip_unchanged() {
        let base = filled();
        let mut edited = base.clone();
        edited.name = "Edited".to_string();
        let mut live = base.clone();
        live.is_enabled = false;
        let out = Clip::rebased(&base, &edited, &live);
        let mut want = base;
        want.name = "Edited".to_string();
        want.is_enabled = false;
        assert_eq!(out, want);
    }

    #[test]
    fn an_unrepresentable_number_falls_back_to_the_edit() {
        let base = base_clip();
        let mut edited = base.clone();
        edited.animation.opacity.value = f64::NAN;
        let mut live = base.clone();
        live.name = "Renamed".to_string();
        let out = Clip::rebased(&base, &edited, &live);
        assert!(out.animation.opacity.value.is_nan());
        assert_eq!(out.name, "Clip");
    }

    #[test]
    fn the_uncoded_legacy_grade_comes_from_live() {
        let base = base_clip();
        let mut edited = base.clone();
        edited.name = "Edited".to_string();
        let mut live = base.clone();
        live.is_enabled = false;
        live.footage_color.legacy_effects = Some(vec![ColorEffect::default()]);
        let out = Clip::rebased(&base, &edited, &live);
        assert_eq!(out.footage_color.legacy_effects, live.footage_color.legacy_effects);
        assert_eq!((out.name.as_str(), out.is_enabled), ("Edited", false));
    }
}
