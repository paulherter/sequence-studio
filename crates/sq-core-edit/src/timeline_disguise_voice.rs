// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioEffectsPitch.swift (`Timeline.disguiseVoice`)

use sq_core_audio::audio_effects::{
    AUDIO_DISGUISE_VOICE_KIND, ClipAudioChainExt as _, DISGUISE_VOICE_KEY, DisguiseVoiceError,
};
use sq_core_effects::effects_editing::ClipEffectsEditingExt as _;
use sq_core_model::{Clip, EditError, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// Why `disguise_voice` refused: the usual edit errors, or a locked linked audio clip.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DisguiseVoiceFailure {
    /// An edit error (`ClipNotFound`, `TrackLocked`, `EmptyClip`, `Collision`).
    Edit(EditError),
    /// A linked audio clip in the range sits on a locked track.
    Linked(DisguiseVoiceError),
}

impl From<EditError> for DisguiseVoiceFailure {
    fn from(e: EditError) -> Self {
        DisguiseVoiceFailure::Edit(e)
    }
}

/// Disguise Voice on a range of audio clips.
pub trait TimelineDisguiseVoiceExt {
    /// Disguise Voice on `range` of the audio clips `clips`: each clip is cut at the range's edges (its linked partners
    /// with it, so picture and sound stay one pair per part) and every part inside the range gets the Disguise Voice
    /// effect. Audio clips linked to a named clip carry the same voice (dual mono): their parts inside the range are
    /// disguised as well. There is no blend at the edges: a part is either the processed voice or outside the range.
    /// Links follow the range edits: left pieces keep the link, right pieces share a new one, later partners take it.
    /// Returns the parts that carry the effect now (parts that had it already count, they are not doubled).
    /// Fails with `ClipNotFound` when no audio clip of `clips` reaches into the range, `TrackLocked` when one sits on a
    /// locked track, `Linked(LinkedAudioLocked)` when a linked audio clip in the range does; nothing changes then.
    fn disguise_voice(
        &mut self,
        range: TimeRange,
        clips: &BTreeSet<Id>,
        voice: i64,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, DisguiseVoiceFailure>;
}

fn carries_voice(c: &Clip) -> bool {
    c.kind == TrackKind::Audio && !c.is_generator()
}

impl TimelineDisguiseVoiceExt for Timeline {
    fn disguise_voice(
        &mut self,
        range: TimeRange,
        clips: &BTreeSet<Id>,
        voice: i64,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, DisguiseVoiceFailure> {
        if range.is_empty() {
            return Err(EditError::EmptyClip.into());
        }
        let mut links: BTreeSet<Id> = BTreeSet::new();
        let mut found = false;
        for tr in self.tracks.iter().filter(|t| t.kind == TrackKind::Audio) {
            for c in
                tr.clips().iter().filter(|c| clips.contains(&c.id) && carries_voice(c) && c.timeline().overlaps(&range))
            {
                if tr.is_locked {
                    return Err(EditError::TrackLocked.into());
                }
                found = true;
                links.extend(c.link);
            }
        }
        if !found {
            return Err(EditError::ClipNotFound.into());
        }
        // What to disguise: (track, the part of the clip inside the range), for the named clips and their linked audio.
        let mut parts: Vec<(usize, TimeRange)> = Vec::new();
        for (i, tr) in self.tracks.iter().enumerate().filter(|(_, t)| t.kind == TrackKind::Audio) {
            for c in tr
                .clips()
                .iter()
                .filter(|c| carries_voice(c) && (clips.contains(&c.id) || c.link.is_some_and(|l| links.contains(&l))))
            {
                let Some(hit) = c.timeline().intersection(&range).filter(|h| !h.is_empty()) else { continue };
                if tr.is_locked {
                    return Err(DisguiseVoiceFailure::Linked(DisguiseVoiceError::LinkedAudioLocked));
                }
                parts.push((i, hit));
            }
        }
        let mut work = self.tracks.clone();
        for cut in [range.start, range.end()] {
            let mut relinks: BTreeMap<Id, Id> = BTreeMap::new();
            for i in 0..work.len() {
                if work[i].is_locked {
                    continue;
                }
                let Some(c) = work[i].clips().iter().find(|c| c.timeline().contains(cut) && c.start < cut).cloned()
                else {
                    continue;
                };
                // Parts lie inside their clip, so only a piece of that clip can overlap one.
                let own = parts.iter().any(|(t, r)| *t == i && c.timeline().overlaps(r));
                if !(own || c.link.is_some_and(|l| links.contains(&l))) {
                    continue;
                }
                work[i].split_relinking(cut, &mut relinks, ids)?;
            }
            // Partners that start at or after the cut belong to the right piece: they take its link.
            for tr in work.iter_mut().filter(|t| !t.is_locked) {
                let mut hit = false;
                let relinked: Vec<Clip> = tr
                    .clips()
                    .iter()
                    .map(|c| {
                        let mut c = c.clone();
                        if let (true, Some(l)) = (c.start >= cut, c.link)
                            && let Some(n) = relinks.get(&l)
                        {
                            c.link = Some(*n);
                            hit = true;
                        }
                        c
                    })
                    .collect();
                if hit {
                    tr.set_clips(relinked);
                }
            }
            links.extend(relinks.values().copied());
        }
        let mut out: Vec<Id> = Vec::new();
        for (track, part) in &parts {
            let pieces: Vec<Clip> = work[*track].clips().to_vec();
            for mut c in pieces {
                if !(carries_voice(&c) && c.start >= part.start && c.timeline().end() <= part.end()) {
                    continue;
                }
                if !c.has_disguise_voice() {
                    let Some(e) = c.add_effect(AUDIO_DISGUISE_VOICE_KIND, None, ids) else { continue };
                    c.set_parameter(e, DISGUISE_VOICE_KEY, voice as f64);
                    work[*track].replace(c.clone());
                }
                out.push(c.id);
            }
        }
        self.tracks = work;
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::{Audio, Video};
    use sq_core_time::Time;

    fn disguise(t: &mut Timeline, a: i64, b: i64, clips: &[Id], voice: i64) -> Result<Vec<Id>, DisguiseVoiceFailure> {
        t.disguise_voice(r(a, b), &clips.iter().copied().collect(), voice, &mut FreshIds)
    }

    fn has(c: &Clip) -> bool {
        c.has_disguise_voice()
    }

    #[test]
    fn range_edit_cuts_the_clip_and_disguises_only_the_inside() {
        let (a0, other) = (a(0, 10), a(12, 4));
        let mut t = timeline(vec![track(Audio, vec![a0.clone(), other])]);
        let parts = disguise(&mut t, 3, 6, &[a0.id], 1).unwrap();
        let clips = t.tracks[0].clips();
        assert_eq!(clips.iter().map(|c| c.start).collect::<Vec<_>>(), [s(0), s(3), s(6), s(12)]);
        assert_eq!(clips.iter().map(has).collect::<Vec<_>>(), [false, true, false, false]);
        assert_eq!(parts, [clips[1].id]);
        assert_eq!(clips[1].timeline(), r(3, 6));
        assert_eq!(clips[1].effects[0].scalar(DISGUISE_VOICE_KEY, Time::ZERO), 1.0);
        assert_eq!(clips[0].id, a0.id);
    }

    #[test]
    fn range_larger_than_the_clip_disguises_all_of_it_without_cuts() {
        let (x, y) = (a(2, 4), a(8, 4));
        let mut t = timeline(vec![track(Audio, vec![x.clone(), y.clone()])]);
        let parts = disguise(&mut t, 0, 9, &[x.id, y.id], 0).unwrap();
        let clips = t.tracks[0].clips();
        assert_eq!(clips.iter().map(|c| c.start).collect::<Vec<_>>(), [s(2), s(8), s(9)]);
        assert_eq!(clips.iter().map(has).collect::<Vec<_>>(), [true, true, false]);
        assert_eq!(parts.len(), 2);
    }

    #[test]
    fn second_run_does_not_stack_the_effect() {
        let x = a(0, 10);
        let mut t = timeline(vec![track(Audio, vec![x.clone()])]);
        disguise(&mut t, 3, 6, &[x.id], 0).unwrap();
        let mid = t.tracks[0].clips()[1].id;
        disguise(&mut t, 3, 6, &[mid], 0).unwrap();
        assert_eq!(t.tracks[0].clips().len(), 3);
        assert_eq!(t.tracks[0].clips()[1].effects.iter().filter(|e| e.kind == AUDIO_DISGUISE_VOICE_KIND).count(), 1);
    }

    #[test]
    fn linked_picture_is_cut_with_the_sound_and_parts_stay_pairs() {
        let l = link();
        let v0 = clip(0, 10, 0, Video, Some(l), None);
        let a0 = clip(0, 10, 0, Audio, Some(l), None);
        let mut t = timeline(vec![track(Video, vec![v0]), track(Audio, vec![a0.clone()])]);
        disguise(&mut t, 3, 6, &[a0.id], 0).unwrap();
        let (vs, au) = (t.tracks[0].clips(), t.tracks[1].clips());
        assert!(vs.len() == 3 && au.len() == 3);
        for k in 0..3 {
            assert!(vs[k].link.is_some() && vs[k].link == au[k].link);
        }
        assert_eq!(au.iter().filter_map(|c| c.link).collect::<BTreeSet<_>>().len(), 3);
        assert!(vs.iter().all(|c| !has(c)));
    }

    #[test]
    fn linked_audio_partner_is_disguised_too() {
        let l = link();
        let v0 = clip(0, 10, 0, Video, Some(l), None);
        let (a1, a2) = (clip(0, 10, 0, Audio, Some(l), None), clip(0, 10, 0, Audio, Some(l), None));
        let mut t = timeline(vec![track(Video, vec![v0]), track(Audio, vec![a1.clone()]), track(Audio, vec![a2])]);
        let parts = disguise(&mut t, 3, 6, &[a1.id], 0).unwrap();
        assert_eq!(parts.len(), 2);
        assert!(has(&t.tracks[1].clips()[1]) && has(&t.tracks[2].clips()[1]));
    }

    #[test]
    fn unselected_clips_and_other_tracks_are_untouched() {
        let (x, y) = (a(0, 10), a(0, 10));
        let mut t = timeline(vec![track(Audio, vec![x.clone()]), track(Audio, vec![y.clone()])]);
        disguise(&mut t, 3, 6, &[x.id], 0).unwrap();
        assert_eq!(t.tracks[1].clips(), [y]);
    }

    #[test]
    fn failures_change_nothing() {
        let x = a(0, 10);
        let mut t = timeline(vec![locked(track(Audio, vec![x.clone()]))]);
        let before = t.clone();
        assert_eq!(disguise(&mut t, 3, 6, &[x.id], 0), Err(EditError::TrackLocked.into()));
        assert_eq!(disguise(&mut t, 20, 26, &[x.id], 0), Err(EditError::ClipNotFound.into()));
        assert_eq!(disguise(&mut t, 3, 6, &[], 0), Err(EditError::ClipNotFound.into()));
        assert!(t == before);
    }
}
