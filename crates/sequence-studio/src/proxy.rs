//! The app's proxy path (Swift: AutoProxy.swift, ProxyTranscoder.swift, ProjectMediaResolver proxy lookup): the FFmpeg
//! transcoder that writes proxies, and the proxy-aware media opener playback and export open files through.

use sq_core_time::{Id, Timestamp};
use sq_media::demuxing::Demuxing;
use sq_media::media_error::MediaError;
use sq_media::media_opener::{MediaOpener, MonitorUse, OpenedMedia};
use sq_media_ffmpeg::decode::{FFmpegDemuxer, FFmpegFrame, FFmpegVideoDecoder};
use sq_media_ffmpeg::encode::{EncodeConfig, Encoder, PixelLayout};
use sq_playback::engine::activity::PlayActivity;
use sq_playback::engine::proxy_picture::has_original_frame_times;
use sq_proxy::model::{ProxyDimensions, ProxyKind};
use sq_proxy::proxy_cache::ProxyCache;
use sq_proxy::proxy_provider::ProxyProvider;
use sq_proxy::proxy_transcoding::{CancelToken, ProxyTranscodeError, ProxyTranscoding, TranscodeOutput};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

/// Frames decoded per call (the decoder keeps its own GOP state between calls).
const CHUNK: usize = 8;

/// Writes proxies with FFmpeg: ProRes 422 Proxy at 1/2 or 1/4 size, ProRes 422 at source size ("Optimized").
// shortcut: video only (playback and export take sound from the original), even sizes only. Frame times are the
// source's own (see `proxy_stamp`).
pub struct FfmpegProxyTranscoder;

impl ProxyTranscoding for FfmpegProxyTranscoder {
    fn transcode(
        &self,
        source: &Path,
        kind: ProxyKind,
        destination: &Path,
        _time_range: Option<sq_core_time::TimeRange>,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
    ) -> Result<TranscodeOutput, ProxyTranscodeError> {
        let read = |e: &dyn std::fmt::Display| ProxyTranscodeError::ReaderFailed(e.to_string());
        let write = |e: &dyn std::fmt::Display| ProxyTranscodeError::WriterFailed(e.to_string());
        // The one open of the file the engine, the info probe and the posters share: a second index pass over a multi-GB file is what
        // slowed the project open.
        let demuxer = FFmpegDemuxer::open_shared(source).map_err(|e| read(&e))?;
        let info = demuxer.track_info();
        let entries = demuxer.index().entries().to_vec();
        let (Some(first), Some(last)) = (entries.first(), entries.last()) else {
            return Err(ProxyTranscodeError::NoVideoTrack);
        };
        let d = kind.scale_divisor();
        let (w, h) = (info.width, info.height);
        let (ow, oh) = (((w / d) & !1).max(2), ((h / d) & !1).max(2));
        // The proxy keeps the source's own frame times: its time base is the source's timescale and every frame is
        // written at the source's presentation time, so a source with a 1/600 clock and 59.94 fps (or a variable rate)
        // gets the same frame times and the proxy passes `has_original_frame_times`.
        let scale = proxy_clock(&entries);
        let stamps: Vec<i64> = entries.iter().map(|e| proxy_stamp(e.pts, scale)).collect();
        // The encoder picks the container by extension, the cache's partial file has none it knows.
        let mut movie = destination.as_os_str().to_owned();
        movie.push(".mov");
        let movie = std::path::PathBuf::from(movie);
        let cfg = EncodeConfig {
            path: movie.clone(),
            width: i32::try_from(ow).map_err(|e| write(&e))?,
            height: i32::try_from(oh).map_err(|e| write(&e))?,
            fps_num: i32::try_from(scale).map_err(|e| write(&e))?,
            fps_den: 1,
            prores: if kind == ProxyKind::Optimized { 3 } else { 1 },
            color_tags: (demuxer.raw().color_primaries, demuxer.raw().color_transfer, demuxer.raw().color_matrix),
            rotation: info.rotation as i32,
            ..EncodeConfig::default()
        };
        let _ = std::fs::remove_file(&movie);
        let mut enc = Encoder::open(&cfg).map_err(|e| write(&e))?;
        let decoder =
            FFmpegVideoDecoder::new(Arc::clone(&demuxer), Id::from_u128(0), false, 0).map_err(|e| read(&e))?;
        let (layout, bytes) =
            if info.bit_depth > 8 { (PixelLayout::P010le, 2usize) } else { (PixelLayout::Nv12, 1usize) };
        let (w, h, ow, oh, d) = (w as usize, h as usize, ow as usize, oh as usize, d as usize);
        let total = entries.len();
        let made = (|| {
            // The frames on the monitor come first: while an engine plays or scrubs, the transcode stands still between
            // frames (a cancel still ends it at once) and goes on when the picture rests.
            let playback = PlayActivity::shared();
            let hold = || playback.wait_while_busy(|| cancel.is_cancelled(), Duration::from_millis(50));
            for from in (0..total).step_by(CHUNK) {
                hold();
                let to = (from + CHUNK - 1).min(total - 1);
                let frames = decoder.decode_blocking(from..=to, None, None).map_err(|e| read(&e))?;
                for (offset, f) in frames.iter().enumerate() {
                    hold();
                    if cancel.is_cancelled() {
                        return Err(ProxyTranscodeError::Cancelled);
                    }
                    let storage =
                        f.frame.storage_as::<FFmpegFrame>().ok_or_else(|| read(&"the decoder gave no picture"))?;
                    let picture = storage.download().map_err(|e| read(&e))?;
                    let small = if d == 1 { picture } else { shrink(&picture, (w, h), (ow, oh), d, bytes) };
                    enc.video(&small, layout, (ow * bytes) as i32, stamps[from + offset]).map_err(|e| write(&e))?;
                }
                progress((to + 1) as f64 / total as f64);
            }
            enc.finish().map_err(|e| write(&e))
        })();
        if let Err(e) = made.and_then(|()| std::fs::rename(&movie, destination).map_err(|e| write(&e))) {
            let _ = std::fs::remove_file(&movie);
            return Err(e);
        }
        progress(1.0);
        Ok(TranscodeOutput {
            dimensions: ProxyDimensions { width: ow as i64, height: oh as i64 },
            source_duration: last.pts + last.duration - first.pts,
        })
    }
}

/// The clock of the proxy's frames: the least common multiple of the (gcd-reduced) timescales of the source's frame
/// times and durations, so every stamp is exact. shortcut: past 1,000,000 ticks per second (a wild variable-rate
/// source) the clock is 90 kHz and stamps are rounded, which then fails the frame-times check and plays the original.
pub(crate) fn proxy_clock(entries: &[sq_media::sample_index::Entry]) -> i64 {
    fn gcd(a: i64, b: i64) -> i64 {
        if b == 0 { a } else { gcd(b, a % b) }
    }
    let mut clock = 1i64;
    for e in entries {
        for ts in [e.pts.timescale(), e.duration.timescale()] {
            let ts = ts.max(1);
            clock = clock / gcd(clock, ts) * ts;
            if clock > 1_000_000 {
                return 90_000;
            }
        }
    }
    clock
}

/// A source frame time in ticks of `1/scale` s (exact when the source already counts in `scale`).
pub(crate) fn proxy_stamp(pts: sq_core_time::Time, scale: i64) -> i64 {
    let (v, ts) = (i128::from(pts.value()), i128::from(pts.timescale().max(1)));
    let n = v * i128::from(scale);
    // Round to nearest, ties away from zero.
    ((n * 2 + n.signum() * ts) / (ts * 2)) as i64
}

/// Box-averages a semi-planar 4:2:0 picture (Y plane, then interleaved UV) by `d` into `out` size. Samples are `bytes`
/// wide (1 = NV12, 2 = P010 little endian), the stride is the plain width.
fn shrink(src: &[u8], (w, h): (usize, usize), (ow, oh): (usize, usize), d: usize, bytes: usize) -> Vec<u8> {
    let sample = |at: usize| -> u32 {
        if bytes == 1 { u32::from(src[at]) } else { u32::from(u16::from_le_bytes([src[at], src[at + 1]])) }
    };
    let mut out = Vec::with_capacity(ow * oh * 3 / 2 * bytes);
    let mut put = |v: u32| {
        if bytes == 1 {
            out.push(v as u8);
        } else {
            out.extend_from_slice(&(v as u16).to_le_bytes());
        }
    };
    // Source plane size, output plane size, samples per pixel (1 = Y, 2 = UV pairs), first byte of the plane.
    let planes = [(w, h, ow, oh, 1usize, 0usize), (w / 2, h / 2, ow / 2, oh / 2, 2, w * h * bytes)];
    for (pw, ph, qw, qh, comps, base) in planes {
        for y in 0..qh {
            for x in 0..qw {
                for c in 0..comps {
                    let (mut sum, mut n) = (0u32, 0u32);
                    for dy in 0..d.min(ph - y * d) {
                        for dx in 0..d.min(pw - x * d) {
                            sum += sample(base + (((y * d + dy) * pw + x * d + dx) * comps + c) * bytes);
                            n += 1;
                        }
                    }
                    put(sum / n.max(1));
                }
            }
        }
    }
    out
}

/// Opens a media's proxy instead of its original when one is ready and `wanted()` says so (Swift
/// `ProjectMediaResolver.proxy_demuxer` and `ProxySource`). The proxy stands in only with the original's frame times; the
/// picture info stays the original's, so layout and effects see the original's size. The provider already refuses
/// interlaced media.
pub struct ProxyAwareOpener {
    inner: Arc<dyn MediaOpener>,
    provider: Arc<ProxyProvider>,
    wanted: Arc<dyn Fn() -> bool + Send + Sync>,
}

impl ProxyAwareOpener {
    /// `inner` opens both the original and the proxy file.
    pub fn new(
        inner: Arc<dyn MediaOpener>,
        provider: Arc<ProxyProvider>,
        wanted: Arc<dyn Fn() -> bool + Send + Sync>,
    ) -> ProxyAwareOpener {
        ProxyAwareOpener { inner, provider, wanted }
    }
}

/// The proxy provider over the default proxy cache (Swift `ProxyProvider` of the app's `AutoProxyService`).
pub fn default_provider() -> Arc<ProxyProvider> {
    let dir = ProxyCache::default_directory(|k| std::env::var(k).ok());
    ProxyProvider::new(shared_cache(dir)).into()
}

/// The one `ProxyCache` of a folder in this process. A cache reads `index.json` once and rewrites it whole, so a second
/// cache over the same folder would not see the proxies the first one makes and would overwrite its index.
pub fn shared_cache(directory: std::path::PathBuf) -> Arc<ProxyCache> {
    static CACHES: std::sync::Mutex<Vec<(std::path::PathBuf, Arc<ProxyCache>)>> = std::sync::Mutex::new(Vec::new());
    let mut caches = CACHES.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some((_, c)) = caches.iter().find(|(d, _)| *d == directory) {
        return Arc::clone(c);
    }
    let cache = Arc::new(ProxyCache::new(directory.clone()));
    caches.push((directory, Arc::clone(&cache)));
    cache
}

/// The opener of the monitors: `open` is the original (a paused frame), `open_for` offers the ready proxy of a
/// scrubbing or playing monitor; the engine opens both and picks by its state.
pub fn monitor_opener(inner: Arc<dyn MediaOpener>) -> Arc<dyn MediaOpener> {
    monitor_opener_over(inner, default_provider())
}

/// [`monitor_opener`] over a provider of the caller's (the service's own, in tests).
pub fn monitor_opener_over(inner: Arc<dyn MediaOpener>, provider: Arc<ProxyProvider>) -> Arc<dyn MediaOpener> {
    Arc::new(ProxyAwareOpener::new(inner, provider, Arc::new(|| false)))
}

/// The opener of an export job: proxies only while "Use proxies when exporting" is on. The choice is read once when
/// the job is enqueued and carried in the job (`ExportSnapshot`), never read from disk on the export thread.
pub fn export_opener(inner: Arc<dyn MediaOpener>, use_proxies: bool) -> Arc<dyn MediaOpener> {
    if !use_proxies {
        return inner;
    }
    Arc::new(ProxyAwareOpener::new(inner, default_provider(), Arc::new(|| true)))
}

pub(crate) fn wall_clock() -> Timestamp {
    Timestamp::from_unix_seconds(
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64()),
    )
}

impl ProxyAwareOpener {
    /// The ready proxy standing in for `original` (same frame times, the original's picture info), if there is one.
    fn proxy_for(&self, path: &Path, media: Id, original: &OpenedMedia) -> Option<OpenedMedia> {
        // Blocking lookup (reads the fingerprint once, then memoized): openers run off the engine's threads.
        let hit = self.provider.optimized_file(path, &ProxyProvider::SCRUB_PREFERENCE, wall_clock())?;
        // The proxy holds the original's codes unscaled: its pictures are read the way the original's are.
        let proxy = self.inner.open_proxy(&hit.url, media, original).ok()?;
        if !has_original_frame_times(proxy.demuxer.index(), original.demuxer.index()) {
            drop(proxy); // its file is deleted below
            // A proxy made by an older encoder (constant rate) never matches: throw it away once so the Auto queue
            // makes a new one with the source's frame times. A second refusal keeps the file and stops there.
            let again = self.provider.retire_mismatched(path, &hit);
            sq_core_time::milestones::note(&format!(
                "proxy: ready proxy of {} not used, its frame times differ from the original ({})",
                path.display(),
                if again { "made again once" } else { "not made again" }
            ));
            return None;
        }
        Some(OpenedMedia { info: original.info.clone(), label: format!("{} proxy", proxy.label), ..proxy })
    }
}

impl MediaOpener for ProxyAwareOpener {
    fn open(&self, path: &Path, media: Id) -> Result<OpenedMedia, MediaError> {
        let original = self.inner.open(path, media)?;
        if !(self.wanted)() {
            return Ok(original);
        }
        Ok(self.proxy_for(path, media, &original).unwrap_or(original))
    }

    /// A monitor's proxy: scrubbing and playing only; a paused frame is the original's (Swift `ProxyUseContext`).
    fn open_for(&self, path: &Path, media: Id, monitor: MonitorUse) -> Option<Result<OpenedMedia, MediaError>> {
        if monitor == MonitorUse::Paused {
            return None;
        }
        let original = self.inner.open(path, media).ok()?;
        self.proxy_for(path, media, &original).map(Ok)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::tests::{ffmpeg_tool, make_clip};
    use sq_playback::engine::media_source::DefaultOpener;
    use sq_proxy::proxy_cache::ProxyCache;
    use sq_proxy::proxy_queue::{ProxyJobPriority, ProxyQueue};

    /// A real clip, a real proxy made by the transcoder through the queue, opened through the opener.
    fn proxied(kind: ProxyKind, wanted: bool) -> Option<(OpenedMedia, OpenedMedia, std::path::PathBuf)> {
        let tool = ffmpeg_tool()?;
        let dir = std::env::temp_dir().join(format!("sq-proxy-test-{}-{}", std::process::id(), kind.raw_value()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).ok()?;
        let clip = make_clip(&tool, &dir)?;
        let cache = Arc::new(ProxyCache::new(dir.join("cache")));
        let mut queue = ProxyQueue::new(Arc::clone(&cache), 1);
        let mut ids = sq_core_time::SequentialIds::default();
        let now = wall_clock();
        queue.enqueue(&clip, kind, ProxyJobPriority::Background, 0, &mut ids, now).ok()?;
        queue.run_until_idle(&FfmpegProxyTranscoder, now);
        let states: Vec<_> = queue.all_jobs().iter().map(|j| format!("{:?}", j.state)).collect();
        assert!(!cache.all_records().is_empty(), "no proxy was made: {states:?}");
        let provider = Arc::new(ProxyProvider::with_interlaced(cache, Box::new(|_| false)));
        let plain: Arc<dyn MediaOpener> = Arc::new(DefaultOpener::new(None));
        let opener = ProxyAwareOpener::new(Arc::clone(&plain), provider, Arc::new(move || wanted));
        let got = opener.open(&clip, Id::from_u128(1)).ok()?;
        let original = plain.open(&clip, Id::from_u128(1)).ok()?;
        Some((got, original, dir))
    }

    #[test]
    fn the_clock_is_exact_for_reduced_times() {
        use sq_core_time::Time;
        use sq_media::sample_index::Entry;
        let at = |v: i64| {
            let t = Time::new(v, 600);
            Entry { pts: t, dts: t, duration: Time::new(10, 600), is_sync: true, decode_ordinal: 0 }
        };
        let clock = proxy_clock(&[at(0), at(10), at(501), at(2862)]);
        assert_eq!(clock, 600);
        assert_eq!(proxy_stamp(Time::new(2862, 600), clock), 2862);
        assert_eq!(proxy_clock(&[at(0)]), 60, "a lone zero frame of a 1/60 s duration");
    }

    #[test]
    fn stamps_keep_the_source_clock() {
        use sq_core_time::Time;
        assert_eq!(proxy_stamp(Time::new(501, 600), 600), 501);
        assert_eq!(proxy_stamp(Time::new(1, 3), 600), 200);
        assert_eq!(proxy_stamp(Time::new(1001, 60000), 600), 10);
    }

    /// An iPhone-like source: 59.94 fps on a 1/600 clock, so frame times are not a multiple of one frame duration.
    #[test]
    fn a_proxy_of_a_59_94_fps_source_on_a_600_clock_keeps_its_frame_times() {
        let Some(tool) = ffmpeg_tool() else { return };
        let dir = std::env::temp_dir().join(format!("sq-proxy-ntsc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let clip = dir.join("ntsc.mov");
        let made = std::process::Command::new(&tool)
            .args(["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=60000/1001:duration=1.5"])
            .args(["-c:v", "mpeg4", "-pix_fmt", "yuv420p", "-video_track_timescale", "600"])
            .arg(&clip)
            .status();
        if !made.is_ok_and(|s| s.success()) {
            return;
        }
        let cache = Arc::new(ProxyCache::new(dir.join("cache")));
        let mut queue = ProxyQueue::new(Arc::clone(&cache), 1);
        let mut ids = sq_core_time::SequentialIds::default();
        let now = wall_clock();
        queue.enqueue(&clip, ProxyKind::ProxyHalf, ProxyJobPriority::Background, 0, &mut ids, now).unwrap();
        queue.run_until_idle(&FfmpegProxyTranscoder, now);
        assert!(!cache.all_records().is_empty(), "no proxy was made");
        let provider = Arc::new(ProxyProvider::with_interlaced(cache, Box::new(|_| false)));
        let plain: Arc<dyn MediaOpener> = Arc::new(DefaultOpener::new(None));
        let opener = ProxyAwareOpener::new(Arc::clone(&plain), provider, Arc::new(|| true));
        let got = opener.open(&clip, Id::from_u128(1)).unwrap();
        assert!(got.label.ends_with("proxy"), "the proxy was refused: {}", got.label);
        let original = plain.open(&clip, Id::from_u128(1)).unwrap();
        let times = |m: &OpenedMedia| m.demuxer.index().entries().iter().map(|e| e.pts).collect::<Vec<_>>();
        assert_eq!(times(&got), times(&original));
        let _ = std::fs::remove_dir_all(dir);
    }

    /// A source whose first frame is not at 0 (start offset): the index counts from its first frame, the proxy is
    /// stamped from the index, so both start at 0 and agree.
    #[test]
    fn a_proxy_of_a_source_with_a_start_offset_keeps_its_frame_times() {
        let Some(tool) = ffmpeg_tool() else { return };
        let dir = std::env::temp_dir().join(format!("sq-proxy-offset-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let clip = dir.join("offset.mov");
        let made = std::process::Command::new(&tool)
            .args(["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=1"])
            .args([
                "-c:v",
                "mpeg4",
                "-pix_fmt",
                "yuv420p",
                "-output_ts_offset",
                "3.5",
                "-avoid_negative_ts",
                "disabled",
            ])
            .arg(&clip)
            .status();
        if !made.is_ok_and(|s| s.success()) {
            return;
        }
        let plain: Arc<dyn MediaOpener> = Arc::new(DefaultOpener::new(None));
        let original = plain.open(&clip, Id::from_u128(1)).unwrap();
        assert_eq!(original.demuxer.index().entries()[0].pts, sq_core_time::Time::ZERO, "the index starts at 0");
        let cache = Arc::new(ProxyCache::new(dir.join("cache")));
        let mut queue = ProxyQueue::new(Arc::clone(&cache), 1);
        let mut ids = sq_core_time::SequentialIds::default();
        let now = wall_clock();
        queue.enqueue(&clip, ProxyKind::ProxyHalf, ProxyJobPriority::Background, 0, &mut ids, now).unwrap();
        queue.run_until_idle(&FfmpegProxyTranscoder, now);
        assert!(!cache.all_records().is_empty(), "no proxy was made");
        let provider = Arc::new(ProxyProvider::with_interlaced(cache, Box::new(|_| false)));
        let opener = ProxyAwareOpener::new(Arc::clone(&plain), provider, Arc::new(|| true));
        let got = opener.open(&clip, Id::from_u128(1)).unwrap();
        assert!(got.label.ends_with("proxy"), "the proxy was refused: {}", got.label);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn one_cache_per_folder_so_the_monitor_sees_proxies_the_service_makes() {
        let dir = std::env::temp_dir().join(format!("sq-shared-cache-{}", std::process::id()));
        let a = shared_cache(dir.join("c"));
        let b = shared_cache(dir.join("c"));
        assert!(Arc::ptr_eq(&a, &b), "a second cache over the same folder would be stale");
        assert!(!Arc::ptr_eq(&a, &shared_cache(dir.join("other"))));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_ready_proxy_is_opened_in_place_of_the_original() {
        let Some((got, original, dir)) = proxied(ProxyKind::ProxyHalf, true) else { return };
        assert!(got.label.ends_with("proxy"), "label {}", got.label);
        assert_eq!(got.demuxer.index().count(), original.demuxer.index().count());
        assert_eq!(got.demuxer.format_description().width, original.info.width / 2, "the proxy file is half size");
        assert_eq!(got.info.width, original.info.width, "the picture info stays the original's");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_original_is_opened_when_proxies_are_not_wanted() {
        let Some((got, original, dir)) = proxied(ProxyKind::ProxyQuarter, false) else { return };
        assert_eq!(got.label, original.label);
        assert_eq!(got.demuxer.format_description().width, original.info.width);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_export_opener_follows_the_stored_preference() {
        let inner: Arc<dyn MediaOpener> = Arc::new(DefaultOpener::new(None));
        assert!(Arc::ptr_eq(&export_opener(Arc::clone(&inner), false), &inner), "off: the plain opener");
        assert!(!Arc::ptr_eq(&export_opener(Arc::clone(&inner), true), &inner), "on: the proxy-aware opener");
    }
}
