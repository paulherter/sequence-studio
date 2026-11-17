// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Generators.swift (addGeneratorClip)

use crate::labels::TEXT_GENERATOR;
use crate::{Clip, EditError, GeneratorRef, Project, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};

/// Where a generator clip goes.
#[derive(Clone, Copy, Debug)]
pub struct GeneratorPlacement {
    /// The sequence.
    pub timeline: Id,
    /// The video track.
    pub track: Id,
    /// Timeline start.
    pub start: Time,
    /// Length.
    pub duration: Time,
}

impl Project {
    /// Places a generator clip (a text layer, a Graphic) on a video track as an overwrite, like any drop. Errors:
    /// `WrongTrackKind` (audio track), `TrackLocked`, `EmptyClip` (duration under one frame or a start before 0),
    /// `ClipNotFound` (track) or `TimelineNotFound`. Returns the new clip's id.
    pub fn add_generator_clip(
        &mut self,
        generator: GeneratorRef,
        name: Option<&str>,
        at: GeneratorPlacement,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        let GeneratorPlacement { timeline, track, start, duration } = at;
        let t = self.timelines.iter().find(|t| t.id == timeline).ok_or(EditError::TimelineNotFound)?;
        let tr = t.tracks.iter().position(|x| x.id == track).ok_or(EditError::ClipNotFound)?;
        if t.tracks[tr].kind != TrackKind::Video {
            return Err(EditError::WrongTrackKind);
        }
        if t.tracks[tr].is_locked {
            return Err(EditError::TrackLocked);
        }
        if duration < t.frame_duration() || start < Time::ZERO {
            return Err(EditError::EmptyClip);
        }
        let id = ids.next_id();
        let title = match name {
            Some(n) => n.to_string(),
            None if generator.kind == TEXT_GENERATOR => "Text".to_string(),
            None => capitalized(&generator.kind),
        };
        let mut clip = Clip::new(id, &title, id, TrackKind::Video, TimeRange::new(Time::ZERO, duration), start);
        clip.generator = Some(generator);
        self.edit(timeline, |t| t.tracks[tr].overwrite(clip, ids))?;
        Ok(id)
    }
}

/// `String.capitalized`: the first letter of each word upper case, the rest lower case.
fn capitalized(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut word_start = true;
    for c in s.chars() {
        if c.is_alphanumeric() {
            if word_start {
                out.extend(c.to_uppercase());
            } else {
                out.extend(c.to_lowercase());
            }
            word_start = false;
        } else {
            out.push(c);
            word_start = true;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nesting::test_util::*;

    fn project() -> Project {
        project_json(
            vec![],
            vec![timeline_json(1, vec![track_json(11, "video", vec![]), track_json(12, "audio", vec![])])],
        )
    }

    #[test]
    fn a_generator_lands_on_a_video_track_with_its_name_and_payload() {
        let mut p = project();
        let ids = &mut TestIds(700);
        let go = |p: &mut Project, kind: &str, name: Option<&str>, ids: &mut TestIds| {
            let g = GeneratorRef { kind: kind.to_string(), payload: vec![1, 2], payload_version: 3 };
            let at = GeneratorPlacement {
                timeline: id(1),
                track: id(11),
                start: Time::new(2, 1),
                duration: Time::new(4, 1),
            };
            p.add_generator_clip(g, name, at, ids)
        };
        let text = go(&mut p, "text", None, ids);
        let c = p.timelines[0].tracks[0].clip(text.unwrap_or(Id::NIL)).cloned();
        assert_eq!(
            c.as_ref().map(|c| (c.name.as_str(), c.start, c.duration(), c.media == c.id)),
            Some(("Text", Time::new(2, 1), Time::new(4, 1), true))
        );
        assert_eq!(c.and_then(|c| c.generator).map(|g| (g.payload, g.payload_version)), Some((vec![1, 2], 3)));
        // It overwrites what it covers; other kinds get a capitalized name.
        let g = go(&mut p, "lottie animation", None, ids).unwrap_or(Id::NIL);
        assert_eq!(p.timelines[0].tracks[0].clips().len(), 1);
        assert_eq!(p.timelines[0].tracks[0].clip(g).map(|c| c.name.as_str()), Some("Lottie Animation"));
        assert_eq!(go(&mut p, "text", Some("Mine"), ids).map(|_| ()), Ok(()));
    }

    #[test]
    fn bad_places_are_refused_and_change_nothing() {
        let mut p = project();
        let ids = &mut TestIds(700);
        let mut go = |p: &mut Project, tl: u32, track: u32, start: i64, dur: i64| {
            let g = GeneratorRef { kind: "text".to_string(), payload: vec![], payload_version: 1 };
            let at = GeneratorPlacement {
                timeline: id(tl),
                track: id(track),
                start: Time::new(start, 1),
                duration: Time::new(dur, 1),
            };
            p.add_generator_clip(g, None, at, ids)
        };
        assert_eq!(go(&mut p, 404, 11, 0, 1), Err(EditError::TimelineNotFound));
        assert_eq!(go(&mut p, 1, 404, 0, 1), Err(EditError::ClipNotFound));
        assert_eq!(go(&mut p, 1, 12, 0, 1), Err(EditError::WrongTrackKind));
        assert_eq!(go(&mut p, 1, 11, -1, 1), Err(EditError::EmptyClip));
        assert_eq!(go(&mut p, 1, 11, 0, 0), Err(EditError::EmptyClip));
        p.timelines[0].tracks[0].is_locked = true;
        assert_eq!(go(&mut p, 1, 11, 0, 1), Err(EditError::TrackLocked));
        assert!(p.timelines[0].tracks[0].clips().is_empty());
    }
}
