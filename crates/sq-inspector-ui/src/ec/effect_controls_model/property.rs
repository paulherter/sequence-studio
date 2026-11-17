// Swift: EffectControlsModel.swift (Sections and properties)
//! `EffectProperty`, `MaskParam` and the display units of Effect Controls rows.

use std::cmp::Ordering;
use std::ops::RangeInclusive;

use sq_core_graphics::custom_animation::{AnimationParam, AnimationSide};
use sq_core_masks::perspective_tilt;
use sq_core_model::PictureAxis;
use sq_core_model::keyframes_editing::PropertyID;
use sq_core_model::{
    AnimatedProperty, ClipEffect, ClipMask, EffectCatalog, EffectParamKind, EffectParamPair, EffectParamSpec,
};
use sq_core_time::{Id, Vec2};
use sq_editor_session::EffectSection;

/// Which component of a vector row a value belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EffectComponent {
    X,
    Y,
    All,
}

/// What the stopwatch / key buttons did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StopwatchOutcome {
    Added,
    Removed,
    /// Turning the stopwatch off deletes all keys: the caller asks first, then repeats with `confirm_removal: true`.
    NeedsConfirmation,
    /// Playhead outside the clip, or no clip.
    Unavailable,
}

/// W6.7: the keyframable numbers of a path mask shown in Effect Controls.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum MaskParam {
    Feather,
    Opacity,
    Expansion,
}

impl MaskParam {
    /// The plain words of a Magic mask's edge rows (Soft edge, Opacity, Grow / shrink).
    pub fn magic_title(self) -> &'static str {
        match self {
            MaskParam::Feather => "Soft edge",
            MaskParam::Opacity => "Opacity",
            MaskParam::Expansion => "Grow / shrink",
        }
    }

    pub const ALL: [MaskParam; 3] = [MaskParam::Feather, MaskParam::Opacity, MaskParam::Expansion];

    pub fn raw_value(self) -> &'static str {
        match self {
            MaskParam::Feather => "feather",
            MaskParam::Opacity => "opacity",
            MaskParam::Expansion => "expansion",
        }
    }

    pub fn from_raw(raw: &str) -> Option<MaskParam> {
        Self::ALL.into_iter().find(|m| m.raw_value() == raw)
    }

    pub fn title(self) -> &'static str {
        match self {
            MaskParam::Feather => "Mask Feather",
            MaskParam::Opacity => "Mask Opacity",
            MaskParam::Expansion => "Mask Expansion",
        }
    }

    pub fn unit(self) -> &'static str {
        if self == MaskParam::Opacity { "%" } else { "px" }
    }

    pub fn range(self) -> RangeInclusive<f64> {
        match self {
            MaskParam::Feather => 0.0..=1000.0,
            MaskParam::Opacity => 0.0..=100.0,
            MaskParam::Expansion => -1000.0..=1000.0,
        }
    }

    pub fn default_value(self) -> f64 {
        match self {
            MaskParam::Feather => ClipMask::DEFAULT_FEATHER,
            MaskParam::Opacity => 100.0,
            MaskParam::Expansion => 0.0,
        }
    }

    pub(crate) fn value_of(self, m: &ClipMask) -> AnimatedProperty<f64> {
        match self {
            MaskParam::Feather => m.feather.clone(),
            MaskParam::Opacity => m.opacity.clone(),
            MaskParam::Expansion => m.expansion.clone(),
        }
    }

    pub(crate) fn set(self, v: AnimatedProperty<f64>, m: &mut ClipMask) {
        match self {
            MaskParam::Feather => m.feather = v,
            MaskParam::Opacity => m.opacity = v,
            MaskParam::Expansion => m.expansion = v,
        }
    }
}

pub(crate) fn side_raw(side: AnimationSide) -> &'static str {
    if side == AnimationSide::Intro { "intro" } else { "outro" }
}

pub(crate) fn anim_param_raw(p: AnimationParam) -> &'static str {
    match p {
        AnimationParam::Position => "position",
        AnimationParam::Scale => "scale",
        AnimationParam::Rotation => "rotation",
        AnimationParam::Opacity => "opacity",
    }
}

/// Value kind of a row.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EffectPropertyKind {
    Vector,
    Uniform,
    Scalar,
    Color,
}

/// An animatable row of Effect Controls.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum EffectProperty {
    Position,
    Scale,
    Rotation,
    Anchor,
    Opacity,
    Volume,
    /// FB-G: Motion's own Shutter Angle (`ClipAnimation.shutterAngle`, degrees, 0 = no motion blur).
    ShutterAngle,
    /// v92: Motion's Anti-flicker Filter (`ClipAnimation.antiFlicker`, 0...1).
    AntiFlicker,
    /// Perspective tilt of the layer (`ClipAnimation.tiltX` / `tiltY`, degrees, +-89).
    TiltX,
    TiltY,
    /// A parameter of an applied effect instance.
    Fx {
        id: Id,
        kind: String,
        key: String,
    },
    /// W6.7: a keyframable number of a path mask.
    Mask(Id, MaskParam),
    /// The Path of a path mask: keys only (drawn on the mask's controls row), no value field and no value graph.
    MaskPath(Id),
    /// One row of a Custom Intro / Outro (text clip): offset from rest in pixels, scale factor, degrees, opacity.
    Anim(AnimationSide, AnimationParam),
}

impl PartialOrd for EffectProperty {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for EffectProperty {
    fn cmp(&self, other: &Self) -> Ordering {
        self.raw_value().cmp(&other.raw_value())
    }
}

impl EffectProperty {
    pub const BUILT_INS: [EffectProperty; 10] = [
        EffectProperty::Position,
        EffectProperty::Scale,
        EffectProperty::Rotation,
        EffectProperty::Anchor,
        EffectProperty::Opacity,
        EffectProperty::Volume,
        EffectProperty::ShutterAngle,
        EffectProperty::AntiFlicker,
        EffectProperty::TiltX,
        EffectProperty::TiltY,
    ];

    /// The stable string form (Swift `rawValue`).
    pub fn raw_value(&self) -> String {
        match self {
            EffectProperty::Position => "position".to_string(),
            EffectProperty::Scale => "scale".to_string(),
            EffectProperty::Rotation => "rotation".to_string(),
            EffectProperty::Anchor => "anchor".to_string(),
            EffectProperty::Opacity => "opacity".to_string(),
            EffectProperty::Volume => "volume".to_string(),
            EffectProperty::ShutterAngle => "shutterAngle".to_string(),
            EffectProperty::AntiFlicker => "antiFlicker".to_string(),
            EffectProperty::TiltX => "tiltX".to_string(),
            EffectProperty::TiltY => "tiltY".to_string(),
            EffectProperty::Fx { id, kind, key } => format!("fx:{id}:{kind}:{key}"),
            EffectProperty::Mask(id, m) => format!("mask:{id}:{}", m.raw_value()),
            EffectProperty::MaskPath(id) => format!("maskpath:{id}"),
            EffectProperty::Anim(side, param) => format!("anim:{}:{}", side_raw(*side), anim_param_raw(*param)),
        }
    }

    // Swift: init?(rawValue:)
    pub fn from_raw_value(raw: &str) -> Option<EffectProperty> {
        if let Some(b) = Self::BUILT_INS.iter().find(|b| b.raw_value() == raw) {
            return Some(b.clone());
        }
        let parts: Vec<&str> = raw.splitn(4, ':').collect();
        if parts.len() == 2 && parts[0] == "maskpath" {
            return Id::parse(parts[1]).map(EffectProperty::MaskPath);
        }
        if parts.len() == 3 && parts[0] == "mask" {
            let id = Id::parse(parts[1])?;
            let m = MaskParam::from_raw(parts[2])?;
            return Some(EffectProperty::Mask(id, m));
        }
        if parts.len() == 3 && parts[0] == "anim" {
            let side = AnimationSide::ALL.into_iter().find(|s| side_raw(*s) == parts[1])?;
            let m = AnimationParam::ALL.into_iter().find(|p| anim_param_raw(*p) == parts[2])?;
            return Some(EffectProperty::Anim(side, m));
        }
        if parts.len() == 4 && parts[0] == "fx" {
            let id = Id::parse(parts[1])?;
            return Some(EffectProperty::Fx { id, kind: parts[2].to_string(), key: parts[3].to_string() });
        }
        None
    }

    pub fn kind(&self) -> EffectPropertyKind {
        match self {
            EffectProperty::Position | EffectProperty::Anchor => EffectPropertyKind::Vector,
            EffectProperty::Scale => EffectPropertyKind::Uniform,
            EffectProperty::Rotation
            | EffectProperty::TiltX
            | EffectProperty::TiltY
            | EffectProperty::Opacity
            | EffectProperty::Volume
            | EffectProperty::ShutterAngle
            | EffectProperty::AntiFlicker
            | EffectProperty::Mask(..)
            | EffectProperty::MaskPath(_) => EffectPropertyKind::Scalar,
            EffectProperty::Anim(_, param) => {
                if *param == AnimationParam::Position {
                    EffectPropertyKind::Vector
                } else {
                    EffectPropertyKind::Scalar
                }
            }
            EffectProperty::Fx { .. } => match self.param_kind() {
                Some(EffectParamKind::Point(_)) => EffectPropertyKind::Vector,
                Some(EffectParamKind::Color(_)) => EffectPropertyKind::Color,
                _ => EffectPropertyKind::Scalar,
            },
        }
    }

    pub fn id(&self) -> PropertyID {
        PropertyID::new(&self.raw_value())
    }

    /// A row of an Animation (In/Out) section (its keys live in the text payload, not in the clip's tracks).
    pub fn is_animation_row(&self) -> bool {
        matches!(self, EffectProperty::Anim(..))
    }

    /// What the catalog says about an effect parameter.
    pub(crate) fn fx_spec(&self) -> Option<EffectParamSpec> {
        if let EffectProperty::Fx { kind, key, .. } = self { EffectCatalog::param(kind, key) } else { None }
    }

    /// P4: the X/Y pair this property is the row of (it is the pair's X member); nil for every other property.
    pub fn pair(&self) -> Option<EffectParamPair> {
        let EffectProperty::Fx { kind, key, .. } = self else { return None };
        let spec = EffectCatalog::spec_for(kind)?;
        let pr = spec.pair_containing(key)?;
        (pr.x == *key).then(|| pr.clone())
    }

    /// Value kind of an effect parameter (slider, checkbox, choice, color, point); nil for the fixed properties.
    /// A pair row is a point (two fields, like Motion's Position) whose default is the members' defaults.
    pub fn param_kind(&self) -> Option<EffectParamKind> {
        if let (Some(pr), EffectProperty::Fx { kind, .. }) = (self.pair(), self) {
            let x = EffectCatalog::param(kind, &pr.x).map_or(0.0, |s| s.default_value);
            let y = EffectCatalog::param(kind, &pr.y).map_or(0.0, |s| s.default_value);
            return Some(EffectParamKind::Point(Vec2::new(x, y)));
        }
        self.fx_spec().map(|s| s.kind)
    }

    /// Has a value graph under its row (sliders and positions; not colors, checkboxes or choices).
    pub fn has_graph(&self) -> bool {
        if matches!(self, EffectProperty::MaskPath(_)) {
            return false; // a shape per key: no value to plot
        }
        !matches!(
            self.param_kind(),
            Some(EffectParamKind::Color(_) | EffectParamKind::Checkbox | EffectParamKind::Choice(_))
        )
    }

    pub fn title(&self) -> String {
        match self {
            EffectProperty::Position => "Position".to_string(),
            EffectProperty::Scale => "Scale".to_string(),
            EffectProperty::Rotation => "Rotation".to_string(),
            EffectProperty::Anchor => "Anchor".to_string(),
            EffectProperty::Opacity => "Opacity".to_string(),
            EffectProperty::Volume => "Volume".to_string(),
            EffectProperty::ShutterAngle => "Shutter Angle".to_string(),
            EffectProperty::AntiFlicker => "Anti-flicker Filter".to_string(),
            EffectProperty::TiltX => "Tilt X".to_string(),
            EffectProperty::TiltY => "Tilt Y".to_string(),
            EffectProperty::Fx { key, .. } => {
                self.pair().map(|p| p.title).or_else(|| self.fx_spec().map(|s| s.title)).unwrap_or_else(|| key.clone())
            }
            EffectProperty::Mask(_, m) => m.title().to_string(),
            EffectProperty::MaskPath(_) => "Mask Path".to_string(),
            EffectProperty::Anim(_, param) => param.title().to_string(),
        }
    }

    pub fn section(&self) -> EffectSection {
        match self {
            EffectProperty::Position
            | EffectProperty::Scale
            | EffectProperty::Rotation
            | EffectProperty::TiltX
            | EffectProperty::TiltY
            | EffectProperty::Anchor
            | EffectProperty::ShutterAngle
            | EffectProperty::AntiFlicker => EffectSection::Motion,
            EffectProperty::Opacity => EffectSection::Opacity,
            EffectProperty::Volume => EffectSection::Volume,
            EffectProperty::Fx { id, kind, .. } => EffectSection::Effect { id: *id, kind: kind.clone() },
            EffectProperty::Mask(id, _) | EffectProperty::MaskPath(id) => EffectSection::Mask(*id),
            EffectProperty::Anim(side, _) => EffectSection::Animation(*side),
        }
    }

    // MARK: Display units (what the ScrubField shows)

    /// Volume is stored as linear gain and shown in dB; this is the dB shown for silence.
    pub const SILENCE_DB: f64 = -60.0;

    /// Resolve / Final Cut convention (docs/research/VALUE-DISPLAY-RESOLVE-FCP.md): Position and Anchor show 0,0 at
    /// the center with Y up, Rotation is counterclockwise positive. Storage stays center-based, y down, clockwise
    /// positive; this sign is the only difference between the shown number and the stored one.
    pub fn display_sign(&self, component: EffectComponent) -> f64 {
        match self {
            EffectProperty::Position | EffectProperty::Anchor | EffectProperty::Anim(_, AnimationParam::Position) => {
                if component == EffectComponent::Y {
                    -1.0
                } else {
                    1.0
                }
            }
            EffectProperty::Rotation | EffectProperty::Anim(_, AnimationParam::Rotation) => -1.0,
            EffectProperty::Fx { kind, key, .. } => {
                let key = key.as_str();
                if key == ClipEffect::STAGE_ROTATION_KEY
                    || key == ClipEffect::STAGE_POSITION_Y_KEY
                    || key == ClipEffect::STAGE_ANCHOR_Y_KEY
                {
                    -1.0
                } else if key == ClipEffect::STAGE_POSITION_X_KEY || key == ClipEffect::STAGE_ANCHOR_X_KEY {
                    if component == EffectComponent::Y { -1.0 } else { 1.0 }
                } else if key == ClipEffect::GROUP_ROTATION_KEY && kind == ClipEffect::GROUP_TRANSFORM_KIND {
                    -1.0
                } else if key == ClipEffect::GROUP_POSITION_KEY || key == ClipEffect::GROUP_ANCHOR_KEY {
                    if kind == ClipEffect::GROUP_TRANSFORM_KIND && component == EffectComponent::Y { -1.0 } else { 1.0 }
                } else {
                    1.0
                }
            }
            _ => 1.0,
        }
    }

    /// Shown = stored x this for an effect row. Crop (stored percent of the picture) is shown in px of the clip's own
    /// picture once `picture` (upright size in px) is known; without it the percent stays.
    pub(crate) fn fx_display_scale(&self, picture: Option<Vec2>) -> f64 {
        let Some(spec) = self.fx_spec() else { return 1.0 };
        if let (Some(axis), Some(pic)) = (spec.picture_axis, picture) {
            let size = if axis == PictureAxis::Width { pic.x } else { pic.y };
            if size > 0.0 {
                return size / 100.0;
            }
        }
        spec.display_scale
    }

    /// True when `fx_display_scale` maps percent to px of the picture (the row's unit is then "px").
    pub(crate) fn shows_picture_units(&self, picture: Option<Vec2>) -> bool {
        let (Some(axis), Some(pic)) = (self.fx_spec().and_then(|s| s.picture_axis), picture) else { return false };
        (if axis == PictureAxis::Width { pic.x } else { pic.y }) > 0.0
    }

    pub fn display(&self, native: f64, component: EffectComponent, picture: Option<Vec2>) -> f64 {
        let v = match self {
            EffectProperty::Scale
            | EffectProperty::Opacity
            | EffectProperty::Anim(_, AnimationParam::Scale)
            | EffectProperty::Anim(_, AnimationParam::Opacity) => native * 100.0,
            EffectProperty::Volume => {
                return if native <= 0.001 { Self::SILENCE_DB } else { (20.0 * native.log10()).max(Self::SILENCE_DB) };
            }
            EffectProperty::Fx { .. } => native * self.fx_display_scale(picture),
            _ => native,
        };
        v * self.display_sign(component) + 0.0 // + 0: never "-0"
    }

    /// `v` (native units) limited to the row's range; Position / Anchor and unranged rows are unlimited.
    pub fn clamped_native(&self, v: f64, picture: Option<Vec2>) -> f64 {
        let r = self.display_range(picture);
        if !(*r.start() > -1e12 || *r.end() < 1e12) {
            return v;
        }
        let a = self.native_from_display(*r.start(), EffectComponent::All, picture);
        let b = self.native_from_display(*r.end(), EffectComponent::All, picture);
        v.max(a.min(b)).min(a.max(b))
    }

    pub fn native_from_display(&self, d: f64, component: EffectComponent, picture: Option<Vec2>) -> f64 {
        let d = d * self.display_sign(component);
        match self {
            EffectProperty::Scale
            | EffectProperty::Opacity
            | EffectProperty::Anim(_, AnimationParam::Scale)
            | EffectProperty::Anim(_, AnimationParam::Opacity) => d / 100.0,
            EffectProperty::Volume => {
                if d <= Self::SILENCE_DB {
                    0.0
                } else {
                    10f64.powf(d / 20.0)
                }
            }
            EffectProperty::Fx { .. } => d / self.fx_display_scale(picture),
            _ => d,
        }
    }

    pub fn display_unit(&self, picture: Option<Vec2>) -> String {
        match self {
            EffectProperty::Scale
            | EffectProperty::Opacity
            | EffectProperty::Anim(_, AnimationParam::Scale)
            | EffectProperty::Anim(_, AnimationParam::Opacity) => "%".to_string(),
            EffectProperty::Rotation
            | EffectProperty::TiltX
            | EffectProperty::TiltY
            | EffectProperty::ShutterAngle
            | EffectProperty::Anim(_, AnimationParam::Rotation) => "\u{00B0}".to_string(),
            EffectProperty::Volume => "dB".to_string(),
            EffectProperty::Fx { .. } => {
                if self.shows_picture_units(picture) {
                    "px".to_string()
                } else {
                    self.fx_spec().map(|s| s.unit).unwrap_or_default()
                }
            }
            EffectProperty::Mask(_, m) => m.unit().to_string(),
            _ => String::new(),
        }
    }

    pub fn display_decimals(&self, picture: Option<Vec2>) -> i64 {
        match self {
            EffectProperty::Scale
            | EffectProperty::Opacity
            | EffectProperty::Position
            | EffectProperty::Anchor
            | EffectProperty::Rotation
            | EffectProperty::TiltX
            | EffectProperty::TiltY
            | EffectProperty::Volume => 1,
            EffectProperty::ShutterAngle => 0,
            EffectProperty::AntiFlicker => 2,
            EffectProperty::Fx { .. } => {
                if self.shows_picture_units(picture) {
                    0
                } else {
                    self.fx_spec().map_or(1, |s| s.decimals)
                }
            }
            EffectProperty::Mask(..) | EffectProperty::MaskPath(_) | EffectProperty::Anim(..) => 1,
        }
    }

    pub fn display_step(&self, picture: Option<Vec2>) -> f64 {
        match self {
            EffectProperty::Volume => 0.1,
            EffectProperty::Position | EffectProperty::Anchor => 1.0,
            EffectProperty::Scale | EffectProperty::Opacity => 0.5,
            EffectProperty::Rotation | EffectProperty::TiltX | EffectProperty::TiltY => 0.5,
            EffectProperty::ShutterAngle => 1.0,
            EffectProperty::AntiFlicker => 0.05,
            EffectProperty::Fx { .. } => {
                if self.shows_picture_units(picture) {
                    1.0
                } else {
                    let spec = self.fx_spec();
                    spec.as_ref().map_or(1.0, |s| s.step) * spec.as_ref().map_or(1.0, |s| s.display_scale)
                }
            }
            EffectProperty::Mask(..) | EffectProperty::MaskPath(_) => 1.0,
            EffectProperty::Anim(_, param) => {
                if *param == AnimationParam::Position {
                    1.0
                } else {
                    0.5
                }
            }
        }
    }

    fn scaled(r: Option<RangeInclusive<f64>>, k: f64) -> RangeInclusive<f64> {
        match r {
            None => -f64::MAX..=f64::MAX,
            Some(r) => *r.start() * k..=*r.end() * k,
        }
    }

    pub fn display_range(&self, picture: Option<Vec2>) -> RangeInclusive<f64> {
        match self {
            EffectProperty::Opacity | EffectProperty::Anim(_, AnimationParam::Opacity) => 0.0..=100.0,
            EffectProperty::ShutterAngle => 0.0..=360.0,
            EffectProperty::AntiFlicker => 0.0..=1.0,
            EffectProperty::TiltX | EffectProperty::TiltY => {
                -perspective_tilt::MAX_DEGREES..=perspective_tilt::MAX_DEGREES
            }
            EffectProperty::Scale | EffectProperty::Anim(_, AnimationParam::Scale) => 0.0..=10_000.0,
            EffectProperty::Volume => Self::SILENCE_DB..=15.0,
            EffectProperty::Mask(_, m) => m.range(),
            EffectProperty::Fx { .. } => Self::scaled(self.fx_spec().map(|s| s.range), self.fx_display_scale(picture)),
            _ => -f64::MAX..=f64::MAX,
        }
    }
}
