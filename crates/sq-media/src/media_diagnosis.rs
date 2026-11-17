// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MediaDiagnosis.swift (`MediaDiagnosis`, `ImportNotes`; `VideoDecodability` needs the platform decoder: the ffmpeg
// probe reports an unsupported codec itself)
//! Plain-language reason a file could not be imported. Looks at the file itself (existence, size, the first bytes, the
//! top-level atoms of MP4/MOV) so the message names what is wrong instead of "could not read". Cheap: a few bytes of I/O,
//! meant for files that already failed to probe.

use crate::media_error::MediaError;
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::Mutex;

/// A container this app does not open: display name and what to convert it to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Container {
    pub name: &'static str,
    pub advice: &'static str,
}

const BRAW_ADVICE: &str =
    "Render it to ProRes 422 or 4444 in DaVinci Resolve (the free version works) and import the result.";
const R3D_ADVICE: &str = "Render it to ProRes 422 or 4444 with REDCINE-X PRO or DaVinci Resolve and import the result.";
const DTS_ADVICE: &str =
    "Convert it to WAV or AIFF (multichannel is fine) with a tool such as ffmpeg or Audacity and import it again.";
const DNG_ADVICE: &str = "A CinemaDNG shot is a folder of numbered frames: render it to ProRes 422 or 4444 in DaVinci Resolve and import the result.";
const LEGACY_VIDEO_ADVICE: &str = "Convert it to MP4 (H.264 or HEVC) with HandBrake or ffmpeg and import it again.";
const CONVERT: &str = "Convert it to MP4 (H.264 or HEVC) and import it again.";
const AUDIO_CONVERT: &str = "Convert it to WAV, AIFF or AAC (m4a) and import it again.";

/// Still image extensions (Swift `StillImage.extensions`: raster, camera RAW, vector).
const STILL_EXTENSIONS: &[&str] = &[
    "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp", "psd", "exr", "tga", "dpx", "dng",
    "ico", "icns", "hdr", "jp2", "j2k", "sgi", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
    "rw2", "pef", "srw", "raw", "dcr", "kdc", "mrw", "3fr", "erf", "svg", "pdf", "ai",
];

const MEDIA_EXTENSIONS: &[&str] = &[
    "mp4", "m4v", "mov", "qt", "mkv", "webm", "mxf", "mts", "m2ts", "ts", "mpg", "mpeg", "m2v", "3gp", "3g2", "wav",
    "aif", "aiff", "aifc", "mp3", "m4a", "aac", "caf", "flac", "opus", "ogg", "oga", "ac3", "mka",
];

fn known_extension(ext: &str) -> bool {
    !ext.is_empty() && (MEDIA_EXTENSIONS.contains(&ext) || STILL_EXTENSIONS.contains(&ext))
}

/// The reason text for a file that failed to import.
pub struct MediaDiagnosis;

impl MediaDiagnosis {
    /// Why `path` cannot be imported; `error` is the importer's own error, when there is one.
    pub fn reason(path: &Path, error: Option<&MediaError>) -> String {
        if let Some(MediaError::UnsupportedCodec(codec)) = error {
            return match Self::codec_advice(codec) {
                Some(c) => format!("{} files are not supported. {}", c.name, c.advice),
                None => format!("Uses {codec}, which this computer cannot decode."),
            };
        }
        let Ok(meta) = std::fs::metadata(path) else { return "The file is no longer there.".into() };
        if meta.is_dir() {
            return "This is a folder, not a media file.".into();
        }
        if File::open(path).is_err() {
            return "Sequence Studio is not allowed to read this file. Check its permissions or the folder's access."
                .into();
        }
        let size = meta.len();
        if size == 0 {
            return "The file is empty (0 bytes). The copy or download probably did not finish.".into();
        }
        let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
        if ext == "m4p" {
            return "The file is copy protected (DRM) and cannot be read.".into();
        }
        let head = Self::read_head(path, 16);
        let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        if let Some(c) = Self::container(&head, &ext, &stem) {
            return format!("{} files are not supported. {}", c.name, c.advice);
        }
        if let Some(kind) = Self::document_kind(&head) {
            return format!("This is {kind}, not a video, audio or image file.");
        }
        if Self::is_iso_base_media(&head) {
            if Self::missing_top_level_atom(path, size) == Some("moov") {
                return "The recording is incomplete: the file has no index (moov). It was probably interrupted. Re-copy it from the card, or repair it with the camera maker's tool.".into();
            }
            return "The file is damaged or uses a format Sequence Studio cannot read.".into();
        }
        if !known_extension(&ext) {
            return if ext.is_empty() {
                "This file has no type Sequence Studio recognizes.".into()
            } else {
                format!("Files of type .{ext} are not a media type Sequence Studio recognizes.")
            };
        }
        "The file may be damaged, or uses a format Sequence Studio cannot read.".into()
    }

    /// Codecs that identify a camera RAW format by their four-character code.
    pub fn codec_advice(codec: &str) -> Option<Container> {
        match codec.trim().to_lowercase().as_str() {
            "aprn" | "aprh" => Some(Container {
                name: "ProRes RAW",
                advice: "Export it as ProRes 422 or 4444 from the camera's own software (or Final Cut Pro) and import that.",
            }),
            "braw" => Some(Container { name: "Blackmagic RAW (BRAW)", advice: BRAW_ADVICE }),
            _ => None,
        }
    }

    fn read_head(path: &Path, count: usize) -> Vec<u8> {
        let mut buf = Vec::new();
        if let Ok(f) = File::open(path) {
            let _ = f.take(count as u64).read_to_end(&mut buf);
        }
        buf
    }

    /// The container named by the first bytes, else by the extension.
    pub fn container(head: &[u8], ext: &str, stem: &str) -> Option<Container> {
        let numbered = stem.chars().last().is_some_and(char::is_numeric); // frame of a numbered CinemaDNG shot
        let starts = |s: &[u8], at: usize| head.len() >= at + s.len() && &head[at..at + s.len()] == s;
        let c = |name, advice| Some(Container { name, advice });
        if starts(b"RED1", 4) || starts(b"RED2", 4) {
            return c("RED R3D", R3D_ADVICE);
        }
        if starts(b"RIFF", 0) && starts(b"AVI ", 8) {
            return c("AVI", CONVERT);
        }
        if starts(&[0x30, 0x26, 0xB2, 0x75], 0) {
            return c("Windows Media (WMV)", LEGACY_VIDEO_ADVICE);
        }
        if starts(b"FLV", 0) {
            return c("Flash Video (FLV)", CONVERT);
        }
        if starts(b".RMF", 0) {
            return c("RealMedia", CONVERT);
        }
        if starts(b"OggS", 0) {
            return c("Ogg", AUDIO_CONVERT);
        }
        if starts(&[0x00, 0x00, 0x01, 0xBA], 0) {
            return c("MPEG program stream (VOB)", CONVERT);
        }
        match ext {
            "avi" => c("AVI", CONVERT),
            "wmv" | "asf" => c("Windows Media (WMV)", LEGACY_VIDEO_ADVICE),
            "braw" => c("Blackmagic RAW (BRAW)", BRAW_ADVICE),
            "r3d" => c("RED R3D", R3D_ADVICE),
            "dts" | "dtshd" => c("DTS audio", DTS_ADVICE),
            "dng" if numbered => c("CinemaDNG", DNG_ADVICE),
            "flv" | "f4v" => c("Flash Video (FLV)", CONVERT),
            "rm" | "rmvb" => c("RealMedia", CONVERT),
            "vob" => c("MPEG program stream (VOB)", CONVERT),
            "wma" => c("Windows Media Audio (WMA)", AUDIO_CONVERT),
            _ => None,
        }
    }

    /// What a non-media file with these first bytes is.
    pub fn document_kind(head: &[u8]) -> Option<&'static str> {
        let starts = |b: &[u8]| head.starts_with(b);
        if starts(b"%PDF") {
            Some("a PDF document")
        } else if starts(&[0x50, 0x4B, 0x03, 0x04]) {
            Some("a zip archive")
        } else if starts(&[0x1F, 0x8B]) {
            Some("a compressed archive")
        } else if starts(b"<?xml") || starts(b"<html") || starts(b"{") {
            Some("a text document")
        } else {
            None
        }
    }

    pub fn is_iso_base_media(head: &[u8]) -> bool {
        head.len() >= 8 && &head[4..8] == b"ftyp"
    }

    /// Walks the top-level atoms of an MP4/MOV; returns "moov" when the file ends without a movie atom (an interrupted
    /// recording), `None` when it is present or the walk cannot tell.
    pub fn missing_top_level_atom(path: &Path, size: u64) -> Option<&'static str> {
        let mut f = File::open(path).ok()?;
        let (mut offset, mut saw_mdat) = (0u64, false);
        for _ in 0..4096 {
            if offset + 8 > size {
                break;
            }
            f.seek(SeekFrom::Start(offset)).ok()?;
            let mut b = Vec::new();
            (&mut f).take(16).read_to_end(&mut b).ok()?;
            if b.len() < 8 {
                return None;
            }
            let mut len = u64::from(u32::from_be_bytes([b[0], b[1], b[2], b[3]]));
            match &b[4..8] {
                b"moov" => return None,
                b"mdat" => saw_mdat = true,
                _ => {}
            }
            if len == 1 && b.len() >= 16 {
                len = u64::from_be_bytes(b[8..16].try_into().ok()?);
            } else if len == 0 {
                len = size - offset; // runs to the end of the file
            }
            if len < 8 {
                return None;
            }
            offset = offset.saturating_add(len);
        }
        // The walk reached the end (or went past it, a cut-off atom) without a movie atom.
        (saw_mdat || offset >= size).then_some("moov")
    }
}

/// What the importer noticed about a file that did import: the model asks once after the probe (`take`) and tells the user.
/// Session-only memory, keyed by path.
pub struct ImportNotes;

static DROPPED_AUDIO: Mutex<BTreeMap<String, String>> = Mutex::new(BTreeMap::new());

impl ImportNotes {
    /// The file imported, but its audio uses a codec this machine cannot decode: it plays as video without sound.
    pub fn note_audio_dropped(path: &Path, codec: &str) {
        if let Ok(mut m) = DROPPED_AUDIO.lock() {
            m.insert(path.to_string_lossy().into_owned(), codec.to_string());
        }
    }

    /// The codec of the audio that was dropped for `path` (once), `None` if none.
    pub fn take_audio_dropped(path: &Path) -> Option<String> {
        DROPPED_AUDIO.lock().ok()?.remove(path.to_string_lossy().as_ref())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn file(name: &str, bytes: &[u8]) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-diag-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join(name);
        File::create(&p).unwrap().write_all(bytes).unwrap();
        p
    }

    fn atom(kind: &[u8; 4], payload: usize) -> Vec<u8> {
        let mut v = ((payload + 8) as u32).to_be_bytes().to_vec();
        v.extend_from_slice(kind);
        v.extend(std::iter::repeat_n(0u8, payload));
        v
    }

    #[test]
    fn missing_empty_and_folder_files_are_named() {
        assert_eq!(MediaDiagnosis::reason(Path::new("/nope/none.mov"), None), "The file is no longer there.");
        assert_eq!(MediaDiagnosis::reason(&std::env::temp_dir(), None), "This is a folder, not a media file.");
        assert!(MediaDiagnosis::reason(&file("e.mov", b""), None).starts_with("The file is empty (0 bytes)"));
        assert!(MediaDiagnosis::reason(&file("a.m4p", b"x"), None).contains("copy protected"));
    }

    #[test]
    fn containers_are_found_by_first_bytes_then_by_extension() {
        let avi = file("clip.bin", b"RIFF\0\0\0\0AVI LIST");
        assert!(MediaDiagnosis::reason(&avi, None).starts_with("AVI files are not supported."));
        let r3d = file("c.dat", b"\0\0\0\x10RED2xxxxxxxx");
        assert!(MediaDiagnosis::reason(&r3d, None).starts_with("RED R3D files"));
        assert!(MediaDiagnosis::reason(&file("x.braw", b"abcd"), None).starts_with("Blackmagic RAW (BRAW) files"));
        assert!(MediaDiagnosis::container(b"", "dng", "A001_0003").is_some());
        assert!(MediaDiagnosis::container(b"", "dng", "photo").is_none());
        assert_eq!(
            MediaDiagnosis::reason(&file("d.pdf", b"%PDF-1.7"), None),
            "This is a PDF document, not a video, audio or image file."
        );
    }

    #[test]
    fn a_recording_without_moov_is_called_incomplete() {
        let mut cut = atom(b"ftyp", 8);
        cut.extend(atom(b"mdat", 100));
        assert!(MediaDiagnosis::reason(&file("cut.mp4", &cut), None).contains("no index (moov)"));
        let mut whole = atom(b"ftyp", 8);
        whole.extend(atom(b"moov", 20));
        whole.extend(atom(b"mdat", 100));
        assert!(MediaDiagnosis::reason(&file("ok.mp4", &whole), None).starts_with("The file is damaged or uses"));
    }

    #[test]
    fn unknown_types_and_codecs_get_their_own_text() {
        assert_eq!(
            MediaDiagnosis::reason(&file("n.xyz", b"hello"), None),
            "Files of type .xyz are not a media type Sequence Studio recognizes."
        );
        assert!(MediaDiagnosis::reason(&file("ok.mp3", b"ID3\0\0\0"), None).starts_with("The file may be damaged"));
        let e = MediaError::UnsupportedCodec("aprh".into());
        assert!(MediaDiagnosis::reason(Path::new("x"), Some(&e)).starts_with("ProRes RAW files are not supported."));
        let e = MediaError::UnsupportedCodec("av01".into());
        assert_eq!(MediaDiagnosis::reason(Path::new("x"), Some(&e)), "Uses av01, which this computer cannot decode.");
    }

    #[test]
    fn dropped_audio_notes_are_taken_once() {
        let p = Path::new("/tmp/sq-note-test.mov");
        ImportNotes::note_audio_dropped(p, "ac-4");
        assert_eq!(ImportNotes::take_audio_dropped(p).as_deref(), Some("ac-4"));
        assert_eq!(ImportNotes::take_audio_dropped(p), None);
    }
}
