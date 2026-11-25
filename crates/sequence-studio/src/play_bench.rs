//! `--engine-bench <out> <clip>`: plays one clip through the real Program engine (platform decoder, GPU compositor, host
//! clock) without a window and measures what the app's monitor does with each new composite: frames shown and dropped
//! at 1x, the cost of moving a composite into the monitor picture, the gaps between pictures, the process CPU time per
//! picture, and how long a scrub request takes to show its exact frame (forward and backward). Numbers: docs/rust/PERF-NOTES.md.

use crate::playback::MonitorUpload;
use sq_audio_out::clock::{HostClock, PlaybackClock};
use sq_core_edit::playback::PlaybackRate;
use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use sq_gpu::gpu::Gpu;
use sq_media::demuxing::BoxFuture;
use sq_media::media_error::MediaError;
use sq_media::media_opener::{MediaOpener, OpenedMedia};
use sq_media::video_decoding::{DecodedFrame, FrameSink, StopCheck, VideoDecoding};
use sq_playback::engine::core::ProgramEngine;
use sq_playback::engine::handle::{EngineDeps, ProgramHandle};
use sq_playback::engine::media_source::DefaultOpener;
use sq_playback::engine::types::MediaRef;
use std::ops::RangeInclusive;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Seconds of 1x playback measured.
const PLAY_SECONDS: u64 = 6;
/// The display the loop is paced by (60 Hz, the common case; ProMotion paces faster).
const TICK: Duration = Duration::from_micros(16_667);

/// p50, p95 and max of `v` in milliseconds.
fn spread(v: &mut [f64]) -> String {
    if v.is_empty() {
        return "n/a".into();
    }
    v.sort_by(f64::total_cmp);
    let at = |q: f64| v[((v.len() - 1) as f64 * q).round() as usize];
    format!("p50 {:.2} ms, p95 {:.2} ms, max {:.2} ms", at(0.5), at(0.95), at(1.0))
}

/// Process CPU time (user + system) in seconds, from `ps`; `None` where `ps` is missing (Windows).
pub(crate) fn cpu_seconds() -> Option<f64> {
    let out = std::process::Command::new("ps").args(["-o", "time=", "-p", &std::process::id().to_string()]).output();
    let text = String::from_utf8(out.ok()?.stdout).ok()?;
    // "M:SS.cc" or "H:MM:SS"
    text.trim().split(':').try_fold(0.0, |acc, part| part.trim().parse::<f64>().ok().map(|p| acc * 60.0 + p))
}

/// Resident memory of this process in MB: the working set on Windows (no `ps` there: the numbers read 0), else `ps`.
#[cfg(windows)]
pub(crate) fn rss_mb() -> Option<f64> {
    let kb = u32::try_from(sq_platform_win::working_set_bytes()? >> 10).unwrap_or(u32::MAX);
    Some(f64::from(kb) / 1024.0)
}

/// Resident memory of this process in MB, from `ps`; `None` where `ps` is missing.
#[cfg(not(windows))]
pub(crate) fn rss_mb() -> Option<f64> {
    let out = std::process::Command::new("ps").args(["-o", "rss=", "-p", &std::process::id().to_string()]).output();
    let kb = String::from_utf8(out.ok()?.stdout).ok()?.trim().parse::<f64>().ok()?;
    Some(kb / 1024.0)
}

/// One line that splits the resident memory by owner (Linux; `None` elsewhere): frame cache bytes and free picture buffers
/// (counted by the engine), then the kernel's view from `/proc/self/smaps` summed by mapping kind, and the thread count.
/// Written once at Play + 2 s into the bench text as `MEM ...` so a peak can be assigned to an owner without a profiler.
pub(crate) fn memory_breakdown(cache_bytes: usize) -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        let smaps = std::fs::read_to_string("/proc/self/smaps").ok()?;
        let mut kinds: std::collections::BTreeMap<String, u64> = std::collections::BTreeMap::new();
        let mut current = String::new();
        let mut anon_total = 0u64;
        // Resident anonymous mappings of 4 MB and up, counted by size in MB: a picture buffer shows as many regions of one size.
        let mut big: std::collections::BTreeMap<u64, (u64, u64)> = std::collections::BTreeMap::new();
        for line in smaps.lines() {
            let mut parts = line.split_whitespace();
            let first = parts.next().unwrap_or("");
            if first.contains('-') && !first.ends_with(':') {
                // "start-end perms offset dev inode [path]"
                let path = parts.nth(4).unwrap_or("");
                current = if path.is_empty() {
                    "anon".into()
                } else if path.starts_with("/dev/dri") || path.starts_with("/dev/nvidia") || path.contains("/dev/kfd") {
                    "gpu-device".into()
                } else if path.starts_with("/memfd") || path.starts_with("/dev/shm") {
                    "shm".into()
                } else if path.starts_with('[') {
                    path.into()
                } else if path.ends_with(".so") || path.contains(".so.") {
                    "libs".into()
                } else {
                    "file".into()
                };
            } else if first == "Rss:" {
                let kb: u64 = parts.next().and_then(|v| v.parse().ok()).unwrap_or(0);
                *kinds.entry(current.clone()).or_default() += kb;
                if current == "anon" && kb >= 4096 {
                    let e = big.entry(kb >> 10).or_default();
                    e.0 += 1;
                    e.1 += kb >> 10;
                }
            } else if first == "Anonymous:" {
                anon_total += parts.next().and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
            }
        }
        let threads = std::fs::read_to_string("/proc/self/status")
            .ok()
            .and_then(|t| t.lines().find_map(|l| l.strip_prefix("Threads:").map(|v| v.trim().to_string())))
            .unwrap_or_default();
        let (open_sw, big_threads) = sq_media_ffmpeg::shim::open_software_decoders();
        let census = sq_gpu::frames::census::report(10);
        let pool = sq_frame::buffer_pool::BufferPool::shared();
        let (reused, fresh) = pool.counts();
        let mut sizes: Vec<(u64, u64, u64)> = big.into_iter().map(|(mb, (n, total))| (total, mb, n)).collect();
        sizes.sort_unstable_by(|a, b| b.cmp(a));
        let sizes_text: Vec<String> =
            sizes.iter().take(8).map(|(total, mb, n)| format!("{n}x{mb} MB={total}")).collect();
        let kinds_text: Vec<String> = kinds.iter().map(|(k, kb)| format!("{k} {} MB", kb >> 10)).collect();
        Some(format!(
            "MEM frame_cache {} MB; free_picture_buffers {} MB (reused {reused}, fresh {fresh}); anonymous {} MB; by mapping: {}; big anonymous regions (resident, top 8): {}; threads {threads}; open software decoders {open_sw} (big frame threads {big_threads}); {census}\n",
            cache_bytes >> 20,
            pool.free_bytes() >> 20,
            anon_total >> 10,
            kinds_text.join(", "),
            sizes_text.join(", "),
        ))
    }
    #[cfg(not(target_os = "linux"))]
    {
        // Windows and the Mac have no smaps: the engine's own counters and the GPU allocator's totals (the iGPU's shared
        // memory is system RAM, so its allocations compete with the process for the same 8 GB).
        let pool = sq_frame::buffer_pool::BufferPool::shared();
        let (reused, fresh) = pool.counts();
        let gpu = crate::surface::shared_gpu()
            .and_then(|(_, g)| g.device().generate_allocator_report())
            .map(|r| {
                let mut by: std::collections::BTreeMap<String, (u64, u64)> = std::collections::BTreeMap::new();
                for a in &r.allocations {
                    let e = by.entry(a.name.clone()).or_default();
                    e.0 += 1;
                    e.1 += a.size;
                }
                let mut top: Vec<_> = by.into_iter().collect();
                top.sort_by(|a, b| b.1.1.cmp(&a.1.1));
                let top: Vec<String> = top.iter().take(8).map(|(n, (c, b))| format!("{n} {c}x={} MB", b >> 20)).collect();
                format!(
                    "gpu allocator allocated {} MB reserved {} MB in {} blocks, top: [{}]",
                    r.total_allocated_bytes >> 20,
                    r.total_reserved_bytes >> 20,
                    r.blocks.len(),
                    top.join("; ")
                )
            })
            .unwrap_or_else(|| "gpu allocator n/a".into());
        let (open_sw, big_threads) = sq_media_ffmpeg::shim::open_software_decoders();
        let census = sq_gpu::frames::census::report(10);
        Some(format!(
            "MEM frame_cache {} MB; free_picture_buffers {} MB (reused {reused}, fresh {fresh}); {gpu}; open software decoders {open_sw} (big frame threads {big_threads}); {census}\n",
            cache_bytes >> 20,
            pool.free_bytes() >> 20,
        ))
    }
}

pub(crate) fn wait(handle: &ProgramHandle, what: &str, cond: impl Fn(&ProgramHandle) -> bool) -> Result<(), String> {
    let end = Instant::now() + Duration::from_secs(30);
    while !cond(handle) {
        if Instant::now() > end {
            return Err(format!("timed out waiting for {what}: {:?}", handle.status()));
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    Ok(())
}

/// The platform opener; every decode call waits `delay` first (a small clip decoding as slowly as a 4K one).
struct SlowOpener {
    inner: DefaultOpener,
    delay: Duration,
}

struct SlowDecoder {
    inner: Arc<dyn VideoDecoding>,
    delay: Duration,
}

impl MediaOpener for SlowOpener {
    fn open(&self, path: &Path, media: Id) -> Result<OpenedMedia, MediaError> {
        let mut m = self.inner.open(path, media)?;
        if !self.delay.is_zero() {
            m.decoder = Arc::new(SlowDecoder { inner: m.decoder, delay: self.delay });
        }
        Ok(m)
    }
}

impl VideoDecoding for SlowDecoder {
    fn info(&self) -> &sq_core_model::VideoTrackInfo {
        self.inner.info()
    }
    fn is_hardware(&self) -> bool {
        self.inner.is_hardware()
    }
    fn decode(&self, range: RangeInclusive<usize>) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        std::thread::sleep(self.delay);
        self.inner.decode(range)
    }
    fn decode_needed_from(
        &self,
        range: RangeInclusive<usize>,
        needed_from: Option<usize>,
        deliver: FrameSink,
    ) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        std::thread::sleep(self.delay);
        self.inner.decode_needed_from(range, needed_from, deliver)
    }
    fn decode_until(
        &self,
        range: RangeInclusive<usize>,
        needed_from: Option<usize>,
        deliver: FrameSink,
        stop: StopCheck,
    ) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        std::thread::sleep(self.delay);
        self.inner.decode_until(range, needed_from, deliver, stop)
    }
    fn invalidate(&self) {
        self.inner.invalidate();
    }
}

/// The real Program engine over one clip on a bare timeline (no window): what the benchmark and the present check drive.
pub(crate) struct BenchEngine {
    pub handle: ProgramHandle,
    pub timing: Arc<sq_playback::engine::DisplayTiming>,
    pub frame: Time,
    pub track: sq_core_model::VideoTrackInfo,
    pub label: String,
}

impl BenchEngine {
    /// `seconds` of `clip` from its start. `hardware`: the platform opener (VideoToolbox on the Mac), else FFmpeg software.
    /// `pacing`: the engine reads the loop's display ticks from `timing`. `color`: the app's clip color resolver (the file's
    /// probed info and its embedded camera LUT), as the window's engine has it.
    pub fn open(
        gpu: &Arc<Gpu>,
        clip: &Path,
        seconds: i64,
        hardware: bool,
        pacing: bool,
        color: bool,
        decode_delay: Duration,
    ) -> Result<BenchEngine, String> {
        let opener: Arc<dyn MediaOpener> =
            Arc::new(SlowOpener { inner: DefaultOpener::new(hardware.then(|| Arc::clone(gpu))), delay: decode_delay });
        let media = Id::from_u128(100);
        let info = opener.open(clip, media).map_err(|e| format!("{}: {e:?}", clip.display()))?;
        let (label, track) = (info.label.clone(), info.info.clone());
        drop(info);
        let frame = track.nominal_frame_duration;
        let mut format = SequenceFormat::new(frame);
        (format.width, format.height) = (track.width, track.height);
        let length = Time::seconds(seconds);
        let c =
            Clip::new(Id::from_u128(10), "c", media, TrackKind::Video, TimeRange::new(Time::ZERO, length), Time::ZERO);
        let mut t = Track::new(Id::from_u128(900), TrackKind::Video);
        t.set_clips(vec![c]);
        let timeline = Timeline::new(Id::from_u128(1), "bench", format, vec![t]);

        let clock: Arc<dyn PlaybackClock> = Arc::new(HostClock::new());
        let mut deps = EngineDeps::new(Arc::clone(&opener), clock);
        deps.gpu = Some(Arc::clone(gpu));
        let timing = Arc::new(sq_playback::engine::DisplayTiming::default());
        if pacing {
            deps.display = Some(Arc::clone(&timing));
        }
        if color {
            let info = crate::probe::FfmpegProbe::media_info(clip).ok();
            let path = clip.to_path_buf();
            let embedded = Box::new(move |_| {
                sq_media::embedded_lut::EmbeddedMeta::lut_in_clip(&path).ok().flatten().map(|l| l.data)
            });
            let luts = sq_render::color::clip_pipeline::CachingLutProvider::new(None, embedded, None);
            deps.color = Some(Arc::new(sq_render::compositor::LayerColorResolver::new(
                Some(Arc::new(luts)),
                Arc::new(move |_| info.clone()),
            )));
        }
        let handle = ProgramEngine::spawn(deps);
        handle.set_media(vec![MediaRef { id: media, path: clip.to_string_lossy().into_owned() }]);
        handle.set_timeline(timeline, Default::default());
        wait(&handle, "the first picture", |h| h.query(|e| e.is_picture_settled()) == Some(true))?;
        Ok(BenchEngine { handle, timing, frame, track, label })
    }
}

/// Runs the benchmark on `clip` and returns the report.
pub fn run(clip: &Path) -> Result<String, String> {
    let gpu = Gpu::new().map_err(|e| format!("no GPU: {e}"))?;
    // The loop below stands in for the window: it reports its 60 Hz ticks (`SQ_BENCH_NO_PACING=1`: the clock alone, as before).
    let pacing = std::env::var_os("SQ_BENCH_NO_PACING").is_none();
    let BenchEngine { handle, timing, frame, track, label } =
        BenchEngine::open(&gpu, clip, PLAY_SECONDS as i64 + 2, true, pacing, false, Duration::ZERO)?;
    let mut upload = MonitorUpload::new(Arc::clone(&gpu))?;
    let mut generation = 0;

    // 1x playback, the loop paced by a 60 Hz display.
    let before = handle.status();
    let cpu0 = cpu_seconds();
    handle.play(PlaybackRate::FORWARD);
    let start = Instant::now();
    let (mut costs, mut gaps, mut last) = (Vec::new(), Vec::new(), None::<Instant>);
    let mut next = start;
    while start.elapsed() < Duration::from_secs(PLAY_SECONDS) {
        next += TICK;
        timing.tick(Instant::now(), TICK, Duration::from_micros(1_000));
        if let Some(shown) = handle.latest_shown()
            && shown.generation != generation
        {
            generation = shown.generation;
            let t = Instant::now();
            upload.take(&shown);
            costs.push(t.elapsed().as_secs_f64() * 1e3);
            if let Some(l) = last {
                gaps.push(l.elapsed().as_secs_f64() * 1e3);
            }
            last = Some(Instant::now());
        }
        std::thread::sleep(next.saturating_duration_since(Instant::now()));
    }
    let secs = start.elapsed().as_secs_f64();
    let cpu1 = cpu_seconds();
    handle.pause();
    handle.sync();
    let after = handle.status();
    let shown = after.shown_frames.saturating_sub(before.shown_frames);
    let dropped = after.skipped_frames.saturating_sub(before.skipped_frames);
    let cpu = cpu0.zip(cpu1).map_or("n/a".into(), |(a, b)| {
        format!(
            "{:.2} ms/picture ({:.0} % of one core)",
            (b - a) * 1e3 / costs.len().max(1) as f64,
            (b - a) / secs * 1e2
        )
    });

    // Scrub: one request per display tick, two frames apart, forward then back; latency until the exact frame shows.
    let mut scrub = Vec::new();
    let mut missed = 0;
    handle.begin_scrub();
    let steps: Vec<i64> = (0..60).map(|i| 30 + 2 * i).chain((0..60).map(|i| 150 - 2 * i)).collect();
    for f in steps {
        let at = frame * f;
        let t = Instant::now();
        handle.scrub(at);
        let end = t + Duration::from_millis(500);
        loop {
            if let Some(s) = handle.latest_shown()
                && s.position == at
                && s.exact
            {
                if s.generation != generation {
                    generation = s.generation;
                    upload.take(&s);
                }
                scrub.push(t.elapsed().as_secs_f64() * 1e3);
                break;
            }
            if Instant::now() > end {
                missed += 1;
                break;
            }
            std::thread::sleep(Duration::from_micros(500));
        }
        std::thread::sleep(TICK.saturating_sub(t.elapsed()));
    }
    handle.end_scrub();

    let mut back = scrub.split_off(scrub.len().min(60));
    let forward = spread(&mut scrub);
    let back = spread(&mut back);
    // Cold seeks: 24 jumps to pseudo-random frames at least 40 frames from the last one (nothing near is cached), one every
    // 300 ms; latency until the exact frame shows.
    let mut seeks = Vec::new();
    let mut seek_missed = 0;
    let (mut seed, mut at_frame) = (0x2545_F491_4F6C_DD1Du64, 0i64);
    handle.begin_scrub();
    for _ in 0..24 {
        let next_frame = loop {
            seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            let f = 10 + (seed >> 33) as i64 % 210;
            if (f - at_frame).abs() >= 40 {
                break f;
            }
        };
        at_frame = next_frame;
        let at = frame * next_frame;
        let t = Instant::now();
        handle.scrub(at);
        loop {
            if let Some(s) = handle.latest_shown()
                && s.position == at
                && s.exact
            {
                if s.generation != generation {
                    generation = s.generation;
                    upload.take(&s);
                }
                seeks.push(t.elapsed().as_secs_f64() * 1e3);
                break;
            }
            if t.elapsed() > Duration::from_secs(2) {
                seek_missed += 1;
                break;
            }
            std::thread::sleep(Duration::from_micros(500));
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    handle.end_scrub();

    Ok(format!(
        "clip: {} ({label}, {} {}-bit {})\npresent path: {}\n\
         1x play {secs:.1} s: {shown} composites shown ({:.1}/s, expected {:.1}/s), {dropped} dropped, {} taken by the monitor\n\
         monitor take: {}\npicture gaps: {}\ncpu: {cpu}\n\
         scrub to the exact frame (120 requests at 60 Hz, 2 frames apart, both directions): {}, {missed} missed (> 500 ms)\n\
         cold seek to the exact frame (24 jumps, >= 40 frames apart): {}, {seek_missed} missed (> 2 s)\n",
        clip.display(),
        track.codec,
        track.bit_depth,
        track.chroma,
        MonitorUpload::PATH,
        shown as f64 / secs,
        1.0 / (frame.value() as f64 / frame.timescale() as f64),
        costs.len(),
        spread(&mut costs),
        spread(&mut gaps),
        format_args!("forward leg {forward}; back leg {back}"),
        spread(&mut seeks),
    ))
}

#[cfg(test)]
mod rss_tests {
    /// The play benchmark's memory numbers must never read 0 (they did on Windows, where `ps` does not exist).
    #[test]
    fn the_process_memory_is_known_and_plausible() {
        assert!(super::rss_mb().is_some_and(|mb| mb > 1.0));
    }
}
