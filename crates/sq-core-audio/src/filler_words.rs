// Swift: FillerWords.swift
//! Filler-word detection on the timed caption words (the project's transcript data): "um", "uh", "äh", "ähm" and the like
//! become frame-aligned cuts for the same ripple path as Remove Silences. The list depends on the language: German "um" is
//! a real word.

use crate::silence_removal::SilenceRemoval;
use sq_core_model::{CaptionWord, Timeline};
use sq_core_time::{Time, TimeRange};
use std::collections::BTreeSet;

/// Namespace of the filler-word rules.
pub enum FillerWords {}

/// Sounds that are never a real word in the languages we know (also the whole list for a language without its own).
const NEUTRAL: [&str; 16] =
    ["uh", "uhh", "uhm", "hm", "hmm", "hmmm", "mm", "mmm", "mhm", "äh", "ähh", "ähm", "ähhm", "öh", "öhm", "ehm"];

fn own(language: &str) -> &'static [&'static str] {
    match language {
        "en" => &["um", "umm", "er", "erm"],
        "de" => &["äm", "ämm"],
        "fr" => &["euh", "euhh"],
        _ => &[],
    }
}

/// What a scan of the captions found.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FillerScan {
    /// Filler words found (before cuts joined neighbors).
    pub count: usize,
    /// The cuts.
    pub cuts: Vec<TimeRange>,
    /// Captions with text but no word timings: their words are only spread over the caption, so they are left alone.
    pub untimed_captions: usize,
}

impl FillerScan {
    /// Total length of the cuts.
    pub fn total(&self) -> Time {
        self.cuts.iter().fold(Time::ZERO, |a, c| a + c.duration)
    }
}

impl FillerWords {
    /// Words of `language` (BCP-47, only the language part counts) that count as filler.
    pub fn list(language: &str) -> BTreeSet<String> {
        let base = language.split(['-', '_']).find(|p| !p.is_empty()).map(str::to_lowercase).unwrap_or_default();
        NEUTRAL.iter().chain(own(&base)).map(|s| s.to_string()).collect()
    }

    /// `text` without punctuation around it, lowercased. Letters are Unicode letters (Foundation's set also counts marks).
    fn normalised(text: &str) -> String {
        text.to_lowercase().trim_matches(|c: char| !c.is_alphabetic()).to_string()
    }

    /// Whether `text` is a filler in `language`.
    pub fn is_filler(text: &str, language: &str) -> bool {
        Self::list(language).contains(&Self::normalised(text))
    }

    /// How many of `words` are fillers.
    pub fn count(words: &[CaptionWord], language: &str) -> usize {
        words.iter().filter(|w| Self::is_filler(&w.text, language)).count()
    }

    /// Cuts for the filler words among `words` (timeline time): each from the nearest frame to its start to the nearest
    /// frame to its end, sorted, touching ones joined, shorter than a frame dropped.
    pub fn cuts(words: &[CaptionWord], language: &str, frame_duration: Time) -> Vec<TimeRange> {
        if frame_duration <= Time::ZERO {
            return Vec::new();
        }
        let half = Time::new(frame_duration.value(), frame_duration.timescale() * 2);
        let nearest = |t: Time| frame_duration * (t + half).frame_index(frame_duration);
        let raw: Vec<TimeRange> = words
            .iter()
            .filter(|w| Self::is_filler(&w.text, language))
            .filter_map(|w| {
                let (a, b) = (nearest(w.range.start), nearest(w.range.end()));
                (b - a >= frame_duration).then(|| TimeRange::from_end(a, b))
            })
            .collect();
        SilenceRemoval::normalized(&raw)
    }

    /// Fillers in the timed words of every visible caption track of `timeline`.
    pub fn scan(timeline: &Timeline, language: &str) -> FillerScan {
        let mut words: Vec<CaptionWord> = Vec::new();
        let mut untimed = 0;
        for track in timeline.caption_tracks.iter().filter(|t| t.is_visible) {
            for item in track.items().iter().filter(|i| !i.tokens().is_empty()) {
                if item.has_word_timings() {
                    words.extend(item.effective_words());
                } else {
                    untimed += 1;
                }
            }
        }
        let cuts = Self::cuts(&words, language, timeline.frame_duration());
        FillerScan { count: Self::count(&words, language), cuts, untimed_captions: untimed }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::audio_role::tests::{fresh_id, timeline};
    use crate::caption_item::tests::{item, range, word};
    use sq_core_model::{CaptionItem, CaptionTrack};

    const FD: Time = Time::new(1, 30);

    #[test]
    fn lists_are_language_aware() {
        assert!(FillerWords::is_filler("um", "en-US"));
        assert!(!FillerWords::is_filler("um", "de-DE")); // German "um" is a real word
        assert!(FillerWords::is_filler("ähm", "de-DE"));
        assert!(FillerWords::is_filler("Äh,", "de-AT"));
        assert!(FillerWords::is_filler("Uh...", "en"));
        assert!(!FillerWords::is_filler("umbrella", "en-GB"));
        assert!(!FillerWords::is_filler("hello", "en-US"));
        assert!(FillerWords::is_filler("uhm", "fr-FR")); // the neutral sounds hold everywhere
        assert!(!FillerWords::is_filler("um", "fr-FR"));
        assert!(FillerWords::is_filler("euh", "fr-FR"));
    }

    #[test]
    fn cuts_are_frame_aligned_sorted_and_merged() {
        let words = [word("so", 0, 300), word("um", 1_010, 1_390), word("uh", 1_400, 1_700), word("yes", 2_000, 2_300)];
        let cuts = FillerWords::cuts(&words, "en-US", FD);
        assert_eq!(cuts, vec![TimeRange::from_end(Time::new(30, 30), Time::new(51, 30))]); // um + uh touch after snapping and join
        let de = FillerWords::cuts(&words, "de-DE", FD);
        assert_eq!(de, vec![TimeRange::from_end(Time::new(42, 30), Time::new(51, 30))]); // "um" is no German filler
        assert_eq!(FillerWords::count(&words, "de-DE"), 1);
    }

    #[test]
    fn fillers_shorter_than_a_frame_are_dropped() {
        assert!(FillerWords::cuts(&[word("uh", 1_000, 1_010)], "en", FD).is_empty());
    }

    /// A track with `items`, built the way the model reads a file (its constructor is not public yet).
    pub(crate) fn track_with(items: &[CaptionItem], visible: bool) -> CaptionTrack {
        let json = serde_json::json!({"id": fresh_id(), "isVisible": visible, "items": items});
        serde_json::from_value(json).unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn scan_uses_timed_captions_and_reports_the_rest() {
        let mut timed = item(&["so um yes"], range(0, 3_000));
        timed.words = vec![word("so", 0, 300), word("um", 1_000, 1_400), word("yes", 2_000, 2_300)];
        let untimed = item(&["uh no"], range(4_000, 5_000));
        let mut tl = timeline(vec![]);
        tl.set_frame_duration(FD);
        tl.caption_tracks = vec![track_with(&[timed, untimed], true)];
        let scan = FillerWords::scan(&tl, "en-US");
        assert!(scan.count == 1 && scan.cuts.len() == 1);
        assert_eq!(scan.untimed_captions, 1); // spread timings would be a guess: not cut
        assert_eq!(scan.total(), scan.cuts[0].duration);
    }

    #[test]
    fn hidden_tracks_are_ignored() {
        let mut c = item(&["um"], range(0, 1_000));
        c.words = vec![word("um", 100, 600)];
        let mut tl = timeline(vec![]);
        tl.set_frame_duration(FD);
        tl.caption_tracks = vec![track_with(&[c], false)];
        assert!(FillerWords::scan(&tl, "en").cuts.is_empty());
    }
}
