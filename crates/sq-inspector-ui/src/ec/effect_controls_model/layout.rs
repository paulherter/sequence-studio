// Swift: EffectControlsModel.swift (Layout (pure)), Vec2 <-> scalar graph projection
//! Row layout of the Effect Controls panel and the Vec2 <-> scalar graph projection.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use sq_core_color::ColorEffectGroups;
use sq_core_masks::stabilize_effect::StabilizerMethod;
use sq_core_model::{ClipEffect, EffectParamKind};
use sq_core_time::{Id, Keyframe, KeyframeTrack, Vec2};
use sq_editor_session::EffectSection;
use sq_uikit::sqicon::SQIcon;

use super::property::EffectProperty;
use crate::ec::controls_metrics::{ControlsMetrics, EQ_CURVE_HEIGHT, EQ_CURVE_KEY};

/// Which component of a vector a graph shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphProjectionComponent {
    X,
    Y,
}

/// Vec2 <-> scalar graph projection.
pub enum GraphProjection {}

impl GraphProjection {
    pub fn project(t: &KeyframeTrack<Vec2>, component: GraphProjectionComponent) -> KeyframeTrack<f64> {
        KeyframeTrack::with_keys(
            t.keys
                .iter()
                .map(|k| {
                    let mut out = Keyframe::new(
                        k.id,
                        k.time,
                        if component == GraphProjectionComponent::X { k.value.x } else { k.value.y },
                    );
                    out.interpolation = k.interpolation;
                    out.in_handle = k.in_handle;
                    out.out_handle = k.out_handle;
                    out
                })
                .collect(),
        )
    }

    /// Existing keys (by id) take time, component value and easing from `edited` and keep everything else;
    /// keys missing from `edited` are dropped; new keys take the other component from the base curve.
    pub fn merge(
        base: &KeyframeTrack<Vec2>,
        edited: &KeyframeTrack<f64>,
        component: GraphProjectionComponent,
        uniform: bool,
    ) -> KeyframeTrack<Vec2> {
        let set = |v: Vec2, d: f64| -> Vec2 {
            if uniform {
                Vec2::new(d, d)
            } else if component == GraphProjectionComponent::X {
                Vec2::new(d, v.y)
            } else {
                Vec2::new(v.x, d)
            }
        };
        KeyframeTrack::with_keys(
            edited
                .keys
                .iter()
                .map(|e| {
                    let mut k = base
                        .key(e.id)
                        .cloned()
                        .unwrap_or_else(|| Keyframe::new(e.id, e.time, base.value(e.time).unwrap_or(Vec2::ZERO)));
                    k.time = e.time;
                    k.value = set(k.value, e.value);
                    k.interpolation = e.interpolation;
                    k.in_handle = e.in_handle;
                    k.out_handle = e.out_handle;
                    k
                })
                .collect(),
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpeedControl {
    Speed,
    Reverse,
    KeepPitch,
    TimeInterpolation,
}

/// "Video" / "Audio" group.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EffectGroup {
    Video,
    Audio,
}

impl EffectGroup {
    pub fn title(self) -> &'static str {
        if self == EffectGroup::Video { "Video" } else { "Audio" }
    }
}

/// What one layout row is.
#[derive(Clone, Debug, PartialEq)]
pub enum EffectRowKind {
    /// A part of a text clip's Text block the host draws (Swift `arrangeFrame` / `animationFrame`).
    TextSlot(TextSlot),
    Section(EffectSection),
    Property(EffectProperty),
    Placeholder(EffectSection),
    Graph(EffectProperty),
    /// The rows of the Speed section: Speed value, Reverse, Keep Pitch.
    SpeedControl(SpeedControl),
    /// Blend Mode pop-up under the Opacity row (only when the view asks for it).
    BlendMode,
    /// "Video" / "Audio" group header above the sections of that side (only when the view asks for it).
    Group(EffectGroup),
    /// W6.7: Invert, Mode, Path stopwatch and delete of the path mask whose section is above.
    MaskControls(Id),
    /// Second mask line: Track Backward / Forward, the Track choice and delete.
    MaskTrack(Id),
    /// A Magic mask's three steps (pick, follow, check) instead of `MaskTrack`; sized with or without its notice.
    MagicSteps(Id),
    /// The dismissable "Experimental" box under the header of an experimental effect (Pro grading, Stabilize).
    ExperimentalNotice(sq_draw::experimental::Feature),
    /// C6: "Picture of [track] [Shape | Brightness]" and delete, instead of `MaskTrack` for a Picture mask.
    PictureMask(Id),
    /// v87 Color range mask: "Color" (picked color, Inverted, delete) and its Tolerance / Softness lines.
    ColorRangeMask(Id),
    ColorRangeAmount {
        mask: Id,
        soft: bool,
    },
    /// How the mask is used: Cuts picture (Opacity) and the effects it is the input of.
    MaskUse(Id),
    /// W9.8: one subject mask of the clip under Opacity (name, Inverted, Mode, delete).
    SubjectMask(Id),
    /// A group of a Color effect: twirl, title and the group's switch.
    ColorGroup {
        effect: Id,
        key: String,
    },
    /// The RGB curve editor under the Curves group.
    Curves(Id),
    /// Multiband Compressor: button row that opens the custom setup popup.
    Multiband(Id),
    /// "All Parameters" disclosure of a Multiband Compressor.
    MultibandParams(Id),
    /// Parametric EQ: "Curve" disclosure, and the inline curve editor while it is open.
    EqCurveHeader(Id),
    EqCurve(Id),
    /// FB-B3: Set Reference / Match under the Color Wheels group.
    ColorMatch(Id),
    /// The Pro grade: its Step count and the Adjust button that opens the Color page.
    ColorGraph(Id),
    /// Start / end of a range grade, under its section header.
    GradeRange(Id),
    /// Fade-in / fade-out lengths of a range grade.
    GradeFade(Id),
    /// Stabilizer: Analyze / Cancel, progress and status, under its Method row.
    StabilizeAnalyze(Id),
    /// Track Mask: the track pop-up, above its Mode row.
    TrackMaskTrack(Id),
}

/// Which part of the Text block a [`EffectRowKind::TextSlot`] row holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextSlot {
    Arrange,
    Animation,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EffectRow {
    pub kind: EffectRowKind,
    pub y: f64,
    pub height: f64,
}

/// The on/off switch of a section header: a power symbol.
pub enum EffectControlsSwitch {}

impl EffectControlsSwitch {
    pub fn symbol(on: bool) -> SQIcon {
        if on { SQIcon::PowerOn } else { SQIcon::PowerOff }
    }
}

/// Inputs of `EffectControlsLayout::rows` (the Swift call has many defaulted arguments).
#[derive(Clone, Debug, Default)]
pub struct EffectRowsRequest {
    pub sections: Vec<EffectSection>,
    pub collapsed: HashSet<EffectSection>,
    pub expanded: BTreeSet<EffectProperty>,
    pub blend_mode_row: bool,
    pub group_headers: bool,
    /// Swift default is true; `Default` gives false, set it explicitly.
    pub first_group_header: bool,
    pub open_color_groups: BTreeSet<String>,
    pub subject_masks: Vec<Id>,
    pub picture_masks: BTreeSet<Id>,
    pub magic_masks: BTreeSet<Id>,
    /// The Magic Mask notice is still open (it makes the steps row taller).
    pub magic_notice: bool,
    /// The experimental features whose notice is still open (a notice row under their effect's header).
    pub open_notices: Vec<sq_draw::experimental::Feature>,
    pub color_range_masks: BTreeSet<Id>,
    pub grade_ranges: Vec<Id>,
    pub stabilizers: BTreeMap<Id, StabilizerMethod>,
    pub transform_crop: Vec<EffectProperty>,
    /// Heights of a text clip's Arrange part (at the end of Transform, none while Transform is collapsed) and its
    /// Animation part (right after Transform); the host draws them in these rows. Zero = no row.
    pub text_slots: (f64, f64),
    /// Parameter rows taller than one row: a narrow panel stacks the fields of a pair (`ControlsGrid::fields_stack`).
    pub row_heights: BTreeMap<EffectProperty, f64>,
}

impl EffectRowsRequest {
    /// A request with the Swift defaults (`firstGroupHeader: true`).
    pub fn new(sections: Vec<EffectSection>) -> EffectRowsRequest {
        EffectRowsRequest { sections, first_group_header: true, ..EffectRowsRequest::default() }
    }
}

pub enum EffectControlsLayout {}

impl EffectControlsLayout {
    /// The opened keyframe row (design source `.epane` / `.eg`): one inline graph per row, vectors included.
    pub const GRAPH_COMPONENT_HEIGHT: f64 = ControlsMetrics::GRAPH;
    pub const CURVES_ROW_HEIGHT: f64 = 200.0;

    pub fn color_group_id(effect: Id, key: &str) -> String {
        format!("{effect}/{key}")
    }

    pub fn graph_height(_p: &EffectProperty) -> f64 {
        Self::GRAPH_COMPONENT_HEIGHT
    }

    fn is_choice(p: &EffectProperty) -> bool {
        matches!(p.param_kind(), Some(EffectParamKind::Choice(_)))
    }

    /// Row heights from the one grid (`ControlsGrid`): every section header `headerHeight`, every parameter row
    /// `rowHeight`, and `sectionGap` between two sections.
    pub fn rows(req: &EffectRowsRequest) -> Vec<EffectRow> {
        let h = ControlsMetrics::PARAMETER;
        let tall = ControlsMetrics::TALL_PARAMETER;
        let mut out: Vec<EffectRow> = Vec::new();
        let mut y = 0.0;
        let add = |out: &mut Vec<EffectRow>, y: &mut f64, k: EffectRowKind, height: f64| {
            out.push(EffectRow { kind: k, y: *y, height });
            *y += height;
        };
        let mut last_group: Option<EffectGroup> = None;
        // The text parts follow Transform: Arrange ends it, Animation comes right after.
        let slots = |out: &mut Vec<EffectRow>, y: &mut f64| {
            let (arrange, animation) = req.text_slots;
            let arrange = if req.collapsed.contains(&EffectSection::Motion) { 0.0 } else { arrange };
            for (slot, height) in [(TextSlot::Arrange, arrange), (TextSlot::Animation, animation)] {
                if height > 0.0 {
                    out.push(EffectRow { kind: EffectRowKind::TextSlot(slot), y: *y, height });
                    *y += height;
                }
            }
        };
        let mut after_motion = false;
        for s in &req.sections {
            if std::mem::take(&mut after_motion) {
                slots(&mut out, &mut y);
            }
            after_motion = *s == EffectSection::Motion;
            // `first_group_header: false`: the panel's own header names the first group; only the switch to the other
            // one repeats it.
            if req.group_headers && Some(Self::group_of(s)) != last_group {
                if req.first_group_header || last_group.is_some() {
                    add(&mut out, &mut y, EffectRowKind::Group(Self::group_of(s)), ControlsMetrics::GROUP);
                }
                last_group = Some(Self::group_of(s));
            }
            if !out.is_empty() {
                y += ControlsMetrics::SECTION_GAP;
            }
            add(&mut out, &mut y, EffectRowKind::Section(s.clone()), ControlsMetrics::SECTION);
            if req.collapsed.contains(s) {
                continue;
            }
            if let EffectSection::Effect { kind, .. } = s
                && let Some(f) = sq_draw::experimental::Feature::for_effect_kind(kind)
                && req.open_notices.contains(&f)
            {
                add(
                    &mut out,
                    &mut y,
                    EffectRowKind::ExperimentalNotice(f),
                    crate::audio_masks::magic_steps::notice_row_height(),
                );
            }
            if *s == EffectSection::Speed {
                for k in [
                    SpeedControl::Speed,
                    SpeedControl::Reverse,
                    SpeedControl::KeepPitch,
                    SpeedControl::TimeInterpolation,
                ] {
                    add(&mut out, &mut y, EffectRowKind::SpeedControl(k), h);
                }
                continue;
            }
            if let EffectSection::Effect { id, kind } = s
                && kind == ClipEffect::COLOR_GRAPH_KIND
            {
                add(&mut out, &mut y, EffectRowKind::ColorGraph(*id), h);
                continue;
            }
            let props = crate::ec::effect_controls_model::section::section_properties(s);
            if props.is_empty() {
                add(&mut out, &mut y, EffectRowKind::Placeholder(s.clone()), h);
            }
            if let EffectSection::Effect { id, kind } = s
                && kind == ClipEffect::AUDIO_MULTIBAND_KIND
            {
                add(&mut out, &mut y, EffectRowKind::Multiband(*id), ControlsMetrics::MULTIBAND_ROW);
                add(&mut out, &mut y, EffectRowKind::MultibandParams(*id), ControlsMetrics::SECTION);
                if !req
                    .open_color_groups
                    .contains(&Self::color_group_id(*id, crate::ec::effect_controls_model::MULTIBAND_PARAMETERS_KEY))
                {
                    continue;
                }
            }
            if let EffectSection::Effect { id, kind } = s
                && kind == ClipEffect::AUDIO_PARAMETRIC_EQ_KIND
            {
                add(&mut out, &mut y, EffectRowKind::EqCurveHeader(*id), ControlsMetrics::SECTION);
                if req.open_color_groups.contains(&Self::color_group_id(*id, EQ_CURVE_KEY)) {
                    add(&mut out, &mut y, EffectRowKind::EqCurve(*id), EQ_CURVE_HEIGHT);
                }
            }
            if let EffectSection::Effect { id, .. } = s
                && req.grade_ranges.contains(id)
            {
                add(&mut out, &mut y, EffectRowKind::GradeRange(*id), h);
                add(&mut out, &mut y, EffectRowKind::GradeFade(*id), h);
            }
            // A Subject mask: its own line (name, Inverted, Mode, delete) first, then Feather / Opacity / Expansion, then its use.
            if let EffectSection::Mask(id) = s
                && req.subject_masks.contains(id)
            {
                add(&mut out, &mut y, EffectRowKind::SubjectMask(*id), tall);
            }
            // Transform ends with its Crop rows (`EffectControlsModel.transformCropProperties`).
            let mut all_props = props.clone();
            if *s == EffectSection::Motion {
                all_props.extend(req.transform_crop.iter().cloned());
            }
            for p in &all_props {
                // A Picture mask has no Feather / Expansion in v1.
                if let EffectProperty::Mask(id, m) = p
                    && (req.picture_masks.contains(id) || req.color_range_masks.contains(id))
                    && (*m == super::property::MaskParam::Feather || *m == super::property::MaskParam::Expansion)
                {
                    continue;
                }
                // A Stabilizer shows Method, its Analyze row, then only the chosen method's rows.
                if let EffectProperty::Fx { id, kind, key } = p
                    && kind == ClipEffect::STABILIZE_KIND
                {
                    let method = req.stabilizers.get(id).copied().unwrap_or(StabilizerMethod::Standard);
                    if !method.visible_keys().contains(&key.as_str()) {
                        continue;
                    }
                    add(
                        &mut out,
                        &mut y,
                        EffectRowKind::Property(p.clone()),
                        if Self::is_choice(p) { tall } else { h },
                    );
                    if key == ClipEffect::STABILIZE_METHOD_KEY {
                        add(&mut out, &mut y, EffectRowKind::StabilizeAnalyze(*id), tall);
                    } else if req.expanded.contains(p) && p.has_graph() {
                        add(&mut out, &mut y, EffectRowKind::Graph(p.clone()), Self::graph_height(p));
                    }
                    continue;
                }
                // A Track Mask picks its track on a row of its own, above Mode.
                if let EffectProperty::Fx { id, kind, key } = p
                    && kind == ClipEffect::TRACK_MASK_KIND
                    && key == ClipEffect::TRACK_MASK_MODE_KEY
                {
                    add(&mut out, &mut y, EffectRowKind::TrackMaskTrack(*id), tall);
                }
                // A Color effect is grouped like the Color page: each group header carries its switch, closed groups hide their rows.
                if let EffectProperty::Fx { id, kind, key } = p
                    && kind == ClipEffect::COLOR_KIND
                {
                    if ColorEffectGroups::is_group_toggle(key) {
                        add(&mut out, &mut y, EffectRowKind::ColorGroup { effect: *id, key: key.clone() }, h);
                        let open = req.open_color_groups.contains(&Self::color_group_id(*id, key));
                        if key == ClipEffect::COLOR_CURVES_ON_KEY && open {
                            add(&mut out, &mut y, EffectRowKind::Curves(*id), Self::CURVES_ROW_HEIGHT);
                        }
                        if key == ClipEffect::COLOR_WHEELS_ON_KEY && open {
                            add(&mut out, &mut y, EffectRowKind::ColorMatch(*id), h);
                        }
                        continue;
                    }
                    if let Some(g) = ColorEffectGroups::group_key(key)
                        && !req.open_color_groups.contains(&Self::color_group_id(*id, &g))
                    {
                        continue;
                    }
                }
                let row_h = req.row_heights.get(p).copied().unwrap_or(if Self::is_choice(p) { tall } else { h });
                add(&mut out, &mut y, EffectRowKind::Property(p.clone()), row_h);
                if req.expanded.contains(p) && p.has_graph() {
                    add(&mut out, &mut y, EffectRowKind::Graph(p.clone()), Self::graph_height(p));
                }
                if *p == EffectProperty::Opacity && req.blend_mode_row {
                    add(&mut out, &mut y, EffectRowKind::BlendMode, tall);
                }
            }
            // Swift defers these to the end of the section.
            if let EffectSection::Mask(id) = s {
                if req.subject_masks.contains(id) {
                    add(&mut out, &mut y, EffectRowKind::MaskUse(*id), tall);
                } else if req.color_range_masks.contains(id) {
                    add(&mut out, &mut y, EffectRowKind::ColorRangeMask(*id), tall);
                    add(&mut out, &mut y, EffectRowKind::ColorRangeAmount { mask: *id, soft: false }, h);
                    add(&mut out, &mut y, EffectRowKind::ColorRangeAmount { mask: *id, soft: true }, h);
                    add(&mut out, &mut y, EffectRowKind::MaskUse(*id), tall);
                } else if req.picture_masks.contains(id) {
                    add(&mut out, &mut y, EffectRowKind::PictureMask(*id), tall);
                    add(&mut out, &mut y, EffectRowKind::MaskControls(*id), tall);
                    add(&mut out, &mut y, EffectRowKind::MaskUse(*id), tall);
                } else if req.magic_masks.contains(id) {
                    add(&mut out, &mut y, EffectRowKind::MaskControls(*id), tall);
                    add(
                        &mut out,
                        &mut y,
                        EffectRowKind::MagicSteps(*id),
                        crate::audio_masks::magic_steps::height(req.magic_notice),
                    );
                    add(&mut out, &mut y, EffectRowKind::MaskUse(*id), tall);
                } else {
                    add(&mut out, &mut y, EffectRowKind::MaskControls(*id), tall);
                    add(&mut out, &mut y, EffectRowKind::MaskTrack(*id), h);
                    add(&mut out, &mut y, EffectRowKind::MaskUse(*id), tall);
                }
            }
        }
        if after_motion {
            slots(&mut out, &mut y);
        }
        out
    }

    /// Video effects (Motion, Opacity, applied effects) sit above the Audio ones (Volume, audio effects).
    pub fn group_of(s: &EffectSection) -> EffectGroup {
        if *s == EffectSection::Volume {
            return EffectGroup::Audio;
        }
        if let Some(k) = s.effect_kind()
            && ClipEffect::is_audio_kind(k)
        {
            return EffectGroup::Audio;
        }
        EffectGroup::Video
    }

    pub fn row_at(y: f64, rows: &[EffectRow]) -> Option<&EffectRow> {
        rows.iter().find(|r| y >= r.y && y < r.y + r.height)
    }
}
