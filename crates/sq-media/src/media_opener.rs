// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: the role of `WinMediaSource.init` / `MediaResolver` (open a file into a demuxer and a decoder)
//! The seam between the playback engine and the platform's decoders: open a media file as a demuxer plus a video
//! decoder. On the Mac the opener tries VideoToolbox first and falls back to FFmpeg; on Windows it is FFmpeg (D3D11VA or
//! software). The engine only sees these traits.

use crate::demuxing::Demuxing;
use crate::media_error::MediaError;
use crate::video_decoding::VideoDecoding;
use sq_core_model::VideoTrackInfo;
use sq_core_time::Id;
use std::path::Path;
use std::sync::Arc;

/// One opened video file: the frame table (`demuxer.index()`), the decoder reading it and the track facts.
#[derive(Clone)]
pub struct OpenedMedia {
    pub demuxer: Arc<dyn Demuxing>,
    pub decoder: Arc<dyn VideoDecoding>,
    pub info: VideoTrackInfo,
    /// "1920x1080 h264 (videotoolbox)": for logs and the play statistics.
    pub label: String,
    /// Switches the decoder's scrub preview mode (software decoders skip the loop filter); `None` = the decoder has none.
    pub set_preview: Option<Arc<dyn Fn(bool) + Send + Sync>>,
    /// The decoder's pictures are read as full range (the stream's own flag); false: video range.
    pub full_range: bool,
}

/// Opens media files. Blocking (reads the index, starts a decoder: up to 400 ms for a 4K file), so callers run it off
/// their own thread. Every call returns an independent decoder (a second lane over the same file).
pub trait MediaOpener: Send + Sync {
    fn open(&self, path: &Path, media: Id) -> Result<OpenedMedia, MediaError>;

    /// The file a monitor reads while it is `monitor`, when that is not the original: a proxy for scrubbing and
    /// playing, never for a paused frame (Swift reads the original while paused). `None`: the original is right.
    fn open_for(&self, path: &Path, media: Id, monitor: MonitorUse) -> Option<Result<OpenedMedia, MediaError>> {
        let _ = (path, media, monitor);
        None
    }

    /// Opens `file`, a proxy of the media that `original` was opened from. A proxy holds the original's codes unscaled and
    /// its container cannot say full range, so its pictures are read the way the original's are (`full_range`), whatever the
    /// proxy's own flags say. The default is a plain open.
    fn open_proxy(&self, file: &Path, media: Id, original: &OpenedMedia) -> Result<OpenedMedia, MediaError> {
        let _ = original;
        self.open(file, media)
    }
}

/// What a monitor is doing when it asks for a file (the one state the opener tells proxy from original by).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MonitorUse {
    /// Stopped on a frame: full quality, the original.
    Paused,
    /// Playing.
    Playing,
    /// Dragging the playhead.
    Scrubbing,
}
