//! N5: the transcript word under the playhead becomes a big styled text clip (Swift `KeywordAtPlayhead`).

use std::collections::BTreeSet;

use sq_core_model::anchored_animation::KeyframeTemplate;
use sq_core_model::{CaptionItem, CaptionTrack, CaptionWord, SequenceFormat, Timeline};
use sq_core_time::{Time, TimeRange};
use sq_text::caption_presets::{CaptionPresetLibrary, KeyframeTemplateCaptionExt};
use sq_text::text_style::{FontWeight, RGBAColor, TextShadow};
use sq_text::text_template::TextTemplate;

/// The transcript word under the playhead as a title (a namespace).
// Swift: KeywordAtPlayhead.swift:8
pub enum KeywordAtPlayhead {}

/// A word with the caption and track it was found in (Swift `Hit`).
#[derive(Clone, Debug, PartialEq)]
pub struct KeywordHit<'a> {
    pub word: CaptionWord,
    pub item: &'a CaptionItem,
    pub track: &'a CaptionTrack,
}

/// The clip runs this long past the next cut, so the word does not vanish exactly on the edit.
const PAST_CUT: Time = Time::new(3, 10);
const FALLBACK_DURATION: Time = Time::new(1, 1);
const MAX_DURATION: Time = Time::new(3, 1);

impl KeywordAtPlayhead {
    /// Name of the text clip and template.
    // Swift: KeywordAtPlayhead.swift:10
    pub const NAME: &'static str = "Keyword";

    /// The word spoken at `t` on the visible caption tracks (timeline time). In a pause between two words of one
    /// caption the word spoken last counts; `None` outside any caption or before its first word.
    // Swift: KeywordAtPlayhead.swift:18
    pub fn word(t: Time, timeline: &Timeline) -> Option<CaptionWord> {
        Self::found(t, timeline).map(|h| h.word)
    }

    // Swift: KeywordAtPlayhead.swift:23
    pub fn found(t: Time, timeline: &Timeline) -> Option<KeywordHit<'_>> {
        for track in timeline.caption_tracks.iter().filter(|c| c.is_visible) {
            let Some(item) = track.items().iter().find(|i| i.range.contains(t)) else { continue };
            let Some(word) = item.effective_words().into_iter().rev().find(|w| w.range.start <= t) else { continue };
            return Some(KeywordHit { word, item, track });
        }
        None
    }

    /// The word without punctuation at its edges ("Wow!", quotes, commas); inner marks stay (don't, 3.5).
    // Swift: KeywordAtPlayhead.swift:35
    pub fn cleaned(word: &str) -> String {
        // Symbols ($ + ...) are never stripped; of the punctuation, the marks that carry meaning on their own stay:
        // 100%, &, #1, @name.
        let edge = |c: char| c.is_whitespace() || (is_punctuation(c) && !"%&#@\u{2030}".contains(c));
        word.trim_matches(edge).to_string()
    }

    /// Edit points of the cut footage only: clip edges of clips that are not generators (text, shapes, earlier keywords).
    // Swift: KeywordAtPlayhead.swift:42
    pub fn cut_points(t: &Timeline) -> Vec<Time> {
        let mut set = BTreeSet::new();
        for track in t.tracks.iter() {
            for c in track.clips().iter().filter(|c| c.generator.is_none()) {
                set.insert(c.start);
                set.insert(c.timeline().end());
            }
        }
        set.into_iter().collect()
    }

    /// From the word start to the next cut plus 0.3 s (one second without a cut), never longer than 3 s and never
    /// shorter than the word itself.
    // Swift: KeywordAtPlayhead.swift:50
    pub fn range(word: &CaptionWord, edit_points: &[Time], frame_duration: Time) -> TimeRange {
        let start = word.range.start.snapped(frame_duration);
        let mut end = edit_points
            .iter()
            .find(|p| **p > word.range.start)
            .map_or(word.range.start + FALLBACK_DURATION, |p| *p + PAST_CUT);
        end = end.min(word.range.start + MAX_DURATION);
        end = end.max(word.range.end()).max(word.range.start + PAST_CUT);
        end = end.snapped(frame_duration).max(start + frame_duration);
        TimeRange::from_end(start, end)
    }

    /// What `EditorSession::add_keyword_at_playhead` places: the cleaned word as a styled template and where it runs, or
    /// the message to show when there is nothing to place.
    pub fn plan(t: &Timeline, playhead: Time) -> Result<(TextTemplate, TimeRange), &'static str> {
        let hit = Self::found(playhead, t).ok_or("No transcript word under the playhead. Create captions first.")?;
        let text = Self::cleaned(&hit.word.text);
        if text.is_empty() {
            return Err("The word under the playhead is only punctuation.");
        }
        let range = Self::range(&hit.word, &Self::cut_points(t), t.frame_duration());
        Ok((Self::template(&text, &t.format, hit.item, hit.track), range))
    }

    /// The caption look of the word's caption (track style, or the caption's own), made big: 8% of the frame height at
    /// least, heavy weight, a shadow, and the caption pop as animation.
    // Swift: KeywordAtPlayhead.swift:61
    pub fn template(text: &str, format: &SequenceFormat, item: &CaptionItem, track: &CaptionTrack) -> TextTemplate {
        let reference =
            if item.style_overridden || track.style_ref.is_empty() { &item.style_ref } else { &track.style_ref };
        let mut style =
            CaptionPresetLibrary::built_in().style(if reference.is_empty() { None } else { Some(reference) });
        style.size = (style.size * 1.5).max(format.height as f64 * 0.08);
        style.weight = style.weight.max(FontWeight::Heavy);
        if style.shadow.is_none() {
            style.shadow = Some(TextShadow::from_angle(
                RGBAColor { red: 0.0, green: 0.0, blue: 0.0, alpha: 0.6 },
                135.0,
                4.0,
                10.0,
            ));
        }
        let mut template = TextTemplate::new(Self::NAME, text, style);
        template.animation = Some(KeyframeTemplate::caption_pop());
        template
    }
}

/// Unicode punctuation (general categories P*) for the characters a transcript word can start or end with.
// ASCII, Latin-1 and the General Punctuation / CJK blocks, not the full Unicode table (see DECISIONS).
fn is_punctuation(c: char) -> bool {
    matches!(
        c,
        '!' | '"'
            | '#'
            | '%'
            | '&'
            | '\''
            | '('
            | ')'
            | '*'
            | ','
            | '-'
            | '.'
            | '/'
            | ':'
            | ';'
            | '?'
            | '@'
            | '['
            | '\\'
            | ']'
            | '_'
            | '{'
            | '}'
    ) || matches!(c, '\u{A1}' | '\u{A7}' | '\u{AB}' | '\u{B6}' | '\u{B7}' | '\u{BB}' | '\u{BF}')
        || ('\u{2010}'..='\u{2027}').contains(&c)
        || ('\u{2030}'..='\u{205E}').contains(&c)
        || ('\u{3001}'..='\u{3003}').contains(&c)
        || ('\u{3008}'..='\u{3011}').contains(&c)
        || ('\u{FF01}'..='\u{FF0F}').contains(&c) && c != '\u{FF04}' && c != '\u{FF0B}'
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, Track, TrackKind};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn word(text: &str, a: Time, b: Time) -> CaptionWord {
        CaptionWord { text: text.into(), range: TimeRange::from_end(a, b), confidence: None }
    }

    #[test]
    fn cleans_punctuation_at_the_edges_only() {
        assert_eq!(KeywordAtPlayhead::cleaned("\u{201C}Wow!\u{201D},"), "Wow");
        assert_eq!(KeywordAtPlayhead::cleaned("don't"), "don't");
        assert_eq!(KeywordAtPlayhead::cleaned("3.5"), "3.5");
        assert_eq!(KeywordAtPlayhead::cleaned("..."), "");
        for w in ["100%", "$5", "C++", "+1", "&"] {
            assert_eq!(KeywordAtPlayhead::cleaned(w), w);
        }
        assert_eq!(KeywordAtPlayhead::cleaned("\"100%\"!"), "100%");
        assert_eq!(KeywordAtPlayhead::cleaned("Wow!!!"), "Wow");
    }

    fn item(text: &str, a: i64, b: i64, words: Vec<CaptionWord>) -> CaptionItem {
        CaptionItem {
            id: sq_core_time::Id::from_u128(9),
            lines: vec![text.into()],
            range: TimeRange::from_end(s(a), s(b)),
            style_ref: "default".into(),
            animation_ref: String::new(),
            style_overridden: false,
            words,
            position: None,
        }
    }

    fn timeline(items: Vec<CaptionItem>) -> Timeline {
        let id = |n: u128| sq_core_time::Id::from_u128(n);
        let mut t = Timeline::new(id(1), "T", SequenceFormat::new(Time::new(1, 30)), Vec::new());
        let ct: CaptionTrack =
            serde_json::from_value(serde_json::json!({"id": id(2), "items": items})).expect("caption track");
        t.caption_tracks = vec![ct];
        t
    }

    #[test]
    fn finds_the_word_under_the_playhead() {
        // No stored timings: spread by length, "three" covers 3.2 s to 6.4 s.
        let t = timeline(vec![item("one two three four", 0, 8, vec![])]);
        assert_eq!(KeywordAtPlayhead::word(s(4), &t).map(|w| w.text), Some("three".into()));
        assert_eq!(KeywordAtPlayhead::word(s(0), &t).map(|w| w.text), Some("one".into()));
        assert_eq!(KeywordAtPlayhead::word(s(8), &t), None); // half-open
        assert_eq!(KeywordAtPlayhead::word(s(9), &t), None);
    }

    #[test]
    fn a_pause_keeps_the_word_spoken_last() {
        let words = vec![word("hello", Time::ZERO, s(1)), word("world", s(3), s(4))];
        let t = timeline(vec![item("hello world", 10, 15, words)]);
        assert_eq!(KeywordAtPlayhead::word(Time::new(23, 2), &t).map(|w| w.text), Some("hello".into()));
        assert_eq!(KeywordAtPlayhead::word(s(13), &t).map(|w| w.text), Some("world".into()));
    }

    #[test]
    fn hidden_tracks_are_ignored_and_boundaries_belong_to_the_later_word() {
        let mut t = timeline(vec![item("one", 0, 4, vec![])]);
        t.caption_tracks[0].is_visible = false;
        assert_eq!(KeywordAtPlayhead::word(s(1), &t), None);
        let words = vec![word("a", Time::ZERO, s(2)), word("b", s(2), s(4))];
        let t = timeline(vec![item("a b", 0, 4, words)]);
        assert_eq!(KeywordAtPlayhead::word(s(2), &t).map(|w| w.text), Some("b".into()));
        assert_eq!(KeywordAtPlayhead::word(Time::new(59, 30), &t).map(|w| w.text), Some("a".into()));
        let lead = timeline(vec![item("a", 0, 4, vec![word("a", s(1), s(2))])]);
        assert_eq!(KeywordAtPlayhead::word(Time::new(1, 2), &lead), None);
    }

    #[test]
    fn template_is_big_heavy_and_pops_in() {
        let t = timeline(vec![item("one", 0, 4, vec![])]);
        let tpl = KeywordAtPlayhead::template("Wow", &t.format, &t.caption_tracks[0].items()[0], &t.caption_tracks[0]);
        assert_eq!((tpl.text.as_str(), tpl.name.as_str()), ("Wow", "Keyword"));
        assert!(tpl.style.weight >= FontWeight::Heavy);
        assert!(tpl.style.size >= t.format.height as f64 * 0.08);
        assert!(tpl.style.shadow.is_some());
        assert_eq!(tpl.animation, Some(KeyframeTemplate::caption_pop()));
    }

    #[test]
    fn plan_reports_what_is_missing() {
        let none = timeline(vec![]);
        assert_eq!(
            KeywordAtPlayhead::plan(&none, s(1)).err(),
            Some("No transcript word under the playhead. Create captions first.")
        );
        let dots = timeline(vec![item("...", 0, 4, vec![])]);
        assert_eq!(
            KeywordAtPlayhead::plan(&dots, s(1)).err(),
            Some("The word under the playhead is only punctuation.")
        );
        let ok = timeline(vec![item("one two three four", 0, 8, vec![])]);
        let (tpl, range) = KeywordAtPlayhead::plan(&ok, s(4)).expect("plan");
        assert_eq!(tpl.text, "three");
        assert_eq!(range.start, Time::new(16, 5).snapped(Time::new(1, 30)));
    }

    #[test]
    fn range_runs_to_the_next_cut_plus_three_tenths() {
        let fd = Time::new(1, 30);
        let w = word("x", s(2), Time::new(5, 2));
        let r = KeywordAtPlayhead::range(&w, &[s(0), s(4), s(9)], fd);
        assert_eq!(r, TimeRange::from_end(s(2), Time::new(43, 10).snapped(fd)));
    }

    #[test]
    fn range_without_a_cut_is_one_second_and_never_shorter_than_the_word() {
        let fd = Time::new(1, 30);
        let w = word("x", s(2), Time::new(5, 2));
        assert_eq!(KeywordAtPlayhead::range(&w, &[], fd), TimeRange::from_end(s(2), s(3)));
        let long = word("x", s(2), s(5));
        assert_eq!(KeywordAtPlayhead::range(&long, &[], fd), TimeRange::from_end(s(2), s(5)));
    }

    #[test]
    fn range_is_capped_at_three_seconds() {
        let w = word("x", s(2), Time::new(5, 2));
        let r = KeywordAtPlayhead::range(&w, &[s(60)], Time::new(1, 30));
        assert_eq!(r.end(), s(5));
    }

    #[test]
    fn cut_points_ignore_generator_clips() {
        let id = |n: u128| sq_core_time::Id::from_u128(n);
        let foot = Clip::new(id(1), "f", id(2), TrackKind::Video, TimeRange::new(Time::ZERO, s(10)), Time::ZERO);
        let mut generator = Clip::new(id(3), "g", id(4), TrackKind::Video, TimeRange::new(Time::ZERO, s(3)), s(2));
        generator.generator =
            Some(sq_core_model::GeneratorRef { kind: "text".into(), payload: Vec::new(), payload_version: 1 });
        let mut v1 = Track::new(id(6), TrackKind::Video);
        v1.set_clips(vec![foot]);
        let mut v2 = Track::new(id(7), TrackKind::Video);
        v2.set_clips(vec![generator]);
        let t = Timeline::new(id(5), "T", SequenceFormat::new(Time::new(1, 30)), vec![v1, v2]);
        assert_eq!(KeywordAtPlayhead::cut_points(&t), vec![Time::ZERO, s(10)]);
    }
}
