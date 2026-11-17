//! Transition layers: transitions that are clips on a video track.

use sq_core_edit::timeline_transition_layer_resize::TimelineTransitionLayerResizeExt as _;
use std::collections::BTreeSet;

use sq_core_effects::transition::{ResolvedTransition, TransitionKindExt};
use sq_core_effects::transition_feel::{TransitionKindFeel, TransitionLayerFeel};
use sq_core_effects::transition_layer::{
    ClipTransitionLayer, ProjectTransitionLayer, TimelineTransitionLayer, TransitionKindLayer,
};
use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{ClipEdge, EditError, Transition, TransitionAlignment, TransitionKind, TransitionLayer};
use sq_core_time::{Id, Time};

use super::transition_targets::TransitionDefaults;
use crate::EditorSession;

/// A transition layer seen as a transition.
#[derive(Clone, Debug, PartialEq)]
pub struct TransitionLayerInfo {
    pub track: Id,
    pub transition: Transition,
    pub resolved: ResolvedTransition,
}

impl EditorSession {
    // Swift: EditorSession+TransitionLayer.swift:7
    pub fn transition_layer_info(&self, id: Id) -> Option<TransitionLayerInfo> {
        let t = self.active_timeline()?;
        let m = t.find(id)?;
        let l = m.clip.transition_layer()?;
        let r = m.clip.resolved_transition_layer(t.format.frame_duration)?;
        let transition = Transition {
            id,
            kind: l.kind,
            duration: r.span.duration,
            alignment: r.alignment,
            custom_before: r.before,
            outgoing: None,
            incoming: None,
            easing: l.easing,
            direction: l.direction,
            reversed: l.reversed,
            softness: l.softness,
            motion_blur: l.motion_blur,
            stinger: None,
            params: l.params,
            color: None,
            border_width: None,
            border_color: None,
        };
        Some(TransitionLayerInfo { track: t.tracks[m.track].id, transition, resolved: r })
    }
    // Swift: EditorSession+TransitionLayer.swift:19
    pub fn transition_layer_duration(&self, kind: TransitionKind, defaults: &TransitionDefaults) -> Time {
        let fd = self.active_timeline().map_or(Time::new(1, 30), |t| t.format.frame_duration);
        self.effect_defaults
            .transition(kind)
            .map(|u| u.duration)
            .unwrap_or_else(|| Self::factory_transition_duration(kind, fd, defaults))
    }
    // Swift: EditorSession+TransitionLayer.swift:26
    pub fn add_transition_layer(
        &mut self,
        kind: TransitionKind,
        track: Id,
        start: Time,
        duration: Time,
        cut: Time,
    ) -> Option<Id> {
        let (Some(tl), true) = (self.active_timeline_id, self.active_timeline().is_some()) else {
            self.set_error("Open a sequence first.");
            return None;
        };
        let user = self.effect_defaults.transition(kind).cloned();
        let mut made = None;
        let lease = self.lend_ids();
        let ids = &mut lease.source();
        let result = self.try_perform(&format!("Add {} Layer", kind.name()), None, |p| {
            let id =
                p.add_transition_layer(kind, GeneratorPlacement { timeline: tl, track, start, duration }, &mut *ids)?;
            p.edit(tl, |t| {
                t.set_transition_layer_cut(id, cut)?;
                // The user's default look of the kind, else the factory look.
                t.set_transition_layer(id, |l| match &user {
                    None => l.apply_factory_look(true),
                    Some(u) => {
                        l.easing = Some(u.easing.clone());
                        l.direction = Some(u.direction);
                        l.softness = Some(u.softness);
                        l.motion_blur = Some(u.motion_blur);
                        if kind.is_zoom_through() {
                            l.params = u.params.clone();
                        }
                    }
                })
            })?;
            made = Some(id);
            Ok::<(), EditError>(())
        });
        self.return_ids(lease);
        if let Err(e) = result {
            self.set_error(e.to_string());
            return None;
        }
        if let Some(id) = made {
            self.select(BTreeSet::from([id]), BTreeSet::new());
        }
        made
    }
    // Swift: EditorSession+TransitionLayer.swift:51
    pub fn move_transition_layer_cut(&mut self, id: Id, to: Time, continues_gesture: bool) -> bool {
        let key = self.gesture_key("layerCut", id, continues_gesture);
        self.attempt_keyed_ids("Move Transition Cut", Some(&key), |t, _| t.set_transition_layer_cut(id, to).map(|_| ()))
    }
    // Swift: EditorSession+TransitionLayer.swift:59
    pub fn resize_transition_layer(
        &mut self,
        id: Id,
        edge: ClipEdge,
        delta: Time,
        symmetric: bool,
        continues_gesture: bool,
    ) -> Time {
        let key = self.gesture_key("layerSize", id, continues_gesture);
        let mut moved = Time::ZERO;
        self.attempt_keyed_ids("Resize Transition Layer", Some(&key), |t, _| {
            moved = t.resize_transition_layer(id, edge, delta, symmetric)?;
            Ok(())
        });
        moved
    }
    // Swift: EditorSession+TransitionLayer.swift:68
    pub fn set_transition_layer_kind(&mut self, id: Id, kind: TransitionKind) -> bool {
        if !kind.is_layer_kind() {
            self.set_error(format!("{} cannot be a transition layer.", kind.name()));
            return false;
        }
        self.attempt_keyed_ids("Change Transition Layer", None, |t, _| {
            t.set_transition_layer(id, |l| l.change_kind(kind))
        })
    }
    // Swift: EditorSession+TransitionLayer.swift:74
    pub fn set_transition_layer_duration(&mut self, id: Id, duration: Time) -> bool {
        self.attempt_keyed_ids("Transition Layer Duration", None, |t, _| t.set_transition_layer_duration(id, duration))
    }
    // Swift: EditorSession+TransitionLayer.swift:79
    pub fn set_transition_layer_alignment(&mut self, id: Id, alignment: TransitionAlignment) -> bool {
        self.attempt_keyed_ids("Transition Layer Alignment", None, |t, _| {
            t.set_transition_layer_alignment(id, alignment)
        })
    }
    // Swift: EditorSession+TransitionLayer.swift:86
    pub fn set_transition_layer_param(&mut self, id: Id, key: &str, value: f64, continues_gesture: bool) -> bool {
        self.set_transition_layer_style(id, "Amount", continues_gesture, |l| l.set_param(key, value))
    }
    /// Changes the layer's style; `name` ends up in the undo name ("Transition Layer <name>").
    // Swift: EditorSession+TransitionLayer.swift:92
    pub fn set_transition_layer_style(
        &mut self,
        id: Id,
        name: &str,
        continues_gesture: bool,
        change: impl FnOnce(&mut TransitionLayer),
    ) -> bool {
        let key = self.gesture_key("layerStyle", id, continues_gesture);
        self.attempt_keyed_ids(&format!("Transition Layer {name}"), Some(&key), |t, _| {
            t.set_transition_layer(id, change)
        })
    }
}
