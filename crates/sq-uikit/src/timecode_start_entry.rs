//! Port of `SQUIKit/Sources/SQUIKit/TimecodeStartEntry.swift`.

use crate::timecode::Timecode;
use sq_core_time::Time;

/// State of the "Starts at" field in Sequence Settings. The start is kept as a rational `Time`, never as text, so a change of
/// frame rate or of Display (Timecode / Frames) reformats the text instead of reinterpreting it: "1800" typed as frames stays
/// 1800 frames when Display switches to Timecode (then reads "00:01:00:00" at 30 fps).
#[derive(Clone, Debug, PartialEq)]
pub struct TimecodeStartEntry {
    /// Last valid start (never negative).
    start: Time,
    frame_duration: Time,
    frames_only: bool,
    /// Field text as shown; may be invalid while the user is typing.
    text: String,
    /// False when `text` does not parse. `start` still holds the last valid value, so nothing is lost.
    is_valid: bool,
}

impl TimecodeStartEntry {
    pub fn new(start: Time, frame_duration: Time, frames_only: bool) -> TimecodeStartEntry {
        let mut e = TimecodeStartEntry { start, frame_duration, frames_only, text: String::new(), is_valid: true };
        e.text = e.timecode().format(start);
        e
    }

    pub fn start(&self) -> Time {
        self.start
    }

    pub fn frame_duration(&self) -> Time {
        self.frame_duration
    }

    pub fn frames_only(&self) -> bool {
        self.frames_only
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn is_valid(&self) -> bool {
        self.is_valid
    }

    /// Drop frame where the rate has it; frame counts when `frames_only`.
    pub fn timecode(&self) -> Timecode {
        let mut tc = Timecode::new(self.frame_duration, true);
        tc.frames_only = self.frames_only;
        tc
    }

    /// The user edited the field. A valid, non-negative entry becomes the start; otherwise the entry is flagged invalid.
    pub fn set_text(&mut self, new_text: &str) {
        self.text = new_text.to_string();
        match self.timecode().parse(new_text) {
            Some(t) if t >= Time::ZERO => {
                self.start = t;
                self.is_valid = true;
            }
            _ => self.is_valid = false,
        }
    }

    /// Frame rate and / or Display changed: the start stays the same time, the text is formatted again. Call `set_text` with the
    /// field's current text first so a pending edit is not dropped.
    pub fn reconfigure(&mut self, frame_duration: Time, frames_only: bool) {
        self.frame_duration = frame_duration;
        self.frames_only = frames_only;
        self.text = self.timecode().format(self.start);
        self.is_valid = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FD30: Time = Time::new(1, 30);
    const FD24: Time = Time::new(1, 24);

    #[test]
    fn rate_change_reformats_instead_of_failing_to_parse() {
        // "00:00:10:25" is valid at 30 fps, not at 24 (frame 25 >= 24).
        let mut e = TimecodeStartEntry::new(FD30 * 325, FD30, false);
        assert_eq!(e.text(), "00:00:10:25");
        let text = e.text().to_string();
        e.set_text(&text);
        e.reconfigure(FD24, false);
        assert!(e.is_valid());
        assert_eq!(e.start(), FD30 * 325);
        assert_eq!(e.text(), "00:00:10:20");
        assert!(e.timecode().parse(e.text()).is_some());
    }

    #[test]
    fn frames_typed_as_frames_stay_frames_when_display_changes() {
        let mut e = TimecodeStartEntry::new(Time::ZERO, FD30, true);
        e.set_text("1800");
        assert!(e.is_valid() && e.start() == FD30 * 1800);
        e.reconfigure(FD30, false);
        assert_eq!(e.text(), "00:01:00:00");
        assert_eq!(e.start(), Time::new(60, 1));
        e.reconfigure(FD30, true);
        assert_eq!(e.text(), "1800");
    }

    #[test]
    fn invalid_text_keeps_the_last_valid_start() {
        let mut e = TimecodeStartEntry::new(Time::new(10, 1), FD30, false);
        e.set_text("00:00:99:00");
        assert!(!e.is_valid());
        assert_eq!(e.start(), Time::new(10, 1));
        e.set_text("-00:00:01:00"); // negative starts are not allowed
        assert!(!e.is_valid());
        e.set_text("00:00:02:00");
        assert!(e.is_valid() && e.start() == Time::new(2, 1));
    }

    #[test]
    fn reconfigure_after_invalid_text_restores_the_last_valid_start() {
        let mut e = TimecodeStartEntry::new(Time::new(10, 1), FD30, false);
        e.set_text("abc");
        e.reconfigure(FD24, false);
        assert!(e.is_valid() && e.text() == "00:00:10:00");
    }
}
