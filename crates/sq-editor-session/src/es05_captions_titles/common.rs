//! Edit helpers shared by the ES5 files.

use sq_core_model::{CaptionHorizontal, CaptionPosition, CaptionVertical, Clip, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};

use crate::EditorSession;

impl EditorSession {
    /// Frame duration of the active sequence (1/30 without one).
    pub(crate) fn es5_frame_duration(&self) -> Time {
        self.active_timeline().map_or(Time::new(1, 30), Timeline::frame_duration)
    }

    /// Where a new generator clip goes: the sequence, a new video track when `never_overwrite` finds no free one, and the
    /// chosen track. A refusal sets `last_error` to `missing`.
    pub(crate) fn es5_generator_target(
        &mut self,
        range: TimeRange,
        preferred: Option<Id>,
        never_overwrite: bool,
        missing: &str,
    ) -> Option<(Id, Option<Track>, Id)> {
        let tl = self.active_timeline_id?;
        let free = generator_track(self.active_timeline()?, range, preferred, !never_overwrite);
        // `never_overwrite`: when no unlocked video track is free over the range, a new video track goes on top.
        let new_track = if free.is_none() && never_overwrite && preferred.is_none() {
            Some(Track::new(self.ids.next_id(), TrackKind::Video))
        } else {
            None
        };
        match free.or(new_track.as_ref().map(|t| t.id)) {
            Some(chosen) => Some((tl, new_track, chosen)),
            None => {
                self.set_error(missing);
                None
            }
        }
    }

    /// The clip `id` of the active sequence.
    pub(crate) fn es5_clip(&self, id: Id) -> Option<&Clip> {
        self.active_timeline()?.tracks.iter().flat_map(|t| t.clips()).find(|c| c.id == id)
    }
}

/// Where a new generator clip (text, shape, graphic) goes: `preferred` when it is a video track, else the lowest unlocked
/// video track that is free over `range` and lies above every clip overlapping `range`, else (`allow_overwrite`) the
/// topmost unlocked video track. `None` when nothing qualifies and overwriting is not allowed: the caller adds a track.
// Swift: EditorSession+Generators.swift:346 (`generatorTrack`, internal)
pub(crate) fn generator_track(
    t: &Timeline,
    range: TimeRange,
    preferred: Option<Id>,
    allow_overwrite: bool,
) -> Option<Id> {
    if let Some(tr) = preferred.and_then(|id| t.track(id))
        && tr.kind == TrackKind::Video
    {
        return Some(tr.id);
    }
    let video: Vec<&Track> = t.tracks.iter().filter(|t| t.kind == TrackKind::Video).collect();
    let overlaps = |tr: &Track| tr.clips().iter().any(|c| c.timeline().overlaps(&range));
    let floor = video.iter().rposition(|tr| overlaps(tr)).map_or(0, |i| i + 1);
    video
        .iter()
        .skip(floor)
        .find(|tr| !tr.is_locked)
        .map(|tr| tr.id)
        .or_else(|| if allow_overwrite { video.iter().rev().find(|tr| !tr.is_locked).map(|tr| tr.id) } else { None })
}

/// Where captions sit without a kit position: bottom center (Swift `CaptionPosition.default`).
pub(crate) fn default_caption_position() -> CaptionPosition {
    CaptionPosition {
        vertical: CaptionVertical::Bottom,
        horizontal: CaptionHorizontal::Center,
        offset_x: 0.0,
        offset_y: 0.0,
    }
}
