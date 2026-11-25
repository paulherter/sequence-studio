// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Windows/SQWinApp WinMediaSource.swift
//! One media file for the engines (Program playback): the frame table, the decoder, the source-time to frame mapping and
//! the conversion of decoded frames into pictures. FFmpeg frames are downloaded into CPU planes (NV12 / P010, or RGBA for
//! footage with alpha) on the decoding thread, box-reduced by the divisor where the shim can; GPU frames (the Mac
//! VideoToolbox import) pass through untouched.
//! shortcut: a divisor the shim has no reduced path for keeps the full-size picture (Swift reduced it on the CPU, dropping
//! 10-bit to 8); add `NV12Reduce` when such media plays reduced often.

use super::stats::{PlayStats, Stage};
use super::types::Picture;
use sq_core_model::{FieldOrder, VideoTrackInfo};
use sq_core_time::{Id, Time};
use sq_frame::buffer_pool::PooledBytes;
use sq_frame::sqframe::{SQFrame, SQFramePixelFormat};
use sq_gpu::gpu::Gpu;
use sq_media::demuxing::Demuxing;
use sq_media::media_error::MediaError;
use sq_media::media_opener::{MediaOpener, OpenedMedia};
use sq_media::video_decoding::{DecodedFrame, StopCheck, VideoDecoding};
use sq_media_ffmpeg::decode::{
    DEFAULT_EXTRA_HW_FRAMES, FFmpegDemuxer, FFmpegFrame, FFmpegVideoDecoder, flagged_full_range, frame_color,
    media_error,
};
use sq_render::program::CpuPlanes;
use sq_video_hw::VtVideoDecoder;
use sq_video_hw::codec::StreamRange;
use std::future::Future;
use std::ops::RangeInclusive;
use std::path::Path;
use std::pin::pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::task::{Context, Poll, Wake, Waker};
use std::time::Instant;

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

/// Runs a future to completion on the calling thread (the decode futures of `VideoDecoding` are blocking inside).
pub fn block_on<T>(fut: impl Future<Output = T>) -> T {
    struct Signal {
        ready: Mutex<bool>,
        cv: Condvar,
    }
    impl Wake for Signal {
        fn wake(self: Arc<Self>) {
            *self.ready.lock().unwrap_or_else(PoisonError::into_inner) = true;
            self.cv.notify_one();
        }
    }
    let signal = Arc::new(Signal { ready: Mutex::new(false), cv: Condvar::new() });
    let waker = Waker::from(Arc::clone(&signal));
    let mut cx = Context::from_waker(&waker);
    let mut fut = pin!(fut);
    loop {
        if let Poll::Ready(v) = fut.as_mut().poll(&mut cx) {
            return v;
        }
        let mut ready = signal.ready.lock().unwrap_or_else(PoisonError::into_inner);
        while !*ready {
            ready = signal.cv.wait(ready).unwrap_or_else(PoisonError::into_inner);
        }
        *ready = false;
    }
}

/// An open file: demuxer, decoder and the track facts, read once at open.
pub struct MediaSource {
    /// Unique per open decoder (the lane pool's queue key).
    pub id: u64,
    pub demuxer: Arc<dyn Demuxing>,
    pub decoder: Arc<dyn VideoDecoding>,
    pub info: VideoTrackInfo,
    pub label: String,
    set_preview: Option<Arc<dyn Fn(bool) + Send + Sync>>,
}

impl MediaSource {
    pub fn from_opened(o: OpenedMedia, stats: &PlayStats) -> MediaSource {
        stats.decoder_opened(&o.label);
        MediaSource {
            id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
            demuxer: o.demuxer,
            decoder: o.decoder,
            info: o.info,
            label: o.label,
            set_preview: o.set_preview,
        }
    }

    pub fn frame_count(&self) -> usize {
        self.demuxer.index().count()
    }

    /// True when scrubbing can use the decoder's preview mode (software decoder; hardware decodes at full speed already).
    pub fn can_preview(&self) -> bool {
        self.set_preview.is_some() && !self.decoder.is_hardware()
    }

    pub fn set_preview(&self, on: bool) {
        if let Some(f) = &self.set_preview {
            f(on);
        }
    }

    /// The presentation index a layer at `source_time` shows (clamped; past the end: the last frame).
    pub fn frame_index(&self, source_time: Time) -> i64 {
        let idx = self.demuxer.index();
        let count = idx.count() as i64;
        let first = idx.entries().first().map_or(Time::ZERO, |e| e.pts);
        let i = idx.frame_at(source_time + first).map(|i| i as i64).unwrap_or(if source_time > Time::ZERO {
            count - 1
        } else {
            0
        });
        i.clamp(0, (count - 1).max(0))
    }

    /// Decodes `range` and hands every picture to `deliver` as soon as it is converted (on the calling thread, in decode
    /// order), reduced by `divisor` (1, 2, 4). `threaded` (playback): a full-size picture also takes the threaded
    /// download path; exports and paused frames keep swscale's chroma filter at full size.
    pub fn stream_pictures(
        &self,
        range: RangeInclusive<i64>,
        divisor: u32,
        threaded: bool,
        stats: &Arc<PlayStats>,
        deliver: Arc<dyn Fn(i64, Picture) + Send + Sync>,
        stop: StopCheck,
    ) -> Result<(), MediaError> {
        let lo = usize::try_from(*range.start()).unwrap_or(0);
        let hi = usize::try_from(*range.end()).unwrap_or(0);
        // What reached `deliver` (a retry after a software reopen must not send a picture twice) and the first download error.
        let delivered: Arc<Mutex<std::collections::HashSet<i64>>> = Arc::default();
        let failure: Arc<Mutex<Option<MediaError>>> = Arc::default();
        let send = {
            let (decoder, deliver, delivered, failure, label) = (
                Arc::clone(&self.decoder),
                Arc::clone(&deliver),
                Arc::clone(&delivered),
                Arc::clone(&failure),
                self.label.clone(),
            );
            move |demuxer: &dyn Demuxing, f: DecodedFrame, stats: &PlayStats| {
                match convert_picture(demuxer, f, divisor, threaded, stats) {
                    Ok(Some((i, p))) => {
                        decoder.report_download(true);
                        if delivered.lock().unwrap_or_else(PoisonError::into_inner).insert(i) {
                            deliver(i, p);
                        }
                    }
                    Ok(None) => {}
                    Err(e) => {
                        // A dropped picture is an error of its frame, never a silent hole (the cursor already moved past it).
                        sq_core_time::milestones::note(&format!(
                            "download failed: {label} hardware {} divisor {divisor} threaded {threaded}: {e}",
                            decoder.is_hardware()
                        ));
                        decoder.report_download(false);
                        failure.lock().unwrap_or_else(PoisonError::into_inner).get_or_insert(e);
                    }
                }
            }
        };
        let lap = Arc::new(Mutex::new(Instant::now()));
        let take_lap = {
            let lap = Arc::clone(&lap);
            move || {
                let mut t = lap.lock().unwrap_or_else(PoisonError::into_inner);
                let ms = t.elapsed().as_secs_f64() * 1e3;
                *t = Instant::now();
                ms
            }
        };
        // Two attempts: a hardware decoder whose downloads keep failing reopens in software at the start of the second.
        for attempt in 0..2 {
            // Software decoding of a paused read (an export, a paused fill): the conversion of picture n runs on a thread of its
            // own while the decoder works on n+1 (decode and download took turns on one thread: 10 + 7 ms per 4K picture). The
            // same conversion in the same order, so the pictures are identical; playback (`threaded`) and hardware surfaces
            // (a small pool that must go back to the decoder) keep the inline path.
            // Only a real FFmpeg software decoder (its label names it), never a test double.
            let overlap = !threaded
                && hi > lo
                && self.label.contains("(software)")
                && !self.decoder.is_hardware()
                && std::env::var_os("SQ_NO_CONVERT_OVERLAP").is_none();
            let (queue, converter) = if overlap {
                let (tx, rx) = std::sync::mpsc::sync_channel::<DecodedFrame>(CONVERT_AHEAD);
                let (demuxer, stats, send, stop) =
                    (Arc::clone(&self.demuxer), Arc::clone(stats), send.clone(), Arc::clone(&stop));
                let t = std::thread::Builder::new().name("sq-convert".into()).spawn(move || {
                    for f in rx {
                        if !stop() {
                            send(demuxer.as_ref(), f, &stats);
                        }
                    }
                });
                match t {
                    Ok(t) => (Some(Arc::new(Mutex::new(Some(tx)))), Some(t)),
                    Err(_) => (None, None),
                }
            } else {
                (None, None)
            };
            let hand = {
                let (demuxer, stats, send, label) =
                    (Arc::clone(&self.demuxer), Arc::clone(stats), send.clone(), self.label.clone());
                let take_lap = take_lap.clone();
                let stop = Arc::clone(&stop);
                let queue = queue.clone();
                move |f: DecodedFrame| {
                    if stop() {
                        return; // nobody wants it: no conversion
                    }
                    let ms = take_lap();
                    stats.add(Stage::Decode, ms, 1);
                    stats.decoded(&label, ms);
                    let tx = queue.as_ref().and_then(|q| q.lock().unwrap_or_else(PoisonError::into_inner).clone());
                    match tx {
                        Some(tx) => {
                            let _ = tx.send(f);
                        }
                        None => send(demuxer.as_ref(), f, &stats),
                    }
                    let _ = take_lap();
                }
            };
            // Frames the decoder carried from an earlier call come back in the result, not through `hand`.
            let decoded = block_on(self.decoder.decode_until(lo..=hi, None, Box::new(hand), Arc::clone(&stop)));
            // Every queued picture is converted and delivered before this call returns (the job's Finished message follows it).
            if let Some(q) = &queue {
                q.lock().unwrap_or_else(PoisonError::into_inner).take();
            }
            if let Some(t) = converter {
                let _ = t.join();
            }
            let rest = decoded?;
            for f in rest {
                if stop() {
                    break;
                }
                send(self.demuxer.as_ref(), f, stats);
            }
            let missing = failure.lock().unwrap_or_else(PoisonError::into_inner).take();
            match missing {
                None => return Ok(()),
                Some(_) if attempt == 0 && !stop() => {} // seek again; software when the downloads kept failing
                Some(e) => return Err(e),
            }
        }
        Ok(())
    }
}

/// Pictures a paused software read may hold between the decoder and its conversion thread (4K NV12: about 12 MB each).
const CONVERT_AHEAD: usize = 2;

/// The frame's index and picture; `None` when the frame has no index in the table (nothing to show).
fn convert_picture(
    demuxer: &dyn Demuxing,
    f: DecodedFrame,
    divisor: u32,
    threaded: bool,
    stats: &PlayStats,
) -> Result<Option<(i64, Picture)>, MediaError> {
    let Some(i) = demuxer.index().frame_at(f.pts()) else { return Ok(None) };
    picture_of(f, divisor, threaded, stats).map(|p| Some((i as i64, p)))
}

/// One decoded frame as a picture: FFmpeg frames downloaded into CPU planes (NV12 / P010 layout, RGBA with alpha),
/// box-reduced by `divisor` where the shim can; any other storage (a GPU frame) is kept as it is.
pub fn picture_of(f: DecodedFrame, divisor: u32, threaded: bool, stats: &PlayStats) -> Result<Picture, MediaError> {
    let cost = f.byte_cost();
    let frame = f.frame;
    let Some(ff) = frame.storage_as::<FFmpegFrame>() else { return Ok(Picture { frame, bytes: cost }) };
    let fail = |e: sq_media_ffmpeg::shim::ShimError| media_error(&e, "");
    let make = |w: usize, h: usize, format: SQFramePixelFormat, bytes: PooledBytes| {
        let n = bytes.len();
        Picture {
            frame: SQFrame::new(
                w,
                h,
                format,
                frame.color_space,
                frame.presentation_time,
                Arc::new(CpuPlanes { bytes }),
            ),
            bytes: n,
        }
    };
    if ff.has_alpha() {
        // Footage with an alpha channel keeps its transparency: full-size straight RGBA (the NV12 download drops alpha).
        let bytes = stats.time(Stage::Download, || ff.download_rgba_pooled()).map_err(fail)?;
        return Ok(make(frame.width, frame.height, SQFramePixelFormat::Rgba8, bytes));
    }
    if divisor > 1 || threaded {
        let reduced = stats.time(Stage::Download, || ff.download_reduced(divisor.max(1) as i32, 4)).map_err(fail)?;
        if let Some(r) = reduced {
            let format = match (r.chroma_422, frame.pixel_format) {
                (true, SQFramePixelFormat::P010) => SQFramePixelFormat::P210,
                (true, SQFramePixelFormat::P010FullRange) => SQFramePixelFormat::P210FullRange,
                (_, f) => f,
            };
            return Ok(make(r.width as usize, r.height as usize, format, r.bytes));
        }
    }
    let bytes = stats.time(Stage::Download, || ff.download_pooled()).map_err(fail)?;
    Ok(make(frame.width, frame.height, frame.pixel_format, bytes))
}

/// The platform opener: VideoToolbox first on the Mac (when a `Gpu` is given), then FFmpeg (D3D11VA on Windows, software).
pub struct DefaultOpener {
    gpu: Option<Arc<Gpu>>,
    fields: Option<DeinterlaceOf>,
    software_ffmpeg: bool,
}

/// The field order a media item's decoder deinterlaces with (`VideoTrackInfo::deinterlace_field_order` of the project's info).
pub type DeinterlaceOf = Arc<dyn Fn(Id) -> Option<FieldOrder> + Send + Sync>;

impl DefaultOpener {
    pub fn new(gpu: Option<Arc<Gpu>>) -> DefaultOpener {
        DefaultOpener { gpu, fields: None, software_ffmpeg: false }
    }

    /// Opens FFmpeg decoders in software even where the GPU could decode (the export on a machine with cores to spare: the VA-API
    /// copy to memory is slower than software decoding). Only decoders of this opener; the default keeps the GPU decoder.
    pub fn with_software_ffmpeg(mut self, on: bool) -> DefaultOpener {
        self.software_ffmpeg = on;
        self
    }

    /// Takes the field order from the project (the item's Deinterlace switch) instead of the stream's own flag.
    pub fn with_deinterlace(mut self, fields: DeinterlaceOf) -> DefaultOpener {
        self.fields = Some(fields);
        self
    }
}

impl MediaOpener for DefaultOpener {
    fn open(&self, path: &Path, media: Id) -> Result<OpenedMedia, MediaError> {
        self.open_as(path, media, None)
    }

    fn open_proxy(&self, file: &Path, media: Id, original: &OpenedMedia) -> Result<OpenedMedia, MediaError> {
        self.open_as(file, media, Some(original.full_range))
    }
}

/// How a file's pictures are read: `flagged_full` picks what VideoToolbox is asked for (the file's own flag), `read_full`
/// how the pictures are interpreted. A proxy keeps the original's codes, so it reads them as the original does while it asks
/// for its own layout: asking VideoToolbox for the full-range twin of a video-range file would rescale the codes.
pub fn stream_range(own: StreamRange, original_read_full: Option<bool>) -> StreamRange {
    StreamRange { flagged_full: own.flagged_full, read_full: original_read_full.unwrap_or(own.read_full) }
}

impl DefaultOpener {
    /// `open`; `original_read_full` is how the original is read when `path` is its proxy.
    fn open_as(&self, path: &Path, media: Id, original_read_full: Option<bool>) -> Result<OpenedMedia, MediaError> {
        let tag = path.file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned());
        let demuxer = FFmpegDemuxer::open_shared(path)?;
        sq_core_time::milestones::mark(&format!("open {tag}: demuxer + stream info"));
        let info = demuxer.track_info();
        let size = format!("{}x{}", info.width, info.height);
        let range = stream_range(
            StreamRange { flagged_full: flagged_full_range(demuxer.raw()), read_full: frame_color(demuxer.raw()).1 },
            original_read_full,
        );
        // SQ_FORCE_SW_DECODE=1 skips VideoToolbox as it skips D3D11VA (software reference for benchmarks and oracle tests).
        let forced_software = std::env::var("SQ_FORCE_SW_DECODE").is_ok_and(|v| v == "1");
        // Interlaced media is deinterlaced right after decode (Swift `makeVideoDecoder(deinterlace:)`). The CPU pass lives
        // in the FFmpeg decoder; VideoToolbox frames stay on the GPU and take the GPU pass (`GpuDeinterlacer`, Swift's
        // `MetalDeinterlacer`); a device that cannot run it falls back to the FFmpeg path.
        let fields = match &self.fields {
            Some(f) => f(media),
            None => info.field_order,
        };
        if let Some(gpu) = self.gpu.as_ref().filter(|_| !forced_software) {
            match VtVideoDecoder::new(
                Arc::clone(&demuxer) as Arc<dyn Demuxing>,
                info.clone(),
                media,
                Arc::clone(gpu),
                range,
            )
            .and_then(|vt| match fields {
                Some(order) => vt.with_deinterlace(order),
                None => Ok(vt),
            }) {
                Ok(vt) => {
                    sq_core_time::milestones::mark(&format!("open {tag}: VideoToolbox session"));
                    let label = format!("{size} {} (videotoolbox)", demuxer.format_description().codec);
                    return Ok(OpenedMedia {
                        demuxer,
                        decoder: Arc::new(vt),
                        info,
                        label,
                        set_preview: None,
                        full_range: range.read_full,
                    });
                }
                // Only the Mac has VideoToolbox: on Windows and Linux the stub always refuses, which is no news worth a line.
                Err(e) if cfg!(target_os = "macos") => eprintln!(
                    "videotoolbox: {} {} {}-bit not decoded in hardware ({e}); using software",
                    demuxer.format_description().codec,
                    info.chroma,
                    info.bit_depth
                ),
                Err(_) => {}
            }
        }
        let decoder = Arc::new(
            FFmpegVideoDecoder::new(Arc::clone(&demuxer), media, !self.software_ffmpeg, DEFAULT_EXTRA_HW_FRAMES)?
                .with_deinterlace(fields)
                .with_full_range(range.read_full),
        );
        let label = format!("{size} {}", decoder.decoder_name());
        let preview = Arc::clone(&decoder);
        Ok(OpenedMedia {
            demuxer,
            decoder,
            info,
            label,
            set_preview: Some(Arc::new(move |on| preview.set_preview(on))),
            full_range: range.read_full,
        })
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn software_decoding_is_an_option_of_one_opener_not_a_global() {
        let export = DefaultOpener::new(None).with_software_ffmpeg(true);
        let monitor = DefaultOpener::new(None);
        assert!(export.software_ffmpeg);
        assert!(!monitor.software_ffmpeg, "an opener made while an export's exists keeps the GPU decoder");
    }

    use super::*;

    /// A proxy asks VideoToolbox for its own layout (a full-range request on video-range codes would rescale them) and reads
    /// the codes the way the original does.
    #[test]
    fn a_proxy_keeps_its_own_layout_request_and_reads_like_the_original() {
        let proxy_file = StreamRange { flagged_full: false, read_full: false };
        let proxy = stream_range(proxy_file, Some(true));
        assert_eq!(proxy, StreamRange { flagged_full: false, read_full: true });
        let original = StreamRange { flagged_full: true, read_full: true };
        assert_eq!(stream_range(original, None), original, "an original is read as its own flags say");
        assert_eq!(stream_range(proxy_file, Some(false)), proxy_file);
    }
}
