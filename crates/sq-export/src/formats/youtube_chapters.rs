// SPDX-License-Identifier: GPL-3.0-or-later
//! Chapter list in the format YouTube reads from a video description: one `M:SS Title` line per chapter, the first at
//! 0:00. YouTube needs at least three chapters, each at least 10 s long, to turn the list into chapters.

use super::is_swift_whitespace_or_newline;
use sq_core_model::Marker;
use sq_core_time::Time;

/// Text and the reasons YouTube would not show it as chapters.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct YouTubeChaptersResult {
    /// The chapter lines.
    pub text: String,
    /// Plain-language reasons YouTube would not show these as chapters (empty = fine).
    pub warnings: Vec<String>,
}

/// YouTube chapter list writer.
pub struct YouTubeChapters;

impl YouTubeChapters {
    /// Chapters YouTube needs at least.
    pub const MINIMUM_CHAPTERS: usize = 3;
    /// Shortest chapter YouTube accepts, seconds.
    pub const MINIMUM_LENGTH_SECONDS: i64 = 10;

    fn stamp(whole: i64) -> String {
        let (h, m, s) = (whole / 3600, whole / 60 % 60, whole % 60);
        if h > 0 { format!("{h}:{m:02}:{s:02}") } else { format!("{m}:{s:02}") }
    }

    /// Named sequence markers in time order, shifted by `range_start` (an In/Out export starts at 0:00). Markers before
    /// the range or after `duration` are dropped; a missing 0:00 chapter is added as "Intro".
    pub fn make(markers: &[Marker], range_start: Time, duration: Option<Time>) -> YouTubeChaptersResult {
        let whole = |t: Time| t.value() / t.timescale();
        let mut sorted: Vec<&Marker> = markers.iter().collect();
        sorted.sort_by_key(|m| m.time);
        let mut items: Vec<(i64, String)> = Vec::new();
        for m in sorted {
            let name = m.name.trim_matches(is_swift_whitespace_or_newline);
            if name.is_empty() || m.time < range_start {
                continue;
            }
            let t = m.time - range_start;
            if duration.is_some_and(|d| t >= d) {
                continue;
            }
            let sec = whole(t); // whole seconds, rounded down: YouTube has no sub-second stamps
            if items.last().is_some_and(|l| l.0 == sec) {
                continue;
            }
            items.push((sec, name.replace('\n', " ")));
        }
        let mut warnings = Vec::new();
        if items.first().map(|i| i.0) != Some(0) {
            items.insert(0, (0, "Intro".to_string()));
            warnings.push("No marker at the start: an \"Intro\" chapter was added at 0:00.".to_string());
        }
        if items.len() < Self::MINIMUM_CHAPTERS {
            warnings.push(format!(
                "YouTube needs at least {} chapters; there are {}.",
                Self::MINIMUM_CHAPTERS,
                items.len()
            ));
        }
        let total = duration.map(whole);
        for i in 0..items.len() {
            let end = if i + 1 < items.len() { Some(items[i + 1].0) } else { total };
            if end.is_some_and(|e| e - items[i].0 < Self::MINIMUM_LENGTH_SECONDS) {
                warnings.push(format!(
                    "Chapter \"{}\" is shorter than {} s.",
                    items[i].1,
                    Self::MINIMUM_LENGTH_SECONDS
                ));
            }
        }
        let text = items.iter().map(|i| format!("{} {}", Self::stamp(i.0), i.1)).collect::<Vec<_>>().join("\n");
        YouTubeChaptersResult { text, warnings }
    }
}
