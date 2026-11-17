//! Port of `SQUIKit/Sources/SQUIKit/SQAccessibilityText.swift`.

use crate::localization::SQL10n;

/// Every VoiceOver string of the custom views (timeline, monitors, meters) in one place, built by pure functions
/// so they are unit-tested and a later localization picks them up from here. Callers pass timecodes already formatted.
pub struct SQAccessibilityText;

impl SQAccessibilityText {
    // MARK: Timeline

    pub fn timeline_label() -> String {
        SQL10n::string("Timeline")
    }

    pub fn timeline_help() -> String {
        SQL10n::string("Tracks and clips of the sequence")
    }

    /// "Video track V1, 3 clips, locked".
    pub fn track(kind: &str, label: &str, clip_count: i64, locked: bool, muted: bool, hidden: bool) -> String {
        let mut parts = vec![
            SQL10n::format("%@ track %@", &[&SQL10n::string(kind), label]),
            SQL10n::plural(clip_count, "%@ clip", "%@ clips"),
        ];
        if locked {
            parts.push(SQL10n::string("locked"));
        }
        if muted {
            parts.push(SQL10n::string("muted"));
        }
        if hidden {
            parts.push(SQL10n::string("hidden"));
        }
        parts.join(", ")
    }

    /// "Interview, from 00:00:01:00, length 00:00:04:00".
    pub fn clip(name: &str, start: &str, length: &str, offline: bool) -> String {
        let n = if name.is_empty() { SQL10n::string("Untitled clip") } else { name.to_string() };
        let mut text = SQL10n::format("%@, from %@, length %@", &[&n, start, length]);
        if offline {
            text.push_str(&SQL10n::string(", media offline"));
        }
        text
    }

    pub fn timeline_playhead(timecode: &str) -> String {
        SQL10n::format("Playhead at %@", &[timecode])
    }

    // MARK: Monitors

    pub fn timecode_label() -> String {
        SQL10n::string("Timecode")
    }

    pub fn play_state(is_playing: bool) -> String {
        SQL10n::string(if is_playing { "Playing" } else { "Paused" })
    }

    pub fn monitor_label() -> String {
        SQL10n::string("Monitor")
    }

    /// "Playing, at 00:00:05:12".
    pub fn monitor_value(is_playing: bool, timecode: &str) -> String {
        SQL10n::format("%@, at %@", &[&Self::play_state(is_playing), timecode])
    }

    // MARK: Meters

    pub fn meter_label() -> String {
        SQL10n::string("Audio meter")
    }

    /// One channel: "Left, minus 12.3 dB", "Left, silent", "Left, clipped" (the clip latch wins). `db` nil = silent.
    pub fn meter_channel(name: &str, db: Option<f32>, clipped: bool) -> String {
        if clipped {
            return SQL10n::format("%@, clipped", &[name]);
        }
        let Some(db) = db else {
            return SQL10n::format("%@, silent", &[name]);
        };
        let v = (f64::from(db) * 10.0).round() / 10.0;
        let spoken = if v < 0.0 { SQL10n::format("minus %@", &[&format!("{:.1}", -v)]) } else { format!("{v:.1}") };
        SQL10n::format("%@, %@ dB", &[name, &spoken])
    }

    /// All channels joined: "Left, minus 12.3 dB. Right, silent".
    pub fn meter_value(channels: &[String]) -> String {
        channels.join(". ")
    }

    /// "L" / "R" / "M" to the spoken channel name.
    pub fn channel_name(short: &str) -> String {
        match short {
            "L" => SQL10n::string("Left"),
            "R" => SQL10n::string("Right"),
            "M" => SQL10n::string("Mono"),
            _ => short.to_string(),
        }
    }

    /// Every key this file looks up (the German catalog must translate them).
    pub const KEYS: [&'static str; 26] = [
        "Timeline",
        "Tracks and clips of the sequence",
        "%@ track %@",
        "%@ clip",
        "%@ clips",
        "locked",
        "muted",
        "hidden",
        "Untitled clip",
        "%@, from %@, length %@",
        ", media offline",
        "Playhead at %@",
        "Timecode",
        "Playing",
        "Paused",
        "Monitor",
        "%@, at %@",
        "Audio meter",
        "%@, clipped",
        "%@, silent",
        "minus %@",
        "%@, %@ dB",
        "Left",
        "Right",
        "Mono",
        "Video",
    ];
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn track_label_lists_states() {
        assert_eq!(SQAccessibilityText::track("Video", "V1", 1, false, false, false), "Video track V1, 1 clip");
        assert_eq!(
            SQAccessibilityText::track("Audio", "A2", 3, true, true, false),
            "Audio track A2, 3 clips, locked, muted"
        );
    }

    #[test]
    fn clip_label() {
        assert_eq!(
            SQAccessibilityText::clip("Take 1", "00:00:01:00", "00:00:02:00", false),
            "Take 1, from 00:00:01:00, length 00:00:02:00"
        );
        assert_eq!(SQAccessibilityText::clip("", "a", "b", true), "Untitled clip, from a, length b, media offline");
    }

    #[test]
    fn monitor_and_meter_values() {
        assert_eq!(SQAccessibilityText::monitor_value(true, "00:00:05:12"), "Playing, at 00:00:05:12");
        assert_eq!(SQAccessibilityText::play_state(false), "Paused");
        assert_eq!(SQAccessibilityText::meter_channel("Left", Some(-12.34), false), "Left, minus 12.3 dB");
        assert_eq!(SQAccessibilityText::meter_channel("Left", None, false), "Left, silent");
        assert_eq!(SQAccessibilityText::meter_channel("Left", Some(-3.0), true), "Left, clipped");
        assert_eq!(SQAccessibilityText::meter_value(&["a".to_string(), "b".to_string()]), "a. b");
        assert_eq!(SQAccessibilityText::channel_name("M"), "Mono");
    }
}
