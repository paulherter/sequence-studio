// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Transition.swift (ResolvedTransition, TransitionEnvelope, Track resolution and evaluation helpers)

//! What a stored transition currently is on the timeline, and what a track shows at one instant.

use super::{
    Border, RenderStyle, TrackElementTransitions, TransitionExt, TransitionKindExt, TransitionMix, TransitionRender,
    TransitionStingerExt, dissolve_weight,
};
use crate::transition_feel::TransitionFeelExt;
use sq_core_audio::ClipAudioChainExt;
use sq_core_model::{
    Clip, Track, TrackKind, Transition, TransitionAlignment, TransitionDirection, TransitionKind, TransitionStinger,
};
use sq_core_time::{EasingCurve, Id, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// More frames than any clip holds: "no limit" in the handle arithmetic.
const UNBOUNDED_FRAMES: i64 = 1 << 40;

/// What a transition currently is on the timeline.
#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedTransition {
    /// The transition's id.
    pub id: Id,
    /// Style.
    pub kind: TransitionKind,
    /// Alignment around the cut.
    pub alignment: TransitionAlignment,
    /// Clip before the cut.
    pub outgoing: Option<Id>,
    /// Clip after the cut.
    pub incoming: Option<Id>,
    /// The cut, or for a single-sided transition the clip edge it sits on.
    pub cut: Time,
    /// The playing span.
    pub span: TimeRange,
    /// Part of the span before `cut`.
    pub before: Time,
    /// Part of the span after `cut`; `before + after == span.duration`.
    pub after: Time,
    /// What the transition asked for.
    pub requested_duration: Time,
    /// Frame duration of the sequence.
    pub frame_duration: Time,
    /// Effective curve (the kind's default filled in).
    pub easing: EasingCurve,
    /// Effective render direction.
    pub direction: TransitionDirection,
    /// Effective softness.
    pub softness: f64,
    /// Effective motion blur.
    pub motion_blur: f64,
    /// `Stinger`: the clip played over the cut.
    pub stinger: Option<TransitionStinger>,
    /// `Stinger`: media time at `span.start` (above zero when a short clip next to the cut trimmed the stinger's head).
    pub stinger_start: Time,
    /// Through Color: the color the picture dips to; `None` = the kind's own.
    pub color: Option<Vec<u8>>,
    /// Zoom In / Out with a stored Amount (scale, 1.1 = 110 %): the settling zoom. `None` = the older look.
    pub zoom_amount: Option<f64>,
    /// Border along the moving edge.
    pub border_width: Option<f64>,
    /// Border color.
    pub border_color: Option<Vec<u8>>,
    /// Frames of the span before the cut where the incoming clip shows its first frame, held (derived, never stored).
    pub held_before: i64,
    /// Frames of the span after the cut where the outgoing clip shows its last frame, held.
    pub held_after: i64,
}

impl ResolvedTransition {
    /// Length of the span.
    pub fn duration(&self) -> Time {
        self.span.duration
    }

    /// Whole frames of the span.
    pub fn frames(&self) -> i64 {
        self.span.duration.frame_index(self.frame_duration)
    }

    /// The handles ran short and `duration` is less than requested, or frames are held.
    pub fn is_clamped(&self) -> bool {
        self.span.duration < self.requested_duration || self.held_frames() > 0
    }

    /// All held frames of the span (either side).
    pub fn held_frames(&self) -> i64 {
        self.held_before + self.held_after
    }

    /// Some frames are held.
    pub fn is_held(&self) -> bool {
        self.held_frames() > 0
    }

    /// One side is missing.
    pub fn is_single_sided(&self) -> bool {
        self.outgoing.is_none() || self.incoming.is_none()
    }

    /// Frame index inside the span (0 ..< frames) for timeline time `t`; `None` outside.
    pub fn frame_index_at(&self, t: Time) -> Option<i64> {
        if !self.span.contains(t) {
            return None;
        }
        Some((t - self.span.start).frame_index(self.frame_duration).max(0).min(self.frames() - 1))
    }

    /// The render style of this transition for `TransitionRender::evaluate`; `border` only where the kind draws one.
    pub fn render_style(&self, has_outgoing: bool, has_incoming: bool, border: Option<Border>) -> RenderStyle<'_> {
        RenderStyle {
            has_outgoing,
            has_incoming,
            zoom_amount: self.zoom_amount.unwrap_or(TransitionRender::ZOOM_AMOUNT),
            zoom_settles: self.zoom_amount.is_some(),
            border,
            ..RenderStyle::new(self.kind, self.direction, self.softness, self.motion_blur, &self.easing)
        }
    }
}

/// Which clip a gain envelope belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EnvelopeRole {
    /// The clip before the cut.
    Outgoing,
    /// The clip after the cut.
    Incoming,
}

/// The gain curve one clip's audio follows inside a transition span.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TransitionEnvelope {
    /// Kind.
    pub kind: TransitionKind,
    /// The span.
    pub span: TimeRange,
    /// Which side of the cut the clip is on.
    pub role: EnvelopeRole,
}

impl TransitionEnvelope {
    /// Progress through the span at `t`, 0 before it and 1 after it.
    pub fn progress(&self, t: Time) -> f64 {
        if t <= self.span.start {
            return 0.0;
        }
        if t >= self.span.end() {
            return 1.0;
        }
        let a = t - self.span.start;
        let d = self.span.duration;
        a.value() as f64 * d.timescale() as f64 / (a.timescale() as f64 * d.value() as f64)
    }

    /// Gain of the clip at `t`.
    pub fn gain(&self, t: Time) -> f64 {
        let (o, i) = TransitionMix::audio_gains(self.kind, self.progress(t));
        if self.role == EnvelopeRole::Outgoing { o } else { i }
    }
}

/// Per clip: how far its audio extends into its handles and the gain envelopes of its audio transitions.
#[derive(Clone, Debug, PartialEq)]
pub struct AudioTransitionInfo {
    /// Audio read before the clip's start.
    pub head: Time,
    /// Audio read after the clip's end.
    pub tail: Time,
    /// Gain envelopes.
    pub envelopes: Vec<TransitionEnvelope>,
}

impl Default for AudioTransitionInfo {
    fn default() -> Self {
        AudioTransitionInfo { head: Time::ZERO, tail: Time::ZERO, envelopes: Vec::new() }
    }
}

/// A motion transition in progress on a track.
#[derive(Clone, Debug, PartialEq)]
pub struct MotionEntry {
    /// The transition.
    pub id: Id,
    /// How the two sides combine on this frame.
    pub render: TransitionRender,
    /// The clip that is the second side, so a single-sided one knows its role.
    pub incoming: Option<Id>,
}

/// What a track shows at one instant: the solid dip layer (bottom), the clips with an opacity factor and the transition node.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct VideoEntries {
    /// A dip in progress: transition id and dip color.
    pub dip: Option<(Id, [u8; 3])>,
    /// A cross dissolve of two clips (the compositor's `pair` node).
    pub pair: Option<Id>,
    /// A motion transition in progress; its clips are drawn at opacity 1.
    pub motion: Option<MotionEntry>,
    /// The clips with their opacity.
    pub items: Vec<(Clip, f64)>,
    /// A Stinger in progress: `items` are then the clip on screen and the stinger clip on top.
    pub stinger: Option<Id>,
}

/// The frame counts a resolved transition is made of.
struct Portions {
    d: i64,
    b: i64,
    a: i64,
    held_before: i64,
    held_after: i64,
}

fn frames_of(t: Time, fd: Time) -> i64 {
    t.frame_index(fd).max(0)
}

fn cap(t: Option<Time>, fd: Time) -> i64 {
    t.map_or(UNBOUNDED_FRAMES, |t| frames_of(t, fd).min(UNBOUNDED_FRAMES))
}

/// Largest duration in frames the handles allow for this alignment (0 = none), given the portion limits.
fn max_frames(alignment: TransitionAlignment, cb: i64, before_max: i64, after_max: i64) -> i64 {
    match alignment {
        TransitionAlignment::Center => (2 * before_max + 1).min(2 * after_max),
        TransitionAlignment::StartAtCut => after_max,
        TransitionAlignment::EndAtCut => before_max,
        TransitionAlignment::Custom if cb <= before_max => cb + after_max,
        TransitionAlignment::Custom => before_max,
    }
}

/// Parts before and after the cut for a duration of `d` frames.
fn split(alignment: TransitionAlignment, cb: i64, d: i64) -> (i64, i64) {
    let b = match alignment {
        TransitionAlignment::Center => d / 2,
        TransitionAlignment::StartAtCut => 0,
        TransitionAlignment::EndAtCut => d,
        TransitionAlignment::Custom => cb.min(d),
    };
    (b, d - b)
}

fn make(tr: &Transition, fd: Time, want: i64, cut: Time, p: Portions) -> ResolvedTransition {
    ResolvedTransition {
        id: tr.id,
        kind: tr.kind,
        alignment: tr.alignment,
        outgoing: tr.outgoing,
        incoming: tr.incoming,
        cut,
        span: TimeRange::new(cut - fd * p.b, fd * p.d),
        before: fd * p.b,
        after: fd * p.a,
        requested_duration: fd * want,
        frame_duration: fd,
        easing: tr.effective_easing(),
        direction: tr.render_direction(),
        softness: tr.effective_softness(),
        motion_blur: tr.effective_motion_blur(),
        stinger: None,
        stinger_start: Time::ZERO,
        color: tr.color.clone(),
        zoom_amount: tr.zoom_amount(),
        border_width: tr.border_width,
        border_color: tr.border_color.clone(),
        held_before: p.held_before,
        held_after: p.held_after,
    }
}

/// Resolution of transitions against a track's clips.
pub trait TrackTransitions {
    /// The current, playable form of every transition of this track, in timeline order.
    fn resolved_transitions(&self, fd: Time) -> Vec<ResolvedTransition>;
    /// `tr` resolved against the current clips; `None` when its cut or clip is gone or no frame fits. This is the full
    /// resolution behind `Track::prune_transitions` (which keeps a transition exactly when this is `Some`).
    fn resolve(&self, tr: &Transition, fd: Time) -> Option<ResolvedTransition>;
    /// `resolve` with a start `hint` for the clip lookup and, when `budgeted`, respecting the clip's other (earlier)
    /// transition: a clip holds at most its own length of transition frames; the head transition keeps what it asks for, the
    /// tail one gets what is left.
    fn resolve_near(
        &self,
        tr: &Transition,
        fd: Time,
        hint: Option<usize>,
        budgeted: bool,
    ) -> Option<ResolvedTransition>;
    /// Alignment a new transition gets: a centered video transition at a cut with media beyond the cut on one side only moves
    /// wholly onto that side when that handle holds the requested length, so no frame is held. Otherwise the alignment asked
    /// for.
    fn applied_alignment(&self, tr: &Transition, fd: Time) -> TransitionAlignment;
    /// Largest whole-frame duration the handles allow for `tr` right now (0 = nothing fits).
    fn max_transition_frames(&self, tr: &Transition, fd: Time) -> i64;
    /// Removes the other transitions of `tr`'s class (element or not) on any edge `tr` uses.
    fn remove_transitions_sharing_edges_with(&mut self, tr: &Transition);
    /// Index of the first clip that ends after `t` (binary search; clips are sorted and never overlap).
    fn clip_index_ending_after(&self, t: Time) -> usize;
    /// What the track shows at `t`. Element transitions (Move / Zoom / Pop) are not drawn here: every returned clip carries
    /// their motion effect instead.
    fn video_entries(&self, t: Time, fd: Time) -> VideoEntries;
    /// Per clip: how far its audio extends into its handles and its gain envelopes. Only for the transitions that touch
    /// `ids`.
    fn audio_transition_info(&self, fd: Time, ids: &BTreeSet<Id>) -> BTreeMap<Id, AudioTransitionInfo>;
}

/// Index of clip `id`, looking next to `hint` first (the evaluation loops already know where they are).
fn clip_index(clips: &[Clip], id: Id, hint: Option<usize>) -> Option<usize> {
    if let Some(h) = hint.filter(|_| !clips.is_empty()) {
        let (lo, hi) = (h.saturating_sub(2), (h + 2).min(clips.len() - 1));
        if let Some(i) = (lo..=hi).find(|i| clips[*i].id == id) {
            return Some(i);
        }
    }
    clips.iter().position(|c| c.id == id)
}

/// Frames of clip `o` taken by the transition of the same class (element or not) that sits on its head (the earlier one),
/// before any budgeting.
fn head_portion(track: &Track, o: Id, except: Id, element: bool, fd: Time) -> i64 {
    track
        .transitions
        .iter()
        .find(|h| h.incoming == Some(o) && h.id != except && h.kind.is_element() == element)
        .and_then(|h| track.resolve_near(h, fd, None, false))
        .map_or(0, |r| r.after.frame_index(fd))
}

impl TrackTransitions for Track {
    fn resolved_transitions(&self, fd: Time) -> Vec<ResolvedTransition> {
        let mut out: Vec<ResolvedTransition> = self.transitions.iter().filter_map(|tr| self.resolve(tr, fd)).collect();
        out.sort_by_key(|r| r.span.start);
        out
    }

    fn resolve(&self, tr: &Transition, fd: Time) -> Option<ResolvedTransition> {
        self.resolve_near(tr, fd, None, true)
    }

    fn resolve_near(
        &self,
        tr: &Transition,
        fd: Time,
        hint: Option<usize>,
        budgeted: bool,
    ) -> Option<ResolvedTransition> {
        if tr.kind.track_kind() != self.kind {
            return None;
        }
        let clips = self.clips();
        let want = frames_of(tr.duration, fd).max(1);
        let cb = frames_of(tr.custom_before, fd);
        let taken = |o: Id| if budgeted { head_portion(self, o, tr.id, tr.kind.is_element(), fd) } else { 0 };
        let touching = |o: Id, i: Id| {
            let oi = clip_index(clips, o, hint)?;
            (oi + 1 < clips.len() && clips[oi + 1].id == i && clips[oi].timeline().end() == clips[oi + 1].start)
                .then_some(oi)
        };

        if tr.kind.is_stinger() {
            // The stinger never shows handle frames: A plays to the edit, B from it. Its cut frame sits on the edit; a clip
            // shorter than its part trims the stinger on that side (a head trim moves `stinger_start`).
            let oi = touching(tr.outgoing?, tr.incoming?)?;
            let (out, inc) = (&clips[oi], &clips[oi + 1]);
            let fraction = tr.stinger.as_ref().map_or(0.5, |s| s.cut_fraction);
            let cut = want.min((want as f64 * fraction).round() as i64);
            let b_max = (frames_of(out.duration(), fd) - taken(out.id)).max(0);
            let b = cut.min(b_max);
            let a = (want - cut).min(frames_of(inc.duration(), fd));
            if b + a < 1 {
                return None;
            }
            let mut r = make(tr, fd, want, inc.start, Portions { d: b + a, b, a, held_before: 0, held_after: 0 });
            r.stinger = tr.stinger.clone();
            r.stinger_start = fd * (cut - b);
            return Some(r);
        }

        match (tr.outgoing, tr.incoming) {
            (Some(o), Some(i)) => {
                let oi = touching(o, i)?;
                let (out, inc) = (&clips[oi], &clips[oi + 1]);
                let out_span = (frames_of(out.duration(), fd) - taken(o)).max(0);
                // Video, no media beyond the cut on a side: that side holds its edge frame instead of refusing, on one side
                // or both. Only the clips' own lengths bound the span then. Audio never holds. A small non-zero handle still
                // shortens the transition.
                let (inc_head, out_tail) = (cap(inc.head_handle(), fd), cap(out.tail_room(), fd));
                let hold_before = self.kind == TrackKind::Video && inc_head == 0;
                let hold_after = self.kind == TrackKind::Video && out_tail == 0;
                let b_max = (if hold_before { UNBOUNDED_FRAMES } else { inc_head }).min(out_span);
                let a_max = (if hold_after { UNBOUNDED_FRAMES } else { out_tail }).min(frames_of(inc.duration(), fd));
                let d = want.min(max_frames(tr.alignment, cb, b_max, a_max));
                if d < 1 {
                    return None;
                }
                let (b, a) = split(tr.alignment, cb, d);
                let held = Portions {
                    d,
                    b,
                    a,
                    held_before: if hold_before { b } else { 0 },
                    held_after: if hold_after { a } else { 0 },
                };
                Some(make(tr, fd, want, inc.start, held))
            }
            (None, Some(i)) => {
                let c = &clips[clip_index(clips, i, hint)?];
                let d = want.min(frames_of(c.duration(), fd));
                (d >= 1).then(|| make(tr, fd, want, c.start, Portions { d, b: 0, a: d, held_before: 0, held_after: 0 }))
            }
            (Some(o), None) => {
                let c = &clips[clip_index(clips, o, hint)?];
                let d = want.min((frames_of(c.duration(), fd) - taken(o)).max(0));
                (d >= 1).then(|| {
                    make(tr, fd, want, c.timeline().end(), Portions { d, b: d, a: 0, held_before: 0, held_after: 0 })
                })
            }
            (None, None) => None,
        }
    }

    fn applied_alignment(&self, tr: &Transition, fd: Time) -> TransitionAlignment {
        if self.kind != TrackKind::Video || tr.alignment != TransitionAlignment::Center || tr.kind.is_stinger() {
            return tr.alignment;
        }
        let (Some(o), Some(i)) = (tr.outgoing, tr.incoming) else { return tr.alignment };
        let (Some(oc), Some(ic)) = (self.clip(o), self.clip(i)) else { return tr.alignment };
        let no_tail = oc.tail_room().is_some_and(|t| t.frame_index(fd) <= 0);
        let no_head = ic.head_handle().is_some_and(|t| t.frame_index(fd) <= 0);
        if no_tail == no_head {
            return tr.alignment;
        }
        let mut probe = tr.clone();
        probe.alignment = if no_tail { TransitionAlignment::EndAtCut } else { TransitionAlignment::StartAtCut };
        match self.resolve(&probe, fd) {
            Some(r) if r.span.duration >= probe.duration && !r.is_held() => probe.alignment,
            _ => tr.alignment,
        }
    }

    fn max_transition_frames(&self, tr: &Transition, fd: Time) -> i64 {
        let mut probe = tr.clone();
        probe.duration = fd * UNBOUNDED_FRAMES;
        self.resolve(&probe, fd).map_or(0, |r| r.frames())
    }

    fn remove_transitions_sharing_edges_with(&mut self, tr: &Transition) {
        self.transitions.retain(|other| {
            let shares = (tr.outgoing.is_some() && other.outgoing == tr.outgoing)
                || (tr.incoming.is_some() && other.incoming == tr.incoming);
            !(other.id != tr.id && other.kind.is_element() == tr.kind.is_element() && shares)
        });
    }

    fn clip_index_ending_after(&self, t: Time) -> usize {
        self.clips().partition_point(|c| c.timeline().end() <= t)
    }

    fn video_entries(&self, t: Time, fd: Time) -> VideoEntries {
        let mut r = mix_entries(self, t, fd);
        if self.transitions.iter().any(|tr| tr.kind.is_element()) {
            r.items = r.items.into_iter().map(|(c, o)| (self.clip_with_element_transitions(&c, t, fd), o)).collect();
        }
        r
    }

    fn audio_transition_info(&self, fd: Time, ids: &BTreeSet<Id>) -> BTreeMap<Id, AudioTransitionInfo> {
        let mut info: BTreeMap<Id, AudioTransitionInfo> = BTreeMap::new();
        if self.kind != TrackKind::Audio || self.transitions.is_empty() {
            return info;
        }
        // Disguise Voice: a clip without the effect never sounds in its handle next to a clip that has it. That handle is the
        // source under the disguised neighbor, so playing it would let the original voice through the fade. The clip ends at
        // its own edge there; the disguised side still fades through its handle.
        let silent_handle = |id: Id, other: Option<Id>| {
            let other_disguised = other.and_then(|o| self.clip(o)).is_some_and(|c| c.has_disguise_voice());
            other_disguised && !self.clip(id).is_some_and(|c| c.has_disguise_voice())
        };
        let touches = |x: Option<Id>| x.is_some_and(|x| ids.contains(&x));
        for tr in self.transitions.iter().filter(|tr| touches(tr.outgoing) || touches(tr.incoming)) {
            let Some(r) = self.resolve(tr, fd) else { continue };
            if let Some(o) = r.outgoing {
                let e = info.entry(o).or_default();
                if !silent_handle(o, r.incoming) {
                    e.tail = e.tail.max(r.after);
                }
                e.envelopes.push(TransitionEnvelope { kind: r.kind, span: r.span, role: EnvelopeRole::Outgoing });
            }
            if let Some(i) = r.incoming {
                let e = info.entry(i).or_default();
                if !silent_handle(i, r.outgoing) {
                    e.head = e.head.max(r.before);
                }
                e.envelopes.push(TransitionEnvelope { kind: r.kind, span: r.span, role: EnvelopeRole::Incoming });
            }
        }
        info
    }
}

fn mix_entries(track: &Track, t: Time, fd: Time) -> VideoEntries {
    let clips = track.clips();
    let k = track.clip_index_ending_after(t);
    let base = clips.get(k).filter(|c| c.timeline().contains(t) && c.is_enabled);
    let base_items = || base.map(|c| vec![(c.clone(), 1.0)]).unwrap_or_default();
    if track.transitions.is_empty() {
        return VideoEntries { items: base_items(), ..VideoEntries::default() };
    }
    // Only transitions on the clip at `t` and its neighbors can reach `t` (a span never leaves the clips it joins).
    let near: BTreeSet<Id> = clips[k.saturating_sub(1)..(k + 2).min(clips.len())].iter().map(|c| c.id).collect();
    let in_near = |x: Option<Id>| x.is_some_and(|x| near.contains(&x));
    for tr in
        track.transitions.iter().filter(|tr| !tr.kind.is_element() && (in_near(tr.outgoing) || in_near(tr.incoming)))
    {
        let Some(r) = track.resolve_near(tr, fd, Some(k), true) else { continue };
        let Some(i) = r.frame_index_at(t) else { continue };
        let enabled_clip = |id: Option<Id>| id.and_then(|id| track.clip(id)).filter(|c| c.is_enabled);
        if r.kind.is_stinger() {
            let Some(st) = r.stinger.as_ref() else { break }; // nothing picked yet: a plain cut
            let mut items = Vec::new();
            let side = if t < r.cut { r.outgoing } else { r.incoming };
            if let Some(c) = enabled_clip(side) {
                items.push((c.clone(), 1.0));
            }
            items.push((st.clip(r.id, r.span, r.stinger_start), 1.0));
            return VideoEntries { items, stinger: Some(r.id), ..VideoEntries::default() };
        }
        if r.kind.is_motion() {
            // A side counts only when its clip is there and enabled (a disabled A: B plays its head-only half).
            let (oc, ic) = (enabled_clip(r.outgoing), enabled_clip(r.incoming));
            let border =
                if r.kind.uses_border() { Border::new(r.border_width, r.border_color.as_deref()) } else { None };
            let style = r.render_style(oc.is_some(), ic.is_some(), border);
            let render = TransitionRender::evaluate(&style, i, r.frames());
            let items = [oc, ic].into_iter().flatten().map(|c| (c.clone(), 1.0)).collect();
            return VideoEntries {
                motion: Some(MotionEntry { id: r.id, render, incoming: r.incoming }),
                items,
                ..VideoEntries::default()
            };
        }
        let w = dissolve_weight(&r.easing, i, r.frames());
        let dip_kind = r.kind.is_dip();
        let dip = dip_kind.then(|| (r.id, TransitionMix::dip_color(r.kind, r.color.as_deref())));
        match (r.outgoing, r.incoming) {
            (Some(o), Some(inc)) => {
                let (Some(oc), Some(ic)) = (track.clip(o), track.clip(inc)) else { continue };
                // A disabled clip next to the cut never shows: the other side fades alone.
                let mut items = Vec::new();
                let m = TransitionMix::video(r.kind, w);
                if oc.is_enabled {
                    items.push((oc.clone(), if dip_kind { m.outgoing } else { 1.0 - w }));
                }
                if ic.is_enabled {
                    items.push((ic.clone(), if dip_kind { m.incoming } else { w }));
                }
                if dip_kind {
                    return VideoEntries { dip, items, ..VideoEntries::default() };
                }
                // Cross dissolve: premultiplied sum A*(1-w) + B*w in linear light (the compositor's `pair` node).
                let pair = (items.len() == 2).then_some(r.id);
                return VideoEntries { pair, items, ..VideoEntries::default() };
            }
            (None, Some(inc)) => {
                let Some(ic) = track.clip(inc) else { continue };
                let items = if ic.is_enabled { vec![(ic.clone(), w)] } else { Vec::new() };
                return VideoEntries { dip, items, ..VideoEntries::default() };
            }
            (Some(o), None) => {
                let Some(oc) = track.clip(o) else { continue };
                let items = if oc.is_enabled { vec![(oc.clone(), 1.0 - w)] } else { Vec::new() };
                return VideoEntries { dip, items, ..VideoEntries::default() };
            }
            (None, None) => continue,
        }
    }
    VideoEntries { items: base_items(), ..VideoEntries::default() }
}
