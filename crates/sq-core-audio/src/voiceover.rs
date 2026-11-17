// Swift: Voiceover.swift
//! Voiceover from typed text: pure helpers for the script, the file name and the rate. The speech itself is rendered by
//! the app layer (on-device synthesizer, never here); `place_voiceover` puts the result on the timeline.

use sq_core_model::{AudioTag, Clip, EditError, Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange, text::graphemes};
use std::collections::BTreeSet;

/// Namespace of the voiceover helpers.
pub enum Voiceover {}

impl Voiceover {
    /// Longest script accepted by the dialog.
    pub const MAX_CHARACTERS: usize = 5000;
    /// Slowest speaking rate on the 0...1 scale.
    pub const MIN_RATE: f64 = 0.0;
    /// Fastest speaking rate on the 0...1 scale.
    pub const MAX_RATE: f64 = 1.0;
    /// Speaking rate on a 0...1 scale (0.5 = the normal speed of the system voice).
    pub const DEFAULT_RATE: f64 = 0.5;

    /// The rate kept inside the scale.
    pub fn clamped_rate(r: f64) -> f64 {
        r.clamp(Self::MIN_RATE, Self::MAX_RATE)
    }

    /// Trimmed text with runs of spaces and tabs folded to one space and more than one blank line folded to one.
    pub fn cleaned(text: &str) -> String {
        let unified = text.replace("\r\n", "\n").replace('\r', "\n");
        let mut lines: Vec<String> = Vec::new();
        let mut blank = 0;
        for raw in unified.split('\n') {
            let line = raw.split([' ', '\t']).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ");
            if line.is_empty() {
                blank += 1;
                if blank == 1 && !lines.is_empty() {
                    lines.push(String::new());
                }
            } else {
                blank = 0;
                lines.push(line);
            }
        }
        while lines.last().is_some_and(|l| l.is_empty()) {
            lines.pop();
        }
        graphemes(&lines.join("\n")).take(Self::MAX_CHARACTERS).collect()
    }

    /// The rate shown as a speed factor: 0 -> 0.5x, 0.5 (normal) -> 1x, 1 -> 2x (two linear halves).
    pub fn speed_factor(rate: f64) -> f64 {
        let r = Self::clamped_rate(rate);
        if r <= 0.5 { 0.5 + r } else { 1.0 + (r - 0.5) * 2.0 }
    }

    /// Inverse of `speed_factor`; a factor outside 0.5...2 is clamped.
    pub fn rate_for_speed_factor(f: f64) -> f64 {
        let x = f.clamp(0.5, 2.0);
        if x <= 1.0 { x - 0.5 } else { 0.5 + (x - 1.0) / 2.0 }
    }

    /// Rough spoken length in seconds for the dialog's hint: about 150 words a minute at the normal rate, and the rate
    /// slider stretches that between 0.5x and 2x.
    pub fn estimated_seconds(text: &str, rate: f64) -> f64 {
        let words = text.split(char::is_whitespace).filter(|w| !w.is_empty()).count();
        if words == 0 {
            return 0.0;
        }
        let factor = Self::speed_factor(rate);
        words as f64 / 150.0 * 60.0 / factor
    }

    /// "Voiceover - first six words.caf", made unique against `existing` with a counter. Characters unsafe in a file name
    /// are dropped.
    pub fn file_name(text: &str, existing: &BTreeSet<String>) -> String {
        let cleaned = Self::cleaned(text);
        let words: Vec<String> = cleaned
            .split(char::is_whitespace)
            .filter(|w| !w.is_empty())
            .map(|w| {
                graphemes(w)
                    .filter(|g| {
                        g.chars().next().is_some_and(|c| c.is_alphanumeric() || c == '\'' || c == '-' || c == '_')
                    })
                    .collect::<String>()
            })
            .filter(|w| !w.is_empty())
            .take(6)
            .collect();
        let base = if words.is_empty() { "Voiceover".to_string() } else { format!("Voiceover - {}", words.join(" ")) };
        let mut name = format!("{base}.caf");
        let mut n = 2;
        while existing.contains(&name) {
            name = format!("{base} {n}.caf");
            n += 1;
        }
        name
    }

    /// The clip name for a file made by `file_name`.
    pub fn clip_name_from_file(file: &str) -> String {
        // NSString.deletingPathExtension: drops the text after the last "." of the last component (a leading dot stays).
        let (dir, name) = file.rfind('/').map_or(("", file), |i| (&file[..=i], &file[i + 1..]));
        let stem = match name.rfind('.') {
            Some(i) if i > 0 => &name[..i],
            _ => name,
        };
        format!("{dir}{stem}")
    }

    /// "About 12 s." under the voiceover fields; explains when nothing can be made. One text for every dialog.
    pub fn hint_text(text: &str, rate: f64, has_voices: bool) -> String {
        if !has_voices {
            return "No voices are installed. Add one in System Settings > Accessibility > Spoken Content.".to_string();
        }
        let clean = Self::cleaned(text);
        if clean.is_empty() {
            return "Type the text first.".to_string();
        }
        let s = Self::estimated_seconds(&clean, rate).round() as i64;
        if s < 1 { "Under a second.".to_string() } else { format!("About {s} s.") }
    }
}

/// Where `place_voiceover` put the clip.
#[derive(Clone, Debug, PartialEq)]
pub struct VoiceoverPlacement {
    /// The new clip.
    pub clip: Id,
    /// The track holding it.
    pub track: Id,
    /// True when no existing audio track was free and a new one was added.
    pub created_track: bool,
}

/// `extension Timeline` of Voiceover.swift.
pub trait VoiceoverTimelineExt {
    /// Puts a voiceover clip (`media`, `duration` long) at `t` rounded up to a frame, on the first audio track that is
    /// free there: a Dialogue track first, then an empty untagged one, else a new track at the bottom. Locked tracks and
    /// tracks with another role are never used, nothing is overwritten. The track gets the Dialogue role (its voiced
    /// preset is the shared voice chain). Fails with `EmptyClip` for a zero length.
    fn place_voiceover(
        &mut self,
        media: Id,
        name: &str,
        duration: Time,
        t: Time,
        ids: &mut dyn IdSource,
    ) -> Result<VoiceoverPlacement, EditError>;
}

impl VoiceoverTimelineExt for Timeline {
    fn place_voiceover(
        &mut self,
        media: Id,
        name: &str,
        duration: Time,
        t: Time,
        ids: &mut dyn IdSource,
    ) -> Result<VoiceoverPlacement, EditError> {
        if duration <= Time::ZERO {
            return Err(EditError::EmptyClip);
        }
        let start = t.ceiled(self.frame_duration()).max(Time::ZERO);
        let range = TimeRange::new(start, duration);
        let free = |tr: &Track| {
            tr.kind == TrackKind::Audio && !tr.is_locked && !tr.clips().iter().any(|c| c.timeline().overlaps(&range))
        };
        let mut index =
            self.tracks.iter().position(|tr| free(tr) && tr.audio_role == Some(AudioTag::Dialogue)).or_else(|| {
                self.tracks.iter().position(|tr| free(tr) && tr.audio_role.is_none() && tr.clips().is_empty())
            });
        let mut created = false;
        if index.is_none() {
            // shortcut: Timeline+AddTrack belongs to the edit crate; swap for Timeline::add_track once it exists.
            let mut track = Track::new(ids.next_id(), TrackKind::Audio);
            track.is_targeted = !self.tracks.iter().any(|x| x.kind == TrackKind::Audio);
            self.tracks.push(track);
            index = Some(self.tracks.len() - 1);
            created = true;
        }
        let i = index.unwrap_or(0);
        let mut clip =
            Clip::new(ids.next_id(), name, media, TrackKind::Audio, TimeRange::new(Time::ZERO, duration), start);
        clip.media_duration = Some(duration);
        let mut work = self.tracks[i].clone();
        work.overwrite(clip.clone(), ids)?;
        work.audio_role = Some(AudioTag::Dialogue);
        let track = work.id;
        self.tracks[i] = work;
        Ok(VoiceoverPlacement { clip: clip.id, track, created_track: created })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio_role::tests::{clip, fresh_id, track};
    use sq_core_model::SequenceFormat;
    use sq_core_time::SequentialIds;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn tl() -> Timeline {
        Timeline::new(
            Id::from_u128(9),
            "T",
            SequenceFormat::new(Time::new(1, 30)),
            vec![Track::new(fresh_id(), TrackKind::Video), Track::new(fresh_id(), TrackKind::Audio)],
        )
    }

    #[test]
    fn script_is_trimmed_and_blank_lines_collapsed() {
        assert_eq!(Voiceover::cleaned("  Hello   world \r\n\r\n\r\n\r\nSecond\t line  "), "Hello world\n\nSecond line");
        assert_eq!(Voiceover::cleaned(" \n "), "");
    }

    #[test]
    fn script_is_capped_at_the_limit() {
        let long = "a".repeat(Voiceover::MAX_CHARACTERS + 50);
        assert_eq!(Voiceover::cleaned(&long).chars().count(), Voiceover::MAX_CHARACTERS);
    }

    #[test]
    fn file_name_uses_first_words_and_stays_unique() {
        let text = "Welcome to the show, today we talk about cats and dogs";
        let name = Voiceover::file_name(text, &BTreeSet::new());
        assert_eq!(name, "Voiceover - Welcome to the show today we.caf");
        let taken: BTreeSet<String> = [name].into();
        assert_eq!(Voiceover::file_name(text, &taken), "Voiceover - Welcome to the show today we 2.caf");
        assert_eq!(Voiceover::file_name("!!!", &BTreeSet::new()), "Voiceover.caf");
        assert_eq!(Voiceover::file_name("a/b: c", &BTreeSet::new()), "Voiceover - ab c.caf");
    }

    #[test]
    fn clip_name_drops_the_extension() {
        assert_eq!(Voiceover::clip_name_from_file("Voiceover - Hi there.caf"), "Voiceover - Hi there");
    }

    #[test]
    fn estimate_scales_with_words_and_rate() {
        let text = "word ".repeat(150);
        let normal = Voiceover::estimated_seconds(&text, Voiceover::DEFAULT_RATE);
        assert!((normal - 60.0).abs() < 6.0);
        assert!(Voiceover::estimated_seconds(&text, Voiceover::MAX_RATE) < normal);
        assert_eq!(Voiceover::estimated_seconds("", Voiceover::DEFAULT_RATE), 0.0);
    }

    #[test]
    fn rate_is_clamped_to_the_range() {
        assert_eq!(Voiceover::clamped_rate(-1.0), Voiceover::MIN_RATE);
        assert_eq!(Voiceover::clamped_rate(5.0), Voiceover::MAX_RATE);
        assert_eq!(Voiceover::clamped_rate(0.5), 0.5);
    }

    #[test]
    fn speed_factor_maps_the_rate_to_half_and_double() {
        assert!(
            Voiceover::speed_factor(0.0) == 0.5
                && Voiceover::speed_factor(0.5) == 1.0
                && Voiceover::speed_factor(1.0) == 2.0
        );
        for f in [0.5, 0.75, 1.0, 1.5, 2.0] {
            assert!((Voiceover::speed_factor(Voiceover::rate_for_speed_factor(f)) - f).abs() < 1e-9);
        }
        assert_eq!(Voiceover::rate_for_speed_factor(9.0), 1.0);
    }

    #[test]
    fn hint_text_explains_what_is_missing() {
        assert!(Voiceover::hint_text("Hi", 0.5, false).starts_with("No voices"));
        assert_eq!(Voiceover::hint_text("  ", 0.5, true), "Type the text first.");
        assert_eq!(Voiceover::hint_text("Hi", 0.5, true), "Under a second.");
        let words = vec!["word"; 150].join(" ");
        assert_eq!(Voiceover::hint_text(&words, 0.5, true), "About 60 s.");
    }

    #[test]
    fn places_on_an_empty_audio_track_and_tags_it_dialogue() {
        let (mut t, mut ids, media) = (tl(), SequentialIds::default(), fresh_id());
        let r = t.place_voiceover(media, "VO", s(4), s(2), &mut ids);
        let Ok(r) = r else { panic!("placement failed: {r:?}") };
        assert!(!r.created_track);
        let tr = t.tracks.iter().find(|x| x.id == r.track);
        assert!(tr.is_some_and(|x| x.kind == TrackKind::Audio && x.audio_role == Some(AudioTag::Dialogue)));
        let c = &tr.map(|x| x.clips()[0].clone());
        let c = c.as_ref().map(|c| (c.id == r.clip, c.start, c.timeline().duration, c.media, c.kind, c.media_duration));
        assert_eq!(c, Some((true, s(2), s(4), media, TrackKind::Audio, Some(s(4)))));
    }

    #[test]
    fn prefers_a_free_dialogue_track_over_an_empty_one() {
        let mut t = tl();
        let dlg = track(77, Some(AudioTag::Dialogue), vec![]);
        t.tracks.push(dlg.clone());
        let r = t.place_voiceover(fresh_id(), "VO", s(2), Time::ZERO, &mut SequentialIds::default());
        assert_eq!(r.map(|r| r.track), Ok(dlg.id));
    }

    #[test]
    fn skips_busy_locked_and_music_tracks_and_never_overwrites() {
        let mut t = tl();
        let existing = clip(0, 10, None);
        t.tracks[1].set_clips(vec![existing.clone()]);
        t.tracks[1].audio_role = Some(AudioTag::Music);
        let mut locked = Track::new(fresh_id(), TrackKind::Audio);
        locked.is_locked = true;
        t.tracks.push(locked.clone());
        let r = t.place_voiceover(fresh_id(), "VO", s(3), s(1), &mut SequentialIds::default());
        let Ok(r) = r else { panic!("placement failed: {r:?}") };
        assert!(r.created_track);
        assert_eq!(t.tracks[1].clips(), &[existing]);
        assert!(t.tracks.iter().find(|x| x.id == r.track).is_some_and(|x| x.audio_role == Some(AudioTag::Dialogue)));
        assert!(t.tracks.iter().find(|x| x.id == locked.id).is_some_and(|x| x.clips().is_empty()));
    }

    #[test]
    fn a_dialogue_track_busy_elsewhere_still_takes_a_clip_in_a_gap() {
        let mut t = tl();
        let dlg = track(77, Some(AudioTag::Dialogue), vec![clip(0, 2, None)]);
        t.tracks.push(dlg.clone());
        let r = t.place_voiceover(fresh_id(), "VO", s(2), s(5), &mut SequentialIds::default());
        assert_eq!(r.map(|r| (r.track, r.created_track)), Ok((dlg.id, false)));
    }

    #[test]
    fn start_is_rounded_up_to_a_frame_and_empty_clips_refused() {
        let mut t = tl();
        let r = t.place_voiceover(fresh_id(), "VO", s(1), Time::new(1, 40), &mut SequentialIds::default());
        let Ok(r) = r else { panic!("placement failed: {r:?}") };
        let start = t.tracks.iter().flat_map(|x| x.clips()).find(|c| c.id == r.clip).map(|c| c.start);
        assert_eq!(start, Some(Time::new(1, 30)));
        let e = t.place_voiceover(fresh_id(), "VO", Time::ZERO, Time::ZERO, &mut SequentialIds::default());
        assert_eq!(e, Err(EditError::EmptyClip));
    }
}
