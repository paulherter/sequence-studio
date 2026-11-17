// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Graphics.swift, Graphics+Follow.swift, ShapeGenerator.swift (the ShapeKind type and the Shape effect keys)

mod shape_style;

pub use shape_style::ShapeStyle;

use crate::{AnimatedProperty, BlendMode, Clip, ClipAnimation, ClipEffect, GeneratorRef, LabelColor, Project};
use serde::ser::SerializeStruct;
use serde::{Deserialize, Serialize, Serializer};
use sq_core_time::{EncodeContext, Id, IdSource, Keyframe, KeyframeValue, Seen, Time, TimeRange, Vec2};

/// The built-in shapes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ShapeKind {
    /// Rectangle.
    Rectangle,
    /// Ellipse.
    Ellipse,
    /// Line.
    Line,
    /// Arrow.
    Arrow,
}

/// What a graphics layer draws. Coded like a Swift enum with labeled payloads: `{"shape": {"kind": ..}}`,
/// `{"path": {"points": .., "closed": ..}}`, `{"text": {"ref": ..}}`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GraphicsContent {
    /// A built-in shape.
    Shape {
        /// Which shape.
        kind: ShapeKind,
    },
    /// A drawn path; points are fractions of the layer's own box.
    Path {
        /// The points.
        points: Vec<Vec2>,
        /// Closed (filled) or open (stroked).
        closed: bool,
    },
    /// A text generator.
    Text {
        /// The generator that renders the text.
        #[serde(rename = "ref")]
        generator: GeneratorRef,
    },
}

/// A named group of layers.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct GraphicsGroup {
    /// Identity.
    pub id: Id,
    /// Shown name.
    pub name: String,
}

/// Which edges of the target a follow layer tracks. Coded as the Swift `OptionSet` raw value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct GraphicsEdges(pub i64);

impl GraphicsEdges {
    /// Left edge.
    pub const LEFT: GraphicsEdges = GraphicsEdges(1);
    /// Top edge.
    pub const TOP: GraphicsEdges = GraphicsEdges(2);
    /// Right edge.
    pub const RIGHT: GraphicsEdges = GraphicsEdges(4);
    /// Bottom edge.
    pub const BOTTOM: GraphicsEdges = GraphicsEdges(8);
    /// All four edges.
    pub const ALL: GraphicsEdges = GraphicsEdges(15);
}

/// Padding per edge.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct GraphicsEdgePadding {
    /// Left.
    pub left: f64,
    /// Top.
    pub top: f64,
    /// Right.
    pub right: f64,
    /// Bottom.
    pub bottom: f64,
}

/// What a follow layer tracks (Swift `GraphicsFollow.Target`). Coded as `{"frame": {}}` or `{"layer": {"id": ..}}`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(from = "FollowTargetWire", into = "FollowTargetWire")]
pub enum FollowTarget {
    /// The frame.
    Frame,
    /// Another layer of the same Graphic.
    Layer(Id),
}

#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum FollowTargetWire {
    Frame {},
    Layer { id: Id },
}

impl From<FollowTargetWire> for FollowTarget {
    fn from(w: FollowTargetWire) -> Self {
        match w {
            FollowTargetWire::Frame {} => FollowTarget::Frame,
            FollowTargetWire::Layer { id } => FollowTarget::Layer(id),
        }
    }
}

impl From<FollowTarget> for FollowTargetWire {
    fn from(t: FollowTarget) -> Self {
        match t {
            FollowTarget::Frame => FollowTargetWire::Frame {},
            FollowTarget::Layer(id) => FollowTargetWire::Layer { id },
        }
    }
}

/// A layer that follows the box of a target (a text, another layer or the frame).
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GraphicsFollow {
    /// What it follows.
    pub target: FollowTarget,
    /// Which edges follow.
    pub edges: GraphicsEdges,
    /// Padding on all edges.
    pub padding: f64,
    /// Padding per edge when the edges differ.
    #[serde(default)]
    pub edge_padding: Option<GraphicsEdgePadding>,
}

impl Serialize for GraphicsFollow {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut st = s.serialize_struct("GraphicsFollow", 3 + usize::from(self.edge_padding.is_some()))?;
        st.serialize_field("target", &self.target)?;
        st.serialize_field("edges", &self.edges)?;
        st.serialize_field("padding", &self.padding)?;
        if let Some(p) = &self.edge_padding {
            st.serialize_field("edgePadding", p)?;
            // Per-edge padding needs file version 85: the writer learns about it here.
            EncodeContext::mark(Seen::FollowEdgePadding);
        }
        st.end()
    }
}

fn layer_name() -> String {
    "Layer".to_string()
}

fn yes() -> bool {
    true
}

/// One layer of a Graphic.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GraphicsLayer {
    /// Identity.
    pub id: Id,
    /// Shown name.
    #[serde(default = "layer_name")]
    pub name: String,
    /// What it draws.
    pub content: GraphicsContent,
    /// Transform and opacity.
    #[serde(default)]
    pub animation: ClipAnimation,
    /// Effects, in render order.
    #[serde(default)]
    pub effects: Vec<ClipEffect>,
    /// Blend mode.
    #[serde(default = "crate::serde_defaults::normal_blend")]
    pub blend_mode: BlendMode,
    /// Eye toggle.
    #[serde(default = "yes")]
    pub is_visible: bool,
    /// Locked layers refuse edits.
    #[serde(default)]
    pub is_locked: bool,
    /// The group the layer belongs to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<Id>,
    /// Follows a target's box.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub follow: Option<GraphicsFollow>,
    /// Visible range, clip-local; `None` = the whole clip.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub range: Option<TimeRange>,
    /// Label color.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<LabelColor>,
}

/// The layers of a graphics clip.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct GraphicsDocument {
    /// Layers, bottom first.
    #[serde(default)]
    pub layers: Vec<GraphicsLayer>,
    /// Groups.
    #[serde(default)]
    pub groups: Vec<GraphicsGroup>,
}

impl GraphicsGroup {
    /// A group tag.
    pub fn new(id: Id, name: &str) -> GraphicsGroup {
        GraphicsGroup { id, name: name.to_string() }
    }
}

impl GraphicsLayer {
    /// A visible, unlocked layer with identity motion, no effects and the Normal blend mode.
    pub fn new(id: Id, name: &str, content: GraphicsContent) -> GraphicsLayer {
        GraphicsLayer {
            id,
            name: name.to_string(),
            content,
            animation: ClipAnimation::default(),
            effects: Vec::new(),
            blend_mode: BlendMode::Normal,
            is_visible: true,
            is_locked: false,
            group: None,
            follow: None,
            range: None,
            label: None,
        }
    }

    /// A text layer from a text payload (`TextGenerator.makeRef`); Swift names it "Text" by default.
    pub fn text(id: Id, generator: GeneratorRef, name: &str) -> GraphicsLayer {
        GraphicsLayer::new(id, name, GraphicsContent::Text { generator })
    }

    /// The layer draws text.
    pub fn is_text(&self) -> bool {
        matches!(self.content, GraphicsContent::Text { .. })
    }

    /// The Shape effect of a shape or path layer.
    pub fn shape_effect(&self) -> Option<&ClipEffect> {
        self.effects.iter().find(|e| e.kind == ClipEffect::SHAPE_EFFECT_KIND)
    }

    /// Sets a static Width x Height on the Shape effect (keys of those two are dropped).
    pub fn set_shape_size(&mut self, width: f64, height: f64) {
        let Some(e) = self.effects.iter_mut().find(|e| e.kind == ClipEffect::SHAPE_EFFECT_KIND) else { return };
        e.parameters.insert(ClipEffect::SHAPE_WIDTH_KEY.to_string(), AnimatedProperty::new(width));
        e.parameters.insert(ClipEffect::SHAPE_HEIGHT_KEY.to_string(), AnimatedProperty::new(height));
    }
}

impl GraphicsDocument {
    /// The layer with `id`.
    pub fn layer(&self, id: Id) -> Option<&GraphicsLayer> {
        self.layers.iter().find(|l| l.id == id)
    }

    /// Position of the layer with `id`.
    pub fn index_of(&self, id: Id) -> Option<usize> {
        self.layers.iter().position(|l| l.id == id)
    }

    /// The group with `id`.
    pub fn group(&self, id: Id) -> Option<&GraphicsGroup> {
        self.groups.iter().find(|g| g.id == id)
    }
}

impl ClipEffect {
    /// Kind of the Shape effect (W5.2; stored strings: never rename).
    pub const SHAPE_EFFECT_KIND: &'static str = "shape";
    /// Shape parameter.
    pub const SHAPE_WIDTH_KEY: &'static str = "shapeWidth";
    /// Shape parameter.
    pub const SHAPE_HEIGHT_KEY: &'static str = "shapeHeight";
    /// Shape parameter.
    pub const SHAPE_CORNER_RADIUS_KEY: &'static str = "shapeCornerRadius";
    /// Shape parameter.
    pub const SHAPE_FILL_KEY: &'static str = "shapeFill";
    /// Shape parameter.
    pub const SHAPE_FILL_COLOR_KEY: &'static str = "shapeFillColor";
    /// Shape parameter.
    pub const SHAPE_STROKE_KEY: &'static str = "shapeStroke";
    /// Shape parameter.
    pub const SHAPE_STROKE_COLOR_KEY: &'static str = "shapeStrokeColor";
    /// Shape parameter.
    pub const SHAPE_STROKE_WIDTH_KEY: &'static str = "shapeStrokeWidth";
    /// Gradient fill: the fill color is the start, `SHAPE_GRADIENT_COLOR_KEY` the end, `SHAPE_GRADIENT_ANGLE_KEY` the
    /// direction in degrees (0 = left to right, 90 = top to bottom). Optional keys: files without them draw the solid
    /// fill.
    pub const SHAPE_GRADIENT_KEY: &'static str = "shapeGradient";
    /// See `SHAPE_GRADIENT_KEY`.
    pub const SHAPE_GRADIENT_COLOR_KEY: &'static str = "shapeGradientColor";
    /// See `SHAPE_GRADIENT_KEY`.
    pub const SHAPE_GRADIENT_ANGLE_KEY: &'static str = "shapeGradientAngle";
}

impl GeneratorRef {
    /// GFX graphics clip: the layers live in `Clip::graphics`; the payload is empty.
    pub const GRAPHICS: &'static str = "graphics";

    /// The generator of an empty graphics clip.
    pub fn graphics_clip() -> GeneratorRef {
        GeneratorRef { kind: Self::GRAPHICS.to_string(), payload: Vec::new(), payload_version: 1 }
    }
}

impl Clip {
    /// The layers of a graphics clip (`None` for any other clip). Setting it on a non-graphics clip stores it but draws
    /// nothing.
    pub fn graphics(&self) -> Option<&GraphicsDocument> {
        self.graphics_store.as_ref()
    }

    /// Stores the layers of a graphics clip.
    pub fn set_graphics(&mut self, doc: Option<GraphicsDocument>) {
        self.graphics_store = doc;
    }

    /// The clip is a graphics clip.
    pub fn is_graphics(&self) -> bool {
        self.generator.as_ref().is_some_and(|g| g.kind == GeneratorRef::GRAPHICS)
    }
}

impl Project {
    /// The graphics clip `id`, `None` when unknown or not a graphics clip.
    pub fn graphics_clip(&self, id: Id) -> Option<&Clip> {
        self.timelines
            .iter()
            .flat_map(|t| t.tracks.iter())
            .flat_map(|tr| tr.clips().iter())
            .find(|c| c.id == id && c.is_graphics())
    }

    /// Any graphics clip in any sequence (gates ProjectFile v42).
    pub fn contains_graphics_clips(&self) -> bool {
        self.timelines.iter().any(|t| t.tracks.iter().any(|tr| tr.clips().iter().any(Clip::is_graphics)))
    }
}

/// Keyframing helpers (Graphics panel).
impl<V: KeyframeValue> AnimatedProperty<V> {
    /// The property shows `v` at clip-local `t`: a key at `t` (added, or the one there replaced keeping its id and
    /// easing) when the property is keyed, else the static value.
    pub fn set_at_local(&mut self, v: V, t: Time, ids: &mut dyn IdSource) {
        if !self.is_animated() {
            self.value = v;
            return;
        }
        match self.track.keys.iter().find(|k| k.time == t).map(|k| k.id) {
            Some(id) => self.track.set(id, v),
            None => self.track.insert(Keyframe::new(ids.next_id(), t, v)),
        }
    }

    /// Stopwatch: off -> one key at `t` with the current value; on -> every key removed, the value at `t` stays static.
    pub fn toggle_keyframing_at_local(&mut self, t: Time, ids: &mut dyn IdSource) {
        let v = self.value_at_local(t);
        if self.is_animated() {
            self.track = sq_core_time::KeyframeTrack::default();
            self.value = v;
        } else {
            self.track.insert(Keyframe::new(ids.next_id(), t, v));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    const ID: &str = "00000000-0000-0000-0000-000000000001";

    #[test]
    fn content_uses_swifts_labeled_payload_shape() {
        assert_round_trip::<GraphicsContent>(json!({"shape": {"kind": "arrow"}}));
        assert_round_trip::<GraphicsContent>(json!({"path": {"points": [{"x": 0.0, "y": 1.0}], "closed": true}}));
        assert_round_trip::<GraphicsContent>(json!({"text": {"ref": {"kind": "text", "payload": "e30=",
                                                                      "payloadVersion": 1}}}));
    }

    #[test]
    fn layer_defaults_for_missing_keys() {
        let l: GraphicsLayer =
            serde_json::from_value(json!({"id": ID, "content": {"shape": {"kind": "ellipse"}}})).unwrap();
        assert_eq!(l.name, "Layer");
        assert!(l.is_visible && !l.is_locked && l.effects.is_empty() && l.blend_mode == BlendMode::Normal);
        assert_eq!(serde_json::to_value(&l).unwrap()["blendMode"], json!("normal"));
    }

    #[test]
    fn document_defaults_to_empty_lists() {
        let d: GraphicsDocument = serde_json::from_value(json!({})).unwrap();
        assert_eq!(d, GraphicsDocument::default());
        assert_round_trip::<GraphicsGroup>(json!({"id": ID, "name": "G"}));
    }

    #[test]
    fn follow_round_trips_and_reports_edge_padding() {
        let plain = json!({"target": {"frame": {}}, "edges": 15, "padding": 4.0});
        let scope = EncodeContext::project_file();
        assert_round_trip::<GraphicsFollow>(plain);
        assert!(!scope.seen().follow_edge_padding);
        assert_round_trip::<GraphicsFollow>(json!({"target": {"layer": {"id": ID}}, "edges": 5, "padding": 0.0,
            "edgePadding": {"left": 1.0, "top": 2.0, "right": 3.0, "bottom": 4.0}}));
        assert!(scope.seen().follow_edge_padding);
    }

    fn layer(n: u128) -> GraphicsLayer {
        GraphicsLayer::new(Id::from_u128(n), "L", GraphicsContent::Shape { kind: ShapeKind::Rectangle })
    }

    #[test]
    fn document_lookups_and_shape_size() {
        let mut shape = layer(1);
        shape.effects.push(ClipEffect::new(Id::from_u128(9), ClipEffect::SHAPE_EFFECT_KIND));
        let doc =
            GraphicsDocument { layers: vec![layer(2), shape], groups: vec![GraphicsGroup::new(Id::from_u128(7), "G")] };
        assert_eq!(doc.index_of(Id::from_u128(1)), Some(1));
        assert!(doc.layer(Id::from_u128(3)).is_none() && doc.group(Id::from_u128(7)).is_some());
        let mut l = doc.layers[1].clone();
        l.set_shape_size(640.0, 360.0);
        assert_eq!(l.shape_effect().map(|e| e.parameters["shapeWidth"].value), Some(640.0));
        let mut none = layer(5);
        none.set_shape_size(1.0, 1.0);
        assert!(none.effects.is_empty() && !none.is_text());
        assert!(GraphicsLayer::text(Id::from_u128(6), GeneratorRef::graphics_clip(), "Text").is_text());
    }

    #[test]
    fn graphics_clips_are_found_by_generator_kind() {
        let mut c = crate::clip_animation::test_util::clip(crate::TrackKind::Video, 0, 2);
        assert!(!c.is_graphics() && c.graphics().is_none());
        c.generator = Some(GeneratorRef::graphics_clip());
        c.set_graphics(Some(GraphicsDocument::default()));
        assert!(c.is_graphics() && c.graphics().is_some());
        let tl = json!({"id": Id::from_u128(5), "name": "t", "format": {"width": 1920, "height": 1080,
            "frameDuration": {"value": 1, "timescale": 30}, "audioSampleRate": 48000},
            "tracks": [{"id": Id::from_u128(6), "kind": "video", "clips": [serde_json::to_value(&c).unwrap_or_default()]}]});
        let p: Project =
            serde_json::from_value(json!({"id": Id::from_u128(8), "name": "p", "media": [], "timelines": [tl]}))
                .unwrap_or_else(|e| panic!("project: {e}"));
        assert!(p.contains_graphics_clips());
        assert!(p.graphics_clip(c.id).is_some() && p.graphics_clip(Id::from_u128(99)).is_none());
    }

    #[test]
    fn keyframing_helpers_set_and_toggle() {
        let mut ids = sq_core_time::SequentialIds::default();
        let mut p = AnimatedProperty::new(1.0);
        p.set_at_local(2.0, Time::new(1, 1), &mut ids);
        assert!(!p.is_animated() && p.value == 2.0);
        p.toggle_keyframing_at_local(Time::new(1, 1), &mut ids);
        assert_eq!(p.track.keys.len(), 1);
        let first = p.track.keys[0].id;
        p.set_at_local(5.0, Time::new(1, 1), &mut ids); // replaces the value, keeps the id
        assert_eq!((p.track.keys[0].id, p.track.keys[0].value), (first, 5.0));
        p.set_at_local(7.0, Time::new(2, 1), &mut ids);
        assert_eq!(p.track.keys.len(), 2);
        p.toggle_keyframing_at_local(Time::new(2, 1), &mut ids);
        assert!(!p.is_animated() && p.value == 7.0);
    }
}
