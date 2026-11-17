// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+SourcePatch.swift (patching verbs; the saved types live in sq-core-model)
//
// Where Insert / Overwrite put the Source view's video and audio is decided by the patch, not by track targeting:
// targeting stays for paste, match frame and the playhead edits (Cmd+K, Up/Down, X). The patch is stored per sequence
// (v88, `Timeline.source_patch_store`) and changes are undo steps; the timeline resolves it.

use sq_core_model::{SourcePatch, SourcePatchSlot, Timeline, TrackKind};
use sq_core_time::Id;
use std::collections::BTreeMap;

fn other(kind: TrackKind) -> TrackKind {
    if kind == TrackKind::Video { TrackKind::Audio } else { TrackKind::Video }
}

fn connected(p: &SourcePatch) -> SourcePatch {
    SourcePatch {
        video: SourcePatchSlot { track: p.video.track, is_connected: true },
        audio: SourcePatchSlot { track: p.audio.track, is_connected: true },
    }
}

/// The patch operations of the Source view's chips.
pub trait SourcePatchExt {
    /// The slot of the stream `kind`.
    fn slot(&self, kind: TrackKind) -> &SourcePatchSlot;

    /// The slot of the stream `kind`, mutable.
    fn slot_mut(&mut self, kind: TrackKind) -> &mut SourcePatchSlot;

    /// Click on a patch chip: disconnect, or connect again to the same track.
    fn toggle_connection(&mut self, kind: TrackKind);

    /// Chip dragged onto a track: patched there and connected. A track of the other kind (or unknown) changes nothing.
    fn patch(&mut self, kind: TrackKind, id: Id, timeline: &Timeline);

    /// Option+click on a chip: only this stream stays connected (solo); clicking it again connects both.
    fn solo(&mut self, kind: TrackKind);

    /// Shift+drag of a chip: `kind` goes to `id` and the other stream moves by the same number of tracks of its kind
    /// (clamped to the first / last track), so the pair keeps its distance. Connection states stay as they are, except
    /// that the dragged stream connects.
    fn patch_both(&mut self, kind: TrackKind, id: Id, timeline: &Timeline);
}

impl SourcePatchExt for SourcePatch {
    fn slot(&self, kind: TrackKind) -> &SourcePatchSlot {
        if kind == TrackKind::Video { &self.video } else { &self.audio }
    }

    fn slot_mut(&mut self, kind: TrackKind) -> &mut SourcePatchSlot {
        if kind == TrackKind::Video { &mut self.video } else { &mut self.audio }
    }

    fn toggle_connection(&mut self, kind: TrackKind) {
        let s = self.slot_mut(kind);
        s.is_connected = !s.is_connected;
    }

    fn patch(&mut self, kind: TrackKind, id: Id, timeline: &Timeline) {
        if timeline.track(id).map(|t| t.kind) != Some(kind) {
            return;
        }
        *self.slot_mut(kind) = SourcePatchSlot { track: Some(id), is_connected: true };
    }

    fn solo(&mut self, kind: TrackKind) {
        let o = other(kind);
        if self.slot(kind).is_connected && !self.slot(o).is_connected {
            self.slot_mut(o).is_connected = true;
        } else {
            self.slot_mut(kind).is_connected = true;
            self.slot_mut(o).is_connected = false;
        }
    }

    fn patch_both(&mut self, kind: TrackKind, id: Id, timeline: &Timeline) {
        if timeline.track(id).map(|t| t.kind) != Some(kind) {
            return;
        }
        let o = other(kind);
        let mine: Vec<Id> = timeline.tracks.iter().filter(|t| t.kind == kind).map(|t| t.id).collect();
        let theirs: Vec<Id> = timeline.tracks.iter().filter(|t| t.kind == o).map(|t| t.id).collect();
        let all_connected = connected(self);
        let from = timeline.patched_track(&all_connected, kind);
        let other_now = timeline.patched_track(&all_connected, o);
        let fi = mine.iter().position(|t| Some(*t) == from);
        let ti = mine.iter().position(|t| *t == id);
        let oi = theirs.iter().position(|t| Some(*t) == other_now);
        if let (Some(fi), Some(ti), Some(oi)) = (fi, ti, oi)
            && !theirs.is_empty()
        {
            let wanted =
                i64::try_from(oi).unwrap_or(0) + i64::try_from(ti).unwrap_or(0) - i64::try_from(fi).unwrap_or(0);
            let last = i64::try_from(theirs.len() - 1).unwrap_or(0);
            let ni = usize::try_from(wanted.clamp(0, last)).unwrap_or(0);
            self.slot_mut(o).track = Some(theirs[ni]);
        }
        let s = self.slot_mut(kind);
        s.track = Some(id);
        s.is_connected = true;
    }
}

/// The source patch of one sequence.
pub trait TimelineSourcePatchExt {
    /// This sequence's source patch (default: video to V1, audio to A1, both connected). A slot whose track no longer
    /// exists (deleted) reads as the default track, so a stale id never keeps the file at v88.
    fn source_patch(&self) -> SourcePatch;

    /// Stores the patch; the default patch stores nothing, so untouched sequences encode as before.
    fn set_source_patch(&mut self, patch: SourcePatch);

    /// After tracks were copied with new ids (`map`: old -> new): the patch follows its tracks; one not copied falls back.
    #[doc(hidden)]
    fn remap_source_patch(&mut self, map: &BTreeMap<Id, Id>);

    /// The track a slot points at: its own track while it exists (and is of the kind), else the first track of the kind.
    /// `None` when the slot is disconnected or the sequence has no track of that kind.
    fn patched_track(&self, patch: &SourcePatch, kind: TrackKind) -> Option<Id>;

    /// Destination tracks of a Source Insert / Overwrite: the patched video track, then the patched audio track. Audio
    /// patched by default into a sequence without audio tracks creates A1 through `ensure_audio_track` (same undo step as
    /// the edit). A stream that is disconnected, not offered by the media (`has_*`) or not chosen (`include_*`) is left out.
    /// `None` when nothing is left to place.
    fn source_patch_targets(
        &mut self,
        patch: &SourcePatch,
        has_video: bool,
        has_audio: bool,
        include_video: bool,
        include_audio: bool,
        ensure_audio_track: &mut dyn FnMut(&mut Timeline) -> Id,
    ) -> Option<Vec<Id>>;
}

impl TimelineSourcePatchExt for Timeline {
    fn source_patch(&self) -> SourcePatch {
        let Some(mut p) = self.source_patch_store.clone() else { return SourcePatch::default() };
        for kind in [TrackKind::Video, TrackKind::Audio] {
            if let Some(id) = p.slot(kind).track
                && self.track(id).map(|t| t.kind) != Some(kind)
            {
                p.slot_mut(kind).track = None;
            }
        }
        p
    }

    fn set_source_patch(&mut self, patch: SourcePatch) {
        self.source_patch_store = if patch == SourcePatch::default() { None } else { Some(patch) };
    }

    fn remap_source_patch(&mut self, map: &BTreeMap<Id, Id>) {
        let Some(mut p) = self.source_patch_store.clone() else { return };
        for kind in [TrackKind::Video, TrackKind::Audio] {
            let s = p.slot_mut(kind);
            s.track = s.track.and_then(|t| map.get(&t).copied());
        }
        self.set_source_patch(p);
    }

    fn patched_track(&self, patch: &SourcePatch, kind: TrackKind) -> Option<Id> {
        let slot = patch.slot(kind);
        if !slot.is_connected {
            return None;
        }
        if let Some(id) = slot.track
            && self.track(id).map(|t| t.kind) == Some(kind)
        {
            return Some(id);
        }
        self.tracks.iter().find(|t| t.kind == kind).map(|t| t.id)
    }

    fn source_patch_targets(
        &mut self,
        patch: &SourcePatch,
        has_video: bool,
        has_audio: bool,
        include_video: bool,
        include_audio: bool,
        ensure_audio_track: &mut dyn FnMut(&mut Timeline) -> Id,
    ) -> Option<Vec<Id>> {
        let mut out: Vec<Id> = Vec::new();
        if has_video
            && include_video
            && let Some(v) = self.patched_track(patch, TrackKind::Video)
        {
            out.push(v);
        }
        if has_audio && include_audio && patch.audio.is_connected {
            match self.patched_track(patch, TrackKind::Audio) {
                Some(a) => out.push(a),
                None => out.push(ensure_audio_track(self)),
            }
        }
        if out.is_empty() { None } else { Some(out) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::{Audio, Video};

    fn tl() -> Timeline {
        timeline(vec![
            track(Video, vec![]),
            track(Video, vec![]),
            track(Audio, vec![]),
            track(Audio, vec![]),
            track(Audio, vec![]),
        ])
    }

    #[test]
    fn the_default_patch_stores_nothing_and_a_stale_slot_reads_as_default() {
        let mut t = tl();
        assert_eq!(t.source_patch(), SourcePatch::default());
        let mut p = SourcePatch::default();
        p.patch(TrackKind::Video, t.tracks[1].id, &t);
        t.set_source_patch(p.clone());
        assert_eq!(t.source_patch_store, Some(p));
        assert_eq!(t.patched_track(&t.source_patch(), TrackKind::Video), Some(t.tracks[1].id));
        t.set_source_patch(SourcePatch::default());
        assert_eq!(t.source_patch_store, None);
        t.source_patch_store = Some(SourcePatch {
            video: SourcePatchSlot { track: Some(Id::from_u128(5)), is_connected: true },
            ..Default::default()
        });
        assert_eq!(t.source_patch().video.track, None);
    }

    #[test]
    fn patching_to_a_track_of_the_other_kind_changes_nothing() {
        let t = tl();
        let mut p = SourcePatch::default();
        p.patch(TrackKind::Video, t.tracks[2].id, &t);
        assert_eq!(p, SourcePatch::default());
    }

    #[test]
    fn connect_toggle_and_solo() {
        let mut p = SourcePatch::default();
        p.toggle_connection(TrackKind::Audio);
        assert!(!p.audio.is_connected);
        p.toggle_connection(TrackKind::Audio);
        p.solo(TrackKind::Video);
        assert!(p.video.is_connected && !p.audio.is_connected);
        p.solo(TrackKind::Video);
        assert!(p.video.is_connected && p.audio.is_connected);
    }

    #[test]
    fn patch_both_keeps_the_distance_between_the_streams() {
        let t = tl();
        let mut p = SourcePatch::default();
        p.patch_both(TrackKind::Video, t.tracks[1].id, &t);
        assert_eq!((p.video.track, p.audio.track), (Some(t.tracks[1].id), Some(t.tracks[3].id)));
        p.patch_both(TrackKind::Video, t.tracks[0].id, &t);
        assert_eq!(p.audio.track, Some(t.tracks[2].id));
    }

    #[test]
    fn targets_follow_the_patch_and_audio_is_created_when_missing() {
        let mut t = timeline(vec![track(Video, vec![])]);
        let p = SourcePatch::default();
        let mut made = None;
        let mut ensure = |tl: &mut Timeline| {
            let id = Id::from_u128(77);
            tl.tracks.push(sq_core_model::Track::new(id, TrackKind::Audio));
            made = Some(id);
            id
        };
        let out = t.source_patch_targets(&p, true, true, true, true, &mut ensure);
        assert_eq!(out, Some(vec![t.tracks[0].id, Id::from_u128(77)]));
        let mut off = SourcePatch::default();
        off.toggle_connection(TrackKind::Audio);
        assert_eq!(t.source_patch_targets(&off, false, true, true, true, &mut |_| Id::NIL), None);
        let _ = made;
    }
}
