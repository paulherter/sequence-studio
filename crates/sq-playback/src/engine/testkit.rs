// SPDX-License-Identifier: GPL-3.0-or-later
//! Test support of the engine: an in-memory opener (synthetic frame table, NV12 pictures that record their index in the
//! first byte), timelines of clips, and polling helpers. Headless: no GPU, no FFmpeg.

use super::core::ProgramEngine;
use super::handle::{EngineDeps, ProgramHandle};
use super::types::MediaRef;
use sq_audio_out::clock::HostClock;
use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind, VideoTrackInfo};
use sq_core_time::{Id, Time, TimeRange};
use sq_frame::sqframe::{SQFrame, SQFrameColorSpace, SQFramePixelFormat};
use sq_media::demuxing::{BoxFuture, DemuxedFormat, DemuxedSample, Demuxing};
use sq_media::media_error::MediaError;
use sq_media::media_opener::{MediaOpener, OpenedMedia};
use sq_media::sample_index::{Entry, SampleIndex};
use sq_media::video_decoding::{DecodedFrame, VideoDecoding};
use sq_render::program::CpuPlanes;
use std::collections::HashMap;
use std::ops::RangeInclusive;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

pub const FPS: i64 = 25;
pub const PIXELS: usize = 16;
/// Bytes of one fake NV12 picture.
pub const PICTURE_BYTES: usize = PIXELS * PIXELS * 3 / 2;

pub fn id(n: u128) -> Id {
    Id::from_u128(n)
}

struct FakeDemuxer {
    index: SampleIndex,
    format: DemuxedFormat,
}

impl Demuxing for FakeDemuxer {
    fn index(&self) -> &SampleIndex {
        &self.index
    }
    fn format_description(&self) -> &DemuxedFormat {
        &self.format
    }
    fn samples_for(&self, _: RangeInclusive<usize>) -> BoxFuture<'_, Result<Vec<DemuxedSample>, MediaError>> {
        Box::pin(async { Ok(Vec::new()) })
    }
}

/// What a fake file did: every decode range asked of it, and how many decoders were opened.
#[derive(Default)]
pub struct FileLog {
    pub ranges: Mutex<Vec<(usize, usize)>>,
    pub opens: AtomicUsize,
    /// The decoder answers every request with no picture at all (a decoder that is stuck or has nothing new to give).
    pub silent: AtomicBool,
}

impl FileLog {
    pub fn ranges(&self) -> Vec<(usize, usize)> {
        self.ranges.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }
}

struct FakeDecoder {
    info: VideoTrackInfo,
    media: Id,
    delay: Duration,
    log: Arc<FileLog>,
}

impl VideoDecoding for FakeDecoder {
    fn info(&self) -> &VideoTrackInfo {
        &self.info
    }
    fn is_hardware(&self) -> bool {
        false
    }
    fn decode(&self, range: RangeInclusive<usize>) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        Box::pin(async move {
            self.log.ranges.lock().unwrap_or_else(PoisonError::into_inner).push((*range.start(), *range.end()));
            std::thread::sleep(self.delay);
            if self.log.silent.load(Ordering::SeqCst) {
                return Ok(Vec::new());
            }
            Ok(range
                .map(|i| {
                    // The whole luma plane holds the index (a composite of two frames differs).
                    let mut bytes = vec![128u8; PICTURE_BYTES];
                    bytes[..PIXELS * PIXELS].fill(u8::try_from(i % 256).unwrap_or(0));
                    let pts = Time::new(i as i64, FPS);
                    let frame = SQFrame::new(
                        PIXELS,
                        PIXELS,
                        SQFramePixelFormat::Nv12,
                        SQFrameColorSpace::Rec709,
                        pts,
                        Arc::new(CpuPlanes { bytes: bytes.into() }),
                    );
                    DecodedFrame::new(self.media, Time::new(1, FPS), frame)
                })
                .collect())
        })
    }
    fn invalidate(&self) {}
}

pub fn track_info() -> VideoTrackInfo {
    VideoTrackInfo {
        width: PIXELS as i64,
        height: PIXELS as i64,
        codec: "fake".into(),
        bit_depth: 8,
        chroma: "4:2:0".into(),
        nominal_frame_duration: Time::new(1, FPS),
        is_variable_frame_rate: false,
        color_primaries: None,
        transfer: None,
        matrix: None,
        rotation: 0,
        pixel_aspect: sq_core_model::PixelAspect::square(),
        pixel_aspect_override: None,
        field_order: None,
        deinterlace_off: false,
    }
}

type FileSpec = (i64, Duration, Arc<FileLog>);

/// Files by path: frame count (25 fps, every 10th frame a sync sample), decode delay, log.
#[derive(Default)]
pub struct FakeOpener {
    files: Mutex<HashMap<String, FileSpec>>,
    /// Proxies by the original's path; `open_for` gives them to every state but paused.
    proxies: Mutex<HashMap<String, FileSpec>>,
}

impl FakeOpener {
    pub fn add(&self, path: &str, frames: i64, delay: Duration) -> Arc<FileLog> {
        let log = Arc::new(FileLog::default());
        self.files
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(path.into(), (frames, delay, Arc::clone(&log)));
        log
    }
}

impl FakeOpener {
    /// A file whose decoder never delivers a picture (every decode answers with none, and no error).
    pub fn add_silent(&self, path: &str, frames: i64) -> Arc<FileLog> {
        let log = self.add(path, frames, Duration::ZERO);
        log.silent.store(true, Ordering::SeqCst);
        log
    }

    /// A proxy of the file at `path` (same frame times) with its own log.
    pub fn add_proxy(&self, path: &str, frames: i64) -> Arc<FileLog> {
        let log = Arc::new(FileLog::default());
        self.proxies
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(path.into(), (frames, Duration::ZERO, Arc::clone(&log)));
        log
    }

    fn open_in(
        &self,
        files: &Mutex<HashMap<String, FileSpec>>,
        path: &Path,
        media: Id,
    ) -> Result<OpenedMedia, MediaError> {
        let key = path.to_string_lossy().into_owned();
        let (frames, delay, log) =
            files.lock().unwrap_or_else(PoisonError::into_inner).get(&key).cloned().ok_or(MediaError::Unreadable)?;
        log.opens.fetch_add(1, Ordering::SeqCst);
        let entries = (0..frames)
            .map(|i| Entry {
                pts: Time::new(i, FPS),
                dts: Time::new(i, FPS),
                duration: Time::new(1, FPS),
                is_sync: i % 10 == 0,
                decode_ordinal: i,
            })
            .collect();
        let info = track_info();
        Ok(OpenedMedia {
            demuxer: Arc::new(FakeDemuxer {
                index: SampleIndex::new(entries),
                format: DemuxedFormat::new("fake", PIXELS as i64, PIXELS as i64, Vec::new()),
            }),
            decoder: Arc::new(FakeDecoder { info: info.clone(), media, delay, log }),
            info,
            label: "16x16 fake".into(),
            set_preview: None,
            full_range: false,
        })
    }
}

impl MediaOpener for FakeOpener {
    fn open(&self, path: &Path, media: Id) -> Result<OpenedMedia, MediaError> {
        self.open_in(&self.files, path, media)
    }

    fn open_for(
        &self,
        path: &Path,
        media: Id,
        monitor: sq_media::media_opener::MonitorUse,
    ) -> Option<Result<OpenedMedia, MediaError>> {
        let has = self
            .proxies
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains_key(&path.to_string_lossy().into_owned());
        (has && monitor != sq_media::media_opener::MonitorUse::Paused).then(|| self.open_in(&self.proxies, path, media))
    }
}

pub fn format() -> SequenceFormat {
    let mut f = SequenceFormat::new(Time::new(1, FPS));
    f.width = 64;
    f.height = 36;
    f
}

/// A video clip of `media`: `src` seconds into the file, `at` seconds on the timeline, `dur` seconds long.
pub fn clip(n: u128, media: Id, src: i64, at: i64, dur: i64) -> Clip {
    Clip::new(
        id(n),
        "c",
        media,
        TrackKind::Video,
        TimeRange::new(Time::seconds(src), Time::seconds(dur)),
        Time::seconds(at),
    )
}

/// One video track per entry of `tracks` (bottom first).
pub fn timeline(tracks: Vec<Vec<Clip>>) -> Timeline {
    let tracks = tracks
        .into_iter()
        .enumerate()
        .map(|(n, clips)| {
            let mut t = Track::new(id(900 + n as u128), TrackKind::Video);
            t.set_clips(clips);
            t
        })
        .collect();
    Timeline::new(id(1), "t", format(), tracks)
}

pub struct Rig {
    pub handle: ProgramHandle,
    pub opener: Arc<FakeOpener>,
}

impl Rig {
    pub fn new(tune: impl FnOnce(&mut EngineDeps)) -> Rig {
        let opener = Arc::new(FakeOpener::default());
        let clock = Arc::new(HostClock::new());
        let mut deps = EngineDeps::new(Arc::clone(&opener) as Arc<dyn MediaOpener>, Arc::clone(&clock) as _);
        tune(&mut deps);
        Rig { handle: ProgramEngine::spawn(deps), opener }
    }

    pub fn media(&self, refs: &[(Id, &str)]) {
        self.handle.set_media(refs.iter().map(|(i, p)| MediaRef { id: *i, path: (*p).to_string() }).collect());
    }

    /// Polls the render thread until `cond` holds (5 s limit).
    pub fn wait(&self, what: &str, cond: impl Fn(&mut ProgramEngine) -> bool + Send + Sync + Clone + 'static) {
        let end = Instant::now() + Duration::from_secs(5);
        while Instant::now() < end {
            if self.handle.query(cond.clone()) == Some(true) {
                return;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        let state = self.handle.query(|e| {
            format!(
                "position {:?} wanted {:?} cache {} err {:?}",
                e.position(),
                e.wanted_keys(),
                e.cache_len(),
                e.last_error()
            )
        });
        panic!("timed out waiting for {what}: {state:?}");
    }
}
