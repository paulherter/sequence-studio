// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: CaptionKaraoke.swift

use crate::text_style::{RGBAColor, TextStyle};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sq_core_audio::{CaptionItemExt, KaraokeKey};
use sq_core_model::{CaptionItem, KaraokeStyle};
use sq_core_time::Time;
use std::ops::Range;

/// A Swift `Range<Int>` is stored as `[lower, upper]`.
mod range_pair {
    use super::*;

    pub fn serialize<S: Serializer>(r: &Range<usize>, s: S) -> Result<S::Ok, S::Error> {
        (r.start, r.end).serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Range<usize>, D::Error> {
        let (a, b) = <(usize, usize)>::deserialize(d)?;
        if a > b {
            return Err(serde::de::Error::custom("range lower bound above upper bound"));
        }
        Ok(a..b)
    }
}

/// Words of a text drawn in another color (the karaoke look). `words` counts whitespace-separated words across all
/// lines, in reading order; the stroke and shadow keep their colors, only the fill changes.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextHighlight {
    /// Lit words.
    #[serde(with = "range_pair")]
    pub words: Range<usize>,
    /// Highlight color.
    pub color: RGBAColor,
    /// True: the raster holds only the lit words' fill in the highlight color, on a transparent ground, with the same
    /// size and origin as the plain raster. Captions draw it as a second layer over the plain raster, so the plain
    /// caption is rendered once per caption and never once per word.
    #[serde(default)]
    pub only_lit: bool,
    /// True: the background (pill) is drawn as one box per word instead of one box around the whole text. Only the plain
    /// layer of a karaoke caption carries it (see `plain_highlight`); it lights no words by itself.
    #[serde(default)]
    pub per_word_pill: bool,
}

impl TextHighlight {
    /// A highlight of `words` in `color`, not only-lit, no per-word pill.
    pub fn new(words: Range<usize>, color: RGBAColor) -> Self {
        TextHighlight { words, color, only_lit: false, per_word_pill: false }
    }
}

/// Which words of a caption are lit at a time: the one place both the Program monitor and the export burn-in ask,
/// so they cannot disagree.
pub enum CaptionKaraoke {}

impl CaptionKaraoke {
    /// The highlight color of a karaoke style.
    pub fn color(k: &KaraokeStyle) -> RGBAColor {
        RGBAColor::rgb(k.red, k.green, k.blue)
    }

    /// The "highlight" of the plain layer of a karaoke caption whose style has a pill: no word is lit, but the pill is drawn per
    /// word. `None` (the plain layer keeps its single box) without karaoke, without a background or with fewer than two words.
    pub fn plain_highlight(
        style: &TextStyle,
        karaoke: Option<&KaraokeStyle>,
        word_count: usize,
    ) -> Option<TextHighlight> {
        if karaoke.is_none() || style.background.is_none() || word_count <= 1 {
            return None;
        }
        Some(TextHighlight { words: 0..0, color: RGBAColor::WHITE, only_lit: false, per_word_pill: true })
    }

    /// The highlight that lights word `i` (and, when words stay lit, all before it).
    pub fn highlight_for_word(i: usize, style: &KaraokeStyle) -> TextHighlight {
        TextHighlight {
            words: (if style.keep_spoken { 0 } else { i })..(i + 1),
            color: Self::color(style),
            only_lit: true,
            per_word_pill: false,
        }
    }

    /// The highlight of `item` at timeline time `t`; `None` when karaoke is off or no word is lit.
    pub fn highlight(item: &CaptionItem, style: Option<&KaraokeStyle>, t: Time) -> Option<TextHighlight> {
        let style = style?;
        let count = item.tokens().len();
        if count == 0 {
            return None;
        }
        if let Some(i) = item.active_word(t) {
            return Some(Self::highlight_for_word(i, style));
        }
        // After the last word has been spoken a progressive fill is complete.
        if style.keep_spoken
            && let Some(end) = item.effective_words().last().map(|w| w.range.end())
            && t >= end
            && item.range.contains(t)
        {
            return Some(TextHighlight {
                words: 0..count,
                color: Self::color(style),
                only_lit: true,
                per_word_pill: false,
            });
        }
        None
    }

    /// The highlight `item` ends with (what `highlight` gives just before its end): a caption that holds
    /// through a small gap or stays as the tail under the next caption keeps it (`CaptionHandover`).
    pub fn held_highlight(item: &CaptionItem, style: Option<&KaraokeStyle>) -> Option<TextHighlight> {
        let style = style?;
        let count = item.tokens().len();
        if count == 0 {
            return None;
        }
        let keys = item.karaoke_keys();
        let last: &KaraokeKey = keys.iter().rev().find(|k| k.time < item.range.end())?;
        if let Some(i) = last.active_word {
            return Some(Self::highlight_for_word(i, style));
        }
        if style.keep_spoken {
            Some(TextHighlight { words: 0..count, color: Self::color(style), only_lit: true, per_word_pill: false })
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn karaoke(keep_spoken: bool) -> KaraokeStyle {
        KaraokeStyle { red: 1.0, green: 0.0, blue: 0.0, keep_spoken }
    }

    #[test]
    fn highlight_lights_one_word_or_all_before_it() {
        let h = CaptionKaraoke::highlight_for_word(2, &karaoke(false));
        assert_eq!((h.words.clone(), h.only_lit, h.per_word_pill), (2..3, true, false));
        assert_eq!(h.color, RGBAColor::rgb(1.0, 0.0, 0.0));
        assert_eq!(CaptionKaraoke::highlight_for_word(2, &karaoke(true)).words, 0..3);
    }

    #[test]
    fn plain_highlight_needs_karaoke_a_pill_and_two_words() {
        let mut style = TextStyle::default();
        let k = karaoke(false);
        assert!(CaptionKaraoke::plain_highlight(&style, Some(&k), 3).is_none());
        style.background =
            Some(crate::text_style::TextBackground::new(RGBAColor::BLACK, crate::text_style::BoxPadding::ZERO, 0.0));
        assert!(CaptionKaraoke::plain_highlight(&style, None, 3).is_none());
        assert!(CaptionKaraoke::plain_highlight(&style, Some(&k), 1).is_none());
        let h = CaptionKaraoke::plain_highlight(&style, Some(&k), 2);
        assert_eq!(h.map(|h| (h.words, h.per_word_pill, h.only_lit)), Some((0..0, true, false)));
    }

    #[test]
    fn highlight_json_uses_a_pair_and_old_files_decode_without_flags() {
        let h = TextHighlight::new(1..2, RGBAColor::WHITE);
        let json = serde_json::to_value(&h).unwrap_or_default();
        assert_eq!(json["words"], serde_json::json!([1, 2]));
        let old = r#"{"words":[0,3],"color":{"red":1,"green":0,"blue":0,"alpha":1}}"#;
        let back: Result<TextHighlight, _> = serde_json::from_str(old);
        assert_eq!(back.map(|b| (b.words, b.only_lit, b.per_word_pill)).ok(), Some((0..3, false, false)));
        assert!(
            serde_json::from_str::<TextHighlight>(r#"{"words":[3,0],"color":{"red":1,"green":0,"blue":0,"alpha":1}}"#)
                .is_err()
        );
    }

    #[test]
    fn footage_fill_recolors_the_highlight() {
        let style =
            TextStyle { footage_fill: Some(crate::text_style::TextFootageFill::Inverted), ..TextStyle::default() };
        let h = TextHighlight::new(0..1, RGBAColor::rgb(1.0, 0.0, 0.0));
        assert_eq!(style.drawn_highlight(Some(h)).map(|h| h.color), Some(RGBAColor::WHITE));
    }
}
