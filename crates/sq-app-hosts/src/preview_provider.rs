// Swift: SQLibrary/MediaPreviewProvider.swift
//! The Library's preview provider: a thumbnail is the frame 10 % into a video (the first frame as a fallback) or the
//! picture of an image, shrunk to fit the request and written as PNG. The file must still match the request's content
//! hash when the preview is done (else `Stale`). A thumbnail follows the file's rotation tag and probes alpha into a
//! `<caches>/thumbnail/<contentKey>.alpha` sidecar ([`MediaPreviewProvider::has_alpha`]); a waveform is the peak pyramid in
//! `WaveformData`'s binary form.

use crate::analysis_links::ffmpeg_frames::FfmpegFrameReader;
use sq_analysis::edge_tamonnx::SubjectFrame;
use sq_library::library_item_kind::LibraryItemKind;
use sq_library::preview_requests::ContentHash;
use sq_library::preview_requests::{PreviewError, PreviewKind, PreviewProvider, PreviewRequest};
use sq_media::peak_pyramid::PeakPyramid;
use sq_media::waveform_data::WaveformData;
use sq_media_ffmpeg::decode::FFmpegAudioSource;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

/// The mixer rate a waveform is decoded at.
const WAVEFORM_RATE: i32 = 48_000;
/// Frames read per chunk while building peaks.
const CHUNK: usize = 1 << 16;

/// `PreviewProvider` over FFmpeg frames and audio.
#[derive(Default)]
pub struct MediaPreviewProvider {
    /// The preview cache's root (the alpha sidecars sit in its `thumbnail` folder); none = no sidecars.
    cache_root: Option<PathBuf>,
}

impl MediaPreviewProvider {
    /// A provider that writes its alpha sidecars into the preview cache at `cache_root`.
    pub fn with_cache(cache_root: PathBuf) -> MediaPreviewProvider {
        MediaPreviewProvider { cache_root: Some(cache_root) }
    }

    fn alpha_path(&self, hash: &ContentHash) -> Option<PathBuf> {
        Some(self.cache_root.as_ref()?.join("thumbnail").join(format!("{}.alpha", hash.key())))
    }

    /// Alpha probed while making the thumbnail; `None` if no thumbnail was made for this content yet.
    // Swift has no caller of `hasAlpha(for:)` either; the sidecar is kept for the Overlay classification.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn has_alpha(&self, request: &PreviewRequest) -> Option<bool> {
        let text = std::fs::read_to_string(self.alpha_path(&request.content_hash)?).ok()?;
        Some(text == "1")
    }

    fn write_alpha(&self, hash: &ContentHash, alpha: bool) -> Result<(), String> {
        let Some(path) = self.alpha_path(hash) else { return Ok(()) };
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        std::fs::write(path, if alpha { "1" } else { "0" }).map_err(|e| e.to_string())
    }
}

/// The peak pyramid of the file's audio in `WaveformData`'s binary form; `Cancelled` when `cancel` is set meanwhile.
fn waveform_bytes(path: &Path, cancel: &AtomicBool) -> Result<Vec<u8>, PreviewError> {
    let source =
        FFmpegAudioSource::open_mapped(path, WAVEFORM_RATE, None).map_err(|e| PreviewError::Failed(e.to_string()))?;
    let rate = usize::try_from(WAVEFORM_RATE).unwrap_or(48_000);
    let built: WaveformData =
        PeakPyramid::waveform_from(&*source, rate, WaveformData::DEFAULT_BASE_BUCKET_SIZE, CHUNK, || {
            cancel.load(Ordering::SeqCst)
        })
        .map_err(|e| PreviewError::Failed(e.to_string()))?
        .ok_or(PreviewError::Cancelled)?;
    Ok(built.serialized())
}

/// The picture turned upright by the file's rotation tag (clockwise degrees).
fn upright(width: usize, height: usize, rgba: Vec<u8>, rotation: i64) -> (usize, usize, Vec<u8>) {
    let turned = SubjectFrame::new(width, height, rgba).upright(rotation);
    (turned.width, turned.height, turned.rgba)
}

fn unchanged(request: &PreviewRequest) -> bool {
    let Ok(meta) = std::fs::metadata(&request.content_hash.path) else { return false };
    let Some(modified) = meta.modified().ok().and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok()) else {
        return false;
    };
    let was = request.content_hash.modified.unix_seconds();
    i64::try_from(meta.len()).is_ok_and(|n| n == request.content_hash.size)
        && (modified.as_secs_f64() - was).abs() <= 0.001
}

fn write_png(path: &Path, width: usize, height: usize, rgba: &[u8]) -> Result<(), String> {
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), width as u32, height as u32);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut writer = enc.write_header().map_err(|e| e.to_string())?;
    writer.write_image_data(rgba).map_err(|e| e.to_string())
}

impl PreviewProvider for MediaPreviewProvider {
    fn generate(&self, request: &PreviewRequest, destination: &Path, cancel: &AtomicBool) -> Result<(), PreviewError> {
        if cancel.load(Ordering::SeqCst) {
            return Err(PreviewError::Cancelled);
        }
        let path = Path::new(&request.content_hash.path);
        if request.kind == PreviewKind::Waveform {
            let bytes = waveform_bytes(path, cancel)?;
            std::fs::write(destination, bytes).map_err(|e| PreviewError::Failed(e.to_string()))?;
            return if unchanged(request) { Ok(()) } else { Err(PreviewError::Stale) };
        }
        if !matches!(
            LibraryItemKind::classify(path, false),
            LibraryItemKind::Video | LibraryItemKind::Overlay | LibraryItemKind::Image
        ) {
            return Err(PreviewError::Failed("unsupported".to_string()));
        }
        let reader = FfmpegFrameReader::open(path).map_err(PreviewError::Failed)?;
        let side = request.pixel_width.max(request.pixel_height).max(1) as usize;
        // 10 % in, the first frame when that one cannot be decoded.
        let picture = reader
            .picture(reader.count() / 10, side)
            .or_else(|| reader.picture(0, side))
            .ok_or_else(|| PreviewError::Failed("decode failed".to_string()))?;
        if cancel.load(Ordering::SeqCst) {
            return Err(PreviewError::Cancelled);
        }
        let (width, height, rgba) = upright(picture.width, picture.height, picture.rgba, reader.rotation());
        write_png(destination, width, height, &rgba).map_err(PreviewError::Failed)?;
        self.write_alpha(&request.content_hash, picture.has_alpha).map_err(PreviewError::Failed)?;
        if !unchanged(request) {
            return Err(PreviewError::Stale);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Timestamp;
    use sq_library::preview_requests::ContentHash;

    #[test]
    fn a_missing_file_fails_for_both_kinds_and_a_set_cancel_flag_wins() {
        let hash =
            ContentHash { path: "/no/such/file.mov".to_string(), modified: Timestamp::from_unix_seconds(0.0), size: 0 };
        let mut r = PreviewRequest {
            entry_id: sq_library::watched_folder::LibraryEntryID {
                folder_id: sq_core_time::Id::from_u128(1),
                relative_path: "file.mov".to_string(),
            },
            kind: PreviewKind::Thumbnail,
            pixel_width: 160,
            pixel_height: 90,
            content_hash: hash,
        };
        let cancel = AtomicBool::new(false);
        let out = std::env::temp_dir().join("sq-preview-test.png");
        let provider = MediaPreviewProvider::default();
        assert!(matches!(provider.generate(&r, &out, &cancel), Err(PreviewError::Failed(_))));
        r.kind = PreviewKind::Waveform;
        assert!(matches!(provider.generate(&r, &out, &cancel), Err(PreviewError::Failed(_))));
        cancel.store(true, Ordering::SeqCst);
        assert_eq!(provider.generate(&r, &out, &cancel), Err(PreviewError::Cancelled));
    }

    fn request_for(path: &str, kind: PreviewKind) -> PreviewRequest {
        let meta = std::fs::metadata(path).ok();
        let modified = meta
            .as_ref()
            .and_then(|m| m.modified().ok())
            .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0.0, |d| d.as_secs_f64());
        PreviewRequest {
            entry_id: sq_library::watched_folder::LibraryEntryID {
                folder_id: sq_core_time::Id::from_u128(1),
                relative_path: "x".to_string(),
            },
            kind,
            pixel_width: 64,
            pixel_height: 64,
            content_hash: ContentHash {
                path: path.to_string(),
                modified: Timestamp::from_unix_seconds(modified),
                size: meta.map_or(0, |m| m.len() as i64),
            },
        }
    }

    #[test]
    fn the_alpha_sidecar_is_unknown_until_written_then_reads_back() {
        let dir = std::env::temp_dir().join(format!("sq-alpha-{}", std::process::id()));
        let provider = MediaPreviewProvider::with_cache(dir.clone());
        let r = request_for("/no/such/clip.mov", PreviewKind::Thumbnail);
        assert_eq!(provider.has_alpha(&r), None);
        provider.write_alpha(&r.content_hash, true).unwrap();
        assert_eq!(provider.has_alpha(&r), Some(true));
        provider.write_alpha(&r.content_hash, false).unwrap();
        assert_eq!(provider.has_alpha(&r), Some(false));
        assert_eq!(MediaPreviewProvider::default().has_alpha(&r), None);
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn a_rotation_tag_turns_the_thumbnail_upright() {
        // 2 x 1 stored, tag 90 clockwise: shown 1 x 2, the left pixel on top.
        let (w, h, rgba) = upright(2, 1, vec![1, 1, 1, 1, 2, 2, 2, 2], 90);
        assert_eq!((w, h), (1, 2));
        assert_eq!(rgba, vec![1, 1, 1, 1, 2, 2, 2, 2]);
        let (w, h, rgba) = upright(2, 1, vec![1, 1, 1, 1, 2, 2, 2, 2], 180);
        assert_eq!((w, h), (2, 1));
        assert_eq!(rgba, vec![2, 2, 2, 2, 1, 1, 1, 1]);
        assert_eq!(upright(2, 1, vec![0; 8], 0).0, 2);
    }

    /// A one second 440 Hz tone as a WAV, so the waveform path runs on a real file.
    #[test]
    fn a_wav_file_gets_a_waveform_in_the_binary_format() {
        let dir = std::env::temp_dir().join(format!("sq-wave-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let wav = dir.join("tone.wav");
        let frames = 48_000_u32;
        let mut bytes = Vec::new();
        bytes.extend(b"RIFF");
        bytes.extend((36 + frames * 2).to_le_bytes());
        bytes.extend(b"WAVEfmt ");
        bytes.extend(16_u32.to_le_bytes());
        bytes.extend(1_u16.to_le_bytes());
        bytes.extend(1_u16.to_le_bytes());
        bytes.extend(48_000_u32.to_le_bytes());
        bytes.extend((48_000_u32 * 2).to_le_bytes());
        bytes.extend(2_u16.to_le_bytes());
        bytes.extend(16_u16.to_le_bytes());
        bytes.extend(b"data");
        bytes.extend((frames * 2).to_le_bytes());
        for i in 0..frames {
            let v = ((i as f32 * 440.0 * std::f32::consts::TAU / 48_000.0).sin() * 16_000.0) as i16;
            bytes.extend(v.to_le_bytes());
        }
        std::fs::write(&wav, bytes).unwrap();
        let r = request_for(wav.to_str().unwrap(), PreviewKind::Waveform);
        let out = dir.join("tone.waveform");
        MediaPreviewProvider::default().generate(&r, &out, &AtomicBool::new(false)).unwrap();
        let data = WaveformData::from_serialized(&std::fs::read(&out).unwrap()).unwrap();
        assert_eq!(data.channel_count, 1);
        assert!(data.bucket(0, 0, 0).max > 0.3);
        std::fs::remove_dir_all(dir).ok();
    }
}
