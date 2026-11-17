//! Transitions on cuts and clip edges: apply defaults, add, edit, user defaults, stingers, remove.

use std::collections::{BTreeMap, BTreeSet};

use sq_core_edit::stinger::StingerExt;
use sq_core_effects::transition::EffectDefaultsTransitionExt;
use sq_core_effects::transition::{
    ResolvedTransition, TimelineTransitions, TrackTransitions, TransitionChange, TransitionKindExt, TransitionPoint,
};
use sq_core_effects::transition_feel::TimelineTransitionFeel;
use sq_core_model::{
    AudioTag, ClipEdge, EditError, MediaRef, Track, TrackKind, Transition, TransitionAlignment, TransitionDirection,
    TransitionKind,
};
use sq_core_time::{EasingCurve, Id, Time};

use super::transition_targets::{TransitionDefaults, TransitionTargets};
use crate::AudioRoleDefaults;
use sq_core_audio::audio_role::TrackRoleExt as _;
use sq_core_model::effect_defaults::EffectDefaults;

use super::effect_support::transition_kind_raw;
use crate::{Change, EdgeSelection, EditorSession};

/// Which track kinds a default transition goes on.
// Swift: EditorSession+Transitions.swift:7
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransitionScope {
    Video,
    Audio,
    Both,
}

impl TransitionScope {
    // Swift: EditorSession+Transitions.swift:9
    pub fn kinds(self) -> &'static [TrackKind] {
        match self {
            TransitionScope::Video => &[TrackKind::Video],
            TransitionScope::Audio => &[TrackKind::Audio],
            TransitionScope::Both => &[TrackKind::Video, TrackKind::Audio],
        }
    }
}

/// A transition with its track and its resolved span.
#[derive(Clone, Debug, PartialEq)]
pub struct TransitionInfo {
    pub track: Id,
    pub transition: Transition,
    pub resolved: Option<ResolvedTransition>,
}

/// Optional changes of a transition's look (Swift `setTransitionStyle` parameters).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TransitionStyleChange {
    pub easing: Option<EasingCurve>,
    pub direction: Option<TransitionDirection>,
    pub softness: Option<f64>,
    pub motion_blur: Option<f64>,
    pub color: Option<Vec<u8>>,
    pub reversed: Option<bool>,
    pub border_width: Option<f64>,
    pub border_color: Option<Vec<u8>>,
}

/// Optional changes of a transition's timing and kind (Swift `setTransition` parameters).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TransitionTimingChange {
    pub duration: Option<Time>,
    pub alignment: Option<TransitionAlignment>,
    pub custom_before: Option<Time>,
    pub kind: Option<TransitionKind>,
}

/// Role (audio tag) of the clip a transition point sits on: the incoming clip of a cut, else the clip itself.
// Swift: EditorSession+Transitions.swift:91
fn role_tag_of(point: TransitionPoint, track: &Track) -> Option<AudioTag> {
    let id = match point {
        TransitionPoint::Cut { incoming, .. } => incoming,
        TransitionPoint::Head(c) | TransitionPoint::Tail(c) => c,
    };
    track.clip(id).and_then(|c| track.role_of(c))
}

impl EditorSession {
    // Swift: EditorSession+Transitions.swift:15
    pub fn transition_info(&self, id: Id) -> Option<TransitionInfo> {
        let t = self.active_timeline()?;
        let (track_id, transition) = t.transition(id)?;
        let resolved =
            t.track(track_id)?.resolved_transitions(t.format.frame_duration).into_iter().find(|r| r.id == id);
        Some(TransitionInfo { track: track_id, transition, resolved })
    }
    // Swift: EditorSession+Transitions.swift:21
    pub fn select_transition(&mut self, id: Option<Id>, keep_clips: bool) {
        if self.selected_transition == id {
            return;
        }
        self.selected_transition = id;
        if id.is_some() && !keep_clips && (!self.selection.is_empty() || !self.caption_selection.is_empty()) {
            self.select(BTreeSet::new(), BTreeSet::new());
        }
        self.notify(Change::SELECTION);
    }
    /// Puts the default transition on every target; returns how many were applied.
    // Swift: EditorSession+Transitions.swift:31
    pub fn apply_default_transitions(
        &mut self,
        scope: TransitionScope,
        edges: Option<&EdgeSelection>,
        only: Option<TransitionKind>,
        defaults: &TransitionDefaults,
    ) -> i64 {
        self.apply_default_transitions_with_roles(scope, edges, only, defaults, &AudioRoleDefaults::standard())
    }

    /// `apply_default_transitions` with the per-role audio defaults of the Preferences: a default audio transition takes the
    /// crossfade kind, and a tagged clip brings its role's length (dialogue short, music long) unless the user set a default.
    // Swift: EditorSession+Transitions.swift:31
    pub fn apply_default_transitions_with_roles(
        &mut self,
        scope: TransitionScope,
        edges: Option<&EdgeSelection>,
        only: Option<TransitionKind>,
        defaults: &TransitionDefaults,
        roles: &AudioRoleDefaults,
    ) -> i64 {
        let Some(t) = self.active_timeline() else { return 0 };
        let element_only = only.is_some_and(|k| k.is_element());
        let targets = TransitionTargets::resolve(t, scope.kinds(), edges, &self.selection, self.playhead, element_only);
        if targets.is_empty() {
            self.set_error(if scope == TransitionScope::Audio {
                "Target an audio track, or select an edit, to apply a transition."
            } else {
                "Target a track, or select an edit, to apply a transition."
            });
            return 0;
        }
        let both_ends = if element_only { Self::clips_with_both_ends(&targets) } else { BTreeSet::new() };
        let user = self.effect_defaults.clone();
        let name = match only {
            Some(k) => format!("Apply {}", k.name()),
            None if targets.len() == 1 => "Apply Transition".to_string(),
            None => "Apply Transitions".to_string(),
        };
        let mut applied = 0;
        let ok = self.attempt_keyed_ids(&name, None, |tl, ids| {
            for target in &targets {
                let Some(track) = tl.track(target.track) else { continue };
                let kind = only.unwrap_or(if track.kind == TrackKind::Audio {
                    roles.crossfade_kind
                } else {
                    TransitionKind::default_kind_for(track.kind)
                });
                if kind.track_kind() != track.kind {
                    continue;
                }
                let fd = tl.format.frame_duration;
                let mut d = user
                    .transition(kind)
                    .map(|u| u.duration)
                    .unwrap_or_else(|| Self::factory_transition_duration(kind, fd, defaults));
                if only.is_none()
                    && track.kind == TrackKind::Audio
                    && user.transition(kind).is_none()
                    && let Some(tag) = role_tag_of(target.point, track)
                {
                    d = roles.transition_duration(Some(tag), defaults.audio_seconds, fd);
                }
                // Start and end of one clip: half the clip each at most, so the Out is not starved by the In.
                if let Some(c) = element_clip(target.point).filter(|c| both_ends.contains(c))
                    && let Some(clip) = track.clip(c)
                {
                    d = <sq_core_model::Timeline as TimelineTransitions>::element_duration(
                        d,
                        clip.duration(),
                        true,
                        fd,
                    );
                }
                if let Ok(id) =
                    tl.add_transition_at(target.point, kind, target.track, d, TransitionAlignment::Center, ids)
                {
                    // The user's default look, else the factory look (new transitions only).
                    let _ = match user.transition(kind) {
                        Some(u) => tl.apply_transition_default(u, id),
                        None => tl.apply_factory_look(id, true),
                    };
                    applied += 1;
                }
            }
            if applied == 0 { Err(EditError::InsufficientMedia) } else { Ok(()) }
        });
        if ok { applied } else { 0 }
    }

    /// Clips that have both their start and their end transition among `targets`.
    pub(crate) fn clips_with_both_ends(targets: &[super::transition_targets::TransitionTarget]) -> BTreeSet<Id> {
        let heads: BTreeSet<Id> = targets
            .iter()
            .filter_map(|t| if let TransitionPoint::Head(c) = t.point { Some(c) } else { None })
            .collect();
        let tails: BTreeSet<Id> = targets
            .iter()
            .filter_map(|t| if let TransitionPoint::Tail(c) = t.point { Some(c) } else { None })
            .collect();
        heads.intersection(&tails).copied().collect()
    }

    /// The length a new transition of `kind` gets without a user default: the kind's own, else the Settings length.
    pub(crate) fn factory_transition_duration(kind: TransitionKind, fd: Time, defaults: &TransitionDefaults) -> Time {
        kind.preset_duration(fd).unwrap_or_else(|| defaults.duration(kind.track_kind(), fd))
    }
    // Swift: EditorSession+Transitions.swift:75
    pub fn add_transition(
        &mut self,
        kind: TransitionKind,
        track: Id,
        point: TransitionPoint,
        alignment: TransitionAlignment,
        defaults: &TransitionDefaults,
    ) -> Option<Id> {
        let user = self.effect_defaults.transition(kind).cloned();
        let mut made = None;
        let ok = self.attempt_keyed_ids(&format!("Apply {}", kind.name()), None, |t, ids| {
            let fd = t.format.frame_duration;
            let d = user
                .as_ref()
                .map(|u| u.duration)
                .unwrap_or_else(|| Self::factory_transition_duration(kind, fd, defaults));
            let id = t.add_transition_at(point, kind, track, d, alignment, ids)?;
            match &user {
                Some(u) => t.apply_transition_default(u, id)?,
                None => t.apply_factory_look(id, true)?,
            }
            made = Some(id);
            Ok(())
        });
        if ok {
            if let Some(id) = made {
                self.select_transition(Some(id), false);
            }
            return made;
        }
        None
    }
    // Swift: EditorSession+Transitions.swift:104
    pub fn has_transition_default(&self, kind: TransitionKind) -> bool {
        self.effect_defaults.has_default_transition(&transition_kind_raw(kind))
    }
    // Swift: EditorSession+Transitions.swift:108
    pub fn use_transition_as_default(&mut self, id: Id) -> bool {
        let Some(tr) =
            self.active_timeline().and_then(|t| t.transition(id)).map(|(_, tr)| tr).filter(|tr| !tr.kind.is_stinger())
        else {
            return false;
        };
        let mut d = self.effect_defaults.clone();
        d.set_default_from(&tr);
        self.change_effect_defaults(d);
        true
    }
    // Swift: EditorSession+Transitions.swift:118
    pub fn reset_transition_default_to_factory(&mut self, kind: TransitionKind) {
        let mut d = self.effect_defaults.clone();
        d.remove_default_transition(&transition_kind_raw(kind));
        self.change_effect_defaults(d);
    }

    /// Stores new effect defaults.
    /// Like Swift, a real change also fires `onEffectDefaultsChange` (`SessionEvent::EffectDefaultsChange`) so the app saves it.
    // Swift: EditorSession+Transitions.swift:131
    pub(crate) fn change_effect_defaults(&mut self, d: EffectDefaults) {
        if d != self.effect_defaults {
            self.effect_defaults = d.clone();
            self.emit(crate::SessionEvent::EffectDefaultsChange(d));
        }
    }
    // Swift: EditorSession+Transitions.swift:125
    pub fn reset_transition(&mut self, id: Id, defaults: &TransitionDefaults) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let Some((_, tr)) = t.transition(id) else { return false };
        let fd = t.format.frame_duration;
        let user = self.effect_defaults.transition(tr.kind).cloned();
        let factory = Self::factory_transition_duration(tr.kind, fd, defaults);
        self.attempt_keyed_ids(&format!("Reset {}", tr.kind.name()), None, |t, _| {
            t.reset_transition(id, user.as_ref(), factory)
        })
    }
    // Swift: EditorSession+Transitions.swift:155
    pub fn add_element_transition(
        &mut self,
        kind: TransitionKind,
        track: Id,
        clip: Id,
        edges: &[ClipEdge],
        defaults: &TransitionDefaults,
    ) -> Vec<Id> {
        if !kind.is_element() || edges.is_empty() {
            return Vec::new();
        }
        let user = self.effect_defaults.transition(kind).cloned();
        let mut made: Vec<Id> = Vec::new();
        let ok = self.attempt_keyed_ids(&format!("Apply {}", kind.name()), None, |t, ids| {
            let fd = t.format.frame_duration;
            let d = user
                .as_ref()
                .map(|u| u.duration)
                .unwrap_or_else(|| Self::factory_transition_duration(kind, fd, defaults));
            made = t.add_element_transitions(kind, track, clip, edges, d, ids)?;
            for id in &made {
                match &user {
                    Some(u) => t.apply_transition_default(u, *id)?,
                    None => t.apply_factory_look(*id, true)?,
                }
            }
            Ok(())
        });
        if !ok {
            return Vec::new();
        }
        if let Some(first) = made.first() {
            self.select_transition(Some(*first), false);
        }
        made
    }
    // Swift: EditorSession+Transitions.swift:172
    pub fn set_transition_params(&mut self, id: Id, params: &BTreeMap<String, f64>, continues_gesture: bool) {
        let key = self.gesture_key("transition", id, continues_gesture);
        self.attempt_keyed_ids("Change Transition", Some(&key), |t, _| t.set_transition_params(id, params, false));
    }
    // Swift: EditorSession+Transitions.swift:179
    pub fn set_transition(&mut self, id: Id, change: &TransitionTimingChange, continues_gesture: bool) {
        let key = self.gesture_key("transition", id, continues_gesture);
        self.attempt_keyed_ids("Change Transition", Some(&key), |t, _| {
            // A new kind starts from its factory look (parameters; the curve unless it was an own one).
            if let Some(kind) = change.kind {
                t.change_transition_kind(id, kind)?;
            }
            t.set_transition(
                id,
                &TransitionChange {
                    duration: change.duration,
                    alignment: change.alignment,
                    custom_before: change.custom_before,
                    ..TransitionChange::default()
                },
            )
        });
    }
    // Swift: EditorSession+Transitions.swift:190
    pub fn set_transition_style(&mut self, id: Id, change: &TransitionStyleChange, continues_gesture: bool) {
        let key = self.gesture_key("transition", id, continues_gesture);
        let c = change.clone();
        self.attempt_keyed_ids("Change Transition", Some(&key), |t, _| {
            t.set_transition(
                id,
                &TransitionChange {
                    easing: c.easing,
                    direction: c.direction,
                    softness: c.softness,
                    motion_blur: c.motion_blur,
                    color: c.color,
                    reversed: c.reversed,
                    border_width: c.border_width,
                    border_color: c.border_color,
                    ..TransitionChange::default()
                },
            )
        });
    }
    /// Clips that can serve as a stinger, by name.
    // Swift: EditorSession+Transitions.swift:202
    pub fn stinger_candidates(&self) -> Vec<MediaRef> {
        // Not probed yet: offered, the render shows it once decoded.
        let mut out: Vec<MediaRef> = self
            .project()
            .media
            .iter()
            .filter(|m| m.info.as_ref().is_none_or(|i| i.video.is_some() && !i.is_still))
            .cloned()
            .collect();
        out.sort_by(|a, b| natural_cmp(&a.name, &b.name));
        out
    }
    // Swift: EditorSession+Transitions.swift:211
    pub fn set_transition_stinger(
        &mut self,
        id: Id,
        media: Option<Id>,
        cut_fraction: Option<f64>,
        continues_gesture: bool,
    ) {
        let key = self.gesture_key("stinger", id, continues_gesture);
        let (Some(tl), Some(current)) =
            (self.active_timeline_id, self.active_timeline().and_then(|t| t.transition(id)).map(|(_, tr)| tr))
        else {
            return;
        };
        let result = self.try_perform("Change Stinger", Some(&key), |p| match (media, current.stinger.as_ref()) {
            (Some(m), s) if s.map(|s| s.media) != Some(m) => {
                p.set_stinger(id, m, cut_fraction.or(s.map(|s| s.cut_fraction)).unwrap_or(0.5), tl)
            }
            (None, _) => p.edit(tl, |t| t.set_stinger(id, None)),
            (Some(_), Some(s)) => match cut_fraction {
                Some(f) => {
                    let mut s = s.clone();
                    s.cut_fraction = f;
                    p.edit(tl, |t| t.set_stinger(id, Some(s)))
                }
                None => Ok(()),
            },
            (Some(_), None) => Ok(()),
        });
        if let Err(e) = result {
            self.set_error(e.to_string());
        }
    }
    // Swift: EditorSession+Transitions.swift:230
    pub fn remove_selected_transition(&mut self) -> bool {
        let Some(id) = self.selected_transition else { return false };
        // Gone already (undo, an edit that removed its cut): forget it and let Delete act on the clips / gap instead.
        if self.active_timeline().and_then(|t| t.transition(id)).is_none() {
            self.selected_transition = None;
            return false;
        }
        self.remove_transition(id)
    }
    // Swift: EditorSession+Transitions.swift:237
    pub fn remove_transition(&mut self, id: Id) -> bool {
        let ok = self.attempt_keyed_ids("Clear Transition", None, |t, _| t.remove_transition(id));
        if ok {
            self.select_transition(None, false);
        }
        ok
    }
}

/// The clip a head or tail point belongs to (Swift `TransitionPoint.elementClip`).
pub(crate) fn element_clip(p: TransitionPoint) -> Option<Id> {
    match p {
        TransitionPoint::Head(c) | TransitionPoint::Tail(c) => Some(c),
        TransitionPoint::Cut { .. } => None,
    }
}

/// Case-insensitive name order that reads digit runs as numbers (Finder-like `localizedStandardCompare`).
fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let (mut x, mut y) =
        (a.chars().flat_map(char::to_lowercase).peekable(), b.chars().flat_map(char::to_lowercase).peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return std::cmp::Ordering::Equal,
            (None, Some(_)) => return std::cmp::Ordering::Less,
            (Some(_), None) => return std::cmp::Ordering::Greater,
            (Some(p), Some(q)) if p.is_ascii_digit() && q.is_ascii_digit() => {
                let num = |it: &mut std::iter::Peekable<_>| -> u128 {
                    let mut n = 0u128;
                    while let Some(d) = it.peek().copied().and_then(|c: char| c.to_digit(10)) {
                        n = n.saturating_mul(10).saturating_add(u128::from(d));
                        it.next();
                    }
                    n
                };
                let (nx, ny) = (num(&mut x), num(&mut y));
                if nx != ny {
                    return nx.cmp(&ny);
                }
            }
            (Some(p), Some(q)) => {
                if p != q {
                    return p.cmp(&q);
                }
                x.next();
                y.next();
            }
        }
    }
}
