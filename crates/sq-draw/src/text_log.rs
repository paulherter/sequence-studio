//! A per-thread record of the text a frame draws, for layout tests: what was asked, what the fit rule drew (whole,
//! ended with an ellipsis, or nothing) and where. Off unless a test starts it; the cost when off is one flag read.

use std::cell::RefCell;

/// One drawn (or hidden) line of text, in pixels.
#[derive(Clone, Debug, PartialEq)]
pub struct TextRun {
    /// The text the view asked for.
    pub asked: String,
    /// The text drawn; `None` when the fit rule hid it.
    pub drawn: Option<String>,
    /// The drawn box: left, top, width, height.
    pub rect: (f32, f32, f32, f32),
    /// The width the view offered.
    pub room: f32,
    /// The clip rect at the time: left, top, width, height.
    pub clip: (f32, f32, f32, f32),
}

impl TextRun {
    /// Whether the drawn text is the asked text unchanged.
    pub fn is_whole(&self) -> bool {
        self.drawn.as_deref() == Some(self.asked.as_str())
    }

    /// Whether the text was cut inside a word (`Captio...`): the drawn text is a prefix of the asked text and the rest does
    /// not start at a word boundary. A whole text, a cut at a word boundary and a hidden text are not.
    pub fn is_cut_inside_a_word(&self) -> bool {
        let Some(d) = self.drawn.as_deref() else { return false };
        if d == self.asked {
            return false;
        }
        let base = d.strip_suffix('\u{2026}').unwrap_or(d);
        match self.asked.strip_prefix(base) {
            Some(rest) => base.is_empty() || !rest.starts_with(char::is_whitespace),
            None => true,
        }
    }
}

thread_local! {
    static LOG: RefCell<Option<Vec<TextRun>>> = const { RefCell::new(None) };
    /// (original, cut text) pairs of the shared fit rule, newest last: a caller that cuts before it draws still shows
    /// the original in the record.
    static CUTS: RefCell<Vec<(String, String)>> = const { RefCell::new(Vec::new()) };
}

/// Notes that the fit rule cut `original` to `cut`.
pub(crate) fn note_cut(original: &str, cut: &str) {
    if active() {
        CUTS.with(|c| c.borrow_mut().push((original.to_string(), cut.to_string())));
    }
}

/// The text `drawn` was cut from by the fit rule while recording, if it was.
pub(crate) fn original_of(drawn: &str) -> Option<String> {
    CUTS.with(|c| c.borrow().iter().rev().find(|(_, cut)| cut == drawn).map(|(o, _)| o.clone()))
}

/// Starts (and clears) the record on this thread.
pub fn start() {
    CUTS.with(|c| c.borrow_mut().clear());
    LOG.with(|l| *l.borrow_mut() = Some(Vec::new()));
}

/// Stops the record and returns it.
pub fn finish() -> Vec<TextRun> {
    LOG.with(|l| l.borrow_mut().take()).unwrap_or_default()
}

/// Whether a record runs on this thread.
pub(crate) fn active() -> bool {
    LOG.with(|l| l.borrow().is_some())
}

pub(crate) fn note(run: TextRun) {
    LOG.with(|l| {
        if let Some(v) = l.borrow_mut().as_mut() {
            v.push(run);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(asked: &str, drawn: Option<&str>) -> TextRun {
        TextRun {
            asked: asked.into(),
            drawn: drawn.map(Into::into),
            rect: (0.0, 0.0, 0.0, 0.0),
            room: 0.0,
            clip: (0.0, 0.0, 0.0, 0.0),
        }
    }

    #[test]
    fn a_cut_inside_a_word_is_told_from_a_cut_at_a_boundary() {
        assert!(run("Captions", Some("Captio\u{2026}")).is_cut_inside_a_word());
        assert!(!run("Transcript Captions", Some("Transcript\u{2026}")).is_cut_inside_a_word());
        assert!(run("Transcript Captions", Some("Transcri\u{2026}")).is_cut_inside_a_word());
        assert!(!run("Name", Some("Name")).is_cut_inside_a_word());
        assert!(!run("Name here", None).is_cut_inside_a_word());
        assert!(!run("Name here", Some("Name")).is_cut_inside_a_word());
    }
}
