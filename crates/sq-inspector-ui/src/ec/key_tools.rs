// Swift: EffectControlsModel+KeyTools.swift
//! Graph Editor key tools on the selected keys: roving, time scale, value scale and the Keyframe Velocity numbers.

use std::collections::BTreeSet;

use sq_core_model::keyframes_editing::{KeyframeSummary, PropertyID, PropertyTrack, SummaryMember};
use sq_core_model::keyframes_roving::{KeyVelocity, RovingKeys};
use sq_core_model::keyframes_speed_overlay::KeySide;
use sq_core_time::Id;
use sq_uikit::keyframe_graph_geometry::GraphMode;

use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::property::EffectProperty;
use crate::ec::inspector_text_formats::ControlsNumberText;

/// The Velocity numbers of one selected key side.
#[derive(Clone, Debug, PartialEq)]
pub struct GraphVelocity {
    pub speed: f64,
    pub influence: f64,
    pub unit: String,
}

impl EffectControlsModel {
    /// Speed or Value graph of one row: its own choice, else the panel default.
    pub fn graph_mode_for(&self, p: &EffectProperty) -> GraphMode {
        self.graph_mode_by_property.get(p).copied().unwrap_or(self.graph_mode)
    }

    /// The mode toggle of one row's graph changes only that row; the panel default stays.
    pub fn set_graph_mode_for(&mut self, mode: GraphMode, p: &EffectProperty) {
        self.graph_mode_by_property.insert(p.clone(), mode);
        self.version += 1;
    }

    /// Roving keys: the selected position keys between fixed keys are re-timed so the motion runs at one speed.
    /// Scale and Anchor are vectors too but have no path, so they are left alone. Returns true when a key moved.
    pub fn rove_selected_keys(&mut self) -> bool {
        let Some(c) = self.working_clip().or_else(|| self.clip.clone()) else { return false };
        if self.selection.is_empty() {
            return false;
        }
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        let mut changed = false;
        let skip: BTreeSet<PropertyID> = BTreeSet::from([EffectProperty::Scale.id(), EffectProperty::Anchor.id()]);
        let props: Vec<PropertyID> = s.tracks.keys().cloned().collect();
        for p in props {
            if skip.contains(&p) {
                continue;
            }
            let ids: BTreeSet<Id> = self.selection.iter().filter(|m| m.property == p).map(|m| m.key_id).collect();
            if ids.is_empty() {
                continue;
            }
            if let Some(PropertyTrack::Vector(v)) = s.tracks.get_mut(&p)
                && v.rove(&ids)
            {
                changed = true;
            }
        }
        if !changed {
            return false;
        }
        let mut out = c;
        self.write(&s.tracks.clone(), &mut out);
        self.commit(out, "Rove Keyframes", None);
        true
    }

    /// Time scale of the selected keys about the earliest one (`num / den` of their distance to it).
    pub fn scale_selection_time(&mut self, num: i64, den: i64) -> bool {
        let Some(c) = self.working_clip().or_else(|| self.clip.clone()) else { return false };
        if self.selection.is_empty() {
            return false;
        }
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        let Some(pivot) =
            s.groups(None).into_iter().filter(|g| !g.members.is_disjoint(&self.selection)).map(|g| g.time).min()
        else {
            return false;
        };
        let mut changed = false;
        let props: Vec<PropertyID> = s.tracks.keys().cloned().collect();
        for p in props {
            let ids: BTreeSet<Id> = self.selection.iter().filter(|m| m.property == p).map(|m| m.key_id).collect();
            if ids.is_empty() {
                continue;
            }
            if let Some(t) = s.tracks.get_mut(&p)
                && t.scale_times(&ids, num, den, pivot)
            {
                changed = true;
            }
        }
        if !changed {
            return false;
        }
        let mut out = c;
        self.write(&s.tracks.clone(), &mut out);
        self.commit(out, "Scale Keyframe Time", None);
        true
    }

    /// The Velocity numbers of one selected key side in display units per second (nil without a speed to show).
    pub fn graph_velocity(&self, m: &SummaryMember, side: KeySide) -> Option<GraphVelocity> {
        let curves = self.graph_editor_curves(48);
        let c = curves.iter().find(|c| c.property == m.property)?;
        let h = c.curve.handles.iter().find(|h| h.key_id == m.key_id && h.side == side)?;
        if h.segment_seconds <= 0.0 {
            return None;
        }
        Some(GraphVelocity { speed: h.speed * c.scale, influence: h.influence, unit: c.unit.clone() })
    }

    /// Sets speed (display units per second) and influence (0...1) on `side` of every selected key. Each key keeps
    /// the sign of its own segment, so the dialog's number is a magnitude.
    pub fn set_graph_velocity(&mut self, speed: f64, influence: f64, side: KeySide) -> bool {
        let Some(c) = self.working_clip().or_else(|| self.clip.clone()) else { return false };
        if self.selection.is_empty() {
            return false;
        }
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        let mut n = 0usize;
        let curves = self.graph_editor_curves(48);
        for m in self.selection.clone() {
            let Some(curve) = curves.iter().find(|c| c.property == m.property) else { continue };
            let Some(h) = curve.curve.handles.iter().find(|h| h.key_id == m.key_id && h.side == side) else { continue };
            if !(h.segment_seconds > 0.0 && curve.scale > 0.0) {
                continue;
            }
            let avg = h.span.abs() / h.segment_seconds;
            let sign = if h.span < 0.0 { -1.0 } else { 1.0 };
            let Some(eh) = KeyVelocity::handle(speed.abs() / curve.scale * sign, influence, avg * sign) else {
                continue;
            };
            n += s.set_handle(eh, side, &BTreeSet::from([m]));
        }
        if n == 0 {
            return false;
        }
        let mut out = c;
        self.write(&s.tracks.clone(), &mut out);
        self.commit(out, "Set Keyframe Velocity", None);
        true
    }
}

/// Text of the speed and influence readout shown while hovering or dragging a Graph Editor handle.
pub enum GraphHandleReadout {}

impl GraphHandleReadout {
    pub fn text(title: &str, speed: f64, influence: f64, unit: &str) -> String {
        format!(
            "{title}\n{} {unit}/s \u{00B7} {} %",
            ControlsNumberText::format(speed, 2),
            ControlsNumberText::format(influence * 100.0, 0)
        )
    }
}
