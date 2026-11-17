// Swift: EditOperation.swift
//! One edit an agent asks for, and its JSON form.

use crate::time_limits::{WireRange, WireTime};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value, json};
use sq_core_model::{ClipEdge, PixelAspect};
use sq_core_time::{Id, Time, TimeRange};
use std::collections::BTreeSet;

/// One edit an agent asks for. JSON: `{"op": "<name>", ...fields}`; times are `{"value": Int, "timescale": Int}` (never
/// seconds as a double). Every case maps onto one existing `Timeline` edit, the same ones the timeline gestures replay, so
/// the API adds no edit logic of its own.
#[derive(Clone, Debug, PartialEq)]
pub enum EditOperation {
    /// Add Edit (Cmd+K) at `at`; `tracks` None = every unlocked track.
    Razor { at: Time, tracks: Option<Vec<Id>> },
    /// Delete and close the gap.
    RippleDelete { clips: Vec<Id> },
    /// Delete leaving a gap.
    Lift { clips: Vec<Id> },
    /// Removes a range and closes the gap; `tracks` None = every unlocked track.
    Extract { range: TimeRange, tracks: Option<Vec<Id>> },
    /// Removes a range and leaves a gap; `tracks` None = every unlocked track.
    LiftRange { range: TimeRange, tracks: Option<Vec<Id>> },
    /// Plain trim of one edge.
    Trim { clip: Id, edge: ClipEdge, by: Time },
    /// Ripple trim of one edge.
    RippleTrim { clip: Id, edge: ClipEdge, by: Time },
    /// Moves a clip (with its linked partners) to `to`, optionally onto another track.
    Move { clip: Id, to: Time, track: Option<Id> },
    /// Changes which part of the media shows.
    Slip { clip: Id, by: Time },
    /// Slides a clip between its neighbors.
    Slide { clip: Id, by: Time },
    /// Rolls the cut at the clip's tail by `by`.
    Roll { clip: Id, by: Time },
    /// Clip > Enable on these clips and their linked partners.
    ToggleEnabled { clips: Vec<Id> },
    /// Adds a sequence marker.
    AddMarker { at: Time, name: String },
    /// Source settings > Pixel Aspect of a media item (all its clips; None = what the file says). One ratio num/den within
    /// 1:4 ... 4:1. A media setting, not a timeline edit: it shows in `pixelAspectChanges` of the diff.
    SetPixelAspect { media: Id, aspect: Option<PixelAspect> },
}

impl EditOperation {
    /// The wire name.
    pub fn name(&self) -> &'static str {
        match self {
            Self::Razor { .. } => "razor",
            Self::RippleDelete { .. } => "rippleDelete",
            Self::Lift { .. } => "lift",
            Self::Extract { .. } => "extract",
            Self::LiftRange { .. } => "liftRange",
            Self::Trim { .. } => "trim",
            Self::RippleTrim { .. } => "rippleTrim",
            Self::Move { .. } => "move",
            Self::Slip { .. } => "slip",
            Self::Slide { .. } => "slide",
            Self::Roll { .. } => "roll",
            Self::ToggleEnabled { .. } => "toggleEnabled",
            Self::AddMarker { .. } => "addMarker",
            Self::SetPixelAspect { .. } => "setPixelAspect",
        }
    }

    /// Every time the operation carries (validated before any arithmetic).
    pub fn times(&self) -> Vec<Time> {
        match self {
            Self::Razor { at, .. } | Self::AddMarker { at, .. } => vec![*at],
            Self::RippleDelete { .. }
            | Self::Lift { .. }
            | Self::ToggleEnabled { .. }
            | Self::SetPixelAspect { .. } => {
                vec![]
            }
            Self::Extract { range, .. } | Self::LiftRange { range, .. } => vec![range.start, range.duration],
            Self::Trim { by, .. }
            | Self::RippleTrim { by, .. }
            | Self::Slip { by, .. }
            | Self::Slide { by, .. }
            | Self::Roll { by, .. } => vec![*by],
            Self::Move { to, .. } => vec![*to],
        }
    }

    /// Every wire name, in documentation order.
    pub const ALL_NAMES: [&'static str; 14] = [
        "razor",
        "rippleDelete",
        "lift",
        "extract",
        "liftRange",
        "trim",
        "rippleTrim",
        "move",
        "slip",
        "slide",
        "roll",
        "toggleEnabled",
        "addMarker",
        "setPixelAspect",
    ];
}

fn edge_name(e: ClipEdge) -> &'static str {
    match e {
        ClipEdge::Head => "head",
        ClipEdge::Tail => "tail",
    }
}

/// Rejects JSON object keys outside `allowed`: an unknown key is almost always a typo, never ignore it.
pub(crate) fn check_strict_keys(map: &Map<String, Value>, allowed: &[&str], what: &str) -> Result<(), String> {
    let unknown: BTreeSet<&str> = map.keys().map(String::as_str).filter(|k| !allowed.contains(k)).collect();
    if unknown.is_empty() {
        return Ok(());
    }
    let list = unknown.iter().map(|k| format!("'{k}'")).collect::<Vec<_>>().join(", ");
    let known = allowed.iter().copied().collect::<BTreeSet<_>>().into_iter().collect::<Vec<_>>().join(", ");
    let s = if unknown.len() > 1 { "s" } else { "" };
    Err(format!("unknown key{s} {list} in {what}; known: {known}"))
}

/// A required field decoded as `T`.
pub(crate) fn required<T: DeserializeOwned>(map: &Map<String, Value>, key: &str) -> Result<T, String> {
    let v = map.get(key).ok_or_else(|| format!("missing field `{key}`"))?;
    T::deserialize(v).map_err(|e| format!("{key}: {e}"))
}

/// An optional field decoded as `T`; absent and `null` are both `None` (Swift `decodeIfPresent`).
pub(crate) fn optional<T: DeserializeOwned>(map: &Map<String, Value>, key: &str) -> Result<Option<T>, String> {
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => T::deserialize(v).map(Some).map_err(|e| format!("{key}: {e}")),
    }
}

fn time(map: &Map<String, Value>, key: &str) -> Result<Time, String> {
    required::<WireTime>(map, key).map(|w| w.time)
}

fn edge(map: &Map<String, Value>) -> Result<ClipEdge, String> {
    match required::<String>(map, "edge")?.as_str() {
        "head" => Ok(ClipEdge::Head),
        "tail" => Ok(ClipEdge::Tail),
        other => Err(format!("edge: unknown edge '{other}'; known: head, tail")),
    }
}

impl EditOperation {
    fn from_map(c: &Map<String, Value>) -> Result<EditOperation, String> {
        let op: String = required(c, "op")?;
        let allowed: Option<&[&str]> = match op.as_str() {
            "razor" => Some(&["op", "at", "tracks"]),
            "rippleDelete" | "lift" | "toggleEnabled" => Some(&["op", "clips"]),
            "extract" | "liftRange" => Some(&["op", "range", "tracks"]),
            "trim" | "rippleTrim" => Some(&["op", "clip", "edge", "by"]),
            "move" => Some(&["op", "clip", "to", "track"]),
            "slip" | "slide" | "roll" => Some(&["op", "clip", "by"]),
            "addMarker" => Some(&["op", "at", "name"]),
            "setPixelAspect" => Some(&["op", "media", "aspect"]),
            _ => None,
        };
        if let Some(allowed) = allowed {
            check_strict_keys(c, allowed, &format!("operation '{op}'"))?;
        }
        let range = || required::<WireRange>(c, "range").map(|w| w.range);
        Ok(match op.as_str() {
            "razor" => Self::Razor { at: time(c, "at")?, tracks: optional(c, "tracks")? },
            "rippleDelete" => Self::RippleDelete { clips: required(c, "clips")? },
            "lift" => Self::Lift { clips: required(c, "clips")? },
            "extract" => Self::Extract { range: range()?, tracks: optional(c, "tracks")? },
            "liftRange" => Self::LiftRange { range: range()?, tracks: optional(c, "tracks")? },
            "trim" => Self::Trim { clip: required(c, "clip")?, edge: edge(c)?, by: time(c, "by")? },
            "rippleTrim" => Self::RippleTrim { clip: required(c, "clip")?, edge: edge(c)?, by: time(c, "by")? },
            "move" => Self::Move { clip: required(c, "clip")?, to: time(c, "to")?, track: optional(c, "track")? },
            "slip" => Self::Slip { clip: required(c, "clip")?, by: time(c, "by")? },
            "slide" => Self::Slide { clip: required(c, "clip")?, by: time(c, "by")? },
            "roll" => Self::Roll { clip: required(c, "clip")?, by: time(c, "by")? },
            "toggleEnabled" => Self::ToggleEnabled { clips: required(c, "clips")? },
            "addMarker" => Self::AddMarker { at: time(c, "at")?, name: optional(c, "name")?.unwrap_or_default() },
            "setPixelAspect" => Self::SetPixelAspect { media: required(c, "media")?, aspect: optional(c, "aspect")? },
            _ => {
                return Err(format!("op: unknown op '{op}'; known: {}", Self::ALL_NAMES.join(", ")));
            }
        })
    }

    fn to_value(&self) -> Value {
        let mut m = Map::new();
        m.insert("op".into(), json!(self.name()));
        let mut put = |k: &str, v: Value| {
            m.insert(k.into(), v);
        };
        let tracks = |t: &Option<Vec<Id>>| t.as_ref().map(|t| json!(t));
        match self {
            Self::Razor { at, tracks: t } => {
                put("at", json!(at));
                tracks(t).into_iter().for_each(|v| put("tracks", v));
            }
            Self::RippleDelete { clips } | Self::Lift { clips } | Self::ToggleEnabled { clips } => {
                put("clips", json!(clips));
            }
            Self::Extract { range, tracks: t } | Self::LiftRange { range, tracks: t } => {
                put("range", json!(range));
                tracks(t).into_iter().for_each(|v| put("tracks", v));
            }
            Self::Trim { clip, edge, by } | Self::RippleTrim { clip, edge, by } => {
                put("clip", json!(clip));
                put("edge", json!(edge_name(*edge)));
                put("by", json!(by));
            }
            Self::Move { clip, to, track } => {
                put("clip", json!(clip));
                put("to", json!(to));
                track.iter().for_each(|t| put("track", json!(t)));
            }
            Self::Slip { clip, by } | Self::Slide { clip, by } | Self::Roll { clip, by } => {
                put("clip", json!(clip));
                put("by", json!(by));
            }
            Self::AddMarker { at, name } => {
                put("at", json!(at));
                put("name", json!(name));
            }
            Self::SetPixelAspect { media, aspect } => {
                put("media", json!(media));
                aspect.iter().for_each(|a| put("aspect", json!(a)));
            }
        }
        Value::Object(m)
    }
}

impl<'de> Deserialize<'de> for EditOperation {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let map = Map::<String, Value>::deserialize(d)?;
        Self::from_map(&map).map_err(serde::de::Error::custom)
    }
}

impl Serialize for EditOperation {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        self.to_value().serialize(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::ClipEdge;

    fn decode(json: &str) -> Result<Vec<EditOperation>, serde_json::Error> {
        serde_json::from_str(json)
    }

    #[test]
    fn decodes_every_operation_from_json() {
        let (id, tr) = (Id::from_u128(7), Id::from_u128(8));
        let json = format!(
            r#"[{{"op":"razor","at":{{"value":2,"timescale":1}}}},
             {{"op":"razor","at":{{"value":2,"timescale":1}},"tracks":["{tr}"]}},
             {{"op":"rippleDelete","clips":["{id}"]}},
             {{"op":"lift","clips":["{id}"]}},
             {{"op":"extract","range":{{"start":{{"value":1,"timescale":1}},"duration":{{"value":1,"timescale":2}}}}}},
             {{"op":"liftRange","range":{{"start":{{"value":1,"timescale":1}},"duration":{{"value":1,"timescale":2}}}},"tracks":["{tr}"]}},
             {{"op":"trim","clip":"{id}","edge":"head","by":{{"value":1,"timescale":25}}}},
             {{"op":"rippleTrim","clip":"{id}","edge":"tail","by":{{"value":-1,"timescale":25}}}},
             {{"op":"move","clip":"{id}","to":{{"value":3,"timescale":1}},"track":"{tr}"}},
             {{"op":"slip","clip":"{id}","by":{{"value":1,"timescale":25}}}},
             {{"op":"slide","clip":"{id}","by":{{"value":1,"timescale":25}}}},
             {{"op":"roll","clip":"{id}","by":{{"value":1,"timescale":25}}}},
             {{"op":"toggleEnabled","clips":["{id}"]}},
             {{"op":"addMarker","at":{{"value":1,"timescale":1}},"name":"Hook"}}]"#
        );
        let ops = decode(&json).unwrap_or_else(|e| panic!("decode: {e}"));
        assert_eq!(ops.len(), 14);
        assert_eq!(ops[0], EditOperation::Razor { at: Time::new(2, 1), tracks: None });
        assert_eq!(ops[6], EditOperation::Trim { clip: id, edge: ClipEdge::Head, by: Time::new(1, 25) });
        assert_eq!(ops[13], EditOperation::AddMarker { at: Time::new(1, 1), name: "Hook".into() });
        let mut names: Vec<&str> = ops.iter().map(EditOperation::name).collect();
        names.dedup(); // the two razors
        assert_eq!(names, EditOperation::ALL_NAMES[..13].to_vec()); // setPixelAspect has its own test
        // Round trip through our own encoder.
        let again = serde_json::to_string(&ops).and_then(|s| serde_json::from_str::<Vec<EditOperation>>(&s));
        assert_eq!(again.ok(), Some(ops));
    }

    #[test]
    fn rejects_unknown_op_and_bad_edge() {
        assert!(decode(r#"[{"op":"explode"}]"#).is_err());
        let bad_edge = format!(
            r#"[{{"op":"trim","clip":"{}","edge":"middle","by":{{"value":1,"timescale":1}}}}]"#,
            Id::from_u128(1)
        );
        assert!(decode(&bad_edge).is_err());
        // A zero timescale never reaches Time's precondition.
        assert!(decode(r#"[{"op":"razor","at":{"value":1,"timescale":0}}]"#).is_err());
    }

    #[test]
    fn unknown_keys_are_named_in_the_error() {
        let e = decode(r#"[{"op":"razor","at":{"value":1,"timescale":1},"clip":"x","zzz":1}]"#)
            .err()
            .map(|e| e.to_string());
        assert!(
            e.is_some_and(|m| m.contains("unknown keys 'clip', 'zzz' in operation 'razor'; known: at, op, tracks"))
        );
    }

    #[test]
    fn set_pixel_aspect_decodes_and_round_trips() {
        let id = Id::from_u128(5);
        let json = format!(
            r#"[{{"op":"setPixelAspect","media":"{id}","aspect":{{"num":4,"den":3}}}},{{"op":"setPixelAspect","media":"{id}"}}]"#
        );
        let ops = decode(&json).unwrap_or_default();
        assert_eq!(
            ops,
            vec![
                EditOperation::SetPixelAspect { media: id, aspect: PixelAspect::new(4, 3) },
                EditOperation::SetPixelAspect { media: id, aspect: None }
            ]
        );
        let again = serde_json::to_string(&ops).and_then(|s| serde_json::from_str::<Vec<EditOperation>>(&s));
        assert_eq!(again.ok(), Some(ops));
        let bad = format!(r#"[{{"op":"setPixelAspect","media":"{id}","aspect":{{"num":9,"den":1}}}}]"#);
        assert!(decode(&bad).is_err());
    }
}
