// Swift: EffectControlsModel+PictureMask.swift
//! C6 Picture mask UI (T5): the track choices of a Picture mask row, adding one from the Program monitor menu, and the
//! two edits of its row (track, channel). Model, evaluation and rendering are in the core crates.

use sq_core_model::{Clip, ClipMask, MaskSource, MatteChannel, Timeline, TrackKind};
use sq_core_time::Id;
use sq_editor_session::EffectSection;

use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::prelude::*;
use sq_core_masks::picture_mask::PictureMaskTimelineExt;

/// One entry of the track popup of a Picture mask.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PictureTrackChoice {
    /// None = "No track" (the mask covers nothing).
    pub track: Option<Id>,
    pub title: String,
    /// "V3": the lane label of the track (None for "No track").
    pub lane: Option<String>,
}

impl EffectControlsModel {
    /// The video track of `clip` (nil when it is not in the shown timeline).
    fn track_id_of(clip: &Clip, t: &Timeline) -> Option<Id> {
        t.tracks.iter().find(|tr| tr.clips().iter().any(|c| c.id == clip.id)).map(|tr| tr.id)
    }

    /// "V3" for the third video track of `t`.
    pub(crate) fn lane_label(track: Id, t: &Timeline) -> Option<String> {
        let video: Vec<_> = t.tracks.iter().filter(|tr| tr.kind == TrackKind::Video).collect();
        let i = video.iter().position(|tr| tr.id == track)?;
        Some(format!("V{}", i + 1))
    }

    /// Choices for the track popup of a Picture mask: "No track", then every other video track (nearest above first) as
    /// "V3 \u{2013} clip name" (the clip there at the playhead, else just "V3").
    pub fn picture_track_choices(&self) -> Vec<PictureTrackChoice> {
        let mut out = vec![PictureTrackChoice { track: None, title: "No track".to_string(), lane: None }];
        let (Some(clip), Some(tl)) = (&self.clip, self.timeline.as_ref().and_then(|f| f())) else { return out };
        let Some(own) = Self::track_id_of(clip, &tl) else { return out };
        for tr in tl.picture_mask_tracks_nearest_first(own) {
            let Some(lane) = Self::lane_label(tr.id, &tl) else { continue };
            let under = tr.clips().iter().find(|c| c.timeline().contains(self.playhead));
            out.push(PictureTrackChoice {
                track: Some(tr.id),
                title: under.map_or_else(|| lane.clone(), |c| format!("{lane} \u{2013} {}", c.name)),
                lane: Some(lane),
            });
        }
        out
    }

    /// Index into `picture_track_choices()` the mask shows: its track, "No track" (0) when it has none or the track is gone.
    pub fn picture_track_selection(&self, id: Id, choices: &[PictureTrackChoice]) -> usize {
        let Some(tr) = self.clip.as_ref().and_then(|c| c.mask(id)).and_then(|m| m.picture_track) else { return 0 };
        choices.iter().position(|c| c.track == Some(tr)).unwrap_or(0)
    }

    /// The track a new Picture mask of the shown clip reads (nearest above with a clip at the playhead).
    pub fn default_picture_track(&self) -> Option<Id> {
        let clip = self.clip.as_ref()?;
        let tl = self.timeline.as_ref().and_then(|f| f())?;
        let own = Self::track_id_of(clip, &tl)?;
        tl.default_picture_mask_track(own, self.playhead)
    }

    /// Adds a Picture mask reading `track` (nil = No track), one undo step "Add Mask"; selects it. Returns its id.
    pub fn add_picture_mask(&mut self, track: Option<Id>) -> Option<Id> {
        let mut c = self.working_clip()?;
        if c.kind != TrackKind::Video {
            return None;
        }
        if let Some(track) = track {
            let tl = self.timeline.as_ref().and_then(|f| f())?;
            let own = Self::track_id_of(&c, &tl)?;
            if !tl.accepts_picture_track(track, own) {
                return None;
            }
        }
        let name = c.next_mask_name();
        let m = ClipMask::make_picture(self.ids.next_id(), &name, track);
        let id = m.id;
        let mut masks = c.masks().to_vec();
        masks.push(m);
        c.set_masks(masks);
        self.commit(c, "Add Mask", None);
        self.selected_section = Some(EffectSection::Mask(id));
        Some(id)
    }

    /// Track popup of a Picture mask row (nil = No track), one undo step. A track that is not a valid choice is refused.
    pub fn set_mask_picture_track(&mut self, id: Id, track: Option<Id>) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(m) = c.mask(id) else { return };
        if m.source() != MaskSource::Picture || m.picture_track == track {
            return;
        }
        if let Some(track) = track {
            let Some(tl) = self.timeline.as_ref().and_then(|f| f()) else { return };
            let Some(own) = Self::track_id_of(&c, &tl) else { return };
            if !tl.accepts_picture_track(track, own) {
                return;
            }
        }
        c.update_mask(id, |m| m.picture_track = track);
        self.commit(c, "Change Mask Track", None);
    }

    /// Shape / Brightness popup of a Picture mask row, one undo step.
    pub fn set_mask_picture_channel(&mut self, id: Id, channel: MatteChannel) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(m) = c.mask(id) else { return };
        if m.source() != MaskSource::Picture || m.picture_channel() == channel {
            return;
        }
        c.update_mask(id, |m| m.set_picture_channel(channel));
        self.commit(c, "Change Mask Channel", None);
    }
}
