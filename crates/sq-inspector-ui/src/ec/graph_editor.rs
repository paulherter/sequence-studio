// Swift: EffectControlsGraphEditor.swift
//! Graph Editor mode of Effect Controls (After Effects style, speed graph only): the whole keyframe area becomes one
//! speed graph. The property rows selected on the left (or every animated property with the "show all" filter) are drawn
//! in that one plot on one shared speed axis (display units per second, 0 at the bottom), one color per property; the
//! row's value fields carry the same color. Keys of several properties are selected together, moved together in time,
//! and their speed handles are edited together. The key selection is the panel's normal selection, so the key menu and
//! the Smooth / Smooth in / Smooth out commands act on it.

use std::collections::BTreeSet;

use sq_core_model::EffectCatalog;
use sq_core_model::keyframes_editing::{KeyframeSummary, SummaryMember};
use sq_core_model::keyframes_premiere::KeyInterpolationChoice;
use sq_core_model::keyframes_speed_overlay::KeySide;
use sq_core_time::{EaseHandle, Time, Vec2};
use sq_uikit::keyframe_viewport::KeyframeViewport;

use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::property::{EffectComponent, EffectProperty, EffectPropertyKind};
use crate::keyframes::graph_editor_geometry::{GraphEditorCurve, GraphEditorPalette};
use crate::keyframes::property_track_glyphs::PropertyTrackGlyphs;
use sq_editor_session::EffectSection;

fn secs(t: Time) -> f64 {
    t.value() as f64 / t.timescale().max(1) as f64
}

impl EffectControlsModel {
    /// Properties drawn in the graph, in panel order. Colors have no speed and are left out.
    pub fn graph_editor_properties(&self) -> Vec<EffectProperty> {
        if self.clip.is_none() {
            return Vec::new();
        }
        let keyed: BTreeSet<_> = self.selection.iter().map(|m| m.property.clone()).collect();
        self.panel_properties()
            .into_iter()
            .filter(|p| {
                if p.kind() == EffectPropertyKind::Color {
                    return false;
                }
                if self.graph_show_all {
                    return self.track_of(p).is_some_and(|t| !t.key_ids().is_empty());
                }
                self.graph_properties.contains(p) || keyed.contains(&p.id())
            })
            .collect()
    }

    /// Samples per segment for the widest drawn segment: one sample per 2 pt, 4...64 (a long segment on screen gets
    /// the full 64, a short or zoomed-out one far fewer).
    pub fn adaptive_samples(segment_seconds: f64, points_per_second: f64) -> usize {
        let n = segment_seconds * points_per_second / 2.0;
        if n.is_finite() { (n as i64).clamp(4, 64) as usize } else { 48 }
    }

    /// Sample count for the current properties and zoom (widest key-to-key span among the drawn properties).
    pub fn graph_sample_count(&self, points_per_second: f64) -> usize {
        if self.clip.is_none() {
            return 4;
        }
        let mut widest = 0.0f64;
        for p in self.graph_editor_properties() {
            let ts: Vec<f64> =
                self.track_of(&p).map(|t| t.glyphs()).unwrap_or_default().iter().map(|g| secs(g.time)).collect();
            for w in ts.windows(2) {
                widest = widest.max(w[1] - w[0]);
            }
        }
        Self::adaptive_samples(widest, points_per_second)
    }

    /// The drawn curves with their color slot and display units. A row without keys is a flat line at 0. Swift default
    /// `samples: 48`.
    pub fn graph_editor_curves(&self, samples: usize) -> Vec<GraphEditorCurve> {
        if self.clip.is_none() {
            return Vec::new();
        }
        let props = self.graph_editor_properties();
        let slots = GraphEditorPalette::slots(&props);
        let picture = self.display_picture();
        props
            .iter()
            .zip(slots)
            .map(|(p, slot)| {
                let t = self.track_of(p);
                let curve = if t.as_ref().is_none_or(|t| t.key_ids().is_empty()) {
                    sq_core_model::keyframes_speed_overlay::SpeedOverlayCurve::still()
                } else {
                    t.and_then(|t| t.speed_overlay(samples, self.is_hue_property(p)))
                        .unwrap_or_else(sq_core_model::keyframes_speed_overlay::SpeedOverlayCurve::still)
                };
                GraphEditorCurve {
                    property: p.id(),
                    title: p.title(),
                    curve,
                    color_index: slot,
                    scale: Self::speed_scale(p, picture),
                    unit: Self::speed_unit(p, picture),
                }
            })
            .collect()
    }

    /// True for a hue parameter (degrees round the color circle): its segments take the short way between keys.
    fn is_hue_property(&self, p: &EffectProperty) -> bool {
        let EffectProperty::Fx { id, kind, key } = p else { return false };
        self.clip.as_ref().is_some_and(|c| c.effects.iter().any(|e| e.id == *id))
            && EffectCatalog::param(kind, key).is_some_and(|s| s.is_hue)
    }

    /// Native units -> display units for speeds (linear display mappings; volume stays in gain).
    pub(crate) fn speed_scale(p: &EffectProperty, picture: Option<Vec2>) -> f64 {
        if *p == EffectProperty::Volume {
            return 1.0;
        }
        let s = p.display(1.0, EffectComponent::All, picture) - p.display(0.0, EffectComponent::All, picture);
        if s.is_finite() && s != 0.0 { s.abs() } else { 1.0 }
    }

    pub(crate) fn speed_unit(p: &EffectProperty, picture: Option<Vec2>) -> String {
        match p {
            EffectProperty::Position | EffectProperty::Anchor => "px".to_string(),
            EffectProperty::Volume => "gain".to_string(),
            _ => p.display_unit(picture),
        }
    }

    /// Click-away (empty space in Controls, or focus left the panel): no row, effect header or key stays selected.
    /// `keep_mask`: a click elsewhere (the Program monitor, where masks are drawn and edited) keeps a selected mask.
    pub fn clear_row_selection(&mut self, keep_mask: bool) {
        self.graph_properties.clear();
        if !(matches!(self.selected_section, Some(EffectSection::Mask(_))) && keep_mask) {
            self.selected_section = None;
        }
        self.clear_selection();
    }

    /// Click on a property row's label: that row and its keys are the one selection; `extend` (Shift / Cmd) adds or
    /// removes the row (and its keys) instead. An effect header selection never stays alongside a row selection.
    pub fn select_property_row(&mut self, p: &EffectProperty, extend: bool) {
        self.selected_section = None;
        let ids: BTreeSet<_> = self.track_of(p).map(|t| t.key_ids().into_iter().collect()).unwrap_or_default();
        if extend {
            let removing = self.graph_properties.contains(p);
            self.set_selection_for(p, &if removing { BTreeSet::new() } else { ids });
        } else {
            self.clear_selection();
            self.set_selection_for(p, &ids);
        }
        self.select_graph_property(p, extend);
    }

    /// Click on an effect header: only that effect is selected, no row or key.
    pub fn select_effect_header(&mut self, s: &EffectSection) {
        self.graph_properties.clear();
        self.clear_selection();
        self.selected_section = Some(s.clone());
    }

    /// Turns the Graph Editor on or off (Controls row menu, View > Graph Editor, the toggle) and reports the new state.
    pub fn toggle_graph_editor(&mut self) {
        self.graph_editor = !self.graph_editor;
        self.version += 1;
        self.events
            .push(super::effect_controls_model::core::EffectControlsEvent::GraphEditorChanged(self.graph_editor));
    }

    /// Row menu entry title: the Graph Editor on or off for the whole panel.
    pub fn graph_editor_menu_title(&self) -> &'static str {
        if self.graph_editor { "Hide Graph Editor" } else { "Show Graph Editor" }
    }

    /// Click on a row name: plain click shows only that property; `extend` (Shift / Cmd) adds or removes it.
    pub fn select_graph_property(&mut self, p: &EffectProperty, extend: bool) {
        if extend {
            if !self.graph_properties.remove(p) {
                self.graph_properties.insert(p.clone());
            }
        } else {
            self.graph_properties = BTreeSet::from([p.clone()]);
        }
        self.version += 1;
    }

    /// Moves the selected keys (all properties) by `seconds` from the gesture base, frame-rounded. With snapping on and a
    /// tolerance given, the move lands exactly on the playhead or another key when one is that close. Call
    /// `begin_gesture` first and `end_graph_key_move` on mouse-up.
    pub fn move_graph_selection(&mut self, seconds: f64, snap_tolerance: Option<f64>) {
        let mut seconds = seconds;
        if self.graph_snap
            && let Some(tol) = snap_tolerance
            && let Some(c) = self.working_clip().or_else(|| self.clip.clone())
        {
            let mut moving: Vec<f64> = Vec::new();
            let mut targets: Vec<f64> = Vec::new();
            for (pid, t) in Self::tracks_of(&c) {
                for (id, time) in t.times() {
                    let s = secs(time);
                    if self.selection.contains(&SummaryMember::new(pid.clone(), id)) {
                        moving.push(s);
                    } else {
                        targets.push(s);
                    }
                }
            }
            targets.push(secs(self.local_playhead()));
            targets.extend([0.0, secs(c.duration())]); // clip start and end
            seconds = GraphEditorSnap::delta(seconds, &moving, &targets, tol);
        }
        let fd = self.frame_duration;
        let fd_secs = fd.value() as f64 / fd.timescale().max(1) as f64;
        let frames = (seconds / fd_secs).round();
        if !(frames.is_finite() && frames.abs() < 1e12) {
            return;
        }
        self.move_selection(Time::frames(frames as i64, fd), false);
    }

    /// Ends a graph key drag as one undo step. Unlike the lanes, the moved keys stay selected (After Effects): the
    /// next step is usually easing them.
    pub fn end_graph_key_move(&mut self) {
        let keep = self.selection.clone();
        self.end_key_move();
        if self.selection != keep {
            let v: Vec<SummaryMember> = keep.into_iter().collect();
            self.select(&v, false);
        }
    }

    /// Gives every selected key `handle` on `side` (same influence, same speed relative to its segment), from the
    /// gesture base. Inside a gesture the whole drag is one undo step.
    pub fn set_graph_handle(&mut self, handle: EaseHandle, side: KeySide) {
        let Some(c) = self.working_clip() else { return };
        if self.selection.is_empty() {
            return;
        }
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        if s.set_handle(handle, side, &self.selection) == 0 {
            return;
        }
        let mut out = c;
        self.write(&s.tracks.clone(), &mut out);
        self.commit(out, "Set Keyframe Speed", None);
    }

    /// Bottom toolbar ease buttons: Smooth, Smooth in, Smooth out, Steady, Hold (same as the key menu).
    pub fn apply_graph_ease(&mut self, choice: KeyInterpolationChoice) {
        if self.selection.is_empty() {
            return;
        }
        self.apply_interpolation(choice);
    }

    /// Fit: the time range of the selected keys (or of every drawn key) fills the plot, with a small margin. The speed
    /// axis always fits itself.
    pub fn fit_graph(&mut self, selection_only: bool) {
        let mut times: Vec<f64> = Vec::new();
        for c in self.graph_editor_curves(48) {
            times.extend(
                c.curve
                    .keys
                    .iter()
                    .filter(|k| {
                        !selection_only || self.selection.contains(&SummaryMember::new(c.property.clone(), k.id))
                    })
                    .map(|k| k.seconds),
            );
        }
        let (Some(lo), Some(hi)) = (times.iter().copied().reduce(f64::min), times.iter().copied().reduce(f64::max))
        else {
            return;
        };
        let span = (hi - lo).max(self.min_viewport_span());
        let pad = span * 0.08;
        self.set_viewport(KeyframeViewport::new(lo - pad, span + 2.0 * pad));
    }

    /// The toolbar's Fit button: the selected keys when there are any, else every drawn key.
    pub fn fit_graph_default(&mut self) {
        let sel = !self.selection.is_empty();
        self.fit_graph(sel);
    }

    /// Selects every key of every drawn curve.
    pub fn select_all_graph_keys(&mut self) {
        let mut all: Vec<SummaryMember> = Vec::new();
        for c in self.graph_editor_curves(48) {
            all.extend(c.curve.keys.iter().map(|k| SummaryMember::new(c.property.clone(), k.id)));
        }
        self.select(&all, false);
    }

    pub fn perform(&mut self, shortcut: crate::keyframes::graph_editor_shortcuts::GraphEditorShortcut) {
        use crate::keyframes::graph_editor_shortcuts::GraphEditorShortcut as S;
        match shortcut {
            S::FitAll => self.fit_graph(false),
            S::FitSelection => self.fit_graph(true),
            S::SelectAll => self.select_all_graph_keys(),
            S::Ease(c) => self.apply_graph_ease(c),
        }
    }
}

/// Snapping of a time move: the smallest correction that puts any moving key onto any target, if within `tolerance`.
pub enum GraphEditorSnap {}

impl GraphEditorSnap {
    pub fn delta(d: f64, moving: &[f64], targets: &[f64], tolerance: f64) -> f64 {
        let mut best: Option<f64> = None;
        for m in moving {
            for t in targets {
                let corr = t - (m + d);
                if corr.abs() <= tolerance && corr.abs() < best.map_or(f64::INFINITY, f64::abs) {
                    best = Some(corr);
                }
            }
        }
        d + best.unwrap_or(0.0)
    }
}
