// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorGraph.swift (types, moved down; graph logic lives in sq-core-color)

use crate::clip_color::{hundred, is_default};
use crate::{HueCurves, LUTRef, RGBCurves};
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sq_core_time::Id;

/// `skip_serializing_if` for the percent values Swift writes only when not 100.
fn is_hundred(v: &f32) -> bool {
    *v == 100.0
}

/// `"Step"`, the label of a Step stored without one.
fn step_label() -> String {
    "Step".to_string()
}

/// Three channel values (red, green, blue). Stored as `[r, g, b]`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "[f32; 3]", into = "[f32; 3]")]
pub struct ColorTriple {
    /// Red.
    pub r: f32,
    /// Green.
    pub g: f32,
    /// Blue.
    pub b: f32,
}

impl From<[f32; 3]> for ColorTriple {
    fn from([r, g, b]: [f32; 3]) -> ColorTriple {
        ColorTriple { r, g, b }
    }
}

impl From<ColorTriple> for [f32; 3] {
    fn from(c: ColorTriple) -> [f32; 3] {
        [c.r, c.g, c.b]
    }
}

impl ColorTriple {
    /// The same value on all three channels.
    pub const fn all(v: f32) -> ColorTriple {
        ColorTriple { r: v, g: v, b: v }
    }
}

/// Lift / Gamma / Gain / Offset, then Contrast around Pivot and Saturation. Every key is optional on decode.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct StepPrimaries {
    /// -1...1.
    pub lift: ColorTriple,
    /// Exponent 0.1...4 (CDL power).
    pub gamma: ColorTriple,
    /// 0...4 (CDL slope).
    pub gain: ColorTriple,
    /// -1...1.
    pub offset: ColorTriple,
    /// 0...2.
    pub contrast: f32,
    /// 0...1, display-referred.
    pub pivot: f32,
    /// 0...4.
    pub saturation: f32,
}

impl Default for StepPrimaries {
    fn default() -> Self {
        StepPrimaries {
            lift: ColorTriple::all(0.0),
            gamma: ColorTriple::all(1.0),
            gain: ColorTriple::all(1.0),
            offset: ColorTriple::all(0.0),
            contrast: 1.0,
            pivot: 0.435,
            saturation: 1.0,
        }
    }
}

impl StepPrimaries {
    /// Nothing moved.
    pub fn is_neutral(&self) -> bool {
        *self == StepPrimaries::default()
    }
}

/// Picks the pixels a Step changes by hue, saturation and luma. Every key is optional on decode.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ColorQualifier {
    /// 0..<360.
    pub hue_center: f32,
    /// 0...360.
    pub hue_width: f32,
    /// 0...100.
    pub sat_min: f32,
    /// 0...100.
    pub sat_max: f32,
    /// 0...100.
    pub lum_min: f32,
    /// 0...100.
    pub lum_max: f32,
    /// 0...100.
    pub softness: f32,
    /// Select everything outside the range.
    pub invert: bool,
}

impl Default for ColorQualifier {
    fn default() -> Self {
        ColorQualifier {
            hue_center: 25.0,
            hue_width: 50.0,
            sat_min: 10.0,
            sat_max: 100.0,
            lum_min: 0.0,
            lum_max: 100.0,
            softness: 20.0,
            invert: false,
        }
    }
}

/// Shape of a Step window.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StepWindowShape {
    /// Ellipse.
    #[default]
    Ellipse,
    /// Rectangle.
    Rectangle,
    /// One side of a line through the center.
    Linear,
}

/// A shape that limits a Step to part of the frame (frame units 0...1, y down). Every key is optional on decode.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct StepWindow {
    /// Shape.
    pub shape: StepWindowShape,
    /// Center x.
    pub center_x: f32,
    /// Center y.
    pub center_y: f32,
    /// Fraction of the frame width.
    pub width: f32,
    /// Fraction of the frame height.
    pub height: f32,
    /// Degrees, clockwise.
    pub rotation: f32,
    /// Soft edge as a fraction of the shape's size.
    pub softness: f32,
    /// Select everything outside.
    pub invert: bool,
}

impl Default for StepWindow {
    fn default() -> Self {
        StepWindow {
            shape: StepWindowShape::Ellipse,
            center_x: 0.5,
            center_y: 0.5,
            width: 0.5,
            height: 0.5,
            rotation: 0.0,
            softness: 0.2,
            invert: false,
        }
    }
}

/// A point on the Steps canvas (canvas units).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct StepPosition {
    /// Horizontal.
    pub x: f64,
    /// Vertical.
    pub y: f64,
}

/// How a Step joins the Steps before it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StepKind {
    /// Starts a new column.
    #[default]
    Serial,
    /// Works on the same input as its column's Serial Step; results are averaged.
    Parallel,
    /// Goes over the averaged result, limited by its key.
    Layer,
}

/// How the key wires that arrive at one mixer box combine into one matte (v80).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KeyMixMode {
    /// Sum.
    Add,
    /// Product (default).
    #[default]
    Multiply,
    /// Difference.
    Subtract,
    /// Maximum.
    Max,
}

/// How a Layer Step's result composites over what is below it (v80).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LayerMixMode {
    /// Replaces.
    #[default]
    Normal,
    /// Add.
    Add,
    /// Subtract.
    Subtract,
    /// Multiply.
    Multiply,
    /// Screen.
    Screen,
    /// Lighten.
    Lighten,
    /// Darken.
    Darken,
}

/// One Step of the Pro grade: primaries, curves, a LUT, limited by an optional qualifier and window. Only `id` is
/// required on decode; the other keys are written only when they differ from their default.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColorStep {
    /// Identity.
    pub id: Id,
    /// Shown name.
    #[serde(default = "step_label")]
    pub label: String,
    /// Switch.
    #[serde(default = "crate::serde_defaults::yes", skip_serializing_if = "crate::clip_color::is_true")]
    pub enabled: bool,
    /// Lift / gamma / gain / offset.
    #[serde(default, skip_serializing_if = "StepPrimaries::is_neutral")]
    pub primaries: StepPrimaries,
    /// RGB curves.
    #[serde(default, skip_serializing_if = "RGBCurves::is_neutral")]
    pub curves: RGBCurves,
    /// Hue curves.
    #[serde(default, skip_serializing_if = "HueCurves::is_neutral")]
    pub hue_curves: HueCurves,
    /// A look LUT inside the Step; `None` = none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lut: Option<LUTRef>,
    /// 0...100.
    #[serde(default = "hundred", skip_serializing_if = "is_hundred")]
    pub lut_intensity: f32,
    /// `None` = every pixel.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub qualifier: Option<ColorQualifier>,
    /// `None` = the whole frame.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<StepWindow>,
    /// How the Step joins the Steps before it.
    #[serde(default, skip_serializing_if = "is_default")]
    pub kind: StepKind,
    /// 0...100, a blend of the output with the input.
    #[serde(default = "hundred", skip_serializing_if = "is_hundred")]
    pub mix: f32,
    /// Where the Step sits on the Steps canvas; `None` = automatic layout.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<StepPosition>,
    /// Where the mixer box behind this Step's stack sits; `None` = automatic.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mixer_position: Option<StepPosition>,
    /// v80: how a Layer Step composites over the result below it.
    #[serde(default, skip_serializing_if = "is_default")]
    pub layer_mix: LayerMixMode,
    /// v80: the Step's key output is read inverted.
    #[serde(default, skip_serializing_if = "is_default")]
    pub key_outside: bool,
    /// v80: how the key wires into the mixer box behind this Step's stack combine.
    #[serde(default, skip_serializing_if = "is_default")]
    pub key_mix: KeyMixMode,
}

impl ColorStep {
    /// A neutral serial Step.
    pub fn new(id: Id, label: &str) -> ColorStep {
        ColorStep {
            id,
            label: label.to_string(),
            enabled: true,
            primaries: StepPrimaries::default(),
            curves: RGBCurves::default(),
            hue_curves: HueCurves::default(),
            lut: None,
            lut_intensity: 100.0,
            qualifier: None,
            window: None,
            kind: StepKind::Serial,
            mix: 100.0,
            position: None,
            mixer_position: None,
            layer_mix: LayerMixMode::Normal,
            key_outside: false,
            key_mix: KeyMixMode::Multiply,
        }
    }
}

/// Where a wire starts or ends: the graph's source or sink, a Step, or the mixer box of a stack (named by the
/// stack's first Step). Stored as `"source"`, `"sink"`, `"step:<UUID>"` or `"mixer:<UUID>"`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GraphPort {
    /// The graph's input.
    Source,
    /// The graph's output.
    Sink,
    /// A Step.
    Step(Id),
    /// The mixer box of the stack headed by this Step.
    Mixer(Id),
}

impl Serialize for GraphPort {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            GraphPort::Source => s.serialize_str("source"),
            GraphPort::Sink => s.serialize_str("sink"),
            GraphPort::Step(i) => s.collect_str(&format_args!("step:{i}")),
            GraphPort::Mixer(i) => s.collect_str(&format_args!("mixer:{i}")),
        }
    }
}

impl<'de> Deserialize<'de> for GraphPort {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<GraphPort, D::Error> {
        let s = String::deserialize(d)?;
        match s.as_str() {
            "source" => return Ok(GraphPort::Source),
            "sink" => return Ok(GraphPort::Sink),
            _ => {}
        }
        let bad = || D::Error::custom(format!("bad port {s}"));
        let (kind, id) = s.split_once(':').ok_or_else(bad)?;
        let id = Id::parse(id).ok_or_else(bad)?;
        match kind {
            "step" => Ok(GraphPort::Step(id)),
            "mixer" => Ok(GraphPort::Mixer(id)),
            _ => Err(bad()),
        }
    }
}

/// A wire: the output of `from` into the input of `to` (an image wire), or the key output of a Step into the key
/// input of a Step or mixer (a key wire).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct GraphLink {
    /// Start.
    pub from: GraphPort,
    /// End.
    pub to: GraphPort,
}

/// The Pro grade: In LUT -> Steps in order -> Out LUT.
///
/// Decoding does not run `sanitizeWiring` (graph logic): the color crate's `ColorGraph` extension owns it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "RawColorGraph", rename_all = "camelCase")]
pub struct ColorGraph {
    steps: Vec<ColorStep>,
    /// The conversion, same rules as Simple's Input LUT; `None` = none.
    #[serde(rename = "inputLUT", skip_serializing_if = "Option::is_none")]
    pub input_lut: Option<LUTRef>,
    /// A last look LUT after every Step; `None` = none.
    #[serde(rename = "outputLUT", skip_serializing_if = "Option::is_none")]
    pub output_lut: Option<LUTRef>,
    /// 0...100.
    #[serde(rename = "outputLUTIntensity", skip_serializing_if = "is_hundred")]
    pub output_lut_intensity: f32,
    /// Simple | Pro: true = this graph is the clip's grade and the Color effects stay dimmed.
    #[serde(rename = "active", skip_serializing_if = "is_default")]
    pub is_active: bool,
    /// v80: custom image wiring; `None` = the wires the Step kinds say.
    #[doc(hidden)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub links: Option<Vec<GraphLink>>,
    /// v80: key wires.
    #[doc(hidden)]
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub key_links: Vec<GraphLink>,
}

impl ColorGraph {
    /// A graph over `steps` (one neutral "Step 1" when empty). Like Swift's `init`, this does not force the first
    /// Step to serial; `set_steps` does.
    pub fn new(
        steps: Vec<ColorStep>,
        input_lut: Option<LUTRef>,
        output_lut: Option<LUTRef>,
        first_id: Id,
    ) -> ColorGraph {
        ColorGraph {
            steps: if steps.is_empty() { vec![ColorStep::new(first_id, "Step 1")] } else { steps },
            input_lut,
            output_lut,
            output_lut_intensity: 100.0,
            is_active: false,
            links: None,
            key_links: Vec::new(),
        }
    }

    /// Serial order = processing order; never empty.
    pub fn steps(&self) -> &[ColorStep] {
        &self.steps
    }

    /// Replaces the Steps (Swift `didSet`: an empty list becomes one neutral Step, the first Step is serial).
    pub fn set_steps(&mut self, steps: Vec<ColorStep>, new_id: Id) {
        self.steps = steps;
        self.settle_steps(new_id);
    }

    /// Edits the Steps in place, then applies the `didSet` rules of `set_steps`.
    pub fn edit_steps(&mut self, new_id: Id, f: impl FnOnce(&mut Vec<ColorStep>)) {
        f(&mut self.steps);
        self.settle_steps(new_id);
    }

    fn settle_steps(&mut self, new_id: Id) {
        if self.steps.is_empty() {
            self.steps = vec![ColorStep::new(new_id, "Step 1")];
        } else if self.steps[0].kind != StepKind::Serial {
            self.steps[0].kind = StepKind::Serial;
        }
    }
}

/// The stored keys of a `ColorGraph`.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawColorGraph {
    #[serde(default)]
    steps: Vec<ColorStep>,
    #[serde(default, rename = "inputLUT")]
    input_lut: Option<LUTRef>,
    #[serde(default, rename = "outputLUT")]
    output_lut: Option<LUTRef>,
    #[serde(default = "hundred", rename = "outputLUTIntensity")]
    output_lut_intensity: f32,
    #[serde(default, rename = "active")]
    is_active: bool,
    #[serde(default)]
    links: Option<Vec<GraphLink>>,
    #[serde(default)]
    key_links: Vec<GraphLink>,
}

impl From<RawColorGraph> for ColorGraph {
    fn from(r: RawColorGraph) -> ColorGraph {
        // An empty stored list gets the one default Step; its id is the fixed first-step id (Swift draws a random one).
        let mut g = ColorGraph::new(r.steps, r.input_lut, r.output_lut, Id::NIL);
        g.output_lut_intensity = r.output_lut_intensity;
        g.is_active = r.is_active;
        g.links = r.links;
        g.key_links = r.key_links;
        g
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clip_color::test_util::{decode, encode, parse, round_trip};

    const A: &str = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
    const B: &str = "00000000-0000-0000-0000-000000000002";

    #[test]
    fn color_triple_is_a_three_element_array() {
        let t = round_trip::<ColorTriple>("[0.25,0.5,1]");
        assert_eq!(t, ColorTriple { r: 0.25, g: 0.5, b: 1.0 });
    }

    #[test]
    fn primaries_default_for_missing_keys() {
        assert_eq!(decode::<StepPrimaries>("{}"), StepPrimaries::default());
        let p = round_trip::<StepPrimaries>(
            r#"{"lift":[0.1,0,0],"gamma":[1,1,1],"gain":[1,1,1.2],"offset":[0,0,0],"contrast":1.5,"pivot":0.435,"saturation":1}"#,
        );
        assert_eq!(p.lift.r, 0.1);
    }

    #[test]
    fn qualifier_and_window_default_for_missing_keys() {
        assert_eq!(decode::<ColorQualifier>(r#"{"softness":5}"#).hue_width, 50.0);
        assert_eq!(decode::<StepWindow>("{}"), StepWindow::default());
        round_trip::<StepWindow>(
            r#"{"shape":"linear","centerX":0.4,"centerY":0.5,"width":0.5,"height":0.5,"rotation":10,"softness":0.2,"invert":true}"#,
        );
    }

    #[test]
    fn step_needs_only_an_id() {
        let s = decode::<ColorStep>(&format!(r#"{{"id":"{A}"}}"#));
        assert_eq!(s, ColorStep::new(Id::parse(A).unwrap(), "Step"));
        assert!(serde_json::from_str::<ColorStep>(r#"{"label":"x"}"#).is_err());
    }

    #[test]
    fn neutral_step_writes_only_id_and_label() {
        round_trip::<ColorStep>(&format!(r#"{{"id":"{A}","label":"Step 1"}}"#));
    }

    #[test]
    fn step_with_every_option_round_trips() {
        let j = format!(
            r#"{{"id":"{A}","label":"Warm","enabled":false,"primaries":{{"lift":[0,0,0],"gamma":[1,1,1],"gain":[1.1,1,1],
            "offset":[0,0,0],"contrast":1,"pivot":0.435,"saturation":1}},"lut":{{"kind":"file","path":"x.cube"}},
            "lutIntensity":60,"qualifier":{{"hueCenter":25,"hueWidth":50,"satMin":10,"satMax":100,"lumMin":0,"lumMax":100,
            "softness":20,"invert":false}},"window":{{"shape":"ellipse","centerX":0.5,"centerY":0.5,"width":0.5,
            "height":0.5,"rotation":0,"softness":0.2,"invert":false}},"kind":"layer","mix":50,
            "position":{{"x":10,"y":20}},"mixerPosition":{{"x":30,"y":40}},"layerMix":"screen","keyOutside":true,
            "keyMix":"max"}}"#
        );
        let s = round_trip::<ColorStep>(&j);
        assert_eq!((s.kind, s.layer_mix, s.key_mix), (StepKind::Layer, LayerMixMode::Screen, KeyMixMode::Max));
    }

    #[test]
    fn ports_use_the_prefixed_string_form() {
        assert_eq!(round_trip::<GraphPort>("\"source\""), GraphPort::Source);
        assert_eq!(round_trip::<GraphPort>("\"sink\""), GraphPort::Sink);
        assert_eq!(round_trip::<GraphPort>(&format!("\"step:{A}\"")), GraphPort::Step(Id::parse(A).unwrap()));
        assert_eq!(round_trip::<GraphPort>(&format!("\"mixer:{B}\"")), GraphPort::Mixer(Id::parse(B).unwrap()));
        for bad in ["\"nowhere\"", "\"step:nope\"", "\"wire:00000000-0000-0000-0000-000000000002\""] {
            assert!(serde_json::from_str::<GraphPort>(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn graph_round_trips_with_wiring() {
        let j = format!(
            r#"{{"steps":[{{"id":"{A}","label":"Step 1"}},{{"id":"{B}","label":"Step 2","kind":"parallel"}}],
            "inputLUT":{{"kind":"automatic"}},"outputLUT":{{"kind":"file","path":"out.cube"}},"outputLUTIntensity":80,
            "active":true,"links":[{{"from":"source","to":"step:{A}"}},{{"from":"step:{A}","to":"sink"}}],
            "keyLinks":[{{"from":"step:{B}","to":"mixer:{A}"}}]}}"#
        );
        let g = round_trip::<ColorGraph>(&j);
        assert!(g.is_active);
        assert_eq!(g.steps().len(), 2);
        assert_eq!(g.links.as_ref().map(Vec::len), Some(2));
        assert_eq!(g.key_links.len(), 1);
    }

    #[test]
    fn graph_missing_keys_default_and_empty_steps_get_one_step() {
        let g = decode::<ColorGraph>("{}");
        assert_eq!(g.steps().len(), 1);
        assert_eq!(g.steps()[0].label, "Step 1");
        assert_eq!(
            (g.input_lut.clone(), g.output_lut_intensity, g.is_active, g.links.clone()),
            (None, 100.0, false, None)
        );
        assert_eq!(encode(&g)["steps"].as_array().map(Vec::len), Some(1));
        assert!(encode(&g).get("active").is_none());
    }

    #[test]
    fn set_steps_keeps_the_first_step_serial_and_never_empty() {
        let mut g = decode::<ColorGraph>("{}");
        let mut layer = ColorStep::new(Id::from_u128(7), "L");
        layer.kind = StepKind::Layer;
        g.set_steps(vec![layer], Id::from_u128(8));
        assert_eq!(g.steps()[0].kind, StepKind::Serial);
        g.set_steps(Vec::new(), Id::from_u128(8));
        assert_eq!((g.steps().len(), g.steps()[0].id), (1, Id::from_u128(8)));
        g.edit_steps(Id::from_u128(9), |s| s.clear());
        assert_eq!(g.steps()[0].id, Id::from_u128(9));
        let _ = parse("{}");
    }
}
