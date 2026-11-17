// SPDX-License-Identifier: GPL-3.0-or-later
//! Marker list as CSV: one row per sequence marker and per clip marker shown on the timeline, in time order. Columns:
//! Scope, Name, Color, In, Out, Duration, Comment. Times are timecode (drop frame for 29.97 / 59.94) of the sequence,
//! shifted by the sequence's timecode start. Text cells that a spreadsheet would run as a formula (first character `=`,
//! `+`, `-`, `@`, tab or CR) get a leading `'`. UTF-8 with CRLF line ends (RFC 4180).

use super::{InterchangeExport, raw_name};
use sq_core_edit::clip_markers::ClipMarkersExt;
use sq_core_model::Timeline;
use sq_core_time::{CmxTimecode, Time};

/// One marker row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MarkerCsvRow {
    /// "Sequence" or "Clip: <clip name>".
    pub scope: String,
    /// Marker name.
    pub name: String,
    /// Marker color name.
    pub color: String,
    /// Position on the sequence.
    pub time: Time,
    /// Length, zero for a point marker.
    pub duration: Time,
    /// Free text.
    pub comment: String,
}

/// Marker CSV writer.
pub struct MarkerCsv;

impl MarkerCsv {
    /// The header cells.
    pub const HEADER: [&'static str; 7] = ["Scope", "Name", "Color", "In", "Out", "Duration", "Comment"];

    /// Sequence markers (scope "Sequence") and visible clip markers (scope "Clip: <clip name>"), sorted by time; equal
    /// times keep sequence markers first, then clips in track order.
    pub fn rows(timeline: &Timeline) -> Vec<MarkerCsvRow> {
        let mut out: Vec<MarkerCsvRow> = timeline
            .markers
            .iter()
            .map(|m| MarkerCsvRow {
                scope: "Sequence".to_string(),
                name: m.name.clone(),
                color: raw_name(&m.color),
                time: m.time,
                duration: m.duration,
                comment: m.comment.clone(),
            })
            .collect();
        for track in &timeline.tracks {
            for c in track.clips().iter().filter(|c| c.markers.as_ref().is_some_and(|m| !m.is_empty())) {
                for m in c.visible_markers(timeline.frame_duration()) {
                    out.push(MarkerCsvRow {
                        scope: format!("Clip: {}", c.name),
                        name: m.name,
                        color: raw_name(&m.color),
                        time: c.start + m.time,
                        duration: m.duration,
                        comment: m.comment,
                    });
                }
            }
        }
        out.sort_by_key(|r| r.time);
        out
    }

    /// The file text.
    pub fn render(rows: &[MarkerCsvRow], frame_duration: Time, timecode_start: Time) -> String {
        let clock = CmxTimecode::from_frame_duration(frame_duration, true);
        let base = timecode_start.frame_index(frame_duration);
        let tc = |t: Time| clock.string(base + t.frame_index(frame_duration).max(0));
        let mut lines = vec![Self::HEADER.map(cell).join(",")];
        for r in rows {
            // A duration is a length: shown from 00:00:00:00, not shifted by the timecode start.
            let length = clock.string(r.duration.frame_index(frame_duration).max(0));
            let cells = [&r.scope, &r.name, &r.color, &tc(r.time), &tc(r.time + r.duration), &length, &r.comment];
            lines.push(cells.map(|c| cell(c)).join(","));
        }
        lines.join("\r\n") + "\r\n"
    }

    /// Rows and text of a sequence.
    pub fn export(timeline: &Timeline) -> InterchangeExport {
        InterchangeExport::new(
            Self::render(&Self::rows(timeline), timeline.frame_duration(), timeline.timecode_start()),
            Vec::new(),
        )
    }
}

/// One cell: formula-guarded, quoted when it holds a comma, quote, or line break.
pub(super) fn cell(text: &str) -> String {
    let mut s = text.to_string();
    if s.chars().next().is_some_and(|f| "=+-@\t\r".contains(f)) {
        s.insert(0, '\'');
    }
    if !contains_special(&s) {
        return s;
    }
    format!("\"{}\"", s.replace('"', "\"\""))
}

/// Swift tests whole Characters: a CR LF pair is one Character that is neither `\r` nor `\n`.
fn contains_special(s: &str) -> bool {
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        match c {
            ',' | '"' | '\n' => return true,
            '\r' if it.peek() == Some(&'\n') => {
                it.next();
            }
            '\r' => return true,
            _ => {}
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_crlf_pair_does_not_force_quotes_like_swift_characters() {
        assert_eq!(cell("a\r\nb"), "a\r\nb");
        assert_eq!(cell("a\nb"), "\"a\nb\"");
    }
}
