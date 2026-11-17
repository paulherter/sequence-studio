//! Turns translated texts back into captions.
// Swift: CaptionTranslation.swift

use sq_core_model::CaptionItem;
use sq_core_time::{IdSource, word_segmentation};

/// Turns translated texts back into captions: the translated track has the same timings and look as the source.
/// Pure logic; the translation itself (Apple Translation, on device) lives in the app.
pub struct CaptionTranslation;

impl CaptionTranslation {
    /// New caption items with the same ranges, style, animation and position as `source`, one per source caption, carrying
    /// `texts[i]` as their text. A text that is longer than `max_chars_per_line` is broken into at most two balanced lines.
    /// Word timings are not carried over (the words differ): the karaoke highlight spreads over the new words by length.
    /// Captions whose translated text is empty keep the source text. Returns None when the counts differ.
    pub fn translated_items(
        source: &[CaptionItem],
        texts: &[String],
        max_chars_per_line: usize,
        ids: &mut dyn IdSource,
    ) -> Option<Vec<CaptionItem>> {
        if source.len() != texts.len() {
            return None;
        }
        Some(
            source
                .iter()
                .zip(texts)
                .map(|(item, text)| {
                    let mut c = item.clone();
                    c.id = ids.next_id();
                    let words = word_segmentation::words(text);
                    if !words.is_empty() {
                        c.lines = Self::balanced_lines(&words, max_chars_per_line);
                    }
                    c.words = Vec::new();
                    c
                })
                .collect(),
        )
    }

    /// One line when it fits, else two lines broken at the word boundary closest to the middle.
    pub(crate) fn balanced_lines(words: &[String], max_chars: usize) -> Vec<String> {
        let whole = word_segmentation::join(words);
        if whole.chars().count() <= max_chars || words.len() <= 1 {
            return vec![whole];
        }
        let len = |w: &[String]| word_segmentation::join(w).chars().count();
        let (mut best, mut best_diff) = (1, usize::MAX);
        for k in 1..words.len() {
            let (a, b) = (len(&words[..k]), len(&words[k..]));
            let diff = a.abs_diff(b);
            if diff < best_diff {
                best = k;
                best_diff = diff;
            }
        }
        vec![word_segmentation::join(&words[..best]), word_segmentation::join(&words[best..])]
    }

    /// Track name for a translation: "Captions 1 (de)".
    pub fn track_name(source: &str, language: &str) -> String {
        let base = if source.is_empty() { "Captions" } else { source };
        format!("{base} ({language})")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{CaptionPosition, CaptionWord};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    fn t(n: i64) -> Time {
        Time::new(n, 1000)
    }
    fn item(ids: &mut SequentialIds, text: &str, a: i64, b: i64) -> CaptionItem {
        CaptionItem {
            id: ids.next_id(),
            lines: vec![text.to_string()],
            range: TimeRange::from_end(t(a), t(b)),
            style_ref: "bold".into(),
            animation_ref: "pop".into(),
            style_overridden: true,
            words: vec![CaptionWord {
                text: "x".into(),
                range: TimeRange::from_end(Time::ZERO, t(100)),
                confidence: None,
            }],
            position: serde_json::from_value::<CaptionPosition>(serde_json::json!({"vertical": "top"})).ok(),
        }
    }
    fn texts(xs: &[&str]) -> Vec<String> {
        xs.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn timings_and_look_stay_text_changes() {
        let mut ids = SequentialIds::default();
        let src = [item(&mut ids, "Hello world", 0, 1000), item(&mut ids, "Bye", 1500, 2000)];
        let out = CaptionTranslation::translated_items(&src, &texts(&["Hallo Welt", "Tschüss"]), 32, &mut ids).unwrap();
        assert_eq!(out.iter().map(|c| c.lines.join("\n")).collect::<Vec<_>>(), ["Hallo Welt", "Tschüss"]);
        assert_eq!(out.iter().map(|c| c.range).collect::<Vec<_>>(), src.iter().map(|c| c.range).collect::<Vec<_>>());
        assert!(out.iter().all(|c| c.style_ref == "bold" && c.animation_ref == "pop" && c.style_overridden));
        assert_eq!(
            out.iter().map(|c| c.position).collect::<Vec<_>>(),
            src.iter().map(|c| c.position).collect::<Vec<_>>()
        );
        assert!(out.iter().all(|c| c.words.is_empty()));
        assert!(out.iter().all(|c| src.iter().all(|s| s.id != c.id)));
    }

    #[test]
    fn count_mismatch_is_refused() {
        let mut ids = SequentialIds::default();
        let src = [item(&mut ids, "a", 0, 1)];
        assert!(CaptionTranslation::translated_items(&src, &[], 32, &mut ids).is_none());
    }

    #[test]
    fn empty_translation_keeps_the_source_text() {
        let mut ids = SequentialIds::default();
        let src = [item(&mut ids, "keep", 0, 500)];
        let out = CaptionTranslation::translated_items(&src, &texts(&["  "]), 32, &mut ids).unwrap();
        assert_eq!(out[0].lines, ["keep"]);
    }

    #[test]
    fn long_text_breaks_into_two_balanced_lines() {
        let mut ids = SequentialIds::default();
        let src = [item(&mut ids, "x", 0, 500)];
        let long = texts(&["Das ist ein ziemlich langer Untertitel mit vielen Wörtern"]);
        let out = CaptionTranslation::translated_items(&src, &long, 30, &mut ids).unwrap();
        assert_eq!(out[0].lines, ["Das ist ein ziemlich langer", "Untertitel mit vielen Wörtern"]);
    }

    #[test]
    fn track_name_carries_the_language() {
        assert_eq!(CaptionTranslation::track_name("Captions 1", "de"), "Captions 1 (de)");
        assert_eq!(CaptionTranslation::track_name("", "fr"), "Captions (fr)");
    }
}
