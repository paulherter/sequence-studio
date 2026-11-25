// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Transition.swift (Timeline API), ElementTransitions.swift (Timeline parts), EffectDefaults.swift (applyTransitionDefault,
// resetTransition), EffectPreset.swift (TransitionPreset logic, replaceTransitionBorder)

//! The `Timeline` verbs for transitions: apply, change and remove, plus presets and defaults.

use super::element::CUSTOM_CURVE_KEYS;
use super::{
    ResolvedTransition, TrackTransitions, TransitionExt, TransitionKindElement, TransitionKindExt, TransitionPoint,
};
use crate::transition_feel::{TimelineTransitionFeel, TransitionKindFeel};
use sq_core_model::effect_defaults::{EffectDefaults, TransitionPreset};
use sq_core_model::{
    ClipEdge, EditError, Timeline, TrackKind, Transition, TransitionAlignment, TransitionDirection, TransitionKind,
    TransitionStinger,
};
use sq_core_time::{EasingCurve, Id, IdSource, Time};
use std::collections::BTreeMap;

/// A transition to apply: at a cut (both clips) or to one clip edge (the other side `None`).
#[derive(Clone, Debug)]
pub struct NewTransition {
    /// Style.
    pub kind: TransitionKind,
    /// The track.
    pub track: Id,
    /// Clip before the cut.
    pub outgoing: Option<Id>,
    /// Clip after the cut.
    pub incoming: Option<Id>,
    /// Requested duration.
    pub duration: Time,
    /// Where it lies around the cut.
    pub alignment: TransitionAlignment,
    /// Used by `Custom`: the part before the cut.
    pub custom_before: Time,
}

/// Properties `set_transition` changes; `None` leaves a property alone.
#[derive(Clone, Debug, Default)]
pub struct TransitionChange {
    /// New kind (the parameters go).
    pub kind: Option<TransitionKind>,
    /// Requested duration, snapped to whole frames and clamped to the handles.
    pub duration: Option<Time>,
    /// Alignment around the cut.
    pub alignment: Option<TransitionAlignment>,
    /// The part before the cut for `Custom`.
    pub custom_before: Option<Time>,
    /// Progress curve.
    pub easing: Option<EasingCurve>,
    /// Direction.
    pub direction: Option<TransitionDirection>,
    /// Soft edge, clamped to 0...0.5.
    pub softness: Option<f64>,
    /// Motion blur shutter in frames, clamped to 0...4.
    pub motion_blur: Option<f64>,
    /// Dip color (three bytes).
    pub color: Option<Vec<u8>>,
    /// Travels the other way (`false` clears it).
    pub reversed: Option<bool>,
    /// Border width; 0 clears it.
    pub border_width: Option<f64>,
    /// Border color (three bytes).
    pub border_color: Option<Vec<u8>>,
}

/// Track and transition index of transition `id`.
pub(crate) fn locate_transition(tl: &Timeline, id: Id) -> Option<(usize, usize)> {
    tl.tracks.iter().enumerate().find_map(|(ti, t)| t.transitions.iter().position(|x| x.id == id).map(|ni| (ti, ni)))
}

/// Like `locate_transition`, but refuses a locked track.
fn locate_unlocked(tl: &Timeline, id: Id) -> Result<(usize, usize), EditError> {
    let (ti, ni) = locate_transition(tl, id).ok_or(EditError::ClipNotFound)?;
    if tl.tracks[ti].is_locked {
        return Err(EditError::TrackLocked);
    }
    Ok((ti, ni))
}

/// Whole frames, at least 1.
fn snapped(d: Time, fd: Time) -> Time {
    fd * d.frame_index(fd).max(1)
}

/// Transition edits and queries of a `Timeline`.
pub trait TimelineTransitions {
    /// One second in whole frames of the sequence (the initial default duration of both kinds).
    fn default_transition_duration(fd: Time) -> Time;
    /// The resolved transitions of a track.
    fn resolved_transitions_on(&self, track: Id) -> Vec<ResolvedTransition>;
    /// Looks a transition up by id: its track and a copy.
    fn transition(&self, id: Id) -> Option<(Id, Transition)>;
    /// Largest whole-frame duration the clip handles allow for the transition now.
    fn max_transition_frames(&self, id: Id) -> i64;
    /// The cut or clip edge on `track` nearest to `t`: where Apply Video/Audio Transition lands.
    fn transition_point_near(&self, t: Time, track: Id) -> Option<TransitionPoint>;
    /// Applies a transition at a cut or to one clip edge. A transition already at that place is replaced. The duration is
    /// snapped to whole frames and clamped to the handles; when no frame fits, `InsufficientMedia`. Returns the new id.
    fn add_transition(&mut self, new: &NewTransition, ids: &mut dyn IdSource) -> Result<Id, EditError>;
    /// `add_transition` at a `TransitionPoint`.
    fn add_transition_at(
        &mut self,
        point: TransitionPoint,
        kind: TransitionKind,
        track: Id,
        duration: Time,
        alignment: TransitionAlignment,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
    /// Changes a transition's properties. The duration is snapped to whole frames and clamped to the handles.
    fn set_transition(&mut self, id: Id, change: &TransitionChange) -> Result<(), EditError>;
    /// Sets parameters of element transition `id` (merged into what it has, each clamped to its range). `InvalidFormat` for
    /// a kind without parameters or an unknown key; nothing changes then. `replacing`: `params` become the whole set.
    fn set_transition_params(
        &mut self,
        id: Id,
        params: &BTreeMap<String, f64>,
        replacing: bool,
    ) -> Result<(), EditError>;
    /// Picks the clip a cut transition plays as a Stinger (`None` = none: a plain cut). A clip makes the transition a Stinger.
    fn set_stinger(&mut self, id: Id, stinger: Option<TransitionStinger>) -> Result<(), EditError>;
    /// Removes a transition.
    fn remove_transition(&mut self, id: Id) -> Result<(), EditError>;
    /// Sets the border as a whole (`None` clears): a preset or reset must not keep the target's old border.
    fn replace_transition_border(
        &mut self,
        id: Id,
        width: Option<f64>,
        color: Option<Vec<u8>>,
    ) -> Result<(), EditError>;
    /// A transition default's look on the new transition `id`: easing, direction, softness, motion blur, border and element
    /// parameters. Kind, length and alignment are left alone.
    fn apply_transition_default(&mut self, d: &TransitionPreset, id: Id) -> Result<(), EditError>;
    /// "Reset" of a transition: its length and look go back to `user_default` (same kind), else to the factory look at
    /// `factory_duration`. Kind and alignment stay.
    fn reset_transition(
        &mut self,
        id: Id,
        user_default: Option<&TransitionPreset>,
        factory_duration: Time,
    ) -> Result<(), EditError>;
    /// Makes the transition `id` what `preset` describes (kind, length as far as the handles allow, alignment, style).
    /// `WrongTrackKind` for a video preset on an audio transition and the reverse; nothing changes then.
    fn apply_transition_preset(&mut self, preset: &TransitionPreset, id: Id) -> Result<(), EditError>;
    /// New transition at `point` built from `preset`.
    fn add_transition_from_preset(
        &mut self,
        preset: &TransitionPreset,
        point: TransitionPoint,
        track: Id,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
    /// Length for an element transition on one end of a `clip_duration` clip; `both_ends`: at most half the clip each, so In
    /// and Out both fit. Whole frames, at least one.
    fn element_duration(d: Time, clip_duration: Time, both_ends: bool, fd: Time) -> Time;
    /// Adds element transition `kind` to `edges` of `clip` (`duration` each; both ends share the clip half and half). An edge
    /// where no frame fits is skipped; `InsufficientMedia` only when none fits. Returns the new ids, head first.
    fn add_element_transitions(
        &mut self,
        kind: TransitionKind,
        track: Id,
        clip: Id,
        edges: &[ClipEdge],
        duration: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError>;
}

impl TimelineTransitions for Timeline {
    fn default_transition_duration(fd: Time) -> Time {
        fd * ((fd.timescale() as f64 / fd.value() as f64).round() as i64).max(1)
    }

    fn resolved_transitions_on(&self, track: Id) -> Vec<ResolvedTransition> {
        self.track(track).map(|t| t.resolved_transitions(self.frame_duration())).unwrap_or_default()
    }

    fn transition(&self, id: Id) -> Option<(Id, Transition)> {
        let (ti, ni) = locate_transition(self, id)?;
        Some((self.tracks[ti].id, self.tracks[ti].transitions[ni].clone()))
    }

    fn max_transition_frames(&self, id: Id) -> i64 {
        let Some((ti, ni)) = locate_transition(self, id) else { return 0 };
        let t = &self.tracks[ti];
        t.max_transition_frames(&t.transitions[ni], self.frame_duration())
    }

    fn transition_point_near(&self, t: Time, track: Id) -> Option<TransitionPoint> {
        let tr = self.track(track)?;
        let mut best: Option<(TransitionPoint, Time)> = None;
        let mut consider = |p: TransitionPoint, at: Time| {
            let d = if at >= t { at - t } else { t - at };
            if best.as_ref().is_none_or(|b| d < b.1) {
                best = Some((p, d));
            }
        };
        let cs = tr.clips();
        for (i, c) in cs.iter().enumerate() {
            let prev_touches = i > 0 && cs[i - 1].timeline().end() == c.start;
            let next_touches = i + 1 < cs.len() && cs[i + 1].start == c.timeline().end();
            if prev_touches {
                consider(TransitionPoint::Cut { outgoing: cs[i - 1].id, incoming: c.id }, c.start);
            } else {
                consider(TransitionPoint::Head(c.id), c.start);
            }
            if !next_touches {
                consider(TransitionPoint::Tail(c.id), c.timeline().end());
            }
        }
        best.map(|b| b.0)
    }

    fn add_transition(&mut self, new: &NewTransition, ids: &mut dyn IdSource) -> Result<Id, EditError> {
        let ti = self.tracks.iter().position(|t| t.id == new.track).ok_or(EditError::ClipNotFound)?;
        let kind = new.kind;
        if self.tracks[ti].is_locked {
            return Err(EditError::TrackLocked);
        }
        if kind.track_kind() != self.tracks[ti].kind {
            return Err(EditError::WrongTrackKind);
        }
        if new.outgoing.is_none() && new.incoming.is_none() {
            return Err(EditError::ClipNotFound);
        }
        if kind.is_stinger() && (new.outgoing.is_none() || new.incoming.is_none()) {
            return Err(EditError::NotACut);
        }
        // An element transition animates one clip at one edge: never across a cut (`Head` / `Tail` of a clip instead).
        if kind.is_element() && new.outgoing.is_some() && new.incoming.is_some() {
            return Err(EditError::NotACut);
        }
        for id in [new.outgoing, new.incoming].into_iter().flatten() {
            if self.tracks[ti].clip(id).is_none() {
                return Err(EditError::ClipNotFound);
            }
        }
        if let (Some(o), Some(i)) = (new.outgoing, new.incoming) {
            let (Some(oc), Some(ic)) = (self.tracks[ti].clip(o), self.tracks[ti].clip(i)) else {
                return Err(EditError::NotACut);
            };
            if oc.timeline().end() != ic.start {
                return Err(EditError::NotACut);
            }
        }
        let fd = self.frame_duration();
        let mut tr = Transition::new(ids.next_id(), kind, snapped(new.duration, fd), new.outgoing, new.incoming);
        tr.alignment = new.alignment;
        tr.custom_before = fd * new.custom_before.frame_index(fd).max(0);
        tr.alignment = self.tracks[ti].applied_alignment(&tr, fd);
        let fit = self.tracks[ti].max_transition_frames(&tr, fd);
        if fit < 1 {
            return Err(EditError::InsufficientMedia);
        }
        // A stinger keeps its length (its clip's own); clips shorter than its parts trim it when it resolves.
        if !kind.is_stinger() {
            tr.duration = tr.duration.min(fd * fit);
        }
        // One transition per clip edge and class: a new one replaces what already sits on the same edge(s). An element
        // transition needs no second picture, so it sits next to a cut transition there.
        self.tracks[ti].remove_transitions_sharing_edges_with(&tr);
        let id = tr.id;
        self.tracks[ti].transitions.push(tr);
        Ok(id)
    }

    fn add_transition_at(
        &mut self,
        point: TransitionPoint,
        kind: TransitionKind,
        track: Id,
        duration: Time,
        alignment: TransitionAlignment,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        let (outgoing, incoming) = match point {
            TransitionPoint::Cut { outgoing, incoming } => (Some(outgoing), Some(incoming)),
            TransitionPoint::Head(c) => (None, Some(c)),
            TransitionPoint::Tail(c) => (Some(c), None),
        };
        let new = NewTransition { kind, track, outgoing, incoming, duration, alignment, custom_before: Time::ZERO };
        self.add_transition(&new, ids)
    }

    fn set_transition(&mut self, id: Id, c: &TransitionChange) -> Result<(), EditError> {
        let (ti, ni) = locate_unlocked(self, id)?;
        let fd = self.frame_duration();
        let mut tr = self.tracks[ti].transitions[ni].clone();
        if let Some(kind) = c.kind {
            if kind.track_kind() != self.tracks[ti].kind {
                return Err(EditError::WrongTrackKind);
            }
            if kind.is_stinger() && tr.is_single_sided() {
                return Err(EditError::NotACut);
            }
            if kind.is_element() && !tr.is_single_sided() {
                return Err(EditError::NotACut);
            }
            // Keys mean different things per kind (Zoom's and Pop's "from"): a new kind starts from its defaults.
            if kind != tr.kind {
                tr.params = None;
            }
            tr.kind = kind;
        }
        if let Some(color) = c.color.as_ref().filter(|c| c.len() == 3) {
            tr.color = Some(color.clone());
        }
        // Border width 0 clears it (`None` = off, identical to a file that never had one).
        if let Some(w) = c.border_width {
            tr.border_width = (w > 0.0).then(|| w.min(<TransitionKind as TransitionKindExt>::MAX_BORDER_WIDTH));
        }
        if let Some(color) = c.border_color.as_ref().filter(|c| c.len() == 3) {
            tr.border_color = Some(color.clone());
        }
        if let Some(e) = &c.easing {
            tr.easing = Some(e.clone());
        }
        if let Some(d) = c.direction {
            tr.direction = Some(d);
        }
        if let Some(r) = c.reversed {
            tr.reversed = r.then_some(true);
        }
        if let Some(s) = c.softness {
            tr.softness = Some(s.clamp(0.0, 0.5));
        }
        if let Some(m) = c.motion_blur {
            tr.motion_blur = Some(m.clamp(0.0, 4.0));
        }
        // An element transition blurs through its clip's Shutter Angle, which stops at 360 degrees (one frame).
        if let (true, Some(mb)) = (tr.kind.is_element(), tr.motion_blur) {
            tr.motion_blur = Some(mb.min(1.0));
        }
        if let Some(a) = c.alignment {
            tr.alignment = a;
        }
        if let Some(cb) = c.custom_before {
            tr.custom_before = fd * cb.frame_index(fd).max(0);
        }
        if let Some(d) = c.duration {
            tr.duration = snapped(d, fd);
        }
        let fit = self.tracks[ti].max_transition_frames(&tr, fd);
        if fit >= 1 && !tr.kind.is_stinger() {
            tr.duration = tr.duration.min(fd * fit);
        }
        let class_changed = tr.kind.is_element() != self.tracks[ti].transitions[ni].kind.is_element();
        self.tracks[ti].transitions[ni] = tr.clone();
        if class_changed {
            self.tracks[ti].remove_transitions_sharing_edges_with(&tr);
        }
        Ok(())
    }

    fn set_transition_params(
        &mut self,
        id: Id,
        params: &BTreeMap<String, f64>,
        replacing: bool,
    ) -> Result<(), EditError> {
        let (ti, ni) = locate_unlocked(self, id)?;
        let mut tr = self.tracks[ti].transitions[ni].clone();
        let mut merged = if replacing { BTreeMap::new() } else { tr.params.clone().unwrap_or_default() };
        for (k, v) in params {
            // The Custom curve (not a row of its own): X 0...1, Y -2...3.
            if tr.kind.is_element() && v.is_finite() && CUSTOM_CURVE_KEYS.contains(&k.as_str()) {
                let x_key =
                    k == sq_core_model::ClipEffect::CURVE_X1_KEY || k == sq_core_model::ClipEffect::CURVE_X2_KEY;
                merged.insert(k.clone(), if x_key { v.clamp(0.0, 1.0) } else { v.clamp(-2.0, 3.0) });
                continue;
            }
            let spec = tr.kind.element_param(k).filter(|_| v.is_finite()).ok_or(EditError::InvalidFormat)?;
            merged.insert(k.clone(), v.clamp(*spec.range.start(), *spec.range.end()));
        }
        tr.params = (!merged.is_empty()).then_some(merged);
        self.tracks[ti].transitions[ni] = tr;
        Ok(())
    }

    fn set_stinger(&mut self, id: Id, stinger: Option<TransitionStinger>) -> Result<(), EditError> {
        let (ti, ni) = locate_unlocked(self, id)?;
        if self.tracks[ti].kind != TrackKind::Video {
            return Err(EditError::WrongTrackKind);
        }
        let tr = &mut self.tracks[ti].transitions[ni];
        if stinger.is_some() {
            if tr.is_single_sided() {
                return Err(EditError::NotACut);
            }
            tr.kind = TransitionKind::Stinger;
        }
        tr.stinger = stinger;
        Ok(())
    }

    fn remove_transition(&mut self, id: Id) -> Result<(), EditError> {
        let (ti, _) = locate_unlocked(self, id)?;
        self.tracks[ti].transitions.retain(|t| t.id != id);
        Ok(())
    }

    fn replace_transition_border(
        &mut self,
        id: Id,
        width: Option<f64>,
        color: Option<Vec<u8>>,
    ) -> Result<(), EditError> {
        let (ti, ni) = locate_transition(self, id).ok_or(EditError::ClipNotFound)?;
        let on = width.filter(|w| *w > 0.0);
        let tr = &mut self.tracks[ti].transitions[ni];
        tr.border_width = on.map(|w| w.min(<TransitionKind as TransitionKindExt>::MAX_BORDER_WIDTH));
        tr.border_color = color.filter(|c| on.is_some() && c.len() == 3);
        Ok(())
    }

    fn apply_transition_default(&mut self, d: &TransitionPreset, id: Id) -> Result<(), EditError> {
        let look = TransitionChange {
            easing: Some(d.easing.clone()),
            direction: Some(d.direction),
            softness: Some(d.softness),
            motion_blur: Some(d.motion_blur),
            reversed: Some(d.reversed.unwrap_or(false)),
            ..TransitionChange::default()
        };
        self.set_transition(id, &look)?;
        self.replace_transition_border(id, d.border_width, d.border_color.clone())?;
        if d.kind.has_params() && self.transition(id).is_some_and(|(_, tr)| tr.kind == d.kind) {
            let known = known_params(d);
            self.set_transition_params(id, &known, true)?;
        }
        Ok(())
    }

    fn reset_transition(
        &mut self,
        id: Id,
        user_default: Option<&TransitionPreset>,
        factory_duration: Time,
    ) -> Result<(), EditError> {
        let (ti, ni) = locate_unlocked(self, id)?;
        let d = user_default.filter(|u| u.kind == self.tracks[ti].transitions[ni].kind);
        let n = &mut self.tracks[ti].transitions[ni];
        n.easing = None;
        n.direction = None;
        n.softness = None;
        n.motion_blur = None;
        n.params = None;
        n.reversed = None;
        n.border_width = None;
        n.border_color = None;
        self.set_transition(
            id,
            &TransitionChange {
                duration: Some(d.map_or(factory_duration, |d| d.duration)),
                ..TransitionChange::default()
            },
        )?;
        match d {
            Some(d) => self.apply_transition_default(d, id),
            None => self.apply_factory_look(id, true),
        }
    }

    fn apply_transition_preset(&mut self, preset: &TransitionPreset, id: Id) -> Result<(), EditError> {
        let look = TransitionChange {
            kind: Some(preset.kind),
            duration: Some(preset.duration),
            alignment: Some(preset.alignment),
            easing: Some(preset.easing.clone()),
            direction: Some(preset.direction),
            softness: Some(preset.softness),
            motion_blur: Some(preset.motion_blur),
            reversed: Some(preset.reversed.unwrap_or(false)),
            ..TransitionChange::default()
        };
        self.set_transition(id, &look)?;
        self.replace_transition_border(id, preset.border_width, preset.border_color.clone())?;
        // The saved look as a whole: params the preset does not set go back to their defaults.
        if preset.kind.has_params() {
            self.set_transition_params(id, &known_params(preset), true)?;
        }
        Ok(())
    }

    fn add_transition_from_preset(
        &mut self,
        preset: &TransitionPreset,
        point: TransitionPoint,
        track: Id,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        let id = self.add_transition_at(point, preset.kind, track, preset.duration, preset.alignment, ids)?;
        let look = TransitionChange {
            easing: Some(preset.easing.clone()),
            direction: Some(preset.direction),
            softness: Some(preset.softness),
            motion_blur: Some(preset.motion_blur),
            ..TransitionChange::default()
        };
        self.set_transition(id, &look)?;
        self.replace_transition_border(id, preset.border_width, preset.border_color.clone())?;
        if let (true, Some(_)) = (preset.kind.has_params(), preset.params.as_ref()) {
            self.set_transition_params(id, &known_params(preset), false)?;
        }
        Ok(id)
    }

    fn element_duration(d: Time, clip_duration: Time, both_ends: bool, fd: Time) -> Time {
        if !both_ends {
            return d;
        }
        let half = (clip_duration.frame_index(fd) / 2).max(1);
        d.min(fd * half)
    }

    fn add_element_transitions(
        &mut self,
        kind: TransitionKind,
        track: Id,
        clip: Id,
        edges: &[ClipEdge],
        duration: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError> {
        if !kind.is_element() {
            return Err(EditError::NotACut);
        }
        let c = self.track(track).and_then(|t| t.clip(clip)).ok_or(EditError::ClipNotFound)?;
        let both = edges.contains(&ClipEdge::Head) && edges.contains(&ClipEdge::Tail);
        let d = Self::element_duration(duration, c.duration(), both, self.frame_duration());
        let mut made = Vec::new();
        for edge in [ClipEdge::Head, ClipEdge::Tail] {
            if !edges.contains(&edge) {
                continue;
            }
            let point = if edge == ClipEdge::Head { TransitionPoint::Head(clip) } else { TransitionPoint::Tail(clip) };
            match self.add_transition_at(point, kind, track, d, TransitionAlignment::Center, ids) {
                Ok(id) => made.push(id),
                Err(EditError::InsufficientMedia) => continue,
                Err(e) => return Err(e),
            }
        }
        if made.is_empty() {
            return Err(EditError::InsufficientMedia);
        }
        Ok(made)
    }
}

/// What to apply: style, track, requested length and alignment (an element transition ignores the alignment).
#[derive(Clone, Copy, Debug)]
pub struct TransitionSpec {
    /// Style.
    pub kind: TransitionKind,
    /// The track.
    pub track: Id,
    /// Requested duration.
    pub duration: Time,
    /// Where it lies around the cut.
    pub alignment: TransitionAlignment,
}

/// A transition as the UI applies it: the new transition and then its look (the user's default of the kind, else the factory
/// look). The one path of the session's Apply Transition and the Edit API.
pub fn add_transition_looked(
    tl: &mut Timeline,
    point: TransitionPoint,
    spec: &TransitionSpec,
    user: Option<&TransitionPreset>,
    ids: &mut dyn IdSource,
) -> Result<Id, EditError> {
    let id = tl.add_transition_at(point, spec.kind, spec.track, spec.duration, spec.alignment, ids)?;
    apply_look_of(tl, user, id)?;
    Ok(id)
}

/// `add_element_transitions` plus the look of each (see `add_transition_looked`).
pub fn add_element_transitions_looked(
    tl: &mut Timeline,
    clip: Id,
    edges: &[ClipEdge],
    spec: &TransitionSpec,
    user: Option<&TransitionPreset>,
    ids: &mut dyn IdSource,
) -> Result<Vec<Id>, EditError> {
    let made = tl.add_element_transitions(spec.kind, spec.track, clip, edges, spec.duration, ids)?;
    for id in &made {
        apply_look_of(tl, user, *id)?;
    }
    Ok(made)
}

fn apply_look_of(tl: &mut Timeline, user: Option<&TransitionPreset>, id: Id) -> Result<(), EditError> {
    match user {
        Some(u) => tl.apply_transition_default(u, id),
        None => tl.apply_factory_look(id, true),
    }
}

/// A preset's params that its kind knows.
fn known_params(d: &TransitionPreset) -> BTreeMap<String, f64> {
    d.params.iter().flatten().filter(|(k, _)| d.kind.element_param(k).is_some()).map(|(k, v)| (k.clone(), *v)).collect()
}

/// Logic of `TransitionPreset`.
pub trait TransitionPresetExt: Sized {
    /// A preset of `kind` and `duration` with the kind's own defaults.
    fn new(kind: TransitionKind, duration: Time) -> Self;
    /// The init rules of a preset: `Custom` alignment saves as `Center`, `reversed` is stored only when set, a border only with
    /// a width, a border color only with a border.
    fn normalized(self) -> Self;
    /// The preset for `t` (its requested duration, not the handle-clamped one).
    fn capture(t: &Transition) -> Self;
    /// The track kind the preset belongs to.
    fn track_kind(&self) -> TrackKind;
}

impl TransitionPresetExt for TransitionPreset {
    fn new(kind: TransitionKind, duration: Time) -> Self {
        TransitionPreset {
            kind,
            duration,
            alignment: TransitionAlignment::Center,
            easing: kind.default_easing(),
            direction: TransitionKind::DEFAULT_DIRECTION,
            softness: TransitionKind::DEFAULT_SOFTNESS,
            motion_blur: kind.default_motion_blur(),
            params: None,
            reversed: None,
            border_width: None,
            border_color: None,
        }
    }

    fn normalized(mut self) -> Self {
        self.reversed = self.reversed.filter(|r| *r);
        self.border_width = self.border_width.filter(|w| *w > 0.0);
        if self.border_width.is_none() {
            self.border_color = None;
        }
        if self.alignment == TransitionAlignment::Custom {
            self.alignment = TransitionAlignment::Center;
        }
        self
    }

    fn capture(t: &Transition) -> Self {
        TransitionPreset {
            kind: t.kind,
            duration: t.duration,
            alignment: t.alignment,
            easing: t.effective_easing(),
            direction: t.effective_direction(),
            softness: t.effective_softness(),
            motion_blur: t.effective_motion_blur(),
            params: if t.kind.has_params() { t.params.clone() } else { None },
            reversed: t.reversed,
            border_width: t.border_width,
            border_color: t.border_color.clone(),
        }
        .normalized()
    }

    fn track_kind(&self) -> TrackKind {
        self.kind.track_kind()
    }
}

/// `EffectDefaults::setDefault(from: Transition)`.
pub trait EffectDefaultsTransitionExt {
    /// Makes `t`'s look (and requested length) the default of its kind.
    fn set_default_from(&mut self, t: &Transition);
}

impl EffectDefaultsTransitionExt for EffectDefaults {
    fn set_default_from(&mut self, t: &Transition) {
        self.set_default_transition(TransitionPreset::capture(t));
    }
}
