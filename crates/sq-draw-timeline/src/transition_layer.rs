// Swift: TimelinePanel+TransitionLayer.swift
//! Transition layer clips (DECISIONS 2026-10-05), translated from `TimelineView+TransitionLayer`: the center marker
//! (the cut) and its drag, the end drags (symmetric around the cut; Alt = this end only) and the lead-in / lead-out ramp
//! drawn over the clip. The body falls through to the ordinary clip gestures (select, move). The drag state, its step and
//! the draw are [`crate::bands`]; this is the panel glue.

use crate::action::TimelineAction;
use crate::bands::{LayerDrag, LayerDrawCx, LayerStep, draw_transition_layers};
use crate::panel::{Gesture, TimelinePanel};
use sq_core_time::Id;
use sq_draw::{Canvas, InputModifiers};
use sq_timeline_ui::TrackRow;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use std::collections::BTreeSet;

impl TimelinePanel {
    /// A single press on a layer's center marker or end (the Selection tool) begins its drag and selects the clip.
    pub(crate) fn transition_layer_down(&mut self, p: CGPoint, clicks: i64) -> Option<Vec<TimelineAction>> {
        let d = LayerDrag::begin(p, clicks, &self.timeline, &self.geometry)?;
        let mut out = Vec::new();
        if self.selected_transition.is_some() {
            self.selected_transition = None;
            out.push(TimelineAction::SelectTransition { id: None, keep_clips: true });
        }
        if self.selection != BTreeSet::<Id>::from([d.id]) {
            out.push(TimelineAction::Select { clips: BTreeSet::from([d.id]), captions: BTreeSet::new() });
        }
        self.gesture = Some(Gesture::TransitionLayer(d));
        Some(out)
    }

    /// One step: the cut moves to the pointer's frame, or the end to it (the bridge measures the step against the
    /// session's current end, so a model clamp never accumulates).
    pub(crate) fn transition_layer_dragged(&mut self, d: LayerDrag, p: CGPoint) -> Vec<TimelineAction> {
        // Alt held now (the host's live keys, `live_modifiers`) resizes one side only.
        let alt = self.drag_modifiers().contains(InputModifiers::OPTION);
        let (d, step) = d.step(p, &self.timeline, &self.geometry, self.playhead, self.snapping(), alt);
        self.gesture = Some(Gesture::TransitionLayer(d));
        match step {
            None => Vec::new(),
            Some(LayerStep::Cut { clip, to, continues }) => {
                vec![TimelineAction::TransitionLayerCut { clip, to, continues }]
            }
            Some(LayerStep::Resize { clip, edge, to, symmetric, continues }) => {
                vec![TimelineAction::TransitionLayerResize { clip, edge, to, symmetric, continues }]
            }
        }
    }

    /// The lead-in / lead-out ramps and cut markers of the transition layer clips.
    pub(crate) fn draw_transition_layer_clips(&self, cv: &mut Canvas, rows: &[TrackRow], clip: CGRect) {
        let cx = LayerDrawCx {
            timeline: &self.timeline,
            geometry: &self.geometry,
            selection: &self.selection,
            transition_layer_tracks: &self.transition_layer_tracks,
            rows,
        };
        draw_transition_layers(cv, &self.theme, &cx, clip);
    }
}
