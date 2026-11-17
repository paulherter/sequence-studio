// Swift: SubtitleReader.swift (ids from an `IdSource`)
//! Imports `.srt`, `.vtt` (WebVTT) and `.ass`/`.ssa` subtitles through one entry point. Styling is ignored: only cue times and
//! text are read (ASS override tags `{...}` and WebVTT markup are stripped).

use crate::srtreader::{self, Cue, Document, SRTReader};
use crate::transcript::trim_blanks;
use sq_core_time::{IdSource, Time};
use std::fmt;

/// The subtitle file types.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    /// SubRip.
    Srt,
    /// WebVTT.
    Vtt,
    /// Advanced SubStation Alpha (also SSA).
    Ass,
}

/// A line the WebVTT or ASS reader could not parse.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    /// 1-based line number.
    pub line: usize,
    /// What is wrong.
    pub message: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "line {}: {}", self.line, self.message)
    }
}

impl std::error::Error for ParseError {}

/// Either reader's error (Swift `parse` throws whichever the format's reader throws).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SubtitleError {
    /// From the SRT reader.
    Srt(srtreader::ParseError),
    /// From the WebVTT or ASS reader.
    Other(ParseError),
}

impl fmt::Display for SubtitleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SubtitleError::Srt(e) => e.fmt(f),
            SubtitleError::Other(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for SubtitleError {}

fn error(line: usize, message: String) -> ParseError {
    ParseError { line, message }
}

/// Imports `.srt`, `.vtt` and `.ass`/`.ssa` subtitles.
pub struct SubtitleReader;

impl SubtitleReader {
    /// The file extensions this reader opens.
    pub const FILE_EXTENSIONS: [&'static str; 4] = ["srt", "vtt", "ass", "ssa"];

    /// Format from a file extension (case-insensitive); `None` when it is not a subtitle type.
    pub fn format_for_extension(ext: &str) -> Option<Format> {
        match ext.to_lowercase().as_str() {
            "srt" => Some(Format::Srt),
            "vtt" => Some(Format::Vtt),
            "ass" | "ssa" => Some(Format::Ass),
            _ => None,
        }
    }

    /// Parses subtitle bytes. Defaults of the Swift call: language "und", style "default", animation "none".
    pub fn parse(
        data: &[u8],
        format: Format,
        language: &str,
        style_ref: &str,
        animation_ref: &str,
        ids: &mut dyn IdSource,
    ) -> Result<Document, SubtitleError> {
        let text = SRTReader::decode(data);
        match format {
            Format::Srt => SRTReader::parse(&text, language, style_ref, animation_ref, ids).map_err(SubtitleError::Srt),
            Format::Vtt => {
                Self::parse_vtt(&text, language, style_ref, animation_ref, ids).map_err(SubtitleError::Other)
            }
            Format::Ass => {
                Self::parse_ass(&text, language, style_ref, animation_ref, ids).map_err(SubtitleError::Other)
            }
        }
    }

    // -- WebVTT

    /// Parses WebVTT text.
    pub fn parse_vtt(
        text: &str,
        language: &str,
        style_ref: &str,
        animation_ref: &str,
        ids: &mut dyn IdSource,
    ) -> Result<Document, ParseError> {
        let lines = SRTReader::lines(text);
        let blank = |i: usize| trim_blanks(&lines[i]).is_empty();
        let mut cues: Vec<Cue> = Vec::new();
        let mut i = 0;
        // Header: "WEBVTT" optionally followed by text, up to the first blank line.
        if lines.first().is_some_and(|f| f.starts_with("WEBVTT")) {
            while i < lines.len() && !blank(i) {
                i += 1;
            }
        }
        while i < lines.len() {
            if blank(i) {
                i += 1;
                continue;
            }
            // One block up to the next blank line.
            let block_start = i;
            let mut block: Vec<&str> = Vec::new();
            while i < lines.len() && !blank(i) {
                block.push(&lines[i]);
                i += 1;
            }
            let head = trim_blanks(block[0]);
            if head == "NOTE"
                || head.starts_with("NOTE ")
                || head.starts_with("NOTE\t")
                || head == "STYLE"
                || head == "REGION"
            {
                continue;
            }
            let Some(timing_idx) = block.iter().position(|l| l.contains("-->")) else { continue }; // stray text
            let ln = block_start + timing_idx + 1;
            let parts: Vec<&str> = block[timing_idx].split("-->").collect();
            if parts.len() != 2 {
                return Err(error(ln, "malformed timing line".into()));
            }
            let start_text = trim_blanks(parts[0]);
            // Cue settings (line:, position:, align:) follow the end time and are ignored.
            let end_text = trim_blanks(parts[1]).split(char::is_whitespace).find(|s| !s.is_empty()).unwrap_or("");
            let Some(start) = Self::vtt_time(start_text) else {
                return Err(error(ln, format!("malformed start time '{start_text}'")));
            };
            let Some(end) = Self::vtt_time(end_text) else {
                return Err(error(ln, format!("malformed end time '{end_text}'")));
            };
            if end < start {
                return Err(error(ln, "end time before start time".into()));
            }
            let text_lines = block[timing_idx + 1..]
                .iter()
                .map(|l| trim_blanks(&Self::decode_entities(&SRTReader::strip_tags(l))).to_string())
                .collect();
            cues.push(Cue { start, end, lines: text_lines });
        }
        Ok(SRTReader::make_document(&cues, language, style_ref, animation_ref, ids))
    }

    /// `[H+:]MM:SS.mmm`.
    pub(crate) fn vtt_time(s: &str) -> Option<Time> {
        let parts: Vec<&str> = s.split(':').collect();
        if parts.len() != 2 && parts.len() != 3 {
            return None;
        }
        let h = if parts.len() == 3 { Self::digits(parts[0]).unwrap_or(-1) } else { 0 };
        let m = Self::digits(parts[parts.len() - 2]).unwrap_or(-1);
        if h < 0 || !(0..60).contains(&m) {
            return None;
        }
        let sec: Vec<&str> = parts[parts.len() - 1].split('.').collect();
        if !(1..=2).contains(&sec.len()) || sec[0].chars().count() != 2 {
            return None;
        }
        let s0 = Self::digits(sec[0])?;
        if s0 >= 60 {
            return None;
        }
        Some(Time::new(((h * 60 + m) * 60 + s0) * 1000 + Self::fraction_ms(&sec)?, 1000))
    }

    /// Milliseconds of the fraction part (1 to 3 digits) of split seconds, 0 without one.
    fn fraction_ms(sec: &[&str]) -> Option<i64> {
        if sec.len() != 2 {
            return Some(0);
        }
        let n = sec[1].chars().count();
        if !(1..=3).contains(&n) {
            return None;
        }
        let f = Self::digits_any(sec[1])?;
        Some(
            f * match n {
                1 => 100,
                2 => 10,
                _ => 1,
            },
        )
    }

    // -- ASS / SSA

    /// Parses ASS or SSA text.
    pub fn parse_ass(
        text: &str,
        language: &str,
        style_ref: &str,
        animation_ref: &str,
        ids: &mut dyn IdSource,
    ) -> Result<Document, ParseError> {
        let lines = SRTReader::lines(text);
        let mut in_events = false;
        let mut saw_events = false;
        let mut columns: Vec<String> = Vec::new();
        let mut cues: Vec<Cue> = Vec::new();
        for (idx, raw) in lines.iter().enumerate() {
            let line = trim_blanks(raw);
            if line.starts_with('[') && line.ends_with(']') {
                in_events = line.to_lowercase() == "[events]";
                saw_events = saw_events || in_events;
                continue;
            }
            if !in_events {
                continue;
            }
            let lower = line.to_lowercase();
            if let Some(rest) = line.get(7..).filter(|_| lower.starts_with("format:")) {
                columns = rest.split(',').filter(|c| !c.is_empty()).map(|c| trim_blanks(c).to_lowercase()).collect();
                continue;
            }
            // Comment:, Picture:, ...
            let Some(rest) = line.get(9..).filter(|_| lower.starts_with("dialogue:")) else { continue };
            let col = |name: &str| columns.iter().position(|c| c == name);
            let (Some(start_col), Some(end_col), Some(text_col)) = (col("start"), col("end"), col("text")) else {
                return Err(error(idx + 1, "Dialogue before a Format line with Start, End and Text".into()));
            };
            // Text is the last column and may itself contain commas.
            let fields: Vec<&str> = rest.splitn(columns.len(), ',').collect();
            if fields.len() != columns.len() {
                return Err(error(idx + 1, "wrong number of fields".into()));
            }
            let start_text = trim_blanks(fields[start_col]);
            let end_text = trim_blanks(fields[end_col]);
            let Some(start) = Self::ass_time(start_text) else {
                return Err(error(idx + 1, format!("malformed start time '{start_text}'")));
            };
            let Some(end) = Self::ass_time(end_text) else {
                return Err(error(idx + 1, format!("malformed end time '{end_text}'")));
            };
            if end < start {
                return Err(error(idx + 1, "end time before start time".into()));
            }
            let body = fields[text_col];
            if body.contains("\\p1") {
                continue; // vector drawing, not text
            }
            cues.push(Cue { start, end, lines: Self::ass_text(body) });
        }
        if !saw_events {
            return Err(error(1, "no [Events] section, this does not look like an ASS file".into()));
        }
        cues.sort_by_key(|c| c.start);
        Ok(SRTReader::make_document(&cues, language, style_ref, animation_ref, ids))
    }

    /// `H:MM:SS.cc` (centiseconds, tolerates 1 to 3 fraction digits).
    pub(crate) fn ass_time(s: &str) -> Option<Time> {
        let parts: Vec<&str> = s.split(':').collect();
        if parts.len() != 3 {
            return None;
        }
        let sec: Vec<&str> = parts[2].split('.').collect();
        if !(1..=2).contains(&sec.len()) {
            return None;
        }
        let (h, m, s0) = (Self::digits(parts[0])?, Self::digits(parts[1])?, Self::digits(sec[0])?);
        if m >= 60 || s0 >= 60 {
            return None;
        }
        Some(Time::new(((h * 60 + m) * 60 + s0) * 1000 + Self::fraction_ms(&sec)?, 1000))
    }

    /// Strips `{...}` override blocks, turns `\N` / `\n` into line breaks and `\h` into a space.
    pub(crate) fn ass_text(s: &str) -> Vec<String> {
        let mut out = String::new();
        let mut in_brace = false;
        let mut it = s.chars();
        while let Some(ch) = it.next() {
            if in_brace {
                if ch == '}' {
                    in_brace = false;
                }
                continue;
            }
            if ch == '{' {
                in_brace = true;
                continue;
            }
            if ch == '\\' {
                let Some(n) = it.next() else { break };
                match n {
                    'N' | 'n' => out.push('\n'),
                    'h' => out.push(' '),
                    _ => {
                        out.push('\\');
                        out.push(n);
                    }
                }
                continue;
            }
            out.push(ch);
        }
        out.split('\n').map(|l| trim_blanks(l).to_string()).collect()
    }

    // -- Shared

    /// Up to 9 ASCII digits (Swift's guarded `digits`).
    fn digits(x: &str) -> Option<i64> {
        if x.chars().count() > 9 {
            return None;
        }
        Self::digits_any(x)
    }

    fn digits_any(x: &str) -> Option<i64> {
        if x.is_empty() || !x.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
        x.parse().ok()
    }

    fn decode_entities(s: &str) -> String {
        s.replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&nbsp;", " ")
            .replace("&lrm;", "")
            .replace("&rlm;", "")
            .replace("&amp;", "&")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::test_support::t;
    use sq_core_time::{SequentialIds, TimeRange};

    fn parse(data: &str, format: Format) -> Result<Document, SubtitleError> {
        SubtitleReader::parse(data.as_bytes(), format, "und", "default", "none", &mut SequentialIds::default())
    }

    fn vtt(text: &str) -> Result<Document, ParseError> {
        SubtitleReader::parse_vtt(text, "und", "default", "none", &mut SequentialIds::default())
    }

    fn ass(text: &str) -> Result<Document, ParseError> {
        SubtitleReader::parse_ass(text, "und", "default", "none", &mut SequentialIds::default())
    }

    const VTT: &str = "\u{FEFF}WEBVTT - demo\r\nKind: captions\r\n\r\nNOTE this is a comment\r\nsecond note line\r\n\r\nSTYLE\r\n::cue { color: red }\r\n\r\nintro\r\n00:01.000 --> 00:03.500 line:90% align:center\r\n<v Bob><i>Hello</i> &amp; <c.yellow>world</c>\r\n\r\n00:00:04.000 --> 00:00:06.000\r\nTwo\r\nlines\r\n";

    #[test]
    fn vtt_basics() {
        let doc = parse(VTT, Format::Vtt).unwrap();
        assert_eq!(doc.captions.len(), 2);
        assert_eq!(doc.captions[0].range, TimeRange::from_end(t(1000), t(3500)));
        assert_eq!(doc.captions[0].lines, ["Hello & world"]);
        assert_eq!(doc.captions[1].lines, ["Two", "lines"]);
        assert_eq!(doc.captions[1].range.start, t(4000));
    }

    #[test]
    fn vtt_malformed_errors() {
        assert!(vtt("WEBVTT\n\n00:xx.000 --> 00:02.000\nHi\n").is_err());
        assert!(vtt("WEBVTT\n\n00:05.000 --> 00:02.000\nHi\n").is_err());
        assert!(vtt("WEBVTT\n").unwrap().captions.is_empty());
    }

    const ASS: &str = "[Script Info]\nTitle: x\nPlayResY: 1080\n\n[V4+ Styles]\nFormat: Name, Fontname\nStyle: Default,Arial\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:05.00,0:00:07.50,Default,,0,0,0,,{\\an8\\b1}Second, with comma\nComment: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,ignored\nDialogue: 0,0:00:01.00,0:00:03.25,Default,,0,0,0,,{\\i1}Hello{\\i0}\\Nworld\\hnow\nDialogue: 0,0:00:08.00,0:00:09.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 10\n";

    #[test]
    fn ass_basics() {
        let doc = parse(ASS, Format::Ass).unwrap();
        assert_eq!(doc.captions.len(), 2);
        assert_eq!(doc.captions[0].lines, ["Hello", "world now"]);
        assert_eq!(doc.captions[0].range, TimeRange::from_end(t(1000), t(3250)));
        assert_eq!(doc.captions[1].lines, ["Second, with comma"]);
        assert_eq!(doc.captions[1].range.end(), t(7500));
    }

    #[test]
    fn ass_malformed() {
        assert!(ass("just some text").is_err());
        assert!(ass("[Events]\nFormat: Start, End, Text\nDialogue: nope,0:00:01.00,Hi\n").is_err());
        assert!(ass("[Events]\nDialogue: 0:00:00.00,0:00:01.00,Hi\n").is_err());
    }

    #[test]
    fn format_by_extension() {
        assert_eq!(SubtitleReader::format_for_extension("VTT"), Some(Format::Vtt));
        assert_eq!(SubtitleReader::format_for_extension("ssa"), Some(Format::Ass));
        assert_eq!(SubtitleReader::format_for_extension("mov"), None);
    }

    #[test]
    fn srt_goes_through_the_srt_reader() {
        let e = parse("1\n00:00:05,000 --> 00:00:02,000\nx\n", Format::Srt).unwrap_err();
        assert!(matches!(e, SubtitleError::Srt(_)));
    }
}
