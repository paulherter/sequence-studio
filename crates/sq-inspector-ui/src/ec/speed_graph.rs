// Swift: EffectControlsModel+SpeedGraph.swift
//! UI state and edits of the opened keyframe row (inline speed graph, variant A). The maths lives in the core crates
//! (`SpeedHill`).

use std::collections::BTreeSet;
use std::ops::RangeInclusive;

use sq_core_model::keyframes_editing::{KeyframeSummary, PropertyID, SummaryMember};
use sq_core_model::keyframes_speed_hill::EaseTrackSegment;
use sq_core_model::{ClipEffect, EaseSegment, EaseSelection, EaseShape};
use sq_core_time::ease_names::ease_name;
use sq_core_time::{EaseSide, EasingCurve, Id, Interpolation};
use sq_editor_session::EffectSection;

use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::property::{EffectComponent, EffectProperty, EffectPropertyKind};
use crate::ec::effect_controls_model::section::EffectSectionExt;
use crate::ec::prelude::*;

/// The curve chips of an opened keyframe row (own names, no Premiere names). Hold Ahead sits directly under Hold; as
/// a shape it is a Hold (`chip_for` reads Hold), the model tells the two apart by the key's kind (`speed_chip`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SpeedCurveChip {
    Steady,
    Smooth,
    SmoothIn,
    SmoothOut,
    Hold,
    HoldAhead,
}

impl SpeedCurveChip {
    pub const ALL: [SpeedCurveChip; 6] = [
        SpeedCurveChip::Steady,
        SpeedCurveChip::Smooth,
        SpeedCurveChip::SmoothIn,
        SpeedCurveChip::SmoothOut,
        SpeedCurveChip::Hold,
        SpeedCurveChip::HoldAhead,
    ];

    /// The kind Hold and Hold Ahead write on the left key of a segment (nil for the curves).
    pub fn hold_kind(self) -> Option<Interpolation> {
        match self {
            SpeedCurveChip::Hold => Some(Interpolation::Hold),
            SpeedCurveChip::HoldAhead => Some(Interpolation::HoldAhead),
            _ => None,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            SpeedCurveChip::Steady => ease_name::STEADY,
            SpeedCurveChip::Smooth => ease_name::SMOOTH,
            SpeedCurveChip::SmoothIn => ease_name::SMOOTH_IN,
            SpeedCurveChip::SmoothOut => ease_name::SMOOTH_OUT,
            SpeedCurveChip::Hold => ease_name::HOLD,
            SpeedCurveChip::HoldAhead => ease_name::HOLD_AHEAD,
        }
    }

    pub fn shape(self) -> EaseShape {
        match self {
            SpeedCurveChip::Steady => EaseShape::LINEAR,
            SpeedCurveChip::Smooth => EasingCurve::ease_in_out().shape(),
            SpeedCurveChip::SmoothIn => EasingCurve::ease_in().shape(),
            SpeedCurveChip::SmoothOut => EasingCurve::ease_out().shape(),
            SpeedCurveChip::Hold | SpeedCurveChip::HoldAhead => EaseShape::HOLD,
        }
    }

    /// The chip a shape reads as: by the speeds at its two keys, whatever the reach is (a Smooth segment stays Smooth
    /// while its handles are dragged). Nil for a shape none of the chips makes.
    pub fn chip_for(shape: &EaseShape) -> Option<SpeedCurveChip> {
        let s = shape.effective();
        if s.interpolation().is_hold() {
            return Some(SpeedCurveChip::Hold);
        }
        Self::ALL.into_iter().find(|c| {
            c.hold_kind().is_none()
                && (c.shape().speed_out() - s.speed_out()).abs() < 0.02
                && (c.shape().speed_in() - s.speed_in()).abs() < 0.02
        })
    }
}

/// Speed and Reach of the selected segments, as the opened row's fields show them.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpeedGraphValues {
    /// Multiples of the steady speed (Steady = 1.0, Smooth = 0.0).
    pub speed_out: f64,
    pub speed_in: f64,
    /// Handle length as a share of the segment (0...1).
    pub reach_out: f64,
    pub reach_in: f64,
}

impl SpeedGraphValues {
    pub fn new(s: &EaseShape) -> SpeedGraphValues {
        SpeedGraphValues {
            speed_out: s.speed_out(),
            speed_in: s.speed_in(),
            reach_out: s.reach_out(),
            reach_in: s.reach_in(),
        }
    }
}

impl EffectControlsModel {
    /// Opens or closes the row's inline graph. Opening selects the row's keys when none of them is selected, so the
    /// chips and fields have something to act on.
    pub fn toggle_open(&mut self, p: &EffectProperty) {
        let mut e = self.expanded.clone();
        if e.remove(p) {
            self.set_expanded(e);
            return;
        }
        e.insert(p.clone());
        self.set_expanded(e);
        if self.selected_key_ids(p).is_empty() {
            let all = self.track_of(p).map(|t| t.key_ids().into_iter().collect()).unwrap_or_default();
            self.set_selection_for(p, &all);
        }
    }

    /// Rows drawn in the graph opened under `p`: `p` itself, then every other selected row that is animated (several rows
    /// selected and eased together draw one hill each), in list order.
    pub fn speed_graph_rows(&self, p: &EffectProperty) -> Vec<EffectProperty> {
        let Some(c) = &self.clip else { return vec![p.clone()] };
        let others: Vec<EffectProperty> = Self::all_properties(c)
            .into_iter()
            .filter(|q| q != p && self.graph_properties.contains(q) && q.has_graph() && self.is_animated(q))
            .collect();
        if self.graph_properties.contains(p) {
            let mut out = vec![p.clone()];
            out.extend(others);
            out
        } else {
            vec![p.clone()]
        }
    }

    /// The segments of a row's track with their effective shapes, clip-local times.
    pub fn speed_segments(&self, p: &EffectProperty) -> Vec<EaseTrackSegment> {
        self.track_of(p).map(|t| t.ease_segments()).unwrap_or_default()
    }

    /// The selected segments that belong to the rows of the graph opened under `p`.
    fn speed_selection(&self, p: &EffectProperty) -> Vec<(EaseSegment, EaseShape)> {
        let Some(c) = &self.clip else { return Vec::new() };
        let ids: BTreeSet<PropertyID> = self.speed_graph_rows(p).iter().map(|q| q.id()).collect();
        let s = KeyframeSummary::new(Self::tracks_of(c));
        EaseSelection::new(&s, &self.selection, &Self::stepped_properties(c))
            .shapes(&s)
            .into_iter()
            .filter(|(seg, _)| ids.contains(&seg.property))
            .collect()
    }

    /// The chip that is on: the one every selected segment of the opened row reads as. A held segment is Hold or
    /// Hold Ahead by the kind of its left key.
    pub fn speed_chip(&self, p: &EffectProperty) -> Option<SpeedCurveChip> {
        let c = self.clip.as_ref()?;
        let s = KeyframeSummary::new(Self::tracks_of(c));
        let mut chips: Vec<Option<SpeedCurveChip>> = Vec::new();
        for (seg, shape) in self.speed_selection(p) {
            let chip = SpeedCurveChip::chip_for(&shape);
            let left = SummaryMember::new(seg.property.clone(), seg.from);
            let chip =
                if chip == Some(SpeedCurveChip::Hold) && s.interpolation_of(&left) == Some(Interpolation::HoldAhead) {
                    Some(SpeedCurveChip::HoldAhead)
                } else {
                    chip
                };
            if !chips.contains(&chip) {
                chips.push(chip);
            }
        }
        if chips.len() == 1 { chips[0] } else { None }
    }

    /// Speed and Reach shown in the fields: those of the first selected segment (nil without a selected segment).
    pub fn speed_values(&self, p: &EffectProperty) -> Option<SpeedGraphValues> {
        self.speed_selection(p).first().map(|(_, s)| SpeedGraphValues::new(s))
    }

    /// Makes sure the edits of the row opened under `p` have a target: with no selected segment there, all its keys.
    fn ensure_speed_selection(&mut self, p: &EffectProperty) {
        if self.speed_selection(p).is_empty() {
            let all = self.track_of(p).map(|t| t.key_ids().into_iter().collect()).unwrap_or_default();
            self.set_selection_for(p, &all);
        }
    }

    /// A curve chip: one shape on every selected segment of the opened row (and of the rows eased with it).
    /// Hold and Hold Ahead set the kind of the segment's left key, so one turns into the other.
    pub fn apply_speed_chip(&mut self, chip: SpeedCurveChip, p: &EffectProperty) {
        if chip == SpeedCurveChip::HoldAhead && (p.is_animation_row() || !self.selection_takes_hold_ahead()) {
            return;
        }
        self.ensure_speed_selection(p);
        let Some(kind) = chip.hold_kind() else {
            self.transform_speed(p, "Set Keyframe Easing", |_, _| chip.shape());
            self.forget_held_kinds();
            return;
        };
        let Some(c) = self.working_clip() else { return };
        let ids: BTreeSet<PropertyID> = self.speed_graph_rows(p).iter().map(|q| q.id()).collect();
        let members: BTreeSet<SummaryMember> =
            self.selection.iter().filter(|m| ids.contains(&m.property)).cloned().collect();
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        if EaseSelection::new(&s, &members, &Self::stepped_properties(&c)).set_hold_kind(kind, &mut s) == 0 {
            return;
        }
        self.forget_held_kinds();
        let mut out = c;
        self.write(&s.tracks.clone(), &mut out);
        self.commit(out, "Set Keyframe Easing", None);
    }

    /// Rewrites every selected segment of the rows drawn under `p` from its own shape: one undo step (inside a gesture
    /// the whole drag is one step). Selected keys of other rows are left alone.
    fn transform_speed(
        &mut self,
        p: &EffectProperty,
        name: &str,
        change: impl FnMut(&EaseSegment, EaseShape) -> EaseShape,
    ) {
        let Some(c) = self.working_clip() else { return };
        let ids: BTreeSet<PropertyID> = self.speed_graph_rows(p).iter().map(|q| q.id()).collect();
        let members: BTreeSet<SummaryMember> =
            self.selection.iter().filter(|m| ids.contains(&m.property)).cloned().collect();
        if members.is_empty() {
            return;
        }
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        let sel = EaseSelection::new(&s, &members, &Self::stepped_properties(&c));
        if sel.transform(&mut s, change) == 0 {
            return;
        }
        let mut out = c;
        self.write(&s.tracks.clone(), &mut out);
        self.commit(out, name, None);
    }

    /// Handle length (share of the segment) on `side` of every selected segment. The key speeds stay what they are.
    pub fn set_reach(&mut self, reach: f64, side: EaseSide, p: &EffectProperty) {
        self.ensure_speed_selection(p);
        self.transform_speed(p, "Set Keyframe Reach", |_, shape| shape.setting_reach(reach, side));
    }

    /// Reach and key speed of the handle on `side` together (one drag step), the speed clamped so the handle's value part
    /// stays inside `value_range` (Swift default -2...3).
    pub fn set_handle(
        &mut self,
        reach: f64,
        speed: f64,
        side: EaseSide,
        p: &EffectProperty,
        value_range: Option<&RangeInclusive<f64>>,
    ) {
        self.ensure_speed_selection(p);
        self.transform_speed(p, "Set Keyframe Reach", |_, shape| {
            shape.setting_reach(reach, side).setting_speed(speed, side, value_range)
        });
    }

    /// A handle of the graph is grabbed: its segment becomes the selection unless it already is part of it.
    pub fn select_speed_segment(&mut self, p: &EffectProperty, from: Id, to: Id) {
        let pid = p.id();
        let has = self
            .ease_selection()
            .segments()
            .iter()
            .any(|s| s.property == pid && s.from == from && s.to == to && s.side == EaseSide::Both);
        if !has {
            self.set_selection_for(p, &BTreeSet::from([from, to]));
        }
    }

    /// Summary value at the right of a section row (design source `.fx .sum`), nil when the section has none.
    /// `collapsed` is the open state the header row was built for; the row passes it so its value changes in the
    /// same pass that adds or removes the body rows (never a model change ahead of the rebuild). Default: the live state.
    pub fn section_summary(&self, s: &EffectSection, collapsed: Option<bool>) -> Option<String> {
        let c = self.clip.as_ref()?;
        let is_collapsed = collapsed.unwrap_or_else(|| self.collapsed_sections.contains(s));
        if let EffectSection::Effect { id, kind } = s
            && kind == ClipEffect::COLOR_KIND
            && let Some(fx) = c.effects.iter().find(|e| e.id == *id)
        {
            return Self::look_summary(fx);
        }
        // v9 `.ksv`: "100 % · Forward".
        if *s == EffectSection::Speed {
            return if is_collapsed {
                Some(format!(
                    "{} % \u{00B7} {}",
                    format_g((self.speed_percent() * 100.0).round() / 100.0),
                    if self.is_reversed() { "Reverse" } else { "Forward" }
                ))
            } else {
                None
            };
        }
        // Collapsed: the first number of the section, so the closed row still says what it does.
        if !is_collapsed {
            return None;
        }
        let p = s.properties().into_iter().find(|p| {
            matches!(p.kind(), EffectPropertyKind::Scalar | EffectPropertyKind::Uniform)
                && !p.param_kind().is_some_and(|k| k.is_stepped())
        })?;
        let pic = self.display_picture();
        let v = p.display(self.scalar_value(&p), EffectComponent::All, pic);
        let text = format!("{:.*}", p.display_decimals(pic).max(0) as usize, v);
        let unit = p.display_unit(pic);
        Some(if unit.is_empty() { text } else { format!("{text} {unit}") })
    }

    fn look_summary(fx: &ClipEffect) -> Option<String> {
        use sq_core_model::LUTRef;
        match fx.grade.as_ref()?.look.as_ref()? {
            LUTRef::File { path } => {
                let file = path.rsplit('/').next().unwrap_or(path);
                let name = file.rsplit_once('.').map_or(file, |(stem, _)| stem);
                if name.is_empty() { None } else { Some(format!("Look {name}")) }
            }
            LUTRef::Embedded { .. } => Some("Look Camera".to_string()),
            _ => None,
        }
    }
}

/// `%g` of a number: the shortest form that keeps six significant digits (no trailing zeros).
fn format_g(v: f64) -> String {
    let s = format!("{v:.6}");
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s.is_empty() || s == "-" { "0".to_string() } else { s.to_string() }
}
