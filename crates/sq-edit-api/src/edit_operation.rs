// Swift: EditOperation.swift
//! One edit an agent asks for, and its JSON form.

use crate::time_limits::{WireRange, WireTime};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value, json};
use sq_core_model::{ClipEdge, ClipSpeed, PixelAspect, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use std::collections::BTreeSet;

/// One edit an agent asks for. JSON: `{"op": "<name>", ...fields}`; times are `{"value": Int, "timescale": Int}` (never
/// seconds as a double). Every case maps onto one existing `Timeline` edit, the same ones the timeline gestures replay, so
/// the API adds no edit logic of its own.
// shortcut: SetKeyframe carries its raw handle JSON inline; box it if the batch memory ever matters (one short Vec per commit).
#[allow(clippy::large_enum_variant)]
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
    /// Plain trim of one edge. `linked: false` is the UI's Alt-trim: only this clip changes, its linked partners stay
    /// (a J/L cut: picture and sound cut at different times).
    Trim { clip: Id, edge: ClipEdge, by: Time, linked: bool },
    /// Ripple trim of one edge; `linked: false` as for `Trim`.
    RippleTrim { clip: Id, edge: ClipEdge, by: Time, linked: bool },
    /// Link (Cmd+L): the clips become one link group.
    Link { clips: Vec<Id> },
    /// Unlink: the clips leave their link groups.
    Unlink { clips: Vec<Id> },
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
    /// Delete clips (and their linked partners): `ripple` closes the gap (Ripple Delete), else it stays (Lift).
    RemoveClip { clips: Vec<Id>, ripple: bool },
    /// New empty track after the last one of its kind (what Sequence > Add Track does).
    AddTrack { kind: TrackKind },
    /// Constant clip speed (and its linked partners), `num/den` of normal speed; the clip's source range stays.
    SetClipSpeed { clip: Id, speed: ClipSpeed },
    /// Track header toggles; absent fields stay as they are.
    SetTrackState { track: Id, mute: Option<bool>, solo: Option<bool>, lock: Option<bool>, visible: Option<bool> },
    /// Sequence Settings of `sequence` (None = the one the commit names); absent fields stay as they are.
    SetSequenceSettings { sequence: Option<Id>, width: Option<i64>, height: Option<i64>, fps: Option<Fps>, sample_rate: Option<i64> },
    /// Session operation. Places an imported media item (video with its linked audio, or video only) like the Overwrite /
    /// Insert commands; `source_in`/`source_out` pick the part of the media (default: all of it).
    AddClip {
        media: Id,
        track: Option<Id>,
        at: Time,
        source_in: Option<Time>,
        source_out: Option<Time>,
        link_audio: bool,
        insert: bool,
        /// Which streams of the media to place; `None` = by `link_audio` (both, or video only).
        streams: Option<ClipStreams>,
        /// Length on the timeline (the end of the used source part); needed to lengthen a still, whose default is 5 s.
        duration: Option<Time>,
    },
    /// Session operation. A new empty sequence (4 video + 4 audio tracks) that becomes the active one.
    CreateSequence { name: String, width: i64, height: i64, fps: Fps, sample_rate: Option<i64> },
    /// Session operation. Opens `sequence` in the timeline; later operations of the batch act on it.
    SetActiveSequence { sequence: Id },
    /// Session operation. Sync Audio to Reference for one clip: lines `clip` (with its linked partners) up with the
    /// reference clip `to` by start timecode, else by the shared sound (waveform fit), else by capture date, and with
    /// `retime` (default true) corrects drift by a constant speed. Both clips must be in the active sequence.
    SyncAudio { clip: Id, to: Id, retime: bool },
    /// Sets the static value of an inspector parameter (path from `GET /v1/clip/{id}/params`).
    SetParam { clip: Id, param: String, value: Value },
    /// Adds a catalog effect (`GET /v1/effects`); `index` = its place in the effect list.
    AddEffect { clip: Id, effect: String, index: Option<usize> },
    /// Removes an effect by its id.
    RemoveEffect { clip: Id, effect: Id },
    /// Applies a transition (`GET /v1/transitions`) to a clip edge (`clip` + `edge`) or between two touching clips
    /// (`between`), with its factory look; `alignment` center (default), start or end.
    AddTransition { place: crate::transition_ops::Place, kind: String, duration: Time, alignment: String },
    /// Removes a transition by its id.
    RemoveTransition { transition: Id },
    /// Applies a built-in effect preset (`GET /v1/effectPresets`) to a clip; `at` head|tail must match the preset's anchor.
    ApplyPreset { clip: Id, preset: String, at: Option<ClipEdge>, mode: Option<String> },
    /// `applyPreset` of a preset the user saved (or imported): the router resolves the name against the host's user
    /// presets and swaps in the decoded preset; never parsed from a request.
    ApplyUserPreset { clip: Id, name: String, preset: Box<sq_core_effects::effect_preset::EffectPreset>, at: Option<ClipEdge>, mode: Option<String> },
    /// Adds or replaces a key at clip-local time `at`.
    SetKeyframe {
        clip: Id,
        param: String,
        at: Time,
        value: Value,
        interpolation: Option<String>,
        ease: Option<String>,
        in_handle: Option<Value>,
        out_handle: Option<Value>,
    },
    /// Removes the key at clip-local time `at`.
    RemoveKeyframe { clip: Id, param: String, at: Time },
    /// Moves the key at clip-local `from` to `to`, keeping value and ease/handles; refused when a key sits at `to`.
    MoveKeyframe { clip: Id, param: String, from: Time, to: Time },
    /// Moves every key of `param` (all keyed params when absent) at or after `after` (all when absent) by `by`.
    ShiftKeyframes { clip: Id, param: Option<String>, by: Time, after: Option<Time> },
    /// Makes ONE graphics clip with text layers (bottom layer first).
    AddGraphic { track: Id, at: Time, duration: Time, name: Option<String>, layers: Vec<Value> },
    /// Changes one text layer; `fields` are the layer fields (text, font, size, color, ...).
    SetTextLayer { clip: Id, layer: Id, fields: Value },
    /// Adds a text layer on top (or at `index`) of a graphics clip.
    AddTextLayer { clip: Id, index: Option<usize>, fields: Value },
    /// Removes a text layer.
    RemoveTextLayer { clip: Id, layer: Id },
    /// Adds the text animator of a side (`in` / `out`) of a text layer.
    AddTextAnimator { clip: Id, layer: Id, fields: Value },
    /// Changes fields of a layer's text animator.
    SetTextAnimator { clip: Id, layer: Id, fields: Value },
    /// Removes a layer's text animator of one side.
    RemoveTextAnimator { clip: Id, layer: Id, side: Option<String> },
    /// Sets (or clears) the static accent of words of a text layer; `fields` are `from`, `to?`, `color` or `clear`.
    SetTextAccent { clip: Id, layer: Id, fields: Value },
    /// Adds a rectangle or ellipse mask to a clip; `fields` are `shape`, `center?`, `size?`, `feather?`, `invert?`, `name?`.
    AddMask { clip: Id, fields: Value },
}

/// Which streams of a media item `addClip` places.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClipStreams {
    /// Picture and its linked sound.
    Both,
    /// Picture only.
    Video,
    /// Sound only, on an audio track.
    Audio,
}

impl ClipStreams {
    fn name(self) -> &'static str {
        match self {
            ClipStreams::Both => "both",
            ClipStreams::Video => "video",
            ClipStreams::Audio => "audio",
        }
    }
}

/// A frame rate as a ratio (`num/den` frames per second; 30000/1001 = 29.97).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Fps {
    /// Frames ...
    pub num: i64,
    /// ... per this many seconds.
    pub den: i64,
}

impl Fps {
    /// Duration of one frame.
    pub fn frame_duration(self) -> Time {
        Time::new(self.den, self.num)
    }

    /// Reads a JSON number (24, 25, 30, 60 and the NTSC rates 23.976, 29.97, 59.94, 119.88) or `{"num", "den"}`.
    fn from_value(v: &Value) -> Result<Fps, String> {
        let (num, den) = if let Some(f) = v.as_f64() {
            let ntsc = [(23.976, 24_000, 1001), (29.97, 30_000, 1001), (59.94, 60_000, 1001), (119.88, 120_000, 1001)];
            if f.fract() == 0.0 && (1.0..=1000.0).contains(&f) {
                (f as i64, 1)
            } else if let Some((_, n, d)) = ntsc.iter().find(|(r, _, _)| (r - f).abs() < 0.006) {
                (*n, *d)
            } else {
                return Err(format!("fps: {f} is not a whole rate or 23.976 / 29.97 / 59.94 / 119.88; pass {{\"num\", \"den\"}}"));
            }
        } else if let Some(o) = v.as_object() {
            check_strict_keys(o, &["num", "den"], "fps")?;
            (required::<i64>(o, "num")?, required::<i64>(o, "den")?)
        } else {
            return Err("fps: expected a number or {num, den}".to_string());
        };
        if !(1..=1_000_000).contains(&num) || !(1..=1_000_000).contains(&den) || num > 1000 * den {
            return Err(format!("fps: {num}/{den} is out of range (up to 1000 fps)"));
        }
        Ok(Fps { num, den })
    }

    fn to_value(self) -> Value {
        json!({"num": self.num, "den": self.den})
    }
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
            Self::Link { .. } => "link",
            Self::Unlink { .. } => "unlink",
            Self::Trim { .. } => "trim",
            Self::RippleTrim { .. } => "rippleTrim",
            Self::Move { .. } => "move",
            Self::Slip { .. } => "slip",
            Self::Slide { .. } => "slide",
            Self::Roll { .. } => "roll",
            Self::ToggleEnabled { .. } => "toggleEnabled",
            Self::AddMarker { .. } => "addMarker",
            Self::SetPixelAspect { .. } => "setPixelAspect",
            Self::RemoveClip { .. } => "removeClip",
            Self::AddTrack { .. } => "addTrack",
            Self::SetClipSpeed { .. } => "setClipSpeed",
            Self::SetTrackState { .. } => "setTrackState",
            Self::SetSequenceSettings { .. } => "setSequenceSettings",
            Self::AddClip { .. } => "addClip",
            Self::CreateSequence { .. } => "createSequence",
            Self::SetActiveSequence { .. } => "setActiveSequence",
            Self::SyncAudio { .. } => "syncAudio",
            Self::SetParam { .. } => "setParam",
            Self::AddEffect { .. } => "addEffect",
            Self::RemoveEffect { .. } => "removeEffect",
            Self::AddTransition { .. } => "addTransition",
            Self::RemoveTransition { .. } => "removeTransition",
            Self::ApplyPreset { .. } | Self::ApplyUserPreset { .. } => "applyPreset",
            Self::SetKeyframe { .. } => "setKeyframe",
            Self::RemoveKeyframe { .. } => "removeKeyframe",
            Self::MoveKeyframe { .. } => "moveKeyframe",
            Self::ShiftKeyframes { .. } => "shiftKeyframes",
            Self::AddGraphic { .. } => "addGraphic",
            Self::SetTextLayer { .. } => "setTextLayer",
            Self::AddTextLayer { .. } => "addTextLayer",
            Self::RemoveTextLayer { .. } => "removeTextLayer",
            Self::AddTextAnimator { .. } => "addTextAnimator",
            Self::SetTextAnimator { .. } => "setTextAnimator",
            Self::SetTextAccent { .. } => "setTextAccent",
            Self::AddMask { .. } => "addMask",
            Self::RemoveTextAnimator { .. } => "removeTextAnimator",
        }
    }

    /// Operations the session runs itself (they change the media placement, the sequence list or the open sequence, not
    /// only one timeline): a batch with one of them runs operation by operation, still ONE undo step.
    pub fn is_session_operation(&self) -> bool {
        matches!(
            self,
            Self::AddClip { .. } | Self::CreateSequence { .. } | Self::SetActiveSequence { .. } | Self::SyncAudio { .. }
        )
    }

    /// Every time the operation carries (validated before any arithmetic).
    pub fn times(&self) -> Vec<Time> {
        match self {
            Self::Razor { at, .. } | Self::AddMarker { at, .. } => vec![*at],
            Self::RippleDelete { .. }
            | Self::Lift { .. }
            | Self::ToggleEnabled { .. }
            | Self::Link { .. }
            | Self::Unlink { .. }
            | Self::SetPixelAspect { .. }
            | Self::RemoveClip { .. }
            | Self::AddTrack { .. }
            | Self::SetClipSpeed { .. }
            | Self::SetTrackState { .. }
            | Self::SetSequenceSettings { .. }
            | Self::CreateSequence { .. }
            | Self::SetActiveSequence { .. }
            | Self::SetParam { .. }
            | Self::AddEffect { .. }
            | Self::RemoveEffect { .. }
            | Self::RemoveTransition { .. }
            | Self::ApplyPreset { .. }
            | Self::ApplyUserPreset { .. }
            | Self::SetTextLayer { .. }
            | Self::AddTextLayer { .. }
            | Self::RemoveTextLayer { .. }
            | Self::AddTextAnimator { .. }
            | Self::SetTextAnimator { .. }
            | Self::SetTextAccent { .. }
            | Self::AddMask { .. }
            | Self::RemoveTextAnimator { .. }
            | Self::SyncAudio { .. } => {
                vec![]
            }
            Self::SetKeyframe { at, .. } | Self::RemoveKeyframe { at, .. } => vec![*at],
            Self::MoveKeyframe { from, to, .. } => vec![*from, *to],
            Self::ShiftKeyframes { by, after, .. } => std::iter::once(*by).chain(*after).collect(),
            Self::AddTransition { duration, .. } => vec![*duration],
            Self::AddGraphic { at, duration, .. } => vec![*at, *duration],
            Self::AddClip { at, source_in, source_out, duration, .. } => {
                std::iter::once(*at).chain(*source_in).chain(*source_out).chain(*duration).collect()
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
    pub const ALL_NAMES: [&'static str; 44] = [
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
        "link",
        "unlink",
        "setPixelAspect",
        "removeClip",
        "addTrack",
        "setClipSpeed",
        "setTrackState",
        "setSequenceSettings",
        "addClip",
        "createSequence",
        "setActiveSequence",
        "syncAudio",
        "setParam",
        "addEffect",
        "removeEffect",
        "addTransition",
        "removeTransition",
        "applyPreset",
        "setKeyframe",
        "removeKeyframe",
        "moveKeyframe",
        "shiftKeyframes",
        "addGraphic",
        "setTextLayer",
        "addTextLayer",
        "removeTextLayer",
        "addTextAnimator",
        "setTextAnimator",
        "setTextAccent",
        "addMask",
        "removeTextAnimator",
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
            "trim" | "rippleTrim" => Some(&["op", "clip", "edge", "by", "linked"]),
            "link" | "unlink" => Some(&["op", "clips"]),
            "move" => Some(&["op", "clip", "to", "track"]),
            "slip" | "slide" | "roll" => Some(&["op", "clip", "by"]),
            "addMarker" => Some(&["op", "at", "name"]),
            "setPixelAspect" => Some(&["op", "media", "aspect"]),
            "removeClip" => Some(&["op", "clips", "ripple"]),
            "addTrack" => Some(&["op", "kind"]),
            "setClipSpeed" => Some(&["op", "clip", "speed"]),
            "setTrackState" => Some(&["op", "track", "mute", "solo", "lock", "visible"]),
            "setSequenceSettings" => Some(&["op", "sequence", "width", "height", "fps", "sampleRate"]),
            "addClip" => Some(&["op", "media", "track", "at", "sourceIn", "sourceOut", "linkAudio", "mode", "streams", "duration"]),
            "createSequence" => Some(&["op", "name", "width", "height", "fps", "sampleRate"]),
            "setActiveSequence" => Some(&["op", "sequence"]),
            "syncAudio" => Some(&["op", "clip", "to", "retime"]),
            "setParam" => Some(&["op", "clip", "param", "value"]),
            "addEffect" => Some(&["op", "clip", "effect", "index"]),
            "removeEffect" => Some(&["op", "clip", "effect"]),
            "setKeyframe" => Some(&["op", "clip", "param", "at", "value", "interpolation", "ease", "inHandle", "outHandle"]),
            "removeKeyframe" => Some(&["op", "clip", "param", "at"]),
            "moveKeyframe" => Some(&["op", "clip", "param", "from", "to"]),
            "shiftKeyframes" => Some(&["op", "clip", "param", "by", "after"]),
            "addTransition" => Some(&["op", "clip", "edge", "between", "kind", "duration", "alignment"]),
            "removeTransition" => Some(&["op", "transition"]),
            "applyPreset" => Some(&["op", "clip", "preset", "at", "mode"]),
            "addGraphic" => Some(&["op", "track", "at", "duration", "name", "layers"]),
            "removeTextLayer" => Some(&["op", "clip", "layer"]),
            "removeTextAnimator" => Some(&["op", "clip", "layer", "side"]),
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
            "trim" => Self::Trim {
                clip: required(c, "clip")?,
                edge: edge(c)?,
                by: time(c, "by")?,
                linked: optional(c, "linked")?.unwrap_or(true),
            },
            "rippleTrim" => Self::RippleTrim {
                clip: required(c, "clip")?,
                edge: edge(c)?,
                by: time(c, "by")?,
                linked: optional(c, "linked")?.unwrap_or(true),
            },
            "link" => Self::Link { clips: required(c, "clips")? },
            "unlink" => Self::Unlink { clips: required(c, "clips")? },
            "move" => Self::Move { clip: required(c, "clip")?, to: time(c, "to")?, track: optional(c, "track")? },
            "slip" => Self::Slip { clip: required(c, "clip")?, by: time(c, "by")? },
            "slide" => Self::Slide { clip: required(c, "clip")?, by: time(c, "by")? },
            "roll" => Self::Roll { clip: required(c, "clip")?, by: time(c, "by")? },
            "toggleEnabled" => Self::ToggleEnabled { clips: required(c, "clips")? },
            "addMarker" => Self::AddMarker { at: time(c, "at")?, name: optional(c, "name")?.unwrap_or_default() },
            "setPixelAspect" => Self::SetPixelAspect { media: required(c, "media")?, aspect: optional(c, "aspect")? },
            "removeClip" => {
                Self::RemoveClip { clips: required(c, "clips")?, ripple: optional(c, "ripple")?.unwrap_or(false) }
            }
            "addTrack" => Self::AddTrack {
                kind: match required::<String>(c, "kind")?.as_str() {
                    "video" => TrackKind::Video,
                    "audio" => TrackKind::Audio,
                    other => return Err(format!("kind: unknown kind '{other}'; known: video, audio")),
                },
            },
            "setClipSpeed" => {
                let w = required::<SpeedWire>(c, "speed")?;
                if w.num <= 0 || w.den <= 0 {
                    return Err(format!("speed: must be positive, got {}/{}", w.num, w.den));
                }
                Self::SetClipSpeed { clip: required(c, "clip")?, speed: ClipSpeed::new(w.num, w.den) }
            }
            "setTrackState" => {
                let (mute, solo, lock, visible) =
                    (optional(c, "mute")?, optional(c, "solo")?, optional(c, "lock")?, optional(c, "visible")?);
                if mute.is_none() && solo.is_none() && lock.is_none() && visible.is_none() {
                    return Err("setTrackState: give at least one of mute, solo, lock, visible".to_string());
                }
                Self::SetTrackState { track: required(c, "track")?, mute, solo, lock, visible }
            }
            "setSequenceSettings" => Self::SetSequenceSettings {
                sequence: optional(c, "sequence")?,
                width: optional(c, "width")?,
                height: optional(c, "height")?,
                fps: c.get("fps").filter(|v| !v.is_null()).map(Fps::from_value).transpose()?,
                sample_rate: optional(c, "sampleRate")?,
            },
            "addClip" => Self::AddClip {
                media: required(c, "media")?,
                track: optional(c, "track")?,
                at: time(c, "at")?,
                source_in: optional::<WireTime>(c, "sourceIn")?.map(|w| w.time),
                source_out: optional::<WireTime>(c, "sourceOut")?.map(|w| w.time),
                link_audio: optional(c, "linkAudio")?.unwrap_or(true),
                streams: match optional::<String>(c, "streams")?.as_deref() {
                    None => None,
                    Some("both") => Some(ClipStreams::Both),
                    Some("video") => Some(ClipStreams::Video),
                    Some("audio") => Some(ClipStreams::Audio),
                    Some(other) => return Err(format!("streams: unknown '{other}'; known: both, video, audio")),
                },
                duration: optional::<WireTime>(c, "duration")?.map(|w| w.time),
                insert: match optional::<String>(c, "mode")?.as_deref() {
                    None | Some("overwrite") => false,
                    Some("insert") => true,
                    Some(other) => return Err(format!("mode: unknown mode '{other}'; known: overwrite, insert")),
                },
            },
            "createSequence" => Self::CreateSequence {
                name: required(c, "name")?,
                width: required(c, "width")?,
                height: required(c, "height")?,
                fps: Fps::from_value(c.get("fps").ok_or("missing field `fps`")?)?,
                sample_rate: optional(c, "sampleRate")?,
            },
            "setActiveSequence" => Self::SetActiveSequence { sequence: required(c, "sequence")? },
            "syncAudio" => Self::SyncAudio {
                clip: required(c, "clip")?,
                to: required(c, "to")?,
                retime: optional::<bool>(c, "retime")?.unwrap_or(true),
            },
            "setParam" => Self::SetParam { clip: required(c, "clip")?, param: required(c, "param")?, value: required(c, "value")? },
            "addEffect" => Self::AddEffect { clip: required(c, "clip")?, effect: required(c, "effect")?, index: optional(c, "index")? },
            "removeEffect" => Self::RemoveEffect { clip: required(c, "clip")?, effect: required(c, "effect")? },
            "setKeyframe" => {
                let interpolation: Option<String> = optional(c, "interpolation")?;
                let ease: Option<String> = optional(c, "ease")?;
                let in_handle: Option<Value> = optional(c, "inHandle")?;
                let out_handle: Option<Value> = optional(c, "outHandle")?;
                // Refuse a bad shape when the batch is read, with the field named.
                crate::clip_params::KeyShape::parse(
                    interpolation.as_deref(),
                    ease.as_deref(),
                    in_handle.as_ref(),
                    out_handle.as_ref(),
                )?;
                Self::SetKeyframe {
                    clip: required(c, "clip")?,
                    param: required(c, "param")?,
                    at: time(c, "at")?,
                    value: required(c, "value")?,
                    interpolation,
                    ease,
                    in_handle,
                    out_handle,
                }
            }
            "addTransition" => {
                let kind: String = required(c, "kind")?;
                let alignment: String = optional(c, "alignment")?.unwrap_or_else(|| "center".to_string());
                crate::transition_ops::parse_kind(&kind)?;
                crate::transition_ops::parse_alignment(&alignment)?;
                let between: Option<[Id; 2]> = optional(c, "between")?;
                let place = match (between, c.contains_key("clip")) {
                    (Some([a, b]), false) if !c.contains_key("edge") => crate::transition_ops::Place::Between(a, b),
                    (None, true) => crate::transition_ops::Place::Edge(required(c, "clip")?, edge(c)?),
                    _ => return Err("addTransition: give either clip + edge, or between: [outgoing, incoming]".into()),
                };
                Self::AddTransition { place, kind, duration: time(c, "duration")?, alignment }
            }
            "removeTransition" => Self::RemoveTransition { transition: required(c, "transition")? },
            "applyPreset" => {
                let at = match optional::<String>(c, "at")?.as_deref() {
                    None => None,
                    Some("head") => Some(ClipEdge::Head),
                    Some("tail") => Some(ClipEdge::Tail),
                    Some(o) => return Err(format!("at: unknown '{o}'; known: head, tail")),
                };
                Self::ApplyPreset { clip: required(c, "clip")?, preset: required(c, "preset")?, at, mode: optional(c, "mode")? }
            }
            "removeKeyframe" => Self::RemoveKeyframe { clip: required(c, "clip")?, param: required(c, "param")?, at: time(c, "at")? },
            "moveKeyframe" => Self::MoveKeyframe {
                clip: required(c, "clip")?,
                param: required(c, "param")?,
                from: time(c, "from")?,
                to: time(c, "to")?,
            },
            "shiftKeyframes" => Self::ShiftKeyframes {
                clip: required(c, "clip")?,
                param: optional(c, "param")?,
                by: time(c, "by")?,
                after: if c.contains_key("after") { Some(time(c, "after")?) } else { None },
            },
            "addGraphic" => {
                let layers: Vec<Value> = required(c, "layers")?;
                if layers.is_empty() || layers.len() > crate::text_layers::MAX_LAYERS {
                    return Err(format!("layers: 1...{} text layers", crate::text_layers::MAX_LAYERS));
                }
                layers.iter().enumerate().try_for_each(|(i, l)| {
                    crate::text_layers::check_spec(l).map_err(|e| format!("layers[{i}]: {e}"))
                })?;
                Self::AddGraphic {
                    track: required(c, "track")?,
                    at: time(c, "at")?,
                    duration: time(c, "duration")?,
                    name: optional(c, "name")?,
                    layers,
                }
            }
            "setTextLayer" | "addTextLayer" => {
                let own: &[&str] = if op == "setTextLayer" { &["op", "clip", "layer"] } else { &["op", "clip", "index"] };
                let fields = crate::text_layers::spec_from(c, own);
                crate::text_layers::check_spec(&fields)?;
                if op == "setTextLayer" {
                    Self::SetTextLayer { clip: required(c, "clip")?, layer: required(c, "layer")?, fields }
                } else {
                    Self::AddTextLayer { clip: required(c, "clip")?, index: optional(c, "index")?, fields }
                }
            }
            "addTextAnimator" | "setTextAnimator" => {
                let fields = crate::text_layers::spec_from(c, &["op", "clip", "layer"]);
                crate::text_animators::check_spec(&fields, op == "addTextAnimator")?;
                let (clip, layer) = (required(c, "clip")?, required(c, "layer")?);
                if op == "addTextAnimator" {
                    Self::AddTextAnimator { clip, layer, fields }
                } else {
                    Self::SetTextAnimator { clip, layer, fields }
                }
            }
            "setTextAccent" => {
                let fields = crate::text_layers::spec_from(c, &["op", "clip", "layer"]);
                if let Value::Object(f) = &fields {
                    crate::text_accent::check_spec(f)?;
                }
                Self::SetTextAccent { clip: required(c, "clip")?, layer: required(c, "layer")?, fields }
            }
            "addMask" => {
                let fields = crate::text_layers::spec_from(c, &["op", "clip"]);
                if let Value::Object(f) = &fields {
                    crate::mask_ops::check_spec(f)?;
                }
                Self::AddMask { clip: required(c, "clip")?, fields }
            }
            "removeTextAnimator" => {
                crate::text_animators::parse_side(c.get("side"))?;
                Self::RemoveTextAnimator { clip: required(c, "clip")?, layer: required(c, "layer")?, side: optional(c, "side")? }
            }
            "removeTextLayer" => Self::RemoveTextLayer { clip: required(c, "clip")?, layer: required(c, "layer")? },
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
            Self::RippleDelete { clips }
            | Self::Lift { clips }
            | Self::ToggleEnabled { clips }
            | Self::Link { clips }
            | Self::Unlink { clips } => {
                put("clips", json!(clips));
            }
            Self::Extract { range, tracks: t } | Self::LiftRange { range, tracks: t } => {
                put("range", json!(range));
                tracks(t).into_iter().for_each(|v| put("tracks", v));
            }
            Self::Trim { clip, edge, by, linked } | Self::RippleTrim { clip, edge, by, linked } => {
                put("clip", json!(clip));
                put("edge", json!(edge_name(*edge)));
                put("by", json!(by));
                if !linked {
                    put("linked", json!(false));
                }
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
            Self::RemoveClip { clips, ripple } => {
                put("clips", json!(clips));
                put("ripple", json!(ripple));
            }
            Self::AddTrack { kind } => put("kind", json!(if *kind == TrackKind::Video { "video" } else { "audio" })),
            Self::SetClipSpeed { clip, speed } => {
                put("clip", json!(clip));
                put("speed", json!({"num": speed.num(), "den": speed.den()}));
            }
            Self::SetTrackState { track, mute, solo, lock, visible } => {
                put("track", json!(track));
                for (k, v) in [("mute", mute), ("solo", solo), ("lock", lock), ("visible", visible)] {
                    v.iter().for_each(|v| put(k, json!(v)));
                }
            }
            Self::SetSequenceSettings { sequence, width, height, fps, sample_rate } => {
                sequence.iter().for_each(|v| put("sequence", json!(v)));
                width.iter().for_each(|v| put("width", json!(v)));
                height.iter().for_each(|v| put("height", json!(v)));
                fps.iter().for_each(|v| put("fps", v.to_value()));
                sample_rate.iter().for_each(|v| put("sampleRate", json!(v)));
            }
            Self::AddClip { media, track, at, source_in, source_out, link_audio, insert, streams, duration } => {
                streams.iter().for_each(|v| put("streams", json!(v.name())));
                duration.iter().for_each(|v| put("duration", json!(v)));
                put("media", json!(media));
                track.iter().for_each(|v| put("track", json!(v)));
                put("at", json!(at));
                source_in.iter().for_each(|v| put("sourceIn", json!(v)));
                source_out.iter().for_each(|v| put("sourceOut", json!(v)));
                put("linkAudio", json!(link_audio));
                put("mode", json!(if *insert { "insert" } else { "overwrite" }));
            }
            Self::CreateSequence { name, width, height, fps, sample_rate } => {
                put("name", json!(name));
                put("width", json!(width));
                put("height", json!(height));
                put("fps", fps.to_value());
                sample_rate.iter().for_each(|v| put("sampleRate", json!(v)));
            }
            Self::SetActiveSequence { sequence } => put("sequence", json!(sequence)),
            Self::SyncAudio { clip, to, retime } => {
                put("clip", json!(clip));
                put("to", json!(to));
                put("retime", json!(retime));
            }
            Self::SetParam { clip, param, value } => {
                put("clip", json!(clip));
                put("param", json!(param));
                put("value", value.clone());
            }
            Self::AddEffect { clip, effect, index } => {
                put("clip", json!(clip));
                put("effect", json!(effect));
                index.iter().for_each(|i| put("index", json!(i)));
            }
            Self::RemoveEffect { clip, effect } => {
                put("clip", json!(clip));
                put("effect", json!(effect));
            }
            Self::SetKeyframe { clip, param, at, value, interpolation, ease, in_handle, out_handle } => {
                put("clip", json!(clip));
                put("param", json!(param));
                put("at", json!(at));
                put("value", value.clone());
                interpolation.iter().for_each(|i| put("interpolation", json!(i)));
                ease.iter().for_each(|e| put("ease", json!(e)));
                in_handle.iter().for_each(|h| put("inHandle", h.clone()));
                out_handle.iter().for_each(|h| put("outHandle", h.clone()));
            }
            Self::AddTransition { place, kind, duration, alignment } => {
                match place {
                    crate::transition_ops::Place::Edge(c, e) => {
                        put("clip", json!(c));
                        put("edge", json!(edge_name(*e)));
                    }
                    crate::transition_ops::Place::Between(a, b) => put("between", json!([a, b])),
                }
                put("kind", json!(kind));
                put("duration", json!(duration));
                put("alignment", json!(alignment));
            }
            Self::RemoveTransition { transition } => put("transition", json!(transition)),
            Self::ApplyUserPreset { clip, name, at, mode, .. } => {
                put("clip", json!(clip));
                put("preset", json!(name));
                at.iter().for_each(|e| put("at", json!(edge_name(*e))));
                mode.iter().for_each(|m| put("mode", json!(m)));
            }
            Self::ApplyPreset { clip, preset, at, mode } => {
                put("clip", json!(clip));
                put("preset", json!(preset));
                at.iter().for_each(|e| put("at", json!(edge_name(*e))));
                mode.iter().for_each(|m| put("mode", json!(m)));
            }
            Self::RemoveKeyframe { clip, param, at } => {
                put("clip", json!(clip));
                put("param", json!(param));
                put("at", json!(at));
            }
            Self::MoveKeyframe { clip, param, from, to } => {
                put("clip", json!(clip));
                put("param", json!(param));
                put("from", json!(from));
                put("to", json!(to));
            }
            Self::ShiftKeyframes { clip, param, by, after } => {
                put("clip", json!(clip));
                param.iter().for_each(|p| put("param", json!(p)));
                put("by", json!(by));
                after.iter().for_each(|a| put("after", json!(a)));
            }
            Self::AddGraphic { track, at, duration, name, layers } => {
                put("track", json!(track));
                put("at", json!(at));
                put("duration", json!(duration));
                name.iter().for_each(|n| put("name", json!(n)));
                put("layers", json!(layers));
            }
            Self::SetTextLayer { clip, layer, fields } => {
                put("clip", json!(clip));
                put("layer", json!(layer));
                if let Value::Object(f) = fields {
                    f.iter().for_each(|(k, v)| put(k, v.clone()));
                }
            }
            Self::AddTextLayer { clip, index, fields } => {
                put("clip", json!(clip));
                index.iter().for_each(|i| put("index", json!(i)));
                if let Value::Object(f) = fields {
                    f.iter().for_each(|(k, v)| put(k, v.clone()));
                }
            }
            Self::RemoveTextLayer { clip, layer } => {
                put("clip", json!(clip));
                put("layer", json!(layer));
            }
            Self::AddTextAnimator { clip, layer, fields } | Self::SetTextAnimator { clip, layer, fields } => {
                put("clip", json!(clip));
                put("layer", json!(layer));
                if let Value::Object(f) = fields {
                    f.iter().for_each(|(k, v)| put(k, v.clone()));
                }
            }
            Self::SetTextAccent { clip, layer, fields } => {
                put("clip", json!(clip));
                put("layer", json!(layer));
                if let Value::Object(f) = fields {
                    f.iter().for_each(|(k, v)| put(k, v.clone()));
                }
            }
            Self::AddMask { clip, fields } => {
                put("clip", json!(clip));
                if let Value::Object(f) = fields {
                    f.iter().for_each(|(k, v)| put(k, v.clone()));
                }
            }
            Self::RemoveTextAnimator { clip, layer, side } => {
                put("clip", json!(clip));
                put("layer", json!(layer));
                side.iter().for_each(|s| put("side", json!(s)));
            }
        }
        Value::Object(m)
    }
}

#[derive(Deserialize)]
struct SpeedWire {
    num: i64,
    den: i64,
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
        assert_eq!(ops[6], EditOperation::Trim { clip: id, edge: ClipEdge::Head, by: Time::new(1, 25), linked: true });
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

    #[test]
    fn timeline_building_operations_decode_and_round_trip() {
        let (id, tr) = (Id::from_u128(5), Id::from_u128(6));
        let json = format!(
            r#"[{{"op":"addClip","media":"{id}","at":{{"value":1,"timescale":1}},"sourceIn":{{"value":2,"timescale":1}},"linkAudio":false,"mode":"insert"}},
             {{"op":"addClip","media":"{id}","track":"{tr}","at":{{"value":0,"timescale":1}}}},
             {{"op":"removeClip","clips":["{id}"],"ripple":true}},
             {{"op":"addTrack","kind":"audio"}},
             {{"op":"setClipSpeed","clip":"{id}","speed":{{"num":2,"den":1}}}},
             {{"op":"setTrackState","track":"{tr}","mute":true,"lock":false}},
             {{"op":"setSequenceSettings","width":1080,"height":1920,"fps":29.97,"sampleRate":44100}},
             {{"op":"createSequence","name":"Reel","width":1080,"height":1920,"fps":60}},
             {{"op":"setActiveSequence","sequence":"{id}"}},
             {{"op":"syncAudio","clip":"{id}","to":"{tr}","retime":false}}]"#
        );
        let ops = decode(&json).unwrap_or_else(|e| panic!("decode: {e}"));
        assert_eq!(ops.len(), 10);
        assert_eq!(ops[9], EditOperation::SyncAudio { clip: id, to: tr, retime: false });
        assert!(matches!(&ops[0], EditOperation::AddClip { link_audio: false, insert: true, track: None, .. }));
        assert!(matches!(&ops[1], EditOperation::AddClip { link_audio: true, insert: false, track: Some(_), .. }));
        let EditOperation::SetSequenceSettings { fps: Some(f), .. } = &ops[6] else { panic!("settings") };
        assert_eq!((f.num, f.den), (30_000, 1001));
        let EditOperation::CreateSequence { fps, .. } = &ops[7] else { panic!("create") };
        assert_eq!(fps.frame_duration(), Time::new(1, 60));
        assert_eq!(ops.iter().filter(|o| o.is_session_operation()).count(), 5);
        let again = serde_json::to_string(&ops).and_then(|s| serde_json::from_str::<Vec<EditOperation>>(&s));
        assert_eq!(again.ok(), Some(ops));
        assert_eq!(EditOperation::ALL_NAMES.len(), 44);
    }

    #[test]
    fn timeline_building_operations_refuse_bad_values() {
        let id = Id::from_u128(5);
        for bad in [
            r#"[{"op":"addTrack","kind":"subtitle"}]"#.to_string(),
            format!(r#"[{{"op":"setClipSpeed","clip":"{id}","speed":{{"num":0,"den":1}}}}]"#),
            format!(r#"[{{"op":"setTrackState","track":"{id}"}}]"#),
            r#"[{"op":"setSequenceSettings","fps":29.5}]"#.to_string(),
            r#"[{"op":"createSequence","name":"x","width":1,"height":1,"fps":2000}]"#.to_string(),
            r#"[{"op":"createSequence","name":"x","width":1,"height":1}]"#.to_string(),
            format!(r#"[{{"op":"addClip","media":"{id}","at":{{"value":0,"timescale":1}},"mode":"replace"}}]"#),
            format!(r#"[{{"op":"addClip","media":"{id}","at":{{"value":0,"timescale":1}},"zzz":1}}]"#),
        ] {
            assert!(decode(&bad).is_err(), "{bad}");
        }
    }
}
