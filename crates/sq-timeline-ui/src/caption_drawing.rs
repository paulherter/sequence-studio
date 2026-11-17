// Swift: CaptionDrawing.swift
//! Text shown on a caption item in the timeline.

use sq_core_model::CaptionItem;

/// Caption item text.
pub struct CaptionDrawing;

impl CaptionDrawing {
    /// Lines joined with a space (one row is too low for line breaks); empty captions show a placeholder.
    pub fn preview(item: &CaptionItem) -> String {
        let joined = item.lines.join(" ");
        // Foundation's `.whitespaces`: spaces and tabs, no newlines.
        let t = joined.trim_matches(|c: char| {
            c == '\t'
                || c.is_whitespace()
                    && !matches!(c, '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}')
        });
        if t.is_empty() { "(empty)".to_string() } else { t.to_string() }
    }
}
