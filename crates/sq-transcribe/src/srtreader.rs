// Swift: SRTReader.swift (word and caption ids come from an `IdSource`)
//! Imports `.srt` subtitles as captions plus an approximate word-level transcript, so imported subtitles can be edited like
//! a recognized transcript.

use crate::caption_segmenter::Caption;
use crate::transcript::{Transcript, TranscriptWord, trim_blanks};
use sq_core_time::{IdSource, Time, TimeRange};
use std::fmt;

/// A line the reader could not parse.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    /// 1-based line number in the (line-ending-normalized) input.
    pub line: usize,
    /// What is wrong.
    pub message: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "SRT line {}: {}", self.line, self.message)
    }
}

impl std::error::Error for ParseError {}

/// Captions plus the transcript made from them.
#[derive(Clone, Debug, PartialEq)]
pub struct Document {
    /// One per cue with text.
    pub captions: Vec<Caption>,
    /// The cue words with times spread over the cue.
    pub transcript: Transcript,
}

/// One parsed subtitle cue before words are derived (shared by the SRT, WebVTT and ASS readers).
pub(crate) struct Cue {
    pub start: Time,
    pub end: Time,
    pub lines: Vec<String>,
}

/// Imports `.srt` subtitles.
pub struct SRTReader;

impl SRTReader {
    /// Parses SRT bytes (UTF-8 or UTF-16 with or without BOM, else Latin-1).
    pub fn parse_data(
        data: &[u8],
        language: &str,
        style_ref: &str,
        animation_ref: &str,
        ids: &mut dyn IdSource,
    ) -> Result<Document, ParseError> {
        Self::parse(&Self::decode(data), language, style_ref, animation_ref, ids)
    }

    /// Parses SRT text. Defaults of the Swift call: language "und", style "default", animation "none".
    pub fn parse(
        text: &str,
        language: &str,
        style_ref: &str,
        animation_ref: &str,
        ids: &mut dyn IdSource,
    ) -> Result<Document, ParseError> {
        let lines = Self::lines(text);
        let mut cues: Vec<Cue> = Vec::new();
        let mut i = 0;
        while i < lines.len() {
            let raw = trim_blanks(&lines[i]);
            if !raw.contains("-->") {
                // blanks, indices, stray text
                i += 1;
                continue;
            }
            let (start, end) = Self::parse_times(raw, i + 1)?;
            i += 1;
            let mut text_lines: Vec<String> = Vec::new();
            while i < lines.len() {
                let l = &lines[i];
                if trim_blanks(l).is_empty() {
                    break;
                }
                if l.contains("-->") {
                    break; // next cue without blank separator
                }
                text_lines.push(trim_blanks(&Self::strip_tags(l)).to_string());
                i += 1;
            }
            // A trailing pure-number line belongs to the next cue (missing blank line).
            if let Some(last) = text_lines.last()
                && i < lines.len()
                && lines[i].contains("-->")
                && !last.is_empty()
                && last.chars().all(char::is_numeric)
            {
                text_lines.pop();
            }
            cues.push(Cue { start, end, lines: text_lines });
        }
        Ok(Self::make_document(&cues, language, style_ref, animation_ref, ids))
    }

    /// Splits text into lines: a leading BOM is removed, CR LF and CR become LF.
    pub(crate) fn lines(text: &str) -> Vec<String> {
        let t = text.strip_prefix('\u{FEFF}').unwrap_or(text);
        t.replace("\r\n", "\n").replace('\r', "\n").split('\n').map(str::to_string).collect()
    }

    /// Builds captions plus an approximate word-level transcript; cues without text are dropped.
    pub(crate) fn make_document(
        cues: &[Cue],
        language: &str,
        style_ref: &str,
        animation_ref: &str,
        ids: &mut dyn IdSource,
    ) -> Document {
        let mut words: Vec<TranscriptWord> = Vec::new();
        let mut captions: Vec<Caption> = Vec::new();
        for cue in cues {
            let (start, end) = (cue.start, cue.end);
            let text_lines: Vec<String> = cue.lines.iter().filter(|l| !l.is_empty()).cloned().collect();
            let cue_words: Vec<&str> =
                text_lines.iter().flat_map(|l| l.split(char::is_whitespace).filter(|s| !s.is_empty())).collect();
            if cue_words.is_empty() {
                continue;
            }
            let first = words.len();
            let char_count = |w: &str| sq_core_time::text::graphemes(w).count() as i64;
            let total: i64 = cue_words.iter().map(|w| char_count(w)).sum();
            let duration = end - start;
            let mut cum = 0i64;
            let mut prev = start;
            for w in cue_words {
                cum += char_count(w);
                let next = if cum == total {
                    end
                } else {
                    start + Time::new(duration.value() * cum, duration.timescale() * total)
                };
                words.push(TranscriptWord::new(ids.next_id(), w, TimeRange::from_end(prev, next)));
                prev = next;
            }
            captions.push(Caption::new(
                text_lines,
                TimeRange::from_end(start, end),
                words[first].id,
                words[words.len() - 1].id,
                first..words.len(),
                style_ref,
                animation_ref,
            ));
        }
        Document { captions, transcript: Transcript::new(language, words) }
    }

    /// Text of subtitle bytes: UTF-8 BOM, UTF-16 BOMs, plain UTF-8, else Latin-1.
    pub(crate) fn decode(data: &[u8]) -> String {
        let utf16 = |b: &[u8], le: bool| {
            let (pairs, _) = b.as_chunks::<2>();
            let units: Vec<u16> =
                pairs.iter().map(|p| if le { u16::from_le_bytes(*p) } else { u16::from_be_bytes(*p) }).collect();
            String::from_utf16(&units).unwrap_or_default()
        };
        if let Some(rest) = data.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
            return String::from_utf8_lossy(rest).into_owned();
        }
        if let Some(rest) = data.strip_prefix(&[0xFF, 0xFE]) {
            return utf16(rest, true);
        }
        if let Some(rest) = data.strip_prefix(&[0xFE, 0xFF]) {
            return utf16(rest, false);
        }
        match std::str::from_utf8(data) {
            Ok(s) => s.to_string(),
            Err(_) => data.iter().map(|&b| char::from(b)).collect(),
        }
    }

    fn parse_times(s: &str, line: usize) -> Result<(Time, Time), ParseError> {
        let err = |message: String| ParseError { line, message };
        let parts: Vec<&str> = s.split("-->").collect();
        if parts.len() != 2 {
            return Err(err("malformed timestamp line".into()));
        }
        let start_text = trim_blanks(parts[0]);
        // Ignore positional settings after the end time ("X1:0 Y1:0 ...").
        let end_text = trim_blanks(parts[1]).split(char::is_whitespace).find(|s| !s.is_empty()).unwrap_or("");
        let Some(start) = Self::timestamp(start_text) else {
            return Err(err(format!("malformed start time '{start_text}'")));
        };
        let Some(end) = Self::timestamp(end_text) else { return Err(err(format!("malformed end time '{end_text}'"))) };
        if end < start {
            return Err(err("end time before start time".into()));
        }
        Ok((start, end))
    }

    /// `H+:MM:SS` with `,` or `.` and 1-3 fraction digits, or no fraction.
    pub(crate) fn timestamp(s: &str) -> Option<Time> {
        let digits = |x: &str| -> Option<i64> {
            if x.is_empty() || !x.chars().all(|c| c.is_ascii_digit()) {
                return None;
            }
            x.parse().ok()
        };
        let hms: Vec<&str> = s.split(':').collect();
        if hms.len() != 3 || hms[0].chars().count() > 3 || hms[1].chars().count() != 2 {
            return None;
        }
        let (h, m) = (digits(hms[0])?, digits(hms[1])?);
        if m >= 60 {
            return None;
        }
        let sec_parts: Vec<&str> = hms[2].split([',', '.']).collect();
        if !(1..=2).contains(&sec_parts.len()) || sec_parts[0].chars().count() != 2 {
            return None;
        }
        let sec = digits(sec_parts[0])?;
        if sec >= 60 {
            return None;
        }
        let mut ms = 0;
        if sec_parts.len() == 2 {
            let frac = sec_parts[1];
            if frac.chars().count() > 3 {
                return None;
            }
            let f = digits(frac)?;
            ms = f * match frac.chars().count() {
                1 => 100,
                2 => 10,
                _ => 1,
            };
        }
        Some(Time::new(((h * 60 + m) * 60 + sec) * 1000 + ms, 1000))
    }

    /// Removes `<...>` tags (i, b, u, font, ...) and `{\an8}`-style override blocks.
    pub(crate) fn strip_tags(s: &str) -> String {
        let chars: Vec<char> = s.chars().collect();
        let mut out = String::new();
        let mut i = 0;
        while i < chars.len() {
            let ch = chars[i];
            // A tag opens with "<" + letter or "/" and an override block with "{\\"; a lone "<" ("I <3 you", "a < b") or "{"
            // is text. An opener without its closer stays text too.
            let next = chars.get(i + 1).copied().unwrap_or(' ');
            let closer = |c: char| chars[i..].iter().position(|&x| x == c).map(|p| i + p);
            if ch == '<'
                && (next.is_alphabetic() || next == '/')
                && let Some(end) = closer('>')
            {
                i = end + 1;
            } else if ch == '{'
                && next == '\\'
                && let Some(end) = closer('}')
            {
                i = end + 1;
            } else {
                out.push(ch);
                i += 1;
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::test_support::t;
    use sq_core_time::SequentialIds;

    const BASIC: &str = "1\n00:00:01,000 --> 00:00:03,500\nHello world\n\n2\n00:00:04,000 --> 00:00:06,000\nSecond line one\nsecond line two\n\n";

    fn parse(text: &str) -> Result<Document, ParseError> {
        SRTReader::parse(text, "und", "default", "none", &mut SequentialIds::default())
    }

    fn parse_data(data: &[u8]) -> Document {
        SRTReader::parse_data(data, "und", "default", "none", &mut SequentialIds::default()).unwrap()
    }

    #[test]
    fn parses_basic_cues() {
        let doc = parse(BASIC).unwrap();
        assert_eq!(doc.captions.len(), 2);
        assert_eq!(doc.captions[0].lines, ["Hello world"]);
        assert_eq!(doc.captions[0].range, TimeRange::from_end(t(1000), t(3500)));
        assert_eq!(doc.captions[1].lines, ["Second line one", "second line two"]);
        assert_eq!(doc.captions[1].range.start, t(4000));
    }

    #[test]
    fn crlf_dots_missing_indices_and_blank_tolerance() {
        let s = "\r\n\r\n00:00:01.5 --> 00:00:02.25\r\nA b\r\n\r\n\r\n\r\n00:01:00,000 --> 01:00:00,001\r\nC\r\n";
        let doc = parse(s).unwrap();
        assert_eq!(doc.captions.len(), 2);
        assert_eq!(doc.captions[0].range, TimeRange::from_end(t(1500), t(2250)));
        assert_eq!(doc.captions[1].range, TimeRange::from_end(t(60_000), t(3_600_001)));
    }

    #[test]
    fn strips_basic_tags() {
        let doc =
            parse("1\n00:00:00,000 --> 00:00:01,000\n<i>Hi</i> <b>there</b> <font color=\"red\">you</font>\n").unwrap();
        assert_eq!(doc.captions[0].lines, ["Hi there you"]);
        assert_eq!(doc.transcript.words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>(), ["Hi", "there", "you"]);
    }

    #[test]
    fn unclosed_angle_or_brace_keeps_the_text() {
        let doc = parse("1\n00:00:00,000 --> 00:00:01,000\nI <3 you <i>so</i>\n\n2\n00:00:02,000 --> 00:00:03,000\nif a < b then {x\n").unwrap();
        assert_eq!(doc.captions[0].lines, ["I <3 you so"]);
        assert_eq!(doc.captions[1].lines, ["if a < b then {x"]);
    }

    #[test]
    fn utf8_bom_and_utf16() {
        let mut d8 = vec![0xEF, 0xBB, 0xBF];
        d8.extend(BASIC.bytes());
        assert_eq!(parse_data(&d8).captions.len(), 2);
        let mut d16le = vec![0xFF, 0xFE];
        d16le.extend(BASIC.encode_utf16().flat_map(u16::to_le_bytes));
        assert_eq!(parse_data(&d16le).captions.len(), 2);
        let mut d16be = vec![0xFE, 0xFF];
        d16be.extend(BASIC.encode_utf16().flat_map(u16::to_be_bytes));
        assert_eq!(parse_data(&d16be).captions[0].lines, ["Hello world"]);
    }

    #[test]
    fn latin1_is_the_last_resort() {
        let doc = parse_data(b"1\n00:00:00,000 --> 00:00:01,000\nCaf\xE9\n");
        assert_eq!(doc.captions[0].lines, ["Caf\u{E9}"]);
    }

    #[test]
    fn transcript_words_spread_proportionally() {
        // "ab cdef" over 0..3000 ms: 2 and 4 of 6 chars -> boundary at 1000 ms.
        let doc = parse("1\n00:00:00,000 --> 00:00:03,000\nab cdef\n").unwrap();
        let words = &doc.transcript.words;
        assert_eq!(words.len(), 2);
        assert_eq!(words[0].range, TimeRange::from_end(t(0), t(1000)));
        assert_eq!(words[1].range, TimeRange::from_end(t(1000), t(3000)));
        assert!(words.iter().all(|w| !w.is_edited));
        let c = &doc.captions[0];
        assert_eq!(c.word_indices, 0..2);
        assert!(c.first_word_id == words[0].id && c.last_word_id == words[1].id);
    }

    #[test]
    fn captions_index_across_cues() {
        let doc = parse(BASIC).unwrap();
        assert_eq!(doc.captions[0].word_indices, 0..2);
        assert_eq!(doc.captions[1].word_indices, 2..8);
        assert_eq!(doc.transcript.words.len(), 8);
    }

    #[test]
    fn malformed_timestamp_reports_line() {
        let s = "1\n00:00:01,000 --> 00:00:02,000\nok\n\n2\n00:00:0x,000 --> 00:00:04,000\nbad\n";
        assert_eq!(parse(s).unwrap_err().line, 6);
    }

    #[test]
    fn end_before_start_errors() {
        let e = parse("1\n00:00:05,000 --> 00:00:02,000\nx\n").unwrap_err();
        assert_eq!(e.to_string(), "SRT line 2: end time before start time");
    }

    #[test]
    fn empty_input_gives_nothing() {
        let doc = parse("\n\n").unwrap();
        assert!(doc.captions.is_empty() && doc.transcript.words.is_empty());
    }

    #[test]
    fn round_trip_with_hand_written_exporter_text() {
        // Text as the SRT writer emits it (index, "HH:MM:SS,mmm --> ...", lines, blank line).
        let expected = "1\n00:00:00,500 --> 00:00:02,000\nGuten Tag\n\n2\n00:00:02,000 --> 00:00:04,250\nzusammen,\nwie geht's?\n\n";
        let doc = parse(expected).unwrap();
        let ts = |time: Time| {
            let ms = time.value() * 1000 / time.timescale();
            format!("{:02}:{:02}:{:02},{:03}", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        };
        let mut out = String::new();
        for (i, c) in doc.captions.iter().enumerate() {
            out += &format!("{}\n{} --> {}\n{}\n\n", i + 1, ts(c.range.start), ts(c.range.end()), c.lines.join("\n"));
        }
        assert_eq!(out, expected);
    }
}
