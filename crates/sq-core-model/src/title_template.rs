// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TitleTemplate.swift (the slot types stored on a clip, moved down; templates themselves: later tasks)

use crate::bin::Underscore0;
use crate::{AnimationZones, EditError, GraphicsContent, Timeline, TrackKind};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sq_core_time::{Id, Time};
use std::fmt;

/// What a slot edits.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TemplateSlotKind {
    /// A text.
    Text,
    /// A color.
    Color,
    /// A font name.
    Font,
    /// A number.
    Number,
}

/// A value a slot can hold. Coded like a Swift enum with payloads: `{"text": {"_0": "..."}}`,
/// `{"color": {"red": .., "green": .., "blue": .., "alpha": ..}}`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "SlotValueWire", into = "SlotValueWire")]
pub enum SlotValue {
    /// A text.
    Text(String),
    /// A color, plain RGBA.
    Color {
        /// Red.
        red: f64,
        /// Green.
        green: f64,
        /// Blue.
        blue: f64,
        /// Alpha.
        alpha: f64,
    },
    /// A font name.
    Font(String),
    /// A number.
    Number(f64),
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum SlotValueWire {
    Text(Underscore0<String>),
    Color { red: f64, green: f64, blue: f64, alpha: f64 },
    Font(Underscore0<String>),
    Number(Underscore0<f64>),
}

impl From<SlotValueWire> for SlotValue {
    fn from(w: SlotValueWire) -> Self {
        match w {
            SlotValueWire::Text(s) => SlotValue::Text(s.value),
            SlotValueWire::Color { red, green, blue, alpha } => SlotValue::Color { red, green, blue, alpha },
            SlotValueWire::Font(s) => SlotValue::Font(s.value),
            SlotValueWire::Number(n) => SlotValue::Number(n.value),
        }
    }
}

impl From<SlotValue> for SlotValueWire {
    fn from(v: SlotValue) -> Self {
        match v {
            SlotValue::Text(s) => SlotValueWire::Text(Underscore0 { value: s }),
            SlotValue::Color { red, green, blue, alpha } => SlotValueWire::Color { red, green, blue, alpha },
            SlotValue::Font(s) => SlotValueWire::Font(Underscore0 { value: s }),
            SlotValue::Number(n) => SlotValueWire::Number(Underscore0 { value: n }),
        }
    }
}

/// An editable value of a template: one key path in one layer's generator payload.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TemplateSlot {
    /// Identity.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// What the slot edits.
    pub kind: TemplateSlotKind,
    /// The layer clip whose payload holds the value.
    pub layer: Id,
    /// The layer inside a Graphic when the slot edits a graphics layer; `None` for a plain layer clip.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub graphics_layer: Option<Id>,
    /// Key path inside the payload.
    pub path: String,
    /// The current value.
    pub value: SlotValue,
}

/// Why a title template function refused (Swift `TitleTemplateError`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TitleTemplateError {
    /// Auto-detect found no keyframes on the clip.
    NoKeyframes,
    /// The slot's path does not exist in its layer's payload (or the layer is not a generator).
    SlotPathNotFound(String),
    /// The clip has no slot with this id, or is not an applied template.
    SlotNotFound,
    /// A template file written by a newer app.
    NewerFormat {
        /// The version found.
        found: i64,
        /// The newest version this build reads.
        supported: i64,
    },
}

impl fmt::Display for TitleTemplateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

impl std::error::Error for TitleTemplateError {}

/// What a title template function throws: an `EditError` or a `TitleTemplateError` (Swift `throws` both).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TemplateEditError {
    /// An ordinary edit refusal.
    Edit(EditError),
    /// A template refusal.
    Template(TitleTemplateError),
}

impl From<EditError> for TemplateEditError {
    fn from(e: EditError) -> Self {
        TemplateEditError::Edit(e)
    }
}

impl From<TitleTemplateError> for TemplateEditError {
    fn from(e: TitleTemplateError) -> Self {
        TemplateEditError::Template(e)
    }
}

impl fmt::Display for TemplateEditError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

impl std::error::Error for TemplateEditError {}

// shortcut: generator kind names copied from SQText / SQGraphics (core-model cannot depend on them); use the owners'
// constants when a shared constants module exists.
const TEXT_KIND: &str = "text";
const SHAPE_KIND: &str = "shape";
const GRAPHICS_KIND: &str = "graphics";
const LOTTIE_KIND: &str = "lottie";
const SOLID_KIND: &str = "solid";

/// What a layer of a template is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TemplateLayerKind {
    /// A text generator.
    Text,
    /// A shape generator.
    Shape,
    /// A graphics, Lottie or solid generator.
    Graphic,
    /// Anything else.
    Other,
}

impl TemplateLayerKind {
    /// The kind of a layer whose generator is `kind`.
    pub fn from_generator(kind: Option<&str>) -> TemplateLayerKind {
        match kind {
            Some(TEXT_KIND) => TemplateLayerKind::Text,
            Some(SHAPE_KIND) => TemplateLayerKind::Shape,
            Some(GRAPHICS_KIND | LOTTIE_KIND | SOLID_KIND) => TemplateLayerKind::Graphic,
            _ => TemplateLayerKind::Other,
        }
    }
}

/// One layer of a template: a clip of `TitleTemplate::content`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TemplateLayer {
    /// The clip.
    pub clip: Id,
    /// Its name.
    pub name: String,
    /// What it is.
    pub kind: TemplateLayerKind,
}

impl SlotValue {
    /// The payload JSON value (a color is written like SQText's `RGBAColor`).
    pub fn json(&self) -> Value {
        match self {
            SlotValue::Text(s) | SlotValue::Font(s) => Value::String(s.clone()),
            SlotValue::Number(n) => serde_json::Number::from_f64(*n).map_or(Value::Null, Value::Number),
            SlotValue::Color { red, green, blue, alpha } => {
                let mut m = serde_json::Map::new();
                for (k, v) in [("red", red), ("green", green), ("blue", blue), ("alpha", alpha)] {
                    m.insert(k.to_string(), serde_json::Number::from_f64(*v).map_or(Value::Null, Value::Number));
                }
                Value::Object(m)
            }
        }
    }
}

/// A title template: several layers saved as ONE template (see the Swift file comment).
#[derive(Clone, Debug, PartialEq)]
pub struct TitleTemplate {
    /// Identity.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Library grouping (Titles, Lower thirds, Captions, Social ...); `None` = uncategorised.
    pub category: Option<String>,
    /// The nested-sequence snapshot: layers on video tracks (bottom first), starting at 0.
    pub content: Timeline,
    /// The editable fields.
    pub slots: Vec<TemplateSlot>,
    /// Template-level zones; `design_duration` is the template length.
    pub zones: AnimationZones,
}

impl TitleTemplate {
    /// On-disk format of a template (PresetStore payload, packs). Raise when a field changes meaning.
    pub const FORMAT_VERSION: i64 = 5;

    /// A template; `zones` get the content's length as `design_duration`.
    pub fn new(
        id: Id,
        name: &str,
        category: Option<String>,
        content: Timeline,
        slots: Vec<TemplateSlot>,
        zones: Option<AnimationZones>,
    ) -> TitleTemplate {
        let d = content.duration();
        let mut z =
            zones.unwrap_or_else(|| AnimationZones::new(Time::ZERO, Time::ZERO, crate::ZoneMiddle::Hold, Some(d)));
        z.design_duration = Some(d);
        TitleTemplate { id, name: name.to_string(), category, content, slots, zones: z }
    }

    /// Format 3 when a graphics layer of the content follows another (G11, `GraphicsLayer.follow`); 2 when some slot
    /// addresses a graphics layer (`TemplateSlot.graphics_layer`). An older build then refuses the template
    /// (`NewerFormat`) instead of dropping the field. Format 4 when layers carry Fast Cut attachments (v67 field). Format
    /// 5 when an item of a Graphic has a range (`GraphicsLayer.range`, v74 field). Plain templates stay format 1.
    pub fn written_format_version(&self) -> i64 {
        if self.content.contains_item_ranges() {
            return 5;
        }
        if self.content.has_attachments() {
            return 4;
        }
        if self.content.contains_follow() {
            return 3;
        }
        if self.slots.iter().any(|s| s.graphics_layer.is_some()) { 2 } else { 1 }
    }

    /// Default length: the content's.
    pub fn duration(&self) -> Time {
        self.content.duration()
    }

    /// Every layer, bottom track first.
    pub fn layers(&self) -> Vec<TemplateLayer> {
        self.content
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Video)
            .flat_map(|t| {
                t.clips().iter().map(|c| TemplateLayer {
                    clip: c.id,
                    name: c.name.clone(),
                    kind: TemplateLayerKind::from_generator(c.generator.as_ref().map(|g| g.kind.as_str())),
                })
            })
            .collect()
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TemplateOut<'a> {
    format_version: i64,
    id: Id,
    name: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    category: Option<&'a str>,
    content: &'a Timeline,
    slots: &'a [TemplateSlot],
    zones: &'a AnimationZones,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TemplateIn {
    #[serde(default)]
    format_version: Option<i64>,
    id: Id,
    name: String,
    #[serde(default)]
    category: Option<String>,
    content: Timeline,
    #[serde(default)]
    slots: Option<Vec<TemplateSlot>>,
    #[serde(default)]
    zones: Option<AnimationZones>,
}

impl Serialize for TitleTemplate {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        TemplateOut {
            format_version: self.written_format_version(),
            id: self.id,
            name: &self.name,
            category: self.category.as_deref(),
            content: &self.content,
            slots: &self.slots,
            zones: &self.zones,
        }
        .serialize(s)
    }
}

impl<'de> Deserialize<'de> for TitleTemplate {
    /// A template of a newer format is refused (`TitleTemplateError::NewerFormat`, as the error text).
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let w = TemplateIn::deserialize(d)?;
        let v = w.format_version.unwrap_or(1);
        if v > TitleTemplate::FORMAT_VERSION {
            let e = TitleTemplateError::NewerFormat { found: v, supported: TitleTemplate::FORMAT_VERSION };
            return Err(serde::de::Error::custom(e));
        }
        Ok(TitleTemplate::new(w.id, &w.name, w.category, w.content, w.slots.unwrap_or_default(), w.zones))
    }
}

/// Dot-path access into a generator payload's JSON object (Swift `PayloadPath`).
pub struct PayloadPath;

impl PayloadPath {
    /// The value at `path`. Errors: `SlotPathNotFound`.
    pub fn value(path: &str, payload: &[u8]) -> Result<Value, TitleTemplateError> {
        let not_found = || TitleTemplateError::SlotPathNotFound(path.to_string());
        let keys: Vec<&str> = path.split('.').filter(|k| !k.is_empty()).collect();
        if keys.is_empty() {
            return Err(not_found());
        }
        let mut node: Value = serde_json::from_slice(payload).map_err(|_| not_found())?;
        for k in keys {
            let Value::Object(mut d) = node else { return Err(not_found()) };
            node = d.remove(k).ok_or_else(not_found)?;
        }
        Ok(node)
    }

    /// The payload with the existing value at `path` replaced (keys sorted, like SQText writes it).
    // shortcut: serde_json writes numbers and `/` differently from Foundation's JSONSerialization (see PORTING-NOTES);
    // the payload is read back by the same JSON reader, so the text differs only in formatting.
    pub fn setting(value: Value, path: &str, payload: &[u8]) -> Result<Vec<u8>, TitleTemplateError> {
        let not_found = || TitleTemplateError::SlotPathNotFound(path.to_string());
        let keys: Vec<&str> = path.split('.').filter(|k| !k.is_empty()).collect();
        if keys.is_empty() {
            return Err(not_found());
        }
        let Ok(Value::Object(mut root)) = serde_json::from_slice::<Value>(payload) else { return Err(not_found()) };
        fn set(d: &mut serde_json::Map<String, Value>, k: &[&str], value: Value) -> Result<(), ()> {
            let Some(key) = k.first() else { return Err(()) };
            if !d.contains_key(*key) {
                return Err(());
            }
            if k.len() == 1 {
                d.insert((*key).to_string(), value);
                return Ok(());
            }
            let Some(Value::Object(sub)) = d.get_mut(*key) else { return Err(()) };
            set(sub, &k[1..], value)
        }
        set(&mut root, &keys, value).map_err(|()| not_found())?;
        serde_json::to_vec(&Value::Object(root)).map_err(|_| not_found())
    }
}

impl Timeline {
    /// Any graphics layer of this sequence's clips follows something (G11): templates gate their format on it too.
    pub fn contains_follow(&self) -> bool {
        self.tracks.iter().any(|t| {
            t.clips().iter().any(|c| c.graphics().is_some_and(|g| g.layers.iter().any(|l| l.follow.is_some())))
        })
    }

    /// Some item of a Graphic in this sequence has a range: templates gate their format on it too (a build without item
    /// ranges would draw every item for the whole clip).
    pub fn contains_item_ranges(&self) -> bool {
        self.tracks.iter().any(|t| t.clips().iter().any(|c| c.graphics().is_some_and(|g| g.has_item_ranges())))
    }

    /// Writes `value` into the payload of the generator layer `layer` at `path`. Errors: `SlotPathNotFound`.
    pub fn set_slot(
        &mut self,
        layer: Id,
        graphics_layer: Option<Id>,
        path: &str,
        value: &SlotValue,
    ) -> Result<(), TitleTemplateError> {
        let not_found = || TitleTemplateError::SlotPathNotFound(path.to_string());
        for i in 0..self.tracks.len() {
            let Some(mut c) = self.tracks[i].clip(layer).cloned() else { continue };
            if let Some(gl) = graphics_layer {
                let Some(doc) = c.graphics_store.as_mut() else { return Err(not_found()) };
                let Some(k) = doc.index_of(gl) else { return Err(not_found()) };
                let GraphicsContent::Text { generator } = &mut doc.layers[k].content else { return Err(not_found()) };
                generator.payload = PayloadPath::setting(value.json(), path, &generator.payload)?;
                self.tracks[i].replace(c);
                return Ok(());
            }
            let Some(g) = c.generator.as_mut() else { return Err(not_found()) };
            g.payload = PayloadPath::setting(value.json(), path, &g.payload)?;
            self.tracks[i].replace(c);
            return Ok(());
        }
        Err(not_found())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    #[test]
    fn slot_values_use_the_swift_enum_shape() {
        assert_round_trip::<SlotValue>(json!({"text": {"_0": "Hello"}}));
        assert_round_trip::<SlotValue>(json!({"font": {"_0": "Inter"}}));
        assert_round_trip::<SlotValue>(json!({"number": {"_0": 2.5}}));
        assert_round_trip::<SlotValue>(json!({"color": {"red": 1.0, "green": 0.5, "blue": 0.0, "alpha": 1.0}}));
    }

    #[test]
    fn slot_round_trips_with_and_without_graphics_layer() {
        let slot = json!({"id": "00000000-0000-0000-0000-000000000001", "name": "Title", "kind": "text",
            "layer": "00000000-0000-0000-0000-000000000002", "path": "text", "value": {"text": {"_0": "A"}}});
        assert_round_trip::<TemplateSlot>(slot.clone());
        let mut with = slot;
        with["graphicsLayer"] = json!("00000000-0000-0000-0000-000000000003");
        assert_round_trip::<TemplateSlot>(with);
    }

    #[test]
    fn payload_path_reads_and_replaces_existing_values_only() {
        let payload = br#"{"template":{"text":"a","style":{"size":80}}}"#;
        assert_eq!(PayloadPath::value("template.text", payload), Ok(json!("a")));
        assert_eq!(
            PayloadPath::value("nope.text", payload),
            Err(TitleTemplateError::SlotPathNotFound("nope.text".to_string()))
        );
        let out = PayloadPath::setting(json!("b"), "template.text", payload).unwrap();
        assert_eq!(PayloadPath::value("template.text", &out), Ok(json!("b")));
        assert_eq!(PayloadPath::value("template.style.size", &out), Ok(json!(80)));
        assert!(PayloadPath::setting(json!("b"), "template.missing", payload).is_err());
        assert!(PayloadPath::setting(json!("b"), "", payload).is_err());
    }

    #[test]
    fn layer_kinds_follow_the_generator() {
        assert_eq!(TemplateLayerKind::from_generator(Some("text")), TemplateLayerKind::Text);
        assert_eq!(TemplateLayerKind::from_generator(Some("shape")), TemplateLayerKind::Shape);
        assert_eq!(TemplateLayerKind::from_generator(Some("lottie")), TemplateLayerKind::Graphic);
        assert_eq!(TemplateLayerKind::from_generator(None), TemplateLayerKind::Other);
    }
}
