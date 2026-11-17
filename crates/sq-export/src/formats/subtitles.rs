// SPDX-License-Identifier: GPL-3.0-or-later
//! Subtitle files: SubRip (.srt, CRLF), WebVTT (.vtt) and iTunes Timed Text (.itt). Timecodes come from rational `Time`
//! with integer arithmetic only: milliseconds are rounded to nearest, ties up.

use super::is_swift_whitespace_or_newline;
use sq_core_time::{Time, TimeRange};

/// What part of the sequence an export covers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RangeSelection {
    /// From the first to the last frame.
    EntireSequence,
    /// Only this window; subtitle times are shifted so the window start is 0.
    InOut(TimeRange),
}

/// One subtitle cue on the sequence timeline. `lines` are kept exactly as segmented.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SrtCue {
    /// Text lines.
    pub lines: Vec<String>,
    /// On screen from start to end.
    pub range: TimeRange,
}

/// A cue ready to write: its non-blank lines, its range clipped to the window and shifted to the window start.
struct Shown<'a> {
    lines: Vec<&'a str>,
    start: Time,
    end: Time,
}

/// Cues in time order (stable for equal starts). Dropped: cues outside the range, without a non-blank line, or empty
/// after rounding to milliseconds.
fn shown(cues: &[SrtCue], range: RangeSelection) -> Vec<Shown<'_>> {
    let mut order: Vec<&SrtCue> = cues.iter().collect();
    order.sort_by_key(|c| c.range.start);
    let mut out = Vec::new();
    for cue in order {
        let lines: Vec<&str> = cue
            .lines
            .iter()
            .map(String::as_str)
            .filter(|l| !l.trim_matches(is_swift_whitespace_or_newline).is_empty())
            .collect();
        if lines.is_empty() {
            continue;
        }
        let mut r = cue.range;
        let mut offset = Time::ZERO;
        if let RangeSelection::InOut(window) = range {
            let Some(clipped) = r.intersection(&window) else { continue };
            r = clipped;
            offset = window.start;
        }
        let (start, end) = (r.start - offset, r.end() - offset);
        if milliseconds(end).max(0) <= milliseconds(start).max(0) {
            continue;
        }
        out.push(Shown { lines, start, end });
    }
    out
}

/// Nearest millisecond, ties toward +infinity.
fn milliseconds(t: Time) -> i128 {
    let num = i128::from(t.value()) * 2000 + i128::from(t.timescale());
    let den = i128::from(t.timescale()) * 2;
    num.div_euclid(den)
}

fn timecode_with(t: Time, sep: char) -> String {
    let ms = milliseconds(t).max(0);
    let (h, m, s, f) = (ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000);
    format!("{h:02}:{m:02}:{s:02}{sep}{f:03}")
}

/// SubRip (.srt) output. UTF-8, CRLF line endings.
pub struct SrtWriter;

impl SrtWriter {
    /// `HH:MM:SS,mmm` (hours grow past two digits if needed). Negative times clamp to zero.
    pub fn timecode(t: Time) -> String {
        timecode_with(t, ',')
    }

    /// Renders cues clipped to `range` and shifted so the range start is 00:00:00,000. Blank lines inside a cue are
    /// removed (a blank line would end the cue in SRT). Indices restart at 1.
    pub fn render(cues: &[SrtCue], range: RangeSelection) -> String {
        let mut out = String::new();
        for (i, c) in shown(cues, range).iter().enumerate() {
            out += &format!("{}\r\n{} --> {}\r\n", i + 1, Self::timecode(c.start), Self::timecode(c.end));
            out += &(c.lines.join("\r\n") + "\r\n\r\n");
        }
        out
    }
}

/// WebVTT (.vtt) output: the same cues and range handling as SRT, `HH:MM:SS.mmm` timecodes, LF line ends. `&` and `<`
/// in cue text are escaped, `-->` inside text is broken up.
pub struct VttWriter;

impl VttWriter {
    /// `HH:MM:SS.mmm`.
    pub fn timecode(t: Time) -> String {
        timecode_with(t, '.')
    }

    fn escape(line: &str) -> String {
        line.replace('&', "&amp;").replace('<', "&lt;").replace("-->", "-&gt;")
    }

    /// The file text.
    pub fn render(cues: &[SrtCue], range: RangeSelection) -> String {
        let mut out = String::from("WEBVTT\n\n");
        for c in shown(cues, range) {
            out += &format!("{} --> {}\n", Self::timecode(c.start), Self::timecode(c.end));
            out += &(c.lines.iter().map(|l| Self::escape(l)).collect::<Vec<_>>().join("\n") + "\n\n");
        }
        out
    }
}

/// iTunes Timed Text (.itt): TTML with media-time clock times for video stores and Apple players. One bottom-centered
/// region, white text.
// Same as Swift (ITTWriter.swift:19): no per-cue position, color or italics (cue text is plain lines), upgrade when caption looks should be exported.
pub struct IttWriter;

impl IttWriter {
    fn escape(line: &str) -> String {
        line.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
    }

    /// The file text.
    pub fn render(cues: &[SrtCue], language: &str, range: RangeSelection) -> String {
        let mut out = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:tts=\"http://www.w3.org/ns/ttml#styling\" xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\" xmlns:ttp=\"http://www.w3.org/ns/ttml#parameter\" ttp:timeBase=\"media\" xml:lang=\"{}\">\n\
             <head>\n\
             <styling>\n\
             <style xml:id=\"s1\" tts:fontFamily=\"sansSerif\" tts:fontSize=\"100%\" tts:fontWeight=\"normal\" tts:color=\"white\" tts:textAlign=\"center\"/>\n\
             </styling>\n\
             <layout>\n\
             <region xml:id=\"bottom\" tts:origin=\"10% 80%\" tts:extent=\"80% 20%\" tts:displayAlign=\"after\"/>\n\
             </layout>\n\
             </head>\n\
             <body>\n\
             <div>\n",
            Self::escape(language)
        );
        for c in shown(cues, range) {
            out += &format!(
                "<p begin=\"{}\" end=\"{}\" region=\"bottom\" style=\"s1\">",
                VttWriter::timecode(c.start),
                VttWriter::timecode(c.end)
            );
            out += &(c.lines.iter().map(|l| Self::escape(l)).collect::<Vec<_>>().join("<br/>") + "</p>\n");
        }
        out += "</div>\n</body>\n</tt>\n";
        out
    }
}
