//! Still images by file name (Swift `StillImage`): which extensions import as a one-picture clip with a default length.
//! Decoding is the platform's (FFmpeg reads the raster ones); this is the shared rule for the import probe.

use sq_core_time::Time;
use std::path::Path;

/// Raster formats. webp, psd, exr and the camera RAW formats depend on the decoder; a file it cannot open fails to import
/// with a reason (`MediaDiagnosis`).
pub const RASTER_EXTENSIONS: [&str; 21] = [
    "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp", "psd", "exr", "tga", "dpx", "dng",
    "ico", "icns", "hdr", "jp2", "j2k", "sgi",
];

/// Camera RAW stills (one frame).
pub const RAW_EXTENSIONS: [&str; 19] = [
    "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "raw", "dcr", "kdc",
    "mrw", "3fr", "erf",
];

/// Vector artwork: SVG and the first page of a PDF or Illustrator file.
pub const VECTOR_EXTENSIONS: [&str; 3] = ["svg", "pdf", "ai"];

/// Length of a still on the timeline when nothing else is said (`MediaInfo.defaultStillDuration`).
pub const DEFAULT_STILL_DURATION: Time = Time::new(5, 1);

/// True when the file name says the file is a still image.
pub fn is_still(path: &Path) -> bool {
    let Some(ext) = path.extension().map(|e| e.to_string_lossy().to_lowercase()) else { return false };
    [&RASTER_EXTENSIONS[..], &RAW_EXTENSIONS[..], &VECTOR_EXTENSIONS[..]].iter().any(|set| set.contains(&ext.as_str()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_decide_case_insensitively() {
        for name in ["a.PNG", "b.jpeg", "c.CR3", "d.svg", "e.dng", "f.tif"] {
            assert!(is_still(Path::new(name)), "{name}");
        }
        for name in ["a.mov", "b.wav", "noext", "c.mp4"] {
            assert!(!is_still(Path::new(name)), "{name}");
        }
    }
}
