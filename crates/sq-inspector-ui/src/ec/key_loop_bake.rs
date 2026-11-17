// Swift: EffectControlsModel+KeyLoopBake.swift
//! Loop, Convert to Keys and Wiggle on the tracks that hold selected keys (undoable, one commit each).

use std::collections::BTreeSet;
use std::ops::RangeInclusive;

use sq_core_model::keyframes_editing::{KeyframeSummary, PropertyID, PropertyTrack};
use sq_core_model::keyframes_loop_bake::{KeyLoopBake, KeyWiggle};
use sq_core_time::{Id, IdSource, Time};

use crate::ec::effect_controls_model::core::EffectControlsModel;

impl EffectControlsModel {
    /// Repeats the key pattern of every track with a selected key `cycles` more times (Loop).
    pub fn loop_selected_tracks(&mut self, cycles: i64) -> bool {
        self.edit_selected_tracks("Loop Keyframes", |track, _, ids| {
            match track {
                PropertyTrack::Scalar(t) => t.loop_keys(cycles, ids),
                PropertyTrack::Vector(t) => t.loop_keys(cycles, ids),
                PropertyTrack::Color(t) => t.loop_keys(cycles, ids),
                PropertyTrack::Path(t) => t.loop_keys(cycles, ids),
            }
            true
        })
    }

    /// Replaces the keys between the first and last selected key of each track by linear keys sampled from the
    /// curve (Convert to Keys). Needs two different selected key times on a track.
    pub fn bake_selected_keys(&mut self, samples_per_second: i64) -> bool {
        self.edit_selected_tracks("Convert to Keys", |track, r, ids| {
            let (lo, hi) = (*r.start(), *r.end());
            match track {
                PropertyTrack::Scalar(t) => t.bake_samples(lo, hi, samples_per_second, ids),
                PropertyTrack::Vector(t) => t.bake_samples(lo, hi, samples_per_second, ids),
                PropertyTrack::Color(t) => t.bake_samples(lo, hi, samples_per_second, ids),
                PropertyTrack::Path(t) => t.bake_samples(lo, hi, samples_per_second, ids),
            }
        })
    }

    /// Wiggle between the first and last selected key of every number track (colors, vectors and paths are left alone).
    pub fn wiggle_selected_keys(&mut self, per_second: i64, amount: f64, seed: u64) -> bool {
        self.edit_selected_tracks("Wiggle Keyframes", |track, r, ids| {
            let PropertyTrack::Scalar(t) = track else { return false };
            t.wiggle(*r.start(), *r.end(), per_second, amount, seed, ids)
        })
    }

    /// True when a selected key sits on a number track (the only kind Wiggle applies to).
    pub fn has_selected_scalar_key(&mut self) -> bool {
        let Some(c) = self.working_clip().or_else(|| self.clip.clone()) else { return false };
        let tracks = KeyframeSummary::new(Self::tracks_of(&c)).tracks;
        self.selection.iter().any(|m| matches!(tracks.get(&m.property), Some(PropertyTrack::Scalar(_))))
    }

    fn edit_selected_tracks(
        &mut self,
        name: &str,
        mut edit: impl FnMut(&mut PropertyTrack, &RangeInclusive<Time>, &mut dyn IdSource) -> bool,
    ) -> bool {
        let Some(c) = self.working_clip().or_else(|| self.clip.clone()) else { return false };
        if self.selection.is_empty() {
            return false;
        }
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        let mut changed = false;
        let props: Vec<PropertyID> = s.tracks.keys().cloned().collect();
        for p in props {
            let ids: BTreeSet<Id> = self.selection.iter().filter(|m| m.property == p).map(|m| m.key_id).collect();
            if ids.is_empty() {
                continue;
            }
            let Some(t) = s.tracks.get(&p) else { continue };
            let times: Vec<Time> =
                t.times().into_iter().filter(|(id, _)| ids.contains(id)).map(|(_, time)| time).collect();
            let (Some(lo), Some(hi)) = (times.iter().copied().min(), times.iter().copied().max()) else { continue };
            let mut track = t.clone();
            if edit(&mut track, &(lo..=hi), &mut *self.ids) {
                s.tracks.insert(p, track);
                changed = true;
            }
        }
        if !changed {
            return false;
        }
        let mut out = c;
        self.write(&s.tracks.clone(), &mut out);
        self.commit(out, name, None);
        true
    }
}
