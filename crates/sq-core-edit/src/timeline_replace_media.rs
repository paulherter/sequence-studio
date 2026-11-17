// Swift: Timeline+ReplaceMedia.swift
//! Replace edit: a clip plays other media, keeping its place and everything else.

use sq_core_model::{Clip, ClipFootageColor, EditError, Timeline, TrackKind};
use sq_core_time::{Id, Time};

/// The media a Replace edit puts into a clip: what the model needs to know about it (the probe result lives elsewhere).
#[derive(Clone, Debug, PartialEq)]
pub struct ReplacementMedia {
    /// Media item id.
    pub id: Id,
    /// Display name.
    pub name: String,
    /// Length of the file.
    pub duration: Time,
    /// Has a picture stream.
    pub has_video: bool,
    /// Has a sound stream.
    pub has_audio: bool,
    /// A still image.
    pub is_still: bool,
}

/// Where the new media starts playing in a Replace edit.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ReplaceAlignment {
    /// The clip's first frame shows `source_in` of the new media.
    ClipStart {
        /// First media time shown.
        source_in: Time,
    },
    /// The frame of the new media at `media_time` (its own playhead) shows at `timeline_time` (match frame).
    MatchFrame {
        /// Time in the new media.
        media_time: Time,
        /// Time on the timeline.
        timeline_time: Time,
    },
}

/// `extension Timeline` of Timeline+ReplaceMedia.swift.
pub trait TimelineReplaceMediaExt {
    /// Replace edit (Option-drop of a Project item onto a clip): the clip plays `media` instead, keeping its position,
    /// timeline length, track, link, speed, effects and keys. A linked partner that played the same media follows when the
    /// new media has that stream. Refused (nothing changes) when the new media is too short for the played range
    /// (`InsufficientMedia`), lacks the clip's stream (`WrongTrackKind`), or the clip is a still, nest, generator, held
    /// frame or speed-remapped clip (`SpeedUnsupported`). `TrackLocked` for a locked track.
    fn replace_media(
        &mut self,
        clip_id: Id,
        media: &ReplacementMedia,
        alignment: ReplaceAlignment,
    ) -> Result<(), EditError>;
}

fn has_stream(media: &ReplacementMedia, kind: TrackKind) -> bool {
    if kind == TrackKind::Video { media.has_video } else { media.has_audio }
}

impl TimelineReplaceMediaExt for Timeline {
    fn replace_media(
        &mut self,
        clip_id: Id,
        media: &ReplacementMedia,
        alignment: ReplaceAlignment,
    ) -> Result<(), EditError> {
        let ti = self.tracks.iter().position(|t| t.clip(clip_id).is_some()).ok_or(EditError::ClipNotFound)?;
        let old = self.tracks[ti].clip(clip_id).ok_or(EditError::ClipNotFound)?.clone();
        if self.tracks[ti].is_locked {
            return Err(EditError::TrackLocked);
        }
        if old.is_nested()
            || old.is_generator()
            || old.is_still
            || old.hold_frame.is_some()
            || old.speed_keys.is_some()
            || media.is_still
        {
            return Err(EditError::SpeedUnsupported);
        }
        if !has_stream(media, old.kind) {
            return Err(EditError::WrongTrackKind);
        }
        let new_start = match alignment {
            ReplaceAlignment::ClipStart { source_in } => source_in,
            ReplaceAlignment::MatchFrame { media_time, timeline_time } => {
                let into = old.speed.scale(timeline_time - old.start); // source time between the clip's first frame and the match
                if old.reversed { media_time + into - old.source.duration } else { media_time - into }
            }
        };
        let fits = |start: Time, length: Time| start >= Time::ZERO && start + length <= media.duration;
        if !fits(new_start, old.source.duration) {
            return Err(EditError::InsufficientMedia);
        }

        let mut work = self.clone();
        let swap = |c: &Clip, start: Time| -> Clip {
            let mut n = c.clone();
            n.media = media.id;
            n.name = media.name.clone();
            n.media_duration = Some(media.duration);
            n.source.start = start;
            n.footage_color = ClipFootageColor::default(); // the old footage's interpretation does not belong to the new media
            n.markers = None; // clip markers are in source time of the old media
            n
        };
        work.tracks[ti].replace(swap(&old, new_start));

        if let Some(link) = old.link {
            for pi in (0..work.tracks.len()).filter(|&pi| pi != ti) {
                let Some(p) = work.tracks[pi]
                    .clips()
                    .iter()
                    .find(|c| c.link == Some(link) && c.kind != old.kind && c.media == old.media)
                    .filter(|p| has_stream(media, p.kind))
                    .cloned()
                else {
                    continue;
                };
                if work.tracks[pi].is_locked {
                    return Err(EditError::TrackLocked);
                }
                let p_start = p.source.start - old.source.start + new_start;
                if !fits(p_start, p.source.duration) {
                    return Err(EditError::InsufficientMedia);
                }
                work.tracks[pi].replace(swap(&p, p_start));
            }
        }
        *self = work;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{AnimatedProperty, ClipEffect, ClipSpeed, SequenceFormat, Track};
    use sq_core_time::TimeRange;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn media(seconds: i64, video: bool, audio: bool, still: bool) -> ReplacementMedia {
        ReplacementMedia {
            id: Id::from_u128(777),
            name: "new".into(),
            duration: s(seconds),
            has_video: video,
            has_audio: audio,
            is_still: still,
        }
    }
    fn at(source_in: i64) -> ReplaceAlignment {
        ReplaceAlignment::ClipStart { source_in: s(source_in) }
    }

    /// V clip 10..14 s (source 5..9 of 30 s media) linked to an A clip with the same range.
    fn setup() -> (Timeline, Clip, Clip) {
        let m = Id::from_u128(70);
        let mk = |n: u128, kind| {
            let mut c = Clip::new(Id::from_u128(n), "old", m, kind, TimeRange::new(s(5), s(4)), s(10));
            c.link = Some(Id::from_u128(90));
            c.media_duration = Some(s(30));
            c
        };
        let (mut v, a) = (mk(1, TrackKind::Video), mk(2, TrackKind::Audio));
        v.animation.opacity = AnimatedProperty::new(0.5);
        v.effects = vec![ClipEffect::new(Id::from_u128(20), "blur")];
        let mut tv = Track::new(Id::from_u128(10), TrackKind::Video);
        let mut ta = Track::new(Id::from_u128(11), TrackKind::Audio);
        tv.set_clips(vec![v.clone()]);
        ta.set_clips(vec![a.clone()]);
        (Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), vec![tv, ta]), v, a)
    }
    fn clip_of(t: &Timeline, id: Id) -> Clip {
        t.find(id).map(|m| m.clip).unwrap_or_else(|| unreachable!("test clip exists"))
    }

    #[test]
    fn keeps_position_length_effects_and_swaps_media_and_linked_audio() {
        let (mut t, v, a) = setup();
        let new = media(60, true, true, false);
        assert_eq!(t.replace_media(v.id, &new, at(20)), Ok(()));
        let (nv, na) = (clip_of(&t, v.id), clip_of(&t, a.id));
        assert!(nv.media == new.id && na.media == new.id);
        assert!(nv.start == s(10) && nv.duration() == s(4));
        assert!(nv.source.start == s(20) && na.source.start == s(20));
        assert!(nv.animation.opacity.value == 0.5 && nv.effects == v.effects);
        assert!(nv.media_duration == Some(s(60)) && nv.link == v.link);
    }

    #[test]
    fn keeps_speed() {
        let (mut t, v, _) = setup();
        let mut fast = v.clone();
        fast.speed = ClipSpeed::from_percent(200.0); // 4 s of source over 2 s on the timeline
        t.tracks[0].replace(fast.clone());
        assert_eq!(t.replace_media(v.id, &media(60, true, true, false), at(0)), Ok(()));
        let c = clip_of(&t, v.id);
        assert!(c.duration() == s(2) && c.source.duration == s(4) && c.speed == fast.speed);
    }

    #[test]
    fn refuses_media_that_is_too_short() {
        let (mut t, v, _) = setup();
        assert_eq!(t.replace_media(v.id, &media(6, true, true, false), at(3)), Err(EditError::InsufficientMedia));
        assert_eq!(clip_of(&t, v.id).media, v.media); // nothing changed
    }

    #[test]
    fn match_frame_aligns_the_frame_under_the_playhead() {
        let (mut t, v, _) = setup();
        // Playhead at 12 s on the timeline (2 s into the clip) shows frame 40 s of the new media: the clip starts at 38 s.
        let al = ReplaceAlignment::MatchFrame { media_time: s(40), timeline_time: s(12) };
        assert_eq!(t.replace_media(v.id, &media(60, true, true, false), al), Ok(()));
        assert_eq!(clip_of(&t, v.id).source.start, s(38));
    }

    #[test]
    fn match_frame_before_the_media_start_is_refused() {
        let (mut t, v, _) = setup();
        let al = ReplaceAlignment::MatchFrame { media_time: s(1), timeline_time: s(12) };
        assert_eq!(t.replace_media(v.id, &media(60, true, true, false), al), Err(EditError::InsufficientMedia));
    }

    #[test]
    fn media_without_audio_leaves_the_linked_audio_alone() {
        let (mut t, v, a) = setup();
        let new = media(60, true, false, false);
        assert_eq!(t.replace_media(v.id, &new, at(0)), Ok(()));
        assert_eq!(clip_of(&t, v.id).media, new.id);
        assert_eq!(clip_of(&t, a.id).media, a.media);
    }

    #[test]
    fn wrong_streams_stills_nests_and_locked_tracks_are_refused() {
        let (mut t, v, a) = setup();
        assert_eq!(t.replace_media(v.id, &media(60, false, true, false), at(0)), Err(EditError::WrongTrackKind));
        assert_eq!(t.replace_media(a.id, &media(60, true, false, false), at(0)), Err(EditError::WrongTrackKind));
        assert_eq!(t.replace_media(v.id, &media(60, true, true, true), at(0)), Err(EditError::SpeedUnsupported));
        t.tracks[0].is_locked = true;
        assert_eq!(t.replace_media(v.id, &media(60, true, true, false), at(0)), Err(EditError::TrackLocked));
    }

    #[test]
    fn replacing_from_the_audio_clip_keeps_the_video_partner_when_new_media_has_no_picture() {
        let (mut t, v, a) = setup();
        let new = media(60, false, true, false);
        assert_eq!(t.replace_media(a.id, &new, at(0)), Ok(()));
        assert_eq!(clip_of(&t, a.id).media, new.id);
        assert_eq!(clip_of(&t, v.id).media, v.media);
    }
}
