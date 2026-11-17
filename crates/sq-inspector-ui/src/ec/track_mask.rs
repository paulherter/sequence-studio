// Swift: EffectControlsModel+TrackMask.swift
//! Track Mask effect: the track row of its section. The choices are those of a Picture mask (the other video tracks of
//! the sequence, nearest above first); Mode and Invert are ordinary catalog rows.

use sq_core_edit::track_mask_effect::TrackMaskEffectExt;
use sq_core_time::Id;

use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::picture_mask::PictureTrackChoice;

impl EffectControlsModel {
    /// Index into `picture_track_choices()` the effect shows: its track, "No track" (0) when it has none or the track is gone.
    pub fn track_mask_selection(&self, effect: Id, choices: &[PictureTrackChoice]) -> usize {
        let Some(tr) =
            self.clip.as_ref().and_then(|c| c.effects.iter().find(|e| e.id == effect)).and_then(|e| e.mask_track)
        else {
            return 0;
        };
        choices.iter().position(|c| c.track == Some(tr)).unwrap_or(0)
    }

    /// Track popup of a Track Mask row (nil = No track), one undo step. A track that is not a valid choice is refused.
    pub fn set_track_mask_track(&mut self, effect: Id, track: Option<Id>) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(i) = c.effects.iter().position(|e| e.id == effect) else { return };
        if c.effects[i].kind != sq_core_model::ClipEffect::TRACK_MASK_KIND || c.effects[i].mask_track == track {
            return;
        }
        if track.is_some() && !self.picture_track_choices().iter().any(|ch| ch.track == track) {
            return;
        }
        c.effects[i].set_mask_track(track);
        self.commit(c, "Change Mask Track", None);
    }
}
