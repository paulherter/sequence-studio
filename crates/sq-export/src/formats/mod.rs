// SPDX-License-Identifier: GPL-3.0-or-later
//! Interchange and text formats: EDL, FCPXML, XMEML, OTIO, SRT, WebVTT, iTunes Timed Text, marker CSV, YouTube
//! chapters. Every writer returns text that is byte-for-byte what the Swift writers produce (golden files in
//! `oracle/sq-export/formats`); XML and JSON are written by hand, no library.
//! Ported from `EDLWriter`, `FCPXMLWriter`, `XMEMLWriter`, `OTIOWriter`, `SRTWriter`, `VTTWriter`, `ITTWriter`,
//! `MarkerCSV` and `YouTubeChapters` in SQExport.

mod edl;
mod fcpxml;
mod marker_csv;
mod otio;
mod subtitles;
mod xmeml;
mod youtube_chapters;

#[cfg(test)]
mod tests;

pub use edl::{EdlWriter, layer_files};
pub use fcpxml::{FcpxmlTarget, FcpxmlVersion, FcpxmlWriter};
pub use marker_csv::{MarkerCsv, MarkerCsvRow};
pub use otio::{OtioScope, OtioWriter};
pub use subtitles::{IttWriter, RangeSelection, SrtCue, SrtWriter, VttWriter};
pub use xmeml::XmemlWriter;
pub use youtube_chapters::{YouTubeChapters, YouTubeChaptersResult};

use sq_core_model::{Clip, ClipSpeed, MediaRef};
use sq_core_time::{Id, Time};
use std::collections::HashMap;
use std::fmt;
use std::path::Path;

/// Text of an interchange file plus what could not be carried (shown to the user after the export).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InterchangeExport {
    /// The file content.
    pub text: String,
    /// What the format could not carry, each reason once.
    pub warnings: Vec<String>,
    /// Set when the text could not be produced; `write_to` then fails instead of writing a broken file.
    pub failure: Option<String>,
}

impl InterchangeExport {
    /// An export that succeeded.
    pub fn new(text: String, warnings: Vec<String>) -> Self {
        InterchangeExport { text, warnings, failure: None }
    }

    /// Writes the file. Fails when the text is incomplete or the disk write fails, so the caller never reports an export
    /// that did not happen. The write goes through a temporary file next to the target, then a rename.
    pub fn write_to(&self, path: &Path) -> Result<(), InterchangeExportError> {
        if let Some(f) = &self.failure {
            return Err(InterchangeExportError::Failed(f.clone()));
        }
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let fail = |why: String| InterchangeExportError::WriteFailed(name.clone(), why);
        let tmp =
            path.with_extension(format!("{}.sqtmp", path.extension().map(|e| e.to_string_lossy()).unwrap_or_default()));
        std::fs::write(&tmp, self.text.as_bytes()).map_err(|e| fail(e.to_string()))?;
        std::fs::rename(&tmp, path).map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            fail(e.to_string())
        })?;
        match std::fs::metadata(path) {
            Ok(m) if m.len() == self.text.len() as u64 => Ok(()),
            _ => Err(fail("the file is incomplete".to_string())),
        }
    }
}

/// Why an interchange file was not written.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InterchangeExportError {
    /// The text could not be produced.
    Failed(String),
    /// The disk write failed: file name, reason.
    WriteFailed(String, String),
}

impl fmt::Display for InterchangeExportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            InterchangeExportError::Failed(s) => write!(f, "The file could not be created: {s}"),
            InterchangeExportError::WriteFailed(name, why) => write!(f, "Could not write {name}: {why}"),
        }
    }
}

impl std::error::Error for InterchangeExportError {}

/// Warnings of one render: each text once, in the order first raised.
#[derive(Default)]
pub(crate) struct Warnings(pub Vec<String>);

impl Warnings {
    pub fn warn(&mut self, w: impl Into<String>) {
        let w = w.into();
        if !self.0.contains(&w) {
            self.0.push(w);
        }
    }
}

/// Frame count of a time rounded to the nearest frame (a half frame goes up).
pub(crate) fn frames_rounded(t: Time, fd: Time) -> i64 {
    (t + fd.halved()).frame_index(fd)
}

/// Media by id; the first of several with the same id wins.
pub(crate) fn media_by_id(media: &[MediaRef]) -> HashMap<Id, &MediaRef> {
    let mut m = HashMap::new();
    for r in media {
        m.entry(r.id).or_insert(r);
    }
    m
}

/// A clip an interchange file can carry: no generator, no nested sequence, enabled.
pub(crate) fn usable_quiet(c: &Clip) -> bool {
    !c.is_generator() && !c.is_nested() && c.is_enabled
}

/// `usable_quiet` that says why a clip is left out.
pub(crate) fn usable(c: &Clip, w: &mut Warnings) -> bool {
    if c.is_generator() {
        w.warn(format!("Text and generator clips are not exported (\"{}\")", c.name));
        return false;
    }
    if c.is_nested() {
        w.warn(format!("Nested sequence \"{}\" is not exported", c.name));
        return false;
    }
    if !c.is_enabled {
        w.warn(format!("Disabled clip \"{}\" skipped", c.name));
        return false;
    }
    true
}

/// Speed and direction a clip is written with: a speed ramp goes out at its average speed, forward.
pub(crate) fn written_speed(c: &Clip, w: &mut Warnings) -> (ClipSpeed, bool) {
    if c.speed_keys.is_some() {
        w.warn(format!("Speed ramp on \"{}\" written at its average speed", c.name));
        return (c.average_speed(), false);
    }
    (c.speed, c.reversed)
}

/// `Transition.kind.rawValue`, the stored identifier.
pub(crate) fn raw_name<T: serde::Serialize>(v: &T) -> String {
    match serde_json::to_value(v) {
        Ok(serde_json::Value::String(s)) => s,
        _ => String::new(),
    }
}

/// `URL(fileURLWithPath:).absoluteString` for a path that is not a directory on disk: `file://`, path percent-encoded
/// like Foundation does.
// shortcut: no relative paths, no trailing slash for directories, and no Unicode decomposition (Foundation on macOS writes
// "e\u{301}" for "\u{e9}"); upgrade when a directory-valued media path appears or readers need the decomposed form.
pub(crate) fn file_url(path: &str) -> String {
    let mut out = String::from("file://");
    let b = path.as_bytes();
    let drive = b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && (b[2] == b'\\' || b[2] == b'/');
    let p: String = if drive { path.replace('\\', "/") } else { path.to_string() };
    let bytes_path = if p.starts_with('/') { p } else { format!("/{p}") };
    for b in bytes_path.bytes() {
        let keep = b.is_ascii_alphanumeric() || b"-._~/!$&'()*+,:;=@".contains(&b);
        if keep {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Swift `trimmingCharacters(in: .whitespaces)`: space separators and tab.
pub(crate) fn is_swift_whitespace(c: char) -> bool {
    matches!(c, '\t' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}')
}

/// Swift `.whitespacesAndNewlines`.
pub(crate) fn is_swift_whitespace_or_newline(c: char) -> bool {
    is_swift_whitespace(c) || matches!(c, '\n' | '\u{B}' | '\u{C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}
