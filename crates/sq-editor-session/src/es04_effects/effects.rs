//! Effects on clips: apply, audio targets, fades, frame holds, Paste Attributes, grade from previous clip or camera.

use std::collections::{BTreeMap, BTreeSet};

use sq_core_edit::camera_signature::{CameraSignature, CameraSignatureTimelineExt};
use sq_core_edit::timeline_magnetic_moves::MagneticGesturesExt;
use sq_core_edit::timeline_replace::TimelineReplaceExt;
use sq_core_effects::effect_stack_preset::EffectStackPresets;
use sq_core_effects::effects_editing::{ClipEffectsEditingExt, TimelineEffectsEditingExt};
use sq_core_effects::style_kit::ClipStyleKitExt;
use sq_core_model::{Clip, ClipEdge, ClipEffect, EditError, EffectCatalog, TrackKind};
use sq_core_time::{Id, Time};
use sq_text::text_presets::TextPresetCatalog;

use crate::{EditorSession, PasteAttributeGroup};

/// Every attribute group, in Swift's `allCases` order.
const PASTE_GROUPS: [PasteAttributeGroup; 5] = [
    PasteAttributeGroup::Motion,
    PasteAttributeGroup::Opacity,
    PasteAttributeGroup::Effects,
    PasteAttributeGroup::Color,
    PasteAttributeGroup::Volume,
];

/// The track kind a group belongs to (Swift `PasteAttributeGroup.kind`; ES2 has the same on the type).
fn group_kind(g: PasteAttributeGroup) -> TrackKind {
    if g == PasteAttributeGroup::Volume { TrackKind::Audio } else { TrackKind::Video }
}

impl EditorSession {
    /// The first video command clip under the playhead.
    fn clip_under_playhead(&self) -> Option<Id> {
        self.command_clips(Some(TrackKind::Video)).iter().find(|c| c.timeline().contains(self.playhead)).map(|c| c.id)
    }

    /// Length of an inserted fade.
    // Swift: EditorSession+Effects.swift:8
    pub const DEFAULT_FADE_DURATION: Time = Time::new(1, 1);
    /// Length of an inserted frame hold segment (Premiere: two seconds).
    // Swift: EditorSession+Effects.swift:10
    pub const DEFAULT_FRAME_HOLD_DURATION: Time = Time::new(2, 1);

    /// The clips a command works on: the selection, else the clips under the playhead on the targeted tracks.
    // Swift: EditorSession+Effects.swift:14
    pub fn command_clips_for_menu(&self, kind: Option<TrackKind>) -> Vec<Clip> {
        self.command_clips(kind)
    }
    // Swift: EditorSession+Effects.swift:16 (internal)
    pub(crate) fn command_clips(&self, kind: Option<TrackKind>) -> Vec<Clip> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        let of_kind = |k: TrackKind| kind.is_none_or(|w| w == k);
        if !self.selection.is_empty() {
            return t
                .tracks
                .iter()
                .flat_map(|tr| tr.clips())
                .filter(|c| of_kind(c.kind) && self.selection.contains(&c.id))
                .cloned()
                .collect();
        }
        let tracks: Vec<_> = t.tracks.iter().filter(|tr| of_kind(tr.kind)).collect();
        let targeted: Vec<_> = tracks.iter().copied().filter(|tr| tr.is_targeted).collect();
        let used = if targeted.is_empty() { tracks } else { targeted };
        used.into_iter().flat_map(|tr| tr.clips()).filter(|c| c.timeline().contains(self.playhead)).cloned().collect()
    }
    /// The clips an effect dropped on `hit` goes to: the whole selection when `hit` is in it.
    // Swift: EditorSession+Effects.swift:28
    pub fn effect_drop_targets(&self, hit: Id) -> BTreeSet<Id> {
        if self.selection.contains(&hit) { self.selection.clone() } else { BTreeSet::from([hit]) }
    }
    /// Adds the effect (or preset row) `kind` to `ids`.
    // Swift: EditorSession+Effects.swift:35
    pub fn add_effect(&mut self, kind: &str, ids: &BTreeSet<Id>) -> bool {
        if TextPresetCatalog::is_text_preset_id(kind) {
            return self.add_text_preset(kind, ids);
        }
        if EffectStackPresets::preset_by_row_id(kind).is_some() {
            return !ids.is_empty() && self.apply_stack_preset(kind, Some(ids));
        }
        if ClipEffect::is_audio_kind(kind) {
            return self.add_audio_effect(kind, ids);
        }
        if kind == ClipEffect::STABILIZE_KIND {
            return self.add_stabilizer(ids);
        }
        let has_video = self.active_timeline().is_some_and(|t| {
            t.tracks.iter().flat_map(|tr| tr.clips()).any(|c| ids.contains(&c.id) && c.kind == TrackKind::Video)
        });
        if EffectCatalog::spec_for(kind).is_none() || ids.is_empty() || !has_video {
            return false;
        }
        // New motion effects start at the Style Kit's duration and curve; the user's default of the kind wins else.
        let motion = self.project().style_kit.as_ref().and_then(|k| k.motion.clone());
        let defaults = self.effect_defaults.clone();
        self.attempt_keyed_ids(&format!("Add {}", EffectCatalog::title_for(kind)), None, |t, ids_src| {
            let mut changed = false;
            for id in ids {
                let Some(mut c) = t.find(*id).map(|m| m.clip).filter(|c| c.kind == TrackKind::Video) else { continue };
                if c.add_effect_with_motion_defaults(kind, motion.as_ref(), Some(&defaults), ids_src).is_none() {
                    continue;
                }
                t.replace_clip(c)?;
                changed = true;
            }
            if changed { Ok(()) } else { Err(EditError::WrongTrackKind) }
        })
    }

    fn add_audio_effect(&mut self, kind: &str, ids: &BTreeSet<Id>) -> bool {
        let targets = self.audio_effect_targets(ids);
        if EffectCatalog::spec_for(kind).is_none() || targets.is_empty() {
            return false;
        }
        let defaults = self.effect_defaults.clone();
        self.attempt_keyed_ids(&format!("Add {}", EffectCatalog::title_for(kind)), None, |t, ids_src| {
            let mut changed = false;
            for id in &targets {
                let Some(mut c) = t.find(*id).map(|m| m.clip) else { continue };
                if c.add_effect(kind, Some(&defaults), ids_src).is_none() {
                    continue;
                }
                t.replace_clip(c)?;
                changed = true;
            }
            if changed { Ok(()) } else { Err(EditError::WrongTrackKind) }
        })
    }
    // Swift: EditorSession+Effects.swift:59
    pub fn audio_effect_targets(&self, ids: &BTreeSet<Id>) -> BTreeSet<Id> {
        let Some(t) = self.active_timeline() else { return BTreeSet::new() };
        let clips: Vec<&Clip> = t.tracks.iter().flat_map(|tr| tr.clips()).collect();
        let links: BTreeSet<Id> =
            clips.iter().filter(|c| ids.contains(&c.id) && c.kind != TrackKind::Audio).filter_map(|c| c.link).collect();
        clips
            .iter()
            .filter(|c| {
                c.kind == TrackKind::Audio && (ids.contains(&c.id) || c.link.is_some_and(|l| links.contains(&l)))
            })
            .map(|c| c.id)
            .collect()
    }
    // Swift: EditorSession+Effects.swift:85
    pub fn fade_video(&mut self, edge: ClipEdge, duration: Time) -> bool {
        let ids: Vec<Id> = self.command_clips(Some(TrackKind::Video)).iter().map(|c| c.id).collect();
        if ids.is_empty() {
            return false;
        }
        self.attempt_keyed_ids(if edge == ClipEdge::Head { "Fade In" } else { "Fade Out" }, None, |t, ids_src| {
            t.fade_video(&ids, edge, duration, ids_src)
        })
    }
    // Swift: EditorSession+Effects.swift:95
    pub fn add_frame_hold(&mut self) -> bool {
        let Some(id) = self.clip_under_playhead() else { return false };
        let at = self.playhead;
        self.attempt_keyed_ids("Add Frame Hold", None, |t, ids| {
            t.magnetic_add_frame_hold(Some(id), at, ids).map(|_| ())
        })
    }
    // Swift: EditorSession+Effects.swift:103
    pub fn insert_frame_hold(&mut self, duration: Time) -> bool {
        let Some(id) = self.clip_under_playhead() else { return false };
        let at = self.playhead;
        self.attempt_keyed_ids("Insert Frame Hold Segment", None, |t, ids| {
            t.magnetic_insert_frame_hold(Some(id), at, duration, ids).map(|_| ())
        })
    }
    // Swift: EditorSession+Effects.swift:113
    pub fn paste_attribute_choices(&self) -> Vec<PasteAttributeGroup> {
        if let Some(b) = &self.built_in_clipboard {
            return if self.can_paste_attributes() { vec![b.group] } else { Vec::new() };
        }
        let (Some(cb), Some(t)) = (&self.clipboard, self.active_timeline()) else { return Vec::new() };
        if !self.can_paste_attributes() {
            return Vec::new();
        }
        let copied_ids: BTreeSet<Id> = cb.entries.iter().map(|e| e.clip.id).collect();
        let target_kinds: Vec<TrackKind> = t
            .tracks
            .iter()
            .flat_map(|tr| tr.clips())
            .filter(|c| self.selection.contains(&c.id) && !copied_ids.contains(&c.id))
            .map(|c| c.kind)
            .collect();
        let copied_kinds: Vec<TrackKind> =
            cb.entries.iter().map(|e| e.clip.kind).filter(|k| target_kinds.contains(k)).collect();
        PASTE_GROUPS.into_iter().filter(|g| copied_kinds.contains(&group_kind(*g))).collect()
    }
    /// True when a copied clip can lend its attributes to something that is selected.
    // Swift: EditorSession+Effects.swift:123
    pub fn can_paste_attributes(&self) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let mut clips = t.tracks.iter().flat_map(|tr| tr.clips());
        if let Some(b) = &self.built_in_clipboard {
            return clips.any(|c| self.selection.contains(&c.id) && c.kind == group_kind(b.group));
        }
        let Some(cb) = &self.clipboard else { return false };
        clips.any(|c| {
            self.selection.contains(&c.id)
                && cb.entries.iter().any(|e| e.clip.kind == c.kind)
                && !cb.entries.iter().any(|e| e.clip.id == c.id)
        })
    }
    // Swift: EditorSession+Effects.swift:135
    pub fn paste_attributes(&mut self, groups: &BTreeSet<PasteAttributeGroup>, scale_times: bool) -> bool {
        if let Some(b) = self.built_in_clipboard.clone() {
            return self.paste_built_in(&b, groups, scale_times);
        }
        let Some(cb) = self.clipboard.clone().filter(|_| self.can_paste_attributes() && !groups.is_empty()) else {
            return false;
        };
        let targets: Vec<Id> = self.selection.iter().copied().collect();
        let lanes: BTreeMap<Id, usize> =
            cb.picture_track_lanes.iter().flatten().filter_map(|(k, v)| Id::parse(k).map(|id| (id, *v))).collect();
        self.attempt_keyed_ids("Paste Settings", None, |t, ids| {
            let mut total = 0;
            for kind in [TrackKind::Video, TrackKind::Audio] {
                let Some(entry) = cb.entries.iter().find(|e| e.clip.kind == kind) else { continue };
                total += crate::paste_attributes(
                    t,
                    &entry.clip,
                    &targets,
                    groups,
                    scale_times,
                    Some(entry.lane),
                    &lanes,
                    ids,
                )
                .unwrap_or(0);
            }
            if total == 0 { Err(EditError::EmptyClip) } else { Ok(()) }
        })
    }
    // Swift: EditorSession+Effects.swift:152
    pub fn grade_from_previous_clip(&mut self, back: i64) -> bool {
        // Deterministic order: by track, then start, so adjacent selected clips chain the same way every time.
        let Some(t) = self.active_timeline() else { return false };
        let mut order: Vec<(usize, Time, Id)> = Vec::new();
        for (ti, tr) in t.tracks.iter().enumerate() {
            order.extend(tr.clips().iter().filter(|c| self.selection.contains(&c.id)).map(|c| (ti, c.start, c.id)));
        }
        // Selected ids that are not in the sequence sort last, like Swift's (Int.max, .zero).
        let mut ids: Vec<(usize, Time, Id)> = order;
        for id in &self.selection {
            if !ids.iter().any(|o| o.2 == *id) {
                ids.push((usize::MAX, Time::ZERO, *id));
            }
        }
        ids.sort_by_key(|a| (a.0, a.1));
        // A linked video and audio pair is one clip: the video clip takes the grade (the audio partner has no picture).
        if let Some(only) = self.single_selected_clip().map(|c| c.id) {
            ids.retain(|o| o.2 == only);
        }
        if ids.is_empty() {
            return false;
        }
        let back = back.max(0) as usize;
        self.attempt_keyed_ids("Grade From Previous Clip", None, |t, ids_src| {
            for (_, _, id) in &ids {
                t.grade_from_previous_clip(*id, back, ids_src)?;
            }
            Ok(())
        })
    }
    // Swift: EditorSession+Effects.swift:170
    pub fn grade_all_from_camera(&mut self) -> i64 {
        // One clip, or a linked video and audio pair (Linked Selection selects both): the video clip.
        let Some(id) = self.single_selected_clip().map(|c| c.id) else {
            self.set_error("Select one clip to grade its camera.");
            return 0;
        };
        let signatures: std::collections::BTreeMap<Id, CameraSignature> = self
            .project()
            .media
            .iter()
            .filter_map(|m| CameraSignature::new(m.info.as_ref()).map(|s| (m.id, s)))
            .collect();
        let mut count = 0usize;
        let ok = self.attempt_keyed_ids("Grade All From This Camera", None, |t, ids| {
            count = t.grade_all_from_camera(id, |m| signatures.get(&m).cloned(), ids)?;
            Ok(())
        });
        if ok { count as i64 } else { 0 }
    }
}
