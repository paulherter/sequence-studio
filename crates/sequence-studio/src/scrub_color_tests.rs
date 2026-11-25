//! A frame has to look the same whichever way the Program monitor got it: scrubbed (a proxy, a reduced or a preview
//! decode) or paused (the original at full size). Real clips from the `ffmpeg` command line go through the real engine,
//! decoders and compositor; the scrub composite is read back and compared with the paused one at the same time.

use crate::export::tests::ffmpeg_tool;
use crate::proxy::{FfmpegProxyTranscoder, monitor_opener_over};
use sq_audio_out::clock::HostClock;
use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use sq_media::media_opener::MediaOpener;
use sq_playback::engine::core::ProgramEngine;
use sq_playback::engine::handle::{EngineDeps, ProgramHandle, Shown};
use sq_playback::engine::media_source::DefaultOpener;
use sq_playback::engine::types::MediaRef;
use sq_proxy::model::ProxyKind;
use sq_proxy::proxy_cache::ProxyCache;
use sq_proxy::proxy_provider::ProxyProvider;
use sq_proxy::proxy_queue::{ProxyJobPriority, ProxyQueue};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// The mean absolute difference between two pictures that may still differ (RGBA bytes, 0..255).
const TOLERANCE: f64 = 2.0;
/// The frame the scrub stops on (a frame the paused picture decodes on its own, away from frame 0).
const FRAME: i64 = 12;

/// One kind of test clip: its size and the `ffmpeg` encoder arguments.
struct Kind {
    name: &'static str,
    ext: &'static str,
    size: (u32, u32),
    encode: &'static [&'static str],
}

/// 8-bit Rec.709 limited range, the common camera and phone clip.
const LIMITED: Kind =
    Kind { name: "limited", ext: "mp4", size: (640, 360), encode: &["-c:v", "mpeg4", "-pix_fmt", "yuv420p"] };
/// Beyond 1080p: a scrub reads it at a quarter of each side.
const BIG: Kind =
    Kind { name: "big", ext: "mp4", size: (2560, 1440), encode: &["-c:v", "mpeg4", "-pix_fmt", "yuv420p"] };
/// 8-bit with the full range flag set (a screen recording, a JPEG-style camera).
const FULL: Kind =
    Kind { name: "full", ext: "mp4", size: (640, 360), encode: &["-c:v", "mjpeg", "-pix_fmt", "yuvj420p"] };
/// 10-bit 4:2:2 (the pixel layout of Sony, Canon and ProRes sources).
const DEEP: Kind = Kind {
    name: "deep",
    ext: "mov",
    size: (640, 360),
    encode: &["-c:v", "prores_ks", "-profile:v", "1", "-pix_fmt", "yuv422p10le"],
};
/// 8-bit 4:2:0 with the full range flag in the file (a log or screen-capture style clip): the codes must reach the screen
/// unscaled, which the camera LUT and the grade rely on.
const FLAGGED: Kind = Kind {
    name: "flagged",
    ext: "mp4",
    size: (640, 360),
    encode: &[
        "-c:v",
        "mpeg4",
        "-pix_fmt",
        "yuv420p",
        "-color_primaries",
        "bt709",
        "-color_trc",
        "bt709",
        "-colorspace",
        "bt709",
        "-color_range",
        "pc",
        "-movflags",
        "write_colr",
    ],
};
/// 10-bit 4:2:0 limited range (a phone's HEVC pixel layout).
const DEEP_420: Kind = Kind {
    name: "deep-420",
    ext: "mkv",
    size: (640, 360),
    encode: &["-c:v", "ffv1", "-pix_fmt", "yuv420p10le", "-color_range", "tv"],
};

/// 10-bit 4:2:2 limited range (a camera's XAVC / ProRes pixel layout, software decoded).
const DEEP_422: Kind = Kind {
    name: "deep-422",
    ext: "mkv",
    size: (640, 360),
    encode: &["-c:v", "ffv1", "-pix_fmt", "yuv422p10le", "-color_range", "tv"],
};

/// H.264 High 4:2:2 10-bit with the full range flag and no colour tags (a Sony XAVC clip like the user's C2177): on the Mac
/// VideoToolbox decodes it, on other systems FFmpeg.
const XAVC: Kind = Kind {
    name: "xavc",
    ext: "mp4",
    size: (640, 360),
    encode: &["-c:v", "libx264", "-pix_fmt", "yuv422p10le", "-color_range", "pc", "-bf", "2"],
};

fn make_clip(tool: &Path, dir: &Path, kind: &Kind) -> Option<PathBuf> {
    let path = dir.join(format!("{}.{}", kind.name, kind.ext));
    let source = format!("smptehdbars=size={}x{}:rate=25:duration=1", kind.size.0, kind.size.1);
    let made = std::process::Command::new(tool)
        .args(["-y", "-v", "error", "-f", "lavfi", "-i", &source])
        .args(kind.encode)
        .arg(&path)
        .status()
        .ok()?;
    (made.success() && path.exists()).then_some(path)
}

/// A proxy of `clip` made through the queue, and the opener the monitor uses over it.
fn proxy_opener(clip: &Path, dir: &Path, gpu: Option<Arc<sq_gpu::gpu::Gpu>>) -> Option<Arc<dyn MediaOpener>> {
    let cache = Arc::new(ProxyCache::new(dir.join("cache")));
    let mut queue = ProxyQueue::new(Arc::clone(&cache), 1);
    let mut ids = sq_core_time::SequentialIds::default();
    let now = crate::proxy::wall_clock();
    queue.enqueue(clip, ProxyKind::ProxyHalf, ProxyJobPriority::Background, 0, &mut ids, now).ok()?;
    queue.run_until_idle(&FfmpegProxyTranscoder, now);
    if cache.all_records().is_empty() {
        return None;
    }
    let provider = Arc::new(ProxyProvider::with_interlaced(cache, Box::new(|_| false)));
    Some(monitor_opener_over(Arc::new(DefaultOpener::new(gpu)), provider))
}

fn timeline(media: Id) -> Timeline {
    let mut track = Track::new(Id::from_u128(900), TrackKind::Video);
    let source = TimeRange::new(Time::ZERO, Time::seconds(1));
    track.set_clips(vec![Clip::new(Id::from_u128(10), "c", media, TrackKind::Video, source, Time::ZERO)]);
    let mut format = SequenceFormat::new(Time::new(1, 25));
    (format.width, format.height) = (320, 180);
    Timeline::new(Id::from_u128(1), "t", format, vec![track])
}

/// The newest composite once `ready` holds for it (10 s limit).
fn shown_when(handle: &ProgramHandle, what: &str, ready: impl Fn(&Shown) -> bool) -> Arc<Shown> {
    let end = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(s) = handle.latest_shown().filter(|s| s.frame.is_some() && ready(s)) {
            return s;
        }
        assert!(Instant::now() < end, "timed out waiting for {what}: {:?}", handle.status());
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Polls the render thread until `cond` holds (10 s limit).
fn engine_when(handle: &ProgramHandle, what: &str, cond: impl Fn(&mut ProgramEngine) -> bool + Send + Clone + 'static) {
    let end = Instant::now() + Duration::from_secs(10);
    while Instant::now() < end {
        if handle.query(cond.clone()) == Some(true) {
            return;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    panic!("timed out waiting for {what}: {:?}", handle.status());
}

/// The composite of frame [`FRAME`] reached by scrubbing, and the paused one at the same time, as RGBA bytes. `proxy`:
/// the scrub is expected to read the proxy of the clip, the paused frame never does.
fn scrub_and_still(gpu: &Arc<sq_gpu::gpu::Gpu>, opener: Arc<dyn MediaOpener>, clip: &Path) -> (Vec<u8>, Vec<u8>, bool) {
    let media = Id::from_u128(100);
    let mut deps = EngineDeps::new(opener, Arc::new(HostClock::new()));
    deps.gpu = Some(Arc::clone(gpu));
    let handle = ProgramEngine::spawn(deps);
    handle.set_media(vec![MediaRef { id: media, path: clip.to_string_lossy().into_owned() }]);
    handle.set_timeline(timeline(media), HashMap::new());
    let at = Time::new(FRAME, 25);
    handle.seek(Time::ZERO);
    shown_when(&handle, "the first picture", |s| s.position == Time::ZERO && s.exact);
    // A proxy opens in the background; give it its moment so the scrub can read it.
    std::thread::sleep(Duration::from_millis(400));

    handle.begin_scrub();
    handle.scrub(at);
    engine_when(&handle, "the scrub frame", move |e| e.position() == at && e.is_frame_settled());
    let scrub = shown_when(&handle, "the scrub composite", |s| s.position == at && s.exact);
    let proxy = handle.query(|e| e.wanted_keys().iter().any(|k| k.proxy)).unwrap_or(false);
    let scrubbed = scrub.frame.as_ref().and_then(|f| gpu.read_texture(&f.planes[0]).ok()).unwrap_or_default();
    let generation = scrub.generation;

    handle.end_scrub();
    engine_when(&handle, "the paused frame", move |e| {
        e.position() == at && e.is_frame_settled() && e.wanted_keys().iter().all(|k| !k.proxy && k.divisor == 1)
    });
    // A clip the scrub read the same way as the paused frame (no proxy, no reduction) is not composed again.
    std::thread::sleep(Duration::from_millis(300));
    let still =
        shown_when(&handle, "the paused composite", |s| s.generation >= generation && s.position == at && s.exact);
    let paused = still.frame.as_ref().and_then(|f| gpu.read_texture(&f.planes[0]).ok()).unwrap_or_default();
    (scrubbed, paused, proxy)
}

/// Mean absolute difference over all channels, and the mean of the red, green and blue samples of each picture.
fn compare(a: &[u8], b: &[u8]) -> (f64, f64, f64) {
    assert_eq!(a.len(), b.len(), "the two composites differ in size");
    assert!(!a.is_empty(), "no composite was read back");
    let n = a.len() as f64;
    let diff = a.iter().zip(b).map(|(x, y)| f64::from(x.abs_diff(*y))).sum::<f64>() / n;
    let mean = |p: &[u8]| p.iter().map(|v| f64::from(*v)).sum::<f64>() / n;
    (diff, mean(a), mean(b))
}

/// Runs one clip kind, with or without a proxy; `None` when the machine has no `ffmpeg` or no GPU adapter. `hardware`: the
/// opener gets the GPU like the app's, so the platform decoder (VideoToolbox on the Mac) reads the clip.
fn mismatch(kind: &Kind, with_proxy: bool, hardware: bool) -> Option<(f64, f64, f64, bool)> {
    let Some(tool) = ffmpeg_tool() else {
        eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
        return None;
    };
    let Ok(gpu) = sq_gpu::gpu::Gpu::new() else {
        eprintln!("skipped: no GPU adapter");
        return None;
    };
    let dir = std::env::temp_dir().join(format!(
        "sq-scrub-color-{}-{}-{with_proxy}-{hardware}",
        std::process::id(),
        kind.name
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).ok()?;
    let clip = make_clip(&tool, &dir, kind)?;
    let decode_gpu = hardware.then(|| Arc::clone(&gpu));
    let opener: Arc<dyn MediaOpener> =
        if with_proxy { proxy_opener(&clip, &dir, decode_gpu)? } else { Arc::new(DefaultOpener::new(decode_gpu)) };
    let (scrubbed, paused, proxy) = scrub_and_still(&gpu, opener, &clip);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(proxy, with_proxy, "{}: the scrub did not read what the test set up", kind.name);
    let (diff, a, b) = compare(&scrubbed, &paused);
    if diff > TOLERANCE {
        // Where it differs: the red, green and blue of a few points along two rows (colour bars on top, the dark strip below).
        let width = 320;
        for row in [30, 150] {
            let at = |p: &[u8], x: usize| format!("{:?}", &p[(row * width + x) * 4..(row * width + x) * 4 + 3]);
            let points: Vec<String> = [10, 60, 110, 160, 210, 260, 310]
                .iter()
                .map(|x| format!("x{x} {} vs {}", at(&scrubbed, *x), at(&paused, *x)))
                .collect();
            eprintln!("  row {row} (scrub vs paused): {}", points.join(" | "));
        }
    }
    eprintln!(
        "scrub vs paused {} proxy={with_proxy} hardware={hardware}: mean diff {diff:.2}, mean sample scrub {a:.1} paused {b:.1}",
        kind.name
    );
    Some((diff, a, b, proxy))
}

/// The software route everywhere, and on the Mac also the route the app takes there (VideoToolbox). Every route runs, so one
/// failure does not hide the numbers of the other.
fn assert_same(kind: &Kind, with_proxy: bool) {
    let routes: &[bool] = if cfg!(target_os = "macos") { &[false, true] } else { &[false] };
    let failed: Vec<String> = routes
        .iter()
        .filter_map(|&hardware| {
            let (diff, ..) = mismatch(kind, with_proxy, hardware)?;
            (diff > TOLERANCE).then(|| format!("hardware {hardware}: {diff:.2}/255"))
        })
        .collect();
    assert!(
        failed.is_empty(),
        "{} (proxy {with_proxy}): the scrub frame differs from the paused frame on average by {}",
        kind.name,
        failed.join(", ")
    );
}

#[test]
fn a_scrubbed_limited_range_frame_equals_the_paused_frame() {
    assert_same(&LIMITED, false);
}

#[test]
fn a_scrubbed_limited_range_proxy_frame_equals_the_paused_frame() {
    assert_same(&LIMITED, true);
}

#[test]
fn a_scrubbed_frame_of_a_big_clip_equals_the_paused_frame() {
    assert_same(&BIG, false);
}

#[test]
fn a_scrubbed_full_range_frame_equals_the_paused_frame() {
    assert_same(&FULL, false);
}

#[test]
fn a_scrubbed_full_range_proxy_frame_equals_the_paused_frame() {
    assert_same(&FULL, true);
}

#[test]
fn a_scrubbed_deep_frame_equals_the_paused_frame() {
    assert_same(&DEEP, false);
}

#[test]
fn a_scrubbed_deep_proxy_frame_equals_the_paused_frame() {
    assert_same(&DEEP, true);
}

#[test]
fn a_scrubbed_flagged_full_range_frame_equals_the_paused_frame() {
    assert_same(&FLAGGED, false);
}

#[test]
fn a_scrubbed_flagged_full_range_proxy_frame_equals_the_paused_frame() {
    assert_same(&FLAGGED, true);
}

#[test]
fn a_scrubbed_xavc_frame_equals_the_paused_frame() {
    assert_same(&XAVC, false);
}

#[test]
fn a_scrubbed_xavc_proxy_frame_equals_the_paused_frame() {
    assert_same(&XAVC, true);
}

#[test]
fn a_scrubbed_deep_420_frame_equals_the_paused_frame() {
    assert_same(&DEEP_420, false);
}

#[test]
fn a_scrubbed_deep_420_proxy_frame_equals_the_paused_frame() {
    assert_same(&DEEP_420, true);
}

/// The codes one decoded frame becomes on each download route: the paused frame (full size, swscale), a playing frame
/// (threaded copy) and a scrub of a big clip (reduced); a route that scaled the range would show another picture.
fn picture(
    opened: &sq_media::media_opener::OpenedMedia,
    divisor: u32,
    threaded: bool,
) -> (sq_frame::sqframe::SQFramePixelFormat, usize, Vec<u8>) {
    let frames = sq_playback::engine::media_source::block_on(opened.decoder.decode(FRAME as usize..=FRAME as usize))
        .expect("decode the frame");
    let frame = frames.into_iter().next().expect("one frame");
    let stats = sq_playback::engine::stats::PlayStats::default();
    let p = sq_playback::engine::media_source::picture_of(frame, divisor, threaded, &stats).expect("a picture");
    let cpu = p.frame.storage_as::<sq_render::program::CpuPlanes>().expect("cpu planes");
    (p.frame.pixel_format, p.frame.width * p.frame.height, cpu.bytes.to_vec())
}

#[test]
fn every_download_route_hands_out_the_same_codes() {
    let Some(tool) = ffmpeg_tool() else {
        eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
        return;
    };
    for kind in [&LIMITED, &FULL, &FLAGGED, &DEEP_420] {
        let dir = std::env::temp_dir().join(format!("sq-download-routes-{}-{}", std::process::id(), kind.name));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp folder");
        let clip = make_clip(&tool, &dir, kind).expect("a test clip");
        let opened = DefaultOpener::new(None).open(&clip, Id::from_u128(1)).expect("open the clip");
        let (format, pixels, paused) = picture(&opened, 1, false);
        let (playing_format, _, playing) = picture(&opened, 1, true);
        assert_eq!(format, playing_format, "{}: the routes label the codes differently", kind.name);
        let bytes = if paused.len() >= pixels * 3 { 2 } else { 1 };
        let off = paused.iter().zip(&playing).filter(|(a, b)| a != b).count();
        assert_eq!(
            off,
            0,
            "{}: {off} codes of {} differ between the paused and the playing download",
            kind.name,
            paused.len()
        );
        // A reduced download averages: the mean luma code stays where it was.
        let (_, reduced_pixels, reduced) = picture(&opened, 2, true);
        let mean = |planes: &[u8], count: usize| -> f64 {
            (0..count)
                .map(|i| {
                    if bytes == 1 {
                        f64::from(planes[i])
                    } else {
                        f64::from(u16::from_le_bytes([planes[2 * i], planes[2 * i + 1]]))
                    }
                })
                .sum::<f64>()
                / count as f64
        };
        let (a, b) = (mean(&paused, pixels), mean(&reduced, reduced_pixels));
        let tolerance = if bytes == 1 { 1.0 } else { 4.0 };
        assert!(
            (a - b).abs() <= tolerance,
            "{}: the reduced download moved the mean luma code from {a:.1} to {b:.1}",
            kind.name
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// A deep 4:2:2 clip keeps its chroma height on the playing route (P210: the GPU samples it, no CPU merge to 4:2:0): the
/// luma plane equals the paused (swscale) picture exactly, the chroma plane holds full-height rows, and a reduced download
/// is the 2 x 2 box of the full one.
#[test]
fn a_deep_422_frame_keeps_its_chroma_height_on_the_playing_route() {
    use sq_frame::sqframe::SQFramePixelFormat::{P010, P210};
    let Some(tool) = ffmpeg_tool() else {
        eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
        return;
    };
    let dir = std::env::temp_dir().join(format!("sq-422-routes-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp folder");
    let clip = make_clip(&tool, &dir, &DEEP_422).expect("a test clip");
    let opened = DefaultOpener::new(None).open(&clip, Id::from_u128(1)).expect("open the clip");
    let (paused_format, pixels, paused) = picture(&opened, 1, false);
    let (format, _, full) = picture(&opened, 1, true);
    assert_eq!(paused_format, P010);
    assert_eq!(format, P210);
    let (w, h) = (DEEP_422.size.0 as usize, DEEP_422.size.1 as usize);
    assert_eq!(full.len(), w * h * 4, "luma plus full-height chroma, 16 bit");
    assert_eq!(full[..pixels * 2], paused[..pixels * 2], "luma codes are the paused picture's");
    let (reduced_format, reduced_pixels, reduced) = picture(&opened, 2, true);
    assert_eq!(reduced_format, P210);
    assert_eq!(reduced.len(), reduced_pixels * 4);
    let word = |b: &[u8], i: usize| i32::from(u16::from_le_bytes([b[2 * i], b[2 * i + 1]]));
    for (x, y) in [(0, 0), (10, 7), (319, 179), (100, 150)] {
        let at = |dx: usize, dy: usize| word(&full, (2 * y + dy) * w + 2 * x + dx) >> 6;
        let box_avg = (at(0, 0) + at(1, 0) + at(0, 1) + at(1, 1) + 2) / 4;
        assert_eq!(word(&reduced, y * (w / 2) + x) >> 6, box_avg, "luma box at {x},{y}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// The opener-level rule behind the pixel tests (needs no GPU): a proxy file cannot say full range, so it is read the way its
/// original is.
#[test]
fn a_proxy_is_read_with_the_range_of_its_original() {
    use sq_frame::sqframe::SQFramePixelFormat::{Nv12, Nv12FullRange, P010, P010FullRange};
    use sq_media::media_opener::MonitorUse;
    let Some(tool) = ffmpeg_tool() else {
        eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
        return;
    };
    for (kind, full) in [(&LIMITED, false), (&FLAGGED, true), (&FULL, true)] {
        let dir = std::env::temp_dir().join(format!("sq-proxy-range-{}-{}", std::process::id(), kind.name));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp folder");
        let clip = make_clip(&tool, &dir, kind).expect("a test clip");
        let opener = proxy_opener(&clip, &dir, None).expect("a proxy");
        let id = Id::from_u128(1);
        let original = DefaultOpener::new(None).open(&clip, id).expect("open the original");
        let proxy =
            opener.open_for(&clip, id, MonitorUse::Scrubbing).expect("a proxy is ready").expect("open the proxy");
        assert_eq!(original.full_range, full, "{}: the original's range", kind.name);
        assert_eq!(proxy.full_range, full, "{}: the proxy is read with another range than its original", kind.name);
        let (format, ..) = picture(&proxy, 1, false);
        let expected = if full { [Nv12FullRange, P010FullRange] } else { [Nv12, P010] };
        assert!(expected.contains(&format), "{}: the proxy's pictures are labeled {format:?}", kind.name);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// Not a check: with `SQ_DUMP_CLIP=<file> SQ_DUMP_FRAMES=<i,j,..> SQ_DUMP_OUT=<folder>` it writes the playing route's pictures
/// (Full size, as the compositor receives them) of a real clip as `<frame>.<w>x<h>.p210` for the sq-render comparison test.
#[test]
fn dump_playing_pictures_of_a_clip() {
    let (Ok(clip), Ok(frames), Ok(out)) =
        (std::env::var("SQ_DUMP_CLIP"), std::env::var("SQ_DUMP_FRAMES"), std::env::var("SQ_DUMP_OUT"))
    else {
        return;
    };
    let opened = DefaultOpener::new(None).open(std::path::Path::new(&clip), Id::from_u128(1)).expect("open the clip");
    for i in frames.split(',').filter_map(|v| v.trim().parse::<usize>().ok()) {
        let f = sq_playback::engine::media_source::block_on(opened.decoder.decode(i..=i)).expect("decode");
        let frame = f.into_iter().next().expect("one frame");
        let stats = sq_playback::engine::stats::PlayStats::default();
        let p = sq_playback::engine::media_source::picture_of(frame, 1, true, &stats).expect("a picture");
        let cpu = p.frame.storage_as::<sq_render::program::CpuPlanes>().expect("cpu planes");
        let name = format!("{out}/{i}.{}x{}.{:?}", p.frame.width, p.frame.height, p.frame.pixel_format);
        std::fs::write(name, &cpu.bytes[..]).expect("write");
    }
}
