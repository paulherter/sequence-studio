// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorMatchToClip.swift (`ColorMatchPair`, `Clip.isColorMatchPicture`, `Timeline.colorMatchPair`)

//! Clip > Video Options > Match Color to Clip: the one-shot form of Color Match. The reference is picked from the
//! timeline (no Set Reference step), both clips are measured on their own (solo picture: raw file + grade), and the same
//! Color Wheels solver writes the target's first Color effect. Pure model side; the host renders and samples the frames.

use sq_core_model::{Clip, Timeline, TrackKind, floored_to_frame};
use sq_core_time::{Id, Time};

/// Where the reference of a Match came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorMatchSource {
    /// The clip under the playhead on another video track (nearest track; below wins a tie).
    Stacked,
    /// The clip before the target on its own track.
    Previous,
}

/// Which clip a target is matched to, and the sequence times of the two frames that are measured.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ColorMatchPair {
    /// The clip that gets graded.
    pub target: Id,
    /// Sequence time of the target frame that is measured.
    pub target_time: Time,
    /// The clip the target is matched to.
    pub reference: Id,
    /// Sequence time of the reference frame that is measured.
    pub reference_time: Time,
    /// Where the reference came from.
    pub source: ColorMatchSource,
}

/// `extension Clip` of ColorMatchToClip.swift.
pub trait ColorMatchClipExt {
    /// A picture of its own that Match can measure: an enabled video clip from a file (no generator, no nested sequence).
    fn is_color_match_picture(&self) -> bool;
    /// The frame Match measures: the playhead's when it is on the clip, else the clip's middle frame.
    fn color_match_sample_time(&self, playhead: Time, frame_duration: Time) -> Time;
}

impl ColorMatchClipExt for Clip {
    fn is_color_match_picture(&self) -> bool {
        self.kind == TrackKind::Video && self.is_enabled && !self.is_generator() && !self.is_nested()
    }

    fn color_match_sample_time(&self, playhead: Time, frame_duration: Time) -> Time {
        if self.timeline().contains(playhead) {
            return floored_to_frame(playhead, frame_duration);
        }
        floored_to_frame(self.start + Time::scaled_int(self.duration(), 1, 2), frame_duration)
    }
}

/// `extension Timeline` of ColorMatchToClip.swift.
pub trait ColorMatchTimelineExt {
    /// The reference for matching video clip `target`: the clip under `playhead` on the nearest other visible video track,
    /// else the previous clip on the target's own track. `None` when the target cannot be matched or nothing qualifies.
    fn color_match_pair(&self, target: Id, playhead: Time) -> Option<ColorMatchPair>;
}

impl ColorMatchTimelineExt for Timeline {
    fn color_match_pair(&self, target: Id, playhead: Time) -> Option<ColorMatchPair> {
        let fd = self.frame_duration();
        let ti = self.tracks.iter().position(|t| t.kind == TrackKind::Video && t.clip(target).is_some())?;
        let clip = self.tracks[ti].clip(target).filter(|c| c.is_color_match_picture())?;
        let target_time = clip.color_match_sample_time(playhead, fd);
        let mut near: Vec<usize> = (0..self.tracks.len())
            .filter(|&i| i != ti && self.tracks[i].kind == TrackKind::Video && self.tracks[i].is_visible)
            .collect();
        near.sort_by_key(|&i| (i.abs_diff(ti), i));
        let stacked = near.into_iter().find_map(|i| {
            self.tracks[i].clips().iter().find(|c| c.is_color_match_picture() && c.timeline().contains(playhead))
        });
        if let Some(r) = stacked {
            return Some(ColorMatchPair {
                target,
                target_time,
                reference: r.id,
                reference_time: floored_to_frame(playhead, fd),
                source: ColorMatchSource::Stacked,
            });
        }
        let prev = self.tracks[ti]
            .clips()
            .iter()
            .rev()
            .find(|c| c.timeline().end() <= clip.start && c.is_color_match_picture())?;
        Some(ColorMatchPair {
            target,
            target_time,
            reference: prev.id,
            reference_time: prev.color_match_sample_time(prev.start - fd, fd),
            source: ColorMatchSource::Previous,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, Track};
    use sq_core_time::TimeRange;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn clip(n: u128, start: i64, dur: i64) -> Clip {
        Clip::new(
            Id::from_u128(n),
            "c",
            Id::from_u128(100 + n),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, s(dur)),
            s(start),
        )
    }

    fn timeline(tracks: Vec<Vec<Clip>>) -> Timeline {
        let tracks = tracks
            .into_iter()
            .enumerate()
            .map(|(i, clips)| {
                let mut t = Track::new(Id::from_u128(900 + i as u128), TrackKind::Video);
                t.set_clips(clips);
                t
            })
            .collect();
        Timeline::new(Id::from_u128(1), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }

    #[test]
    fn the_stacked_clip_under_the_playhead_is_the_reference() {
        let tl = timeline(vec![vec![clip(1, 0, 10)], vec![clip(2, 0, 10)]]);
        let p = tl.color_match_pair(Id::from_u128(1), s(4)).unwrap();
        assert_eq!((p.reference, p.source), (Id::from_u128(2), ColorMatchSource::Stacked));
        assert_eq!((p.target_time, p.reference_time), (s(4), s(4)));
    }

    #[test]
    fn nearest_track_wins_and_below_wins_a_tie() {
        let tl = timeline(vec![vec![clip(1, 0, 10)], vec![clip(2, 0, 10)], vec![clip(3, 0, 10)], vec![clip(4, 0, 10)]]);
        assert_eq!(tl.color_match_pair(Id::from_u128(3), s(1)).unwrap().reference, Id::from_u128(2));
        assert_eq!(tl.color_match_pair(Id::from_u128(1), s(1)).unwrap().reference, Id::from_u128(2));
    }

    #[test]
    fn without_a_stacked_clip_the_previous_clip_on_the_track_is_used() {
        let tl = timeline(vec![vec![clip(1, 0, 4), clip(2, 6, 4)]]);
        let p = tl.color_match_pair(Id::from_u128(2), s(8)).unwrap();
        assert_eq!((p.reference, p.source), (Id::from_u128(1), ColorMatchSource::Previous));
        // The previous clip is measured at its middle frame (the playhead is not on it).
        assert_eq!(p.reference_time, s(2));
    }

    #[test]
    fn an_unmatchable_target_or_a_lone_clip_has_no_pair() {
        let mut off = clip(1, 0, 10);
        off.is_enabled = false;
        assert!(timeline(vec![vec![off], vec![clip(2, 0, 10)]]).color_match_pair(Id::from_u128(1), s(1)).is_none());
        assert!(timeline(vec![vec![clip(1, 0, 10)]]).color_match_pair(Id::from_u128(1), s(1)).is_none());
    }
}
