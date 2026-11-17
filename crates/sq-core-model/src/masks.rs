// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Masks.swift (saved types, moved down; mask logic lives in sq-core-masks)
// The mask source types of SubjectMask.swift, MagicMask.swift, Anonymize.swift and ColorRangeKey.swift are here too:
// `ClipMask` stores them, so they sit below the masks crate (plan: "masks <-> color move down into model").

mod construct;

use crate::AnimatedProperty;
use serde::{Deserialize, Deserializer, Serialize};
use sq_core_time::{Id, KeyframeValue, Time, Vec2};

/// One point of a mask path: position and bezier tangents (offsets from the point), all in fractions of the clip's
/// own frame (0...1, origin top left, y down).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MaskVertex {
    /// Position.
    pub point: Vec2,
    /// Incoming tangent offset.
    pub in_tangent: Vec2,
    /// Outgoing tangent offset.
    pub out_tangent: Vec2,
}

impl MaskVertex {
    /// A corner vertex (no tangents).
    pub fn corner(point: Vec2) -> MaskVertex {
        MaskVertex { point, in_tangent: Vec2::ZERO, out_tangent: Vec2::ZERO }
    }
}

/// A closed bezier path. Rectangle and ellipse are just paths with four vertices.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MaskPath {
    /// The vertices in order.
    pub vertices: Vec<MaskVertex>,
}

/// Path keys interpolate vertex by vertex. Two paths with different vertex counts cannot be blended: the earlier one
/// holds until the next key.
impl KeyframeValue for MaskPath {
    fn lerp(a: &MaskPath, b: &MaskPath, t: f64) -> MaskPath {
        if a.vertices.len() != b.vertices.len() {
            return if t < 1.0 { a.clone() } else { b.clone() };
        }
        let mut out = a.clone();
        for (v, (x, y)) in out.vertices.iter_mut().zip(a.vertices.iter().zip(&b.vertices)) {
            *v = MaskVertex {
                point: Vec2::lerp(&x.point, &y.point, t),
                in_tangent: Vec2::lerp(&x.in_tangent, &y.in_tangent, t),
                out_tangent: Vec2::lerp(&x.out_tangent, &y.out_tangent, t),
            };
        }
        out
    }

    fn plus(a: &MaskPath, b: &MaskPath) -> MaskPath {
        if a.vertices.len() != b.vertices.len() {
            return a.clone();
        }
        let mut out = a.clone();
        for (v, (x, y)) in out.vertices.iter_mut().zip(a.vertices.iter().zip(&b.vertices)) {
            *v = MaskVertex {
                point: x.point + y.point,
                in_tangent: x.in_tangent + y.in_tangent,
                out_tangent: x.out_tangent + y.out_tangent,
            };
        }
        out
    }

    fn minus(a: &MaskPath, b: &MaskPath) -> MaskPath {
        let mut out = a.clone();
        if a.vertices.len() != b.vertices.len() {
            out.vertices.iter_mut().for_each(|v| *v = MaskVertex::corner(Vec2::ZERO));
            return out;
        }
        for (v, (x, y)) in out.vertices.iter_mut().zip(a.vertices.iter().zip(&b.vertices)) {
            *v = MaskVertex {
                point: x.point - y.point,
                in_tangent: x.in_tangent - y.in_tangent,
                out_tangent: x.out_tangent - y.out_tangent,
            };
        }
        out
    }

    /// Largest vertex move.
    fn speed_magnitude(&self) -> f64 {
        self.vertices.iter().map(|v| v.point.length()).fold(0.0, f64::max)
    }
}

/// How a mask combines with the masks above it in the list.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MaskMode {
    /// Union.
    Add,
    /// Cut out.
    Subtract,
    /// Keep the overlap.
    Intersect,
    /// Keep what does not overlap.
    Difference,
}

/// Which tool drew the mask (UI only; the path is the truth).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MaskShapeKind {
    /// Rectangle tool.
    Rectangle,
    /// Ellipse tool.
    Ellipse,
    /// Pen tool.
    Bezier,
}

/// Where a clip mask's shape comes from.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MaskSource {
    /// The keyframed bezier/rectangle/ellipse path.
    #[default]
    Path,
    /// The person matte of the clip's frame.
    Subject,
    /// Magic: the picked objects, followed frame by frame by Track.
    Magic,
    /// Another video track's picture at the same sequence time (v65).
    Picture,
    /// The clip's own picture keyed by distance to a picked color (v87).
    ColorRange,
}

impl<'de> Deserialize<'de> for MaskSource {
    /// Unknown values (a newer build's source) read as `Path`, so the mask keeps its stored path.
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<MaskSource, D::Error> {
        Ok(match String::deserialize(d)?.as_str() {
            "subject" => MaskSource::Subject,
            "magic" => MaskSource::Magic,
            "picture" => MaskSource::Picture,
            "colorRange" => MaskSource::ColorRange,
            _ => MaskSource::Path,
        })
    }
}

/// Which part of the matte track's picture a Picture mask reads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MatteChannel {
    /// The picture's alpha.
    #[default]
    Shape,
    /// Rec.709 luma times alpha.
    Brightness,
}

/// What an Anonymize run covers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AnonymizeTarget {
    /// Face.
    Face,
    /// Whole person.
    Person,
    /// Skin.
    Skin,
}

/// One click of the Magic mode: a frame-fraction position on the source frame at `source_time`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MagicPoint {
    /// Frame fraction (0...1, origin top left).
    pub position: Vec2,
    /// Option-click: removes the object under it.
    pub subtract: bool,
    /// Source media time of the frame the click was made on.
    pub source_time: Time,
}

/// What a Magic mask picked. The per-frame mattes live outside the project (the matte cache).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct MagicSelection {
    /// The clicks.
    pub points: Vec<MagicPoint>,
    /// Anonymize: narrows the followed person's matte per frame; `None` = an ordinary pick.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub part: Option<AnonymizeTarget>,
}

/// v87 Color range mask: the pixels near a picked color (display-encoded Rec.709, 0...1). Values are clamped into
/// 0...1 (non-finite become 0) on construction and on decode.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "RawColorRangeKey")]
pub struct ColorRangeKey {
    /// Red.
    pub red: f64,
    /// Green.
    pub green: f64,
    /// Blue.
    pub blue: f64,
    /// 0...1: the distance that is still fully covered.
    pub tolerance: f64,
    /// 0...1: width of the soft edge outside the tolerance.
    pub softness: f64,
}

impl ColorRangeKey {
    /// A mid green, the usual screen color; tolerance 25 %, softness 15 %.
    pub const DEFAULT: ColorRangeKey =
        ColorRangeKey { red: 0.1, green: 0.75, blue: 0.2, tolerance: 0.25, softness: 0.15 };

    /// A key with every value clamped into 0...1.
    pub fn new(red: f64, green: f64, blue: f64, tolerance: f64, softness: f64) -> ColorRangeKey {
        let c = |v: f64| if v.is_finite() { v.clamp(0.0, 1.0) } else { 0.0 };
        ColorRangeKey { red: c(red), green: c(green), blue: c(blue), tolerance: c(tolerance), softness: c(softness) }
    }
}

#[derive(Deserialize)]
struct RawColorRangeKey {
    red: f64,
    green: f64,
    blue: f64,
    tolerance: Option<f64>,
    softness: Option<f64>,
}

impl From<RawColorRangeKey> for ColorRangeKey {
    fn from(r: RawColorRangeKey) -> ColorRangeKey {
        let d = ColorRangeKey::DEFAULT;
        ColorRangeKey::new(r.red, r.green, r.blue, r.tolerance.unwrap_or(d.tolerance), r.softness.unwrap_or(d.softness))
    }
}

/// A mask on a clip. Values are keyframable, keys are clip-local (like `ClipAnimation`).
///
/// The optional keys (`source`, `opacityOff`, `pictureChannel`, `colorRange`) are stored only when they differ from
/// the plain path mask; decoding normalizes them so a mask equals the plain one it behaves like. Read and write them
/// through the accessors.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipMask {
    /// Identity.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Which tool drew the mask.
    pub kind: MaskShapeKind,
    /// Switch.
    pub enabled: bool,
    /// How it combines with the masks above it.
    pub mode: MaskMode,
    /// Cuts everything outside the shape.
    pub inverted: bool,
    /// The shape.
    pub path: AnimatedProperty<MaskPath>,
    /// Soft edge width in px of the clip's own frame (>= 0).
    pub feather: AnimatedProperty<f64>,
    /// 0...100 %.
    pub opacity: AnimatedProperty<f64>,
    /// Grows (positive) or shrinks the shape, px of the clip's own frame.
    pub expansion: AnimatedProperty<f64>,
    /// Where the shape comes from; stored only when not `Path` (v37). Use `source()`.
    #[doc(hidden)]
    #[serde(rename = "source", skip_serializing_if = "Option::is_none")]
    pub source_store: Option<MaskSource>,
    /// Magic masks: the picked points (v54).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub magic: Option<MagicSelection>,
    /// v54: `Some(true)` = the mask only feeds the effects that take it as input. Use `used_by_opacity()`.
    #[doc(hidden)]
    #[serde(rename = "opacityOff", skip_serializing_if = "Option::is_none")]
    pub opacity_off_store: Option<bool>,
    /// Picture masks (v65): the video track whose picture is the matte.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub picture_track: Option<Id>,
    /// Which channel of that picture is read; stored only on a Picture mask when not `Shape`. Use `picture_channel()`.
    #[doc(hidden)]
    #[serde(rename = "pictureChannel", skip_serializing_if = "Option::is_none")]
    pub picture_channel_store: Option<MatteChannel>,
    /// v87 Color range masks: stored only on a `ColorRange` mask. Use `color_range()`.
    #[doc(hidden)]
    #[serde(rename = "colorRange", skip_serializing_if = "Option::is_none")]
    pub color_range_store: Option<ColorRangeKey>,
}

impl ClipMask {
    /// `ClipMask.defaultFeather`.
    pub const DEFAULT_FEATHER: f64 = 10.0;

    /// A path mask with Swift's defaults: enabled, Add, not inverted, feather 0, opacity 100, expansion 0.
    pub fn new(id: Id, name: &str, kind: MaskShapeKind, path: MaskPath) -> ClipMask {
        ClipMask {
            id,
            name: name.to_string(),
            kind,
            enabled: true,
            mode: MaskMode::Add,
            inverted: false,
            path: AnimatedProperty::new(path),
            feather: AnimatedProperty::new(0.0),
            opacity: AnimatedProperty::new(100.0),
            expansion: AnimatedProperty::new(0.0),
            source_store: None,
            magic: None,
            opacity_off_store: None,
            picture_track: None,
            picture_channel_store: None,
            color_range_store: None,
        }
    }

    /// Where the shape comes from.
    pub fn source(&self) -> MaskSource {
        self.source_store.unwrap_or_default()
    }

    /// Sets the source; `Path` is stored as absent.
    pub fn set_source(&mut self, source: MaskSource) {
        self.source_store = (source != MaskSource::Path).then_some(source);
    }

    /// False = the mask only feeds the effects that take it as input and no longer cuts the clip's picture.
    pub fn used_by_opacity(&self) -> bool {
        self.opacity_off_store != Some(true)
    }

    /// Sets `used_by_opacity`; stored only when false.
    pub fn set_used_by_opacity(&mut self, on: bool) {
        self.opacity_off_store = (!on).then_some(true);
    }

    /// Which channel of the matte picture is read (`Shape` unless a Picture mask says otherwise).
    pub fn picture_channel(&self) -> MatteChannel {
        if self.source() == MaskSource::Picture {
            self.picture_channel_store.unwrap_or_default()
        } else {
            MatteChannel::Shape
        }
    }

    /// Sets the channel; stored only on a Picture mask when not `Shape`.
    pub fn set_picture_channel(&mut self, channel: MatteChannel) {
        self.picture_channel_store =
            (channel != MatteChannel::Shape && self.source() == MaskSource::Picture).then_some(channel);
    }

    /// The picked color of a Color range mask (the default key for other sources).
    pub fn color_range(&self) -> ColorRangeKey {
        if self.source() == MaskSource::ColorRange {
            self.color_range_store.unwrap_or(ColorRangeKey::DEFAULT)
        } else {
            ColorRangeKey::DEFAULT
        }
    }

    /// Sets the key; stored only on a Color range mask.
    pub fn set_color_range(&mut self, key: ColorRangeKey) {
        self.color_range_store = (self.source() == MaskSource::ColorRange).then_some(key);
    }
}

/// The stored keys of a `ClipMask` as they are read, before the normalization of `From`.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawClipMask {
    id: Id,
    name: String,
    kind: MaskShapeKind,
    enabled: bool,
    mode: MaskMode,
    inverted: bool,
    path: AnimatedProperty<MaskPath>,
    feather: AnimatedProperty<f64>,
    opacity: AnimatedProperty<f64>,
    expansion: AnimatedProperty<f64>,
    source: Option<MaskSource>,
    magic: Option<MagicSelection>,
    opacity_off: Option<bool>,
    picture_track: Option<Id>,
    picture_channel: Option<MatteChannel>,
    color_range: Option<ColorRangeKey>,
}

impl<'de> Deserialize<'de> for ClipMask {
    /// Decodes like the synthesized form, but an unknown or explicit `Path` source is stored as `None`, a `false`
    /// `opacityOff` and a `Shape` channel are dropped, and channel and color range are kept only on their source.
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<ClipMask, D::Error> {
        let r = RawClipMask::deserialize(d)?;
        let source_store = r.source.filter(|s| *s != MaskSource::Path);
        Ok(ClipMask {
            id: r.id,
            name: r.name,
            kind: r.kind,
            enabled: r.enabled,
            mode: r.mode,
            inverted: r.inverted,
            path: r.path,
            feather: r.feather,
            opacity: r.opacity,
            expansion: r.expansion,
            source_store,
            magic: r.magic,
            opacity_off_store: (r.opacity_off == Some(true)).then_some(true),
            picture_track: r.picture_track,
            picture_channel_store: r
                .picture_channel
                .filter(|c| *c != MatteChannel::Shape && source_store == Some(MaskSource::Picture)),
            color_range_store: r.color_range.filter(|_| source_store == Some(MaskSource::ColorRange)),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clip_color::test_util::{decode, encode, parse, round_trip};
    use crate::{BakedEffect, ColorGradeData, ColorGraph};

    const ID: &str = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
    const TRACK: &str = "00000000-0000-0000-0000-0000000000AA";
    const SQUARE: &str = r#"{"vertices":[
        {"point":{"x":0.25,"y":0.25},"inTangent":{"x":0,"y":0},"outTangent":{"x":0,"y":0}},
        {"point":{"x":0.75,"y":0.25},"inTangent":{"x":0,"y":0},"outTangent":{"x":0,"y":0}},
        {"point":{"x":0.75,"y":0.75},"inTangent":{"x":0,"y":0},"outTangent":{"x":0,"y":0}},
        {"point":{"x":0.25,"y":0.75},"inTangent":{"x":0,"y":0},"outTangent":{"x":0,"y":0}}]}"#;

    fn prop(value: &str) -> String {
        format!(r#"{{"value":{value},"track":{{"keys":[]}}}}"#)
    }

    /// A mask as Swift writes it, with extra keys spliced in before the closing brace.
    fn mask_json(extra: &str) -> String {
        format!(
            r#"{{"id":"{ID}","name":"Mask","kind":"rectangle","enabled":true,"mode":"add","inverted":false,"path":{},
            "feather":{},"opacity":{},"expansion":{}{extra}}}"#,
            prop(SQUARE),
            prop("10"),
            prop("100"),
            prop("0")
        )
    }

    fn path(points: &[(f64, f64)]) -> MaskPath {
        MaskPath { vertices: points.iter().map(|&(x, y)| MaskVertex::corner(Vec2 { x, y })).collect() }
    }

    #[test]
    fn path_mask_round_trips_without_optional_keys() {
        let m = round_trip::<ClipMask>(&mask_json(""));
        assert_eq!(
            (m.source(), m.used_by_opacity(), m.picture_channel()),
            (MaskSource::Path, true, MatteChannel::Shape)
        );
        assert_eq!(m.path.value.vertices.len(), 4);
    }

    #[test]
    fn explicit_path_source_and_false_opacity_off_are_dropped() {
        let m = decode::<ClipMask>(&mask_json(r#","source":"path","opacityOff":false"#));
        assert_eq!(m, decode::<ClipMask>(&mask_json("")));
        assert_eq!(encode(&m), parse(&mask_json("")));
    }

    #[test]
    fn unknown_source_reads_as_path() {
        let m = decode::<ClipMask>(&mask_json(r#","source":"hologram""#));
        assert_eq!(m.source_store, None);
    }

    #[test]
    fn subject_and_opacity_off_round_trip() {
        let m = round_trip::<ClipMask>(&mask_json(r#","source":"subject","opacityOff":true"#));
        assert_eq!((m.source(), m.used_by_opacity()), (MaskSource::Subject, false));
    }

    #[test]
    fn magic_mask_round_trips_its_points() {
        let extra = r#","source":"magic","magic":{"points":[{"position":{"x":0.5,"y":0.4},"subtract":false,
            "sourceTime":{"value":7,"timescale":30}}],"part":"face"}"#;
        let m = round_trip::<ClipMask>(&mask_json(extra));
        assert_eq!(m.magic.as_ref().map(|s| (s.points.len(), s.part)), Some((1, Some(AnonymizeTarget::Face))));
    }

    #[test]
    fn picture_mask_keeps_track_and_brightness_channel() {
        let extra = format!(r#","source":"picture","pictureTrack":"{TRACK}","pictureChannel":"brightness""#);
        let m = round_trip::<ClipMask>(&mask_json(&extra));
        assert_eq!(m.picture_channel(), MatteChannel::Brightness);
        assert_eq!(m.picture_track, Id::parse(TRACK));
    }

    #[test]
    fn picture_channel_is_dropped_for_shape_and_for_other_sources() {
        let shape = decode::<ClipMask>(&mask_json(r#","source":"picture","pictureChannel":"shape""#));
        assert_eq!(shape.picture_channel_store, None);
        let other = decode::<ClipMask>(&mask_json(r#","source":"subject","pictureChannel":"brightness""#));
        assert_eq!((other.picture_channel_store, other.picture_channel()), (None, MatteChannel::Shape));
    }

    #[test]
    fn color_range_is_kept_only_on_a_color_range_mask() {
        let key = r#""colorRange":{"red":0.2,"green":0.8,"blue":0.1,"tolerance":0.3,"softness":0.1}"#;
        let m = round_trip::<ClipMask>(&mask_json(&format!(r#","source":"colorRange",{key}"#)));
        assert_eq!(m.color_range(), ColorRangeKey::new(0.2, 0.8, 0.1, 0.3, 0.1));
        let stray = decode::<ClipMask>(&mask_json(&format!(",{key}")));
        assert_eq!((stray.color_range_store, stray.color_range()), (None, ColorRangeKey::DEFAULT));
    }

    #[test]
    fn color_range_key_clamps_and_defaults_missing_tolerance_and_softness() {
        let k = decode::<ColorRangeKey>(r#"{"red":2,"green":-1,"blue":0.5}"#);
        assert_eq!(k, ColorRangeKey::new(1.0, 0.0, 0.5, 0.25, 0.15));
    }

    #[test]
    fn setters_store_only_what_differs_from_the_plain_mask() {
        let mut m = ClipMask::new(Id::from_u128(1), "M", MaskShapeKind::Bezier, path(&[(0.0, 0.0)]));
        m.set_source(MaskSource::Picture);
        m.set_picture_channel(MatteChannel::Brightness);
        m.set_used_by_opacity(false);
        assert_eq!(
            (m.source_store, m.picture_channel_store, m.opacity_off_store),
            (Some(MaskSource::Picture), Some(MatteChannel::Brightness), Some(true))
        );
        m.set_source(MaskSource::Path);
        m.set_picture_channel(MatteChannel::Brightness);
        m.set_used_by_opacity(true);
        assert_eq!((m.source_store, m.picture_channel_store, m.opacity_off_store), (None, None, None));
        m.set_color_range(ColorRangeKey::DEFAULT);
        assert_eq!(m.color_range_store, None);
    }

    #[test]
    fn mask_path_keys_blend_vertex_by_vertex() {
        let a = path(&[(0.0, 0.0), (1.0, 0.0)]);
        let b = path(&[(1.0, 1.0), (1.0, 1.0)]);
        assert_eq!(MaskPath::lerp(&a, &b, 0.5), path(&[(0.5, 0.5), (1.0, 0.5)]));
        assert_eq!(MaskPath::plus(&a, &b), path(&[(1.0, 1.0), (2.0, 1.0)]));
        assert_eq!(MaskPath::minus(&b, &a), path(&[(1.0, 1.0), (0.0, 1.0)]));
    }

    #[test]
    fn mask_paths_with_different_vertex_counts_hold_the_earlier_one() {
        let a = path(&[(0.0, 0.0)]);
        let b = path(&[(1.0, 1.0), (1.0, 1.0)]);
        assert_eq!(MaskPath::lerp(&a, &b, 0.99), a);
        assert_eq!(MaskPath::lerp(&a, &b, 1.0), b);
        assert_eq!(MaskPath::plus(&a, &b), a);
        assert_eq!(MaskPath::minus(&a, &b), path(&[(0.0, 0.0)]));
        assert_eq!(MaskPath::speed_magnitude(&path(&[(3.0, 4.0), (0.0, 1.0)])), 5.0);
    }

    #[test]
    fn baked_effect_round_trips() {
        let motion = encode(&crate::ClipAnimation::default());
        let j = serde_json::json!({
            "id": ID, "recipeID": "fadeIn", "index": 2, "motion": motion,
            "effect": {"id": TRACK, "kind": "gaussianBlur", "enabled": true,
                       "parameters": {"blur": {"value": 12, "track": {"keys": []}}}},
        })
        .to_string();
        let b = round_trip::<BakedEffect>(&j);
        assert_eq!((b.recipe_id.as_str(), b.index), ("fadeIn", 2));
    }

    #[test]
    fn walks_the_v71_fixture_for_the_color_and_mask_keys() {
        let text = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../Packages/SQCore/Tests/Fixtures/project-v71.json"
        ))
        .expect("fixture is in the repository");
        fn walk(v: &serde_json::Value) {
            match v {
                serde_json::Value::Object(o) => {
                    for (k, child) in o {
                        let text = child.to_string();
                        match k.as_str() {
                            "masks" => drop(round_trip::<Vec<ClipMask>>(&text)),
                            "bakedEffects" => drop(round_trip::<Vec<BakedEffect>>(&text)),
                            "grade" => drop(round_trip::<ColorGradeData>(&text)),
                            "colorGraph" => drop(round_trip::<ColorGraph>(&text)),
                            _ => walk(child),
                        }
                    }
                }
                serde_json::Value::Array(a) => a.iter().for_each(walk),
                _ => {}
            }
        }
        // shortcut: v71 holds none of these types today, so this only guards a future richer fixture.
        walk(&serde_json::from_str(&text).expect("fixture is JSON"));
    }
}
