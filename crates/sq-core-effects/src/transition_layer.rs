// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TransitionLayer.swift (logic; the saved type is in sq-core-model)

//! A transition placed as its own clip on a video track, like an Adjustment Layer: a generator clip
//! (`TransitionLayer::GENERATOR_KIND`) whose payload is a `TransitionLayer` (kind, style and the cut). It transitions
//! everything composited below its track in the same sequence.
//!
//! The cut is stored in the clip's own source time, like a marker on its content: a head trim (which moves the generator's
//! source start with the clip start) leaves it where it is on the timeline, a move carries it along. It resolves clamped into
//! the clip and onto the frame grid. Stingers and element transitions (one picture) are not layer kinds.

use crate::transition::{
    Compose, ResolvedTransition, TrackTransitions, TransitionDirectionExt, TransitionKindExt, TransitionMix,
    TransitionRender, TransitionSide, dissolve_weight,
};
use crate::transition_feel::TransitionLayerFeel;
use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{
    Clip, EditError, GeneratorRef, Project, Timeline, Track, TrackKind, TransitionAlignment, TransitionDirection,
    TransitionKind, TransitionLayer,
};
use sq_core_time::{EasingCurve, Id, IdSource, Time};

/// Whole frames of half this duration, rounded down (the center split of a transition).
fn halved_frames(t: Time, fd: Time) -> Time {
    fd * (t.frame_index(fd) / 2)
}

/// Logic of `TransitionLayer`.
pub trait TransitionLayerExt: Sized {
    /// A layer of `kind` with its cut and no own style.
    fn new(kind: TransitionKind, cut: Time) -> Self;
    /// Own curve or the kind's default.
    fn effective_easing(&self) -> EasingCurve;
    /// Own direction or `Left`.
    fn effective_direction(&self) -> TransitionDirection;
    /// Own softness or 0.1.
    fn effective_softness(&self) -> f64;
    /// Own motion blur or the kind's default.
    fn effective_motion_blur(&self) -> f64;
    /// Travels the other way (v89).
    fn is_reversed(&self) -> bool;
    /// The direction the render travels: the style's direction, turned around when reversed.
    fn render_direction(&self) -> TransitionDirection;
    /// The generator payload bytes.
    fn payload(&self) -> Vec<u8>;
    /// Reads a generator payload.
    fn decode(data: &[u8]) -> Option<Self>;
}

impl TransitionLayerExt for TransitionLayer {
    fn new(kind: TransitionKind, cut: Time) -> Self {
        TransitionLayer {
            kind,
            cut,
            easing: None,
            direction: None,
            reversed: None,
            softness: None,
            motion_blur: None,
            color: None,
            params: None,
        }
    }

    fn effective_easing(&self) -> EasingCurve {
        self.easing.clone().unwrap_or_else(|| self.kind.default_easing())
    }

    fn effective_direction(&self) -> TransitionDirection {
        self.direction.unwrap_or(TransitionKind::DEFAULT_DIRECTION)
    }

    fn effective_softness(&self) -> f64 {
        self.softness.unwrap_or(TransitionKind::DEFAULT_SOFTNESS)
    }

    fn effective_motion_blur(&self) -> f64 {
        self.motion_blur.unwrap_or_else(|| self.kind.default_motion_blur())
    }

    fn is_reversed(&self) -> bool {
        self.reversed == Some(true)
    }

    fn render_direction(&self) -> TransitionDirection {
        let d = self.effective_direction();
        if self.is_reversed() { d.opposite() } else { d }
    }

    fn payload(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    fn decode(data: &[u8]) -> Option<Self> {
        serde_json::from_slice(data).ok()
    }
}

/// Layer kinds.
pub trait TransitionKindLayer: Sized {
    /// Kinds a transition layer can take: video transitions that mix two pictures.
    fn is_layer_kind(&self) -> bool;
    /// Every layer kind.
    fn layer_kinds() -> Vec<Self>;
}

impl TransitionKindLayer for TransitionKind {
    fn is_layer_kind(&self) -> bool {
        self.track_kind() == TrackKind::Video && !self.is_stinger() && !self.is_element()
    }

    fn layer_kinds() -> Vec<Self> {
        crate::transition::ALL_TRANSITION_KINDS.iter().copied().filter(|k| k.is_layer_kind()).collect()
    }
}

/// Transition layer parts of `Clip`.
pub trait ClipTransitionLayer {
    /// The clip is a transition layer.
    fn is_transition_layer(&self) -> bool;
    /// The payload of a transition layer clip; `None` for any other clip.
    fn transition_layer(&self) -> Option<TransitionLayer>;
    /// The cut on the timeline, clamped into the clip (not yet snapped to frames).
    fn transition_layer_cut(&self) -> Option<Time>;
    /// What the layer plays: the cut (clamped into the clip, snapped to the frame grid), before / after parts and the style.
    /// `outgoing` / `incoming` are `None` (the sides are the stack below, not clips). `None` for another clip, an unknown kind
    /// or a span shorter than a frame.
    fn resolved_transition_layer(&self, fd: Time) -> Option<ResolvedTransition>;
}

impl ClipTransitionLayer for Clip {
    fn is_transition_layer(&self) -> bool {
        self.generator.as_ref().is_some_and(|g| g.kind == TransitionLayer::GENERATOR_KIND)
    }

    fn transition_layer(&self) -> Option<TransitionLayer> {
        let g = self.generator.as_ref().filter(|g| g.kind == TransitionLayer::GENERATOR_KIND)?;
        TransitionLayer::decode(&g.payload)
    }

    fn transition_layer_cut(&self) -> Option<Time> {
        let l = self.transition_layer()?;
        let t = self.start + (l.cut - self.source.start);
        Some(t.max(self.start).min(self.timeline().end()))
    }

    fn resolved_transition_layer(&self, fd: Time) -> Option<ResolvedTransition> {
        let l = self.transition_layer().filter(|l| l.kind.is_layer_kind())?;
        let raw = self.transition_layer_cut()?;
        let span = self.timeline();
        if span.duration.frame_index(fd) < 1 {
            return None;
        }
        let cut = raw.snapped(fd).max(span.start).min(span.end());
        let (before, after) = (cut - span.start, span.end() - cut);
        let alignment = if before == Time::ZERO {
            TransitionAlignment::StartAtCut
        } else if after == Time::ZERO {
            TransitionAlignment::EndAtCut
        } else if before == halved_frames(span.duration, fd) {
            TransitionAlignment::Center
        } else {
            TransitionAlignment::Custom
        };
        Some(ResolvedTransition {
            id: self.id,
            kind: l.kind,
            alignment,
            outgoing: None,
            incoming: None,
            cut,
            span,
            before,
            after,
            requested_duration: span.duration,
            frame_duration: fd,
            easing: l.effective_easing(),
            direction: l.render_direction(),
            softness: l.effective_softness(),
            motion_blur: l.effective_motion_blur(),
            stinger: None,
            stinger_start: Time::ZERO,
            color: l.color.clone(),
            zoom_amount: l.zoom_amount(),
            border_width: None,
            border_color: None,
            held_before: 0,
            held_after: 0,
        })
    }
}

/// How the two sides combine on frame `i` of `r` (the clip-edge engine's maths).
pub fn stack_render(r: &ResolvedTransition, i: i64) -> TransitionRender {
    if r.kind.is_motion() {
        return TransitionRender::evaluate(&r.render_style(true, true, None), i, r.frames());
    }
    let w = dissolve_weight(&r.easing, i, r.frames());
    let m = TransitionMix::video(r.kind, w);
    TransitionRender {
        outgoing: TransitionSide { opacity: m.outgoing, ..TransitionSide::default() },
        incoming: TransitionSide { opacity: m.incoming, ..TransitionSide::default() },
        compose: Compose::Sum,
        ..TransitionRender::default()
    }
}

/// The enabled transition layer clip under `t` of a track.
pub trait TrackTransitionLayer {
    /// The enabled transition layer clip under `t`, if any.
    fn active_transition_layer(&self, t: Time) -> Option<&Clip>;
}

impl TrackTransitionLayer for Track {
    fn active_transition_layer(&self, t: Time) -> Option<&Clip> {
        let c = self.clips().get(self.clip_index_ending_after(t))?;
        (c.timeline().contains(t) && c.is_enabled && c.is_transition_layer()).then_some(c)
    }
}

/// Places a transition layer on a video track.
pub trait ProjectTransitionLayer {
    /// Places a transition layer on a video track (overwrite, like any generator drop) with its cut in the middle (whole
    /// frames, the earlier one for an odd length). `WrongTrackKind` for an audio track or a kind that is not a layer kind,
    /// otherwise like `add_generator_clip`.
    fn add_transition_layer(
        &mut self,
        kind: TransitionKind,
        at: GeneratorPlacement,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
    /// Any transition layer in any sequence (gates ProjectFile v53).
    fn contains_transition_layers(&self) -> bool;
}

impl ProjectTransitionLayer for Project {
    fn add_transition_layer(
        &mut self,
        kind: TransitionKind,
        at: GeneratorPlacement,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        if !kind.is_layer_kind() {
            return Err(EditError::WrongTrackKind);
        }
        let fd = self.timeline(at.timeline).map_or(Time::new(1, 30), Timeline::frame_duration);
        let d = at.duration.snapped(fd);
        let layer = TransitionLayer::new(kind, halved_frames(d, fd));
        let generator = GeneratorRef {
            kind: TransitionLayer::GENERATOR_KIND.to_string(),
            payload: layer.payload(),
            payload_version: TransitionLayer::PAYLOAD_VERSION,
        };
        self.add_generator_clip(generator, Some("Transition Layer"), GeneratorPlacement { duration: d, ..at }, ids)
    }

    fn contains_transition_layers(&self) -> bool {
        self.timelines.iter().any(|t| t.tracks.iter().any(|tr| tr.clips().iter().any(Clip::is_transition_layer)))
    }
}

/// The clip a layer edit works on: its track index, the clip and its layer.
fn layer_clip(tl: &Timeline, id: Id) -> Result<(usize, Clip, TransitionLayer), EditError> {
    let m = tl.find(id).ok_or(EditError::ClipNotFound)?;
    let l = m.clip.transition_layer().ok_or(EditError::ClipNotFound)?;
    if tl.tracks[m.track].is_locked {
        return Err(EditError::TrackLocked);
    }
    Ok((m.track, m.clip, l))
}

/// Transition layer edits of a `Timeline`.
pub trait TimelineTransitionLayer {
    /// The resolved transition layer clip `id`, or `None`.
    fn resolved_transition_layer(&self, id: Id) -> Option<ResolvedTransition>;
    /// Moves the cut (center marker) of transition layer `id` to timeline time `t`, snapped to whole frames and clamped into
    /// the clip. Returns the cut as applied. `ClipNotFound` for another clip, `TrackLocked` on a locked track.
    fn set_transition_layer_cut(&mut self, id: Id, t: Time) -> Result<Time, EditError>;
    /// Places transition layer `id` around its fixed cut: `Center` half before (whole frames), `StartAtCut` all after,
    /// `EndAtCut` all before. `Custom` changes nothing. The length stays; a neighbor in the way is a `Collision`.
    fn set_transition_layer_alignment(&mut self, id: Id, alignment: TransitionAlignment) -> Result<(), EditError>;
    /// Sets the length of transition layer `id` (whole frames, at least one) around its fixed cut, keeping the share before
    /// the cut. A neighbor in the way is a `Collision`.
    fn set_transition_layer_duration(&mut self, id: Id, duration: Time) -> Result<(), EditError>;
    /// Changes the kind or style of transition layer `id`. `WrongTrackKind` when the kind is not a layer kind.
    fn set_transition_layer(&mut self, id: Id, change: impl FnOnce(&mut TransitionLayer)) -> Result<(), EditError>;
}

impl TimelineTransitionLayer for Timeline {
    fn resolved_transition_layer(&self, id: Id) -> Option<ResolvedTransition> {
        self.find(id)?.clip.resolved_transition_layer(self.frame_duration())
    }

    fn set_transition_layer_cut(&mut self, id: Id, t: Time) -> Result<Time, EditError> {
        let (ti, mut c, mut l) = layer_clip(self, id)?;
        let cut = t.snapped(self.frame_duration()).max(c.start).min(c.timeline().end());
        l.cut = c.source.start + (cut - c.start);
        write_layer(&l, &mut c);
        self.tracks[ti].replace(c);
        Ok(cut)
    }

    fn set_transition_layer_alignment(&mut self, id: Id, alignment: TransitionAlignment) -> Result<(), EditError> {
        let (_, c, _) = layer_clip(self, id)?;
        let fd = self.frame_duration();
        let r = c.resolved_transition_layer(fd).ok_or(EditError::ClipNotFound)?;
        let before = match alignment {
            TransitionAlignment::Center => halved_frames(r.span.duration, fd),
            TransitionAlignment::StartAtCut => Time::ZERO,
            TransitionAlignment::EndAtCut => r.span.duration,
            TransitionAlignment::Custom => return Ok(()),
        };
        place(self, id, r.cut - before, r.span.duration, r.cut)
    }

    fn set_transition_layer_duration(&mut self, id: Id, duration: Time) -> Result<(), EditError> {
        let (_, c, _) = layer_clip(self, id)?;
        let fd = self.frame_duration();
        let r = c.resolved_transition_layer(fd).ok_or(EditError::ClipNotFound)?;
        let n = duration.frame_index(fd).max(1);
        let total = r.span.duration.frame_index(fd).max(1);
        let b = r.before.frame_index(fd);
        let nb = n.min((b as f64 * n as f64 / total as f64).round() as i64);
        place(self, id, r.cut - fd * nb, fd * n, r.cut)
    }

    fn set_transition_layer(&mut self, id: Id, change: impl FnOnce(&mut TransitionLayer)) -> Result<(), EditError> {
        let (ti, mut c, mut l) = layer_clip(self, id)?;
        change(&mut l);
        if !l.kind.is_layer_kind() {
            return Err(EditError::WrongTrackKind);
        }
        write_layer(&l, &mut c);
        self.tracks[ti].replace(c);
        Ok(())
    }
}

fn write_layer(l: &TransitionLayer, c: &mut Clip) {
    if let Some(g) = c.generator.as_mut() {
        g.payload = l.payload();
    }
}

/// Sets the clip to `[start, start + duration)` keeping its cut at `cut` (one change, checked against the track).
fn place(tl: &mut Timeline, id: Id, start: Time, duration: Time, cut: Time) -> Result<(), EditError> {
    let (ti, mut c, mut l) = layer_clip(tl, id)?;
    if start < Time::ZERO {
        return Err(EditError::Collision);
    }
    // A generator's content has no limits: move its source start with the start, like a head trim.
    let shift = c.start - start;
    c.source.start += start - c.start;
    c.animation = c.animation.shifted(shift);
    c.effects = c.effects.iter().map(|e| e.shifted(shift)).collect();
    c.source.duration = duration;
    c.start = start;
    l.cut = c.source.start + (cut - c.start);
    write_layer(&l, &mut c);
    let mut work = tl.tracks[ti].clone();
    work.replace(c);
    if !work.is_consistent() {
        return Err(EditError::Collision);
    }
    tl.tracks[ti] = work;
    Ok(())
}

#[cfg(test)]
mod tests;
