// Swift: CaptionPreset.swift
//! Segmentation limits plus opaque style/animation references (resolved elsewhere).

use serde::{Deserialize, Serialize};
use sq_core_time::Time;

/// Look of the caption text box; resolved by the renderer, not by the segmenter.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CaptionEmphasis {
    /// Plain text.
    #[default]
    None,
    /// Rounded filled box behind the text.
    Pill,
}

fn zero_time() -> Time {
    Time::ZERO
}

/// Segmentation limits plus opaque style/animation references (resolved elsewhere).
/// The options of the Create Captions dialog: characters per line, single or double line, minimum duration, gap.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptionPreset {
    /// Longest line.
    pub max_chars_per_line: i64,
    /// Lines per caption.
    pub max_lines: i64,
    /// Longest caption.
    pub max_duration: Time,
    /// Minimum time a caption stays on screen: shorter ones are extended into the silence after them
    /// (`CaptionSegmenter::apply_timing`). It is also a soft limit for sentence-end splits.
    pub min_duration: Time,
    /// A silence between two words at least this long starts a new caption.
    pub pause_break: Time,
    /// Style reference.
    pub style_ref: String,
    /// Animation reference.
    pub animation_ref: String,
    /// Smallest time between the end of a caption and the start of the next one (gap in frames).
    #[serde(default = "zero_time")]
    pub gap: Time,
    /// Hard cap on words per caption (short-video style: 1). `None` = limited only by line/duration rules.
    /// When set to 1, a word longer than `max_chars_per_line` stays whole (words are never split) and too-short
    /// captions borrow time from or merge with a neighbor so `min_duration` always holds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_words_per_caption: Option<i64>,
    /// Look of the text box.
    #[serde(default)]
    pub emphasis: CaptionEmphasis,
}

/// The dialog's fields for `CaptionPreset::with`; unset fields stay as they are.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaptionPresetOptions {
    /// Characters per line, clamped to 8...100.
    pub max_chars_per_line: Option<i64>,
    /// One or two lines.
    pub lines: Option<i64>,
    /// Minimum duration, at least zero.
    pub min_duration: Option<Time>,
    /// Gap in frames of `frame_duration`.
    pub gap_frames: Option<i64>,
    /// Frame duration the gap is counted in.
    pub frame_duration: Time,
}

impl Default for CaptionPresetOptions {
    fn default() -> CaptionPresetOptions {
        CaptionPresetOptions {
            max_chars_per_line: None,
            lines: None,
            min_duration: None,
            gap_frames: None,
            frame_duration: Time::new(1, 30),
        }
    }
}

impl CaptionPreset {
    /// Premiere's name for the gap between captions.
    pub fn min_gap(&self) -> Time {
        self.gap
    }

    /// Sets the gap, at least zero.
    pub fn set_min_gap(&mut self, value: Time) {
        self.gap = value.max(Time::ZERO);
    }

    /// The default look: two lines of 42 characters.
    pub fn standard() -> CaptionPreset {
        CaptionPreset {
            max_chars_per_line: 42,
            max_lines: 2,
            max_duration: Time::new(6, 1),
            min_duration: Time::new(1, 1),
            pause_break: Time::new(4, 5),
            style_ref: "default".into(),
            animation_ref: "caption-pop".into(),
            gap: Time::ZERO,
            max_words_per_caption: None,
            emphasis: CaptionEmphasis::None,
        }
    }

    /// Short-video look: one word per caption, at least 0.2 s, at most 11 characters (a longer word stays whole),
    /// pill emphasis.
    pub fn short_video() -> CaptionPreset {
        CaptionPreset {
            max_chars_per_line: 11,
            max_lines: 1,
            max_duration: Time::new(3, 1),
            min_duration: Time::new(1, 5),
            pause_break: Time::new(1, 2),
            style_ref: "pill".into(),
            animation_ref: "caption-pop".into(),
            gap: Time::ZERO,
            max_words_per_caption: Some(1),
            emphasis: CaptionEmphasis::Pill,
        }
    }

    /// The dialog's fields, clamped to sane values: 8...100 characters, one or two lines.
    pub fn with(&self, o: &CaptionPresetOptions) -> CaptionPreset {
        let mut p = self.clone();
        if let Some(m) = o.max_chars_per_line {
            p.max_chars_per_line = m.clamp(8, 100);
        }
        if let Some(l) = o.lines {
            p.max_lines = if l <= 1 { 1 } else { 2 };
        }
        if let Some(d) = o.min_duration {
            p.min_duration = d.max(Time::ZERO);
        }
        if let Some(g) = o.gap_frames {
            p.gap = o.frame_duration * g.max(0);
        }
        p
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_video_defaults() {
        let p = CaptionPreset::short_video();
        assert_eq!(p.max_words_per_caption, Some(1));
        assert_eq!(p.min_duration, Time::new(200, 1000));
        assert_eq!(p.max_chars_per_line, 11);
        assert_eq!(p.emphasis, CaptionEmphasis::Pill);
    }

    #[test]
    fn min_gap_is_the_gap_of_the_preset() {
        let mut p = CaptionPreset::standard();
        p.set_min_gap(Time::new(200, 1000));
        assert!(p.gap == Time::new(200, 1000) && p.min_gap() == Time::new(200, 1000));
        p.set_min_gap(Time::new(-1, 1));
        assert_eq!(p.gap, Time::ZERO);
    }

    #[test]
    fn gap_is_frame_based_when_built_from_frames() {
        let f = Time::new(1001, 30000);
        let o = CaptionPresetOptions { gap_frames: Some(2), frame_duration: f, ..Default::default() };
        assert_eq!(CaptionPreset::standard().with(&o).gap, f * 2);
    }

    #[test]
    fn options_set_the_limits() {
        let o = CaptionPresetOptions {
            max_chars_per_line: Some(20),
            lines: Some(1),
            min_duration: Some(Time::new(3, 2)),
            ..Default::default()
        };
        let p = CaptionPreset::standard().with(&o);
        assert!(p.max_chars_per_line == 20 && p.max_lines == 1 && p.min_duration == Time::new(3, 2));
        let five = CaptionPresetOptions { lines: Some(5), ..Default::default() };
        assert_eq!(CaptionPreset::standard().with(&five).max_lines, 2); // single or double only
        let two = CaptionPresetOptions { max_chars_per_line: Some(2), ..Default::default() };
        assert_eq!(CaptionPreset::standard().with(&two).max_chars_per_line, 8);
    }

    #[test]
    fn old_preset_json_has_no_gap() {
        let json = r#"{"maxCharsPerLine":30,"maxLines":2,"maxDuration":{"value":6,"timescale":1},"minDuration":{"value":1,"timescale":1},"pauseBreak":{"value":4,"timescale":5},"styleRef":"default","animationRef":"none"}"#;
        let p: CaptionPreset = serde_json::from_str(json).unwrap();
        assert_eq!(p.gap, Time::ZERO);
        assert!(p.max_words_per_caption.is_none() && p.emphasis == CaptionEmphasis::None);
    }

    #[test]
    fn json_round_trip_omits_an_unset_word_cap() {
        let v = serde_json::to_value(CaptionPreset::standard()).unwrap();
        assert!(v.get("maxWordsPerCaption").is_none());
        let back: CaptionPreset = serde_json::from_value(v).unwrap();
        assert_eq!(back, CaptionPreset::standard());
    }
}
