// Swift: LibraryItemKind.swift
//! Kind of a file shown in the library. Extension based (no UTType dependency).

use serde::{Deserialize, Serialize};
use std::path::Path;

/// Kind of a file shown in the library.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LibraryItemKind {
    /// Sound file.
    Audio,
    /// Movie file.
    Video,
    /// Still image.
    Image,
    /// Video or image with an alpha channel.
    Overlay,
    /// Color lookup table.
    Lut,
    /// Font file.
    Font,
    /// Anything else.
    Other,
}

const VIDEO: &[&str] = &["mp4", "mov", "m4v", "mkv", "avi", "mxf", "webm", "mpg", "mpeg", "mts", "m2ts", "prores"];
const AUDIO: &[&str] = &["wav", "mp3", "aif", "aiff", "aifc", "m4a", "aac", "flac", "caf", "ogg", "opus"];
const IMAGE: &[&str] =
    &["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp", "exr", "dpx", "psd"];
const LUT: &[&str] = &["cube", "3dl", "look", "mga", "m3d"];
const FONT: &[&str] = &["ttf", "otf", "ttc", "otc", "woff", "woff2"];

impl LibraryItemKind {
    /// Every case, in declaration order.
    pub const ALL: [LibraryItemKind; 7] = [
        LibraryItemKind::Audio,
        LibraryItemKind::Video,
        LibraryItemKind::Image,
        LibraryItemKind::Overlay,
        LibraryItemKind::Lut,
        LibraryItemKind::Font,
        LibraryItemKind::Other,
    ];

    /// Classify by extension. `has_alpha` is a hint from a later probe: alpha video or image becomes `Overlay`.
    pub fn classify(path: &Path, has_alpha: bool) -> LibraryItemKind {
        let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
        let ext = ext.as_str();
        if VIDEO.contains(&ext) {
            return if has_alpha { Self::Overlay } else { Self::Video };
        }
        if IMAGE.contains(&ext) {
            return if has_alpha { Self::Overlay } else { Self::Image };
        }
        if AUDIO.contains(&ext) {
            return Self::Audio;
        }
        if LUT.contains(&ext) {
            return Self::Lut;
        }
        if FONT.contains(&ext) {
            return Self::Font;
        }
        Self::Other
    }

    /// True for hidden and OS metadata files.
    pub fn is_ignored(file_name: &str) -> bool {
        if file_name.starts_with('.') {
            return true;
        }
        let lower = file_name.to_lowercase();
        lower == "thumbs.db" || lower == "desktop.ini"
    }

    /// Kind, or `None` when the file is hidden/system.
    pub fn classify_if_visible(path: &Path, has_alpha: bool) -> Option<LibraryItemKind> {
        let name = path.file_name().map(|n| n.to_string_lossy()).unwrap_or_default();
        if Self::is_ignored(&name) { None } else { Some(Self::classify(path, has_alpha)) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use LibraryItemKind::*;

    fn p(name: &str) -> std::path::PathBuf {
        Path::new("/x").join(name)
    }

    #[test]
    fn classifies_by_extension() {
        let cases = [
            ("a.mp4", Video),
            ("a.MOV", Video),
            ("a.mkv", Video),
            ("a.m4v", Video),
            ("a.wav", Audio),
            ("a.MP3", Audio),
            ("a.aiff", Audio),
            ("a.AIFC", Audio),
            ("a.m4a", Audio),
            ("a.flac", Audio),
            ("a.png", Image),
            ("a.JPG", Image),
            ("a.heic", Image),
            ("a.tiff", Image),
            ("a.cube", Lut),
            ("a.3dl", Lut),
            ("a.CUBE", Lut),
            ("a.ttf", Font),
            ("a.otf", Font),
            ("a.ttc", Font),
            ("a.txt", Other),
            ("noextension", Other),
            ("a.pdf", Other),
        ];
        for (name, expected) in cases {
            assert_eq!(LibraryItemKind::classify(&p(name), false), expected, "{name}");
        }
    }

    #[test]
    fn alpha_promotes_video_and_image_to_overlay() {
        assert_eq!(LibraryItemKind::classify(&p("a.mov"), true), Overlay);
        assert_eq!(LibraryItemKind::classify(&p("a.png"), true), Overlay);
        assert_eq!(LibraryItemKind::classify(&p("a.wav"), true), Audio);
        assert_eq!(LibraryItemKind::classify(&p("a.mov"), false), Video);
    }

    #[test]
    fn hidden_and_system_files_are_ignored() {
        for name in [".DS_Store", ".hidden.mp4", "._clip.mov", "Thumbs.db", "desktop.ini", ".localized"] {
            assert!(LibraryItemKind::is_ignored(name), "{name}");
        }
        assert!(!LibraryItemKind::is_ignored("clip.mov"));
        assert_eq!(LibraryItemKind::classify_if_visible(&p(".DS_Store"), false), None);
        assert_eq!(LibraryItemKind::classify_if_visible(&p("a.mov"), false), Some(Video));
    }
}
