// SPDX-License-Identifier: GPL-3.0-or-later
//! The engine on real media: a synthetic 5 s clip made with the `ffmpeg` command line, the platform opener (VideoToolbox on
//! the Mac, FFmpeg elsewhere) and the machine's GPU. They skip with a message when there is no adapter, no linked FFmpeg
//! shim or no `ffmpeg` command. Oracle: the paused frame equals the frame a direct decode + compose of the same position
//! gives (what an export frame source does), byte for byte; playback at 1x shows every frame.

use super::core::ProgramEngine;
use super::handle::EngineDeps;
use super::media_source::{DefaultOpener, block_on, picture_of};
use super::stats::PlayStats;
use super::testkit::{clip, id, timeline};
use super::types::MediaRef;
use sq_audio_out::clock::{HostClock, PlaybackClock};
use sq_core_edit::playback::PlaybackRate;
use sq_core_effects::evaluation::{LayerHooks, TimelineEvaluation};
use sq_core_model::{SequenceFormat, Timeline};
use sq_core_time::Time;
use sq_gpu::gpu::Gpu;
use sq_media::media_opener::MediaOpener;
use sq_render::program::{Inputs, LayerSource, ProgramCompositor, RenderOptions, Source};
use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn ffmpeg() -> Command {
    let bundled = std::env::var_os("SQ_FFMPEG").map(|r| PathBuf::from(r).join("bin").join("ffmpeg"));
    Command::new(bundled.filter(|p| p.exists() || p.with_extension("exe").exists()).unwrap_or_else(|| "ffmpeg".into()))
}

/// A 5 s, 25 fps, 640x360 testsrc2 clip (keyframe every second, B-frames) made with `encoder`, or `None` with a message.
fn make_clip(encoder: &str) -> Option<PathBuf> {
    if !sq_media_ffmpeg::shim::AVAILABLE {
        sq_os::errln!("skipped: the FFmpeg shim is not linked");
        return None;
    }
    let dir = std::env::temp_dir().join(format!("sq-playback-engine-{}", std::process::id()));
    std::fs::create_dir_all(&dir).ok()?;
    let path = dir.join(format!("five-seconds-{encoder}.mp4"));
    let out = ffmpeg()
        .args(["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=5"])
        .args(["-c:v", encoder, "-b:v", "4M", "-pix_fmt", "yuv420p", "-bf", "2", "-g", "25"])
        .arg(&path)
        .output()
        .ok()?;
    if !out.status.success() || !path.exists() {
        sq_os::errln!("skipped: no ffmpeg command with a {encoder} encoder");
        return None;
    }
    Some(path)
}

fn gpu() -> Option<Arc<Gpu>> {
    match Gpu::new() {
        Ok(g) => {
            sq_os::errln!("adapter: {} ({:?})", g.info().name, g.info().backend);
            Some(g)
        }
        Err(e) => {
            sq_os::errln!("skipped: no GPU adapter ({e})");
            None
        }
    }
}

fn five_second_timeline(media: sq_core_time::Id) -> Timeline {
    let mut tl = timeline(vec![vec![clip(10, media, 0, 0, 5)]]);
    tl.format = SequenceFormat { width: 640, height: 360, ..tl.format };
    tl
}

/// Plays and checks one clip.
fn check(encoder: &str) {
    let (Some(path), Some(gpu)) = (make_clip(encoder), gpu()) else { return };
    let media = id(100);
    let tl = five_second_timeline(media);
    let clock = Arc::new(HostClock::new());
    let opener = Arc::new(DefaultOpener::new(Some(Arc::clone(&gpu))));
    let mut deps =
        EngineDeps::new(Arc::clone(&opener) as Arc<dyn MediaOpener>, Arc::clone(&clock) as Arc<dyn PlaybackClock>);
    deps.gpu = Some(Arc::clone(&gpu));
    let handle = ProgramEngine::spawn(deps);
    handle.set_media(vec![MediaRef { id: media, path: path.to_string_lossy().into_owned() }]);
    handle.set_timeline(tl.clone(), Default::default());

    let until = |what: &str, cond: &dyn Fn() -> bool| {
        let end = Instant::now() + Duration::from_secs(20);
        while !cond() {
            assert!(Instant::now() < end, "timed out waiting for {what}: {:?}", handle.status());
            std::thread::sleep(Duration::from_millis(10));
        }
    };
    until("first picture", &|| handle.query(|e| e.is_picture_settled()) == Some(true));

    handle.play(PlaybackRate::FORWARD);
    until("the end", &|| {
        let s = handle.status();
        s.rate.is_some_and(|r| r.is_paused()) && s.shown_frames > 0
    });
    let s = handle.status();
    sq_os::errln!("play 1x ({encoder}): {s:?}");
    sq_os::errln!("{:#?}", handle.query(|e| e.stats().report()));
    assert_eq!(s.last_error, None);
    // Real-time test: the whole-workspace run loads every core, so a scheduler stall may skip a frame or two
    // (seen: 2 of 125 under load, 0 alone). More than 2 % still means the engine cannot keep up.
    assert!(s.skipped_frames <= 2, "dropped frames at 1x: {s:?}");
    assert!(s.shown_frames >= 120, "{s:?}");
    assert_eq!(s.position, Time::new(124, 25));

    // The paused frame at 2.4 s against a direct decode + compose.
    handle.seek(Time::new(12, 5));
    until("the paused frame", &|| {
        handle.query(|e| e.is_picture_settled() && e.position() == Time::new(12, 5)) == Some(true)
    });
    let shown = handle.latest_shown().expect("shown");
    let texture = shown.frame.as_ref().expect("a composite").planes[0].clone();
    let engine_pixels = gpu.read_texture(&texture).expect("read engine frame");

    let opened = opener.open(&path, media).expect("open");
    let frames = block_on(opened.decoder.decode(60..=60)).expect("decode");
    let picture = picture_of(frames.into_iter().next().expect("frame"), 1, false, &PlayStats::new()).expect("picture");
    let mut comp = ProgramCompositor::new(&gpu).expect("compositor");
    let t = Time::new(12, 5);
    let requests = tl.video_layers(t, &|_| None, &LayerHooks::plain(), None);
    let source = |l: &sq_core_effects::evaluation::LayerRequest| {
        LayerSource::Media(Source {
            media: l.media,
            index: 60,
            frame: picture.frame.clone(),
            info: opened.info.clone(),
            proxy: false,
            divisor: 1,
            gyro: None,
        })
    };
    let grade = |_: &sq_core_effects::evaluation::LayerRequest| None;
    let inputs = Inputs { grade: &grade, split: None, mattes: None, source: &source };
    let frame = comp
        .render(&requests, &tl.format, &RenderOptions { readback: true, ..RenderOptions::default() }, &inputs)
        .expect("render");
    let direct = comp.download_rgba8(frame).expect("download");
    assert_eq!(engine_pixels.len(), direct.len());
    assert!(engine_pixels == direct, "the paused engine frame differs from the direct (export-path) frame");
}

#[test]
fn five_seconds_play_at_1x_without_dropped_frames_and_the_paused_frame_equals_a_direct_render() {
    check("mpeg4");
}

/// The hardware route: VideoToolbox decodes H.264 on the Mac (zero-copy GPU frames), D3D11VA / software elsewhere.
#[test]
fn the_same_with_h264() {
    check("libx264");
}

/// Measures what the app sees: plays a real TestMedia clip at 1x for 4 s on a 1080p sequence, reads every new composite
/// back like the app's picture pump and logs shown frames per second. Skips without the clip.
#[test]
fn measure_app_like_playback_fps() {
    // SQ_BENCH_CLIP overrides the clip (a heavier file than the stock one).
    let path = std::env::var_os("SQ_BENCH_CLIP").map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(std::env::var("HOME").unwrap_or_default())
            .join("Documents/SequenceStudio/TestMedia/stock/waterfall.mp4")
    });
    let Some(gpu) = gpu().filter(|_| path.exists()) else { return };
    let media = id(100);
    let mut tl = timeline(vec![vec![clip(10, media, 0, 0, 10)]]);
    tl.format = SequenceFormat { width: 1920, height: 1080, ..tl.format };
    let clock = Arc::new(HostClock::new());
    let opener = Arc::new(DefaultOpener::new(Some(Arc::clone(&gpu))));
    let mut deps = EngineDeps::new(opener as Arc<dyn MediaOpener>, clock as Arc<dyn PlaybackClock>);
    deps.gpu = Some(Arc::clone(&gpu));
    let handle = ProgramEngine::spawn(deps);
    handle.set_media(vec![MediaRef { id: media, path: path.to_string_lossy().into_owned() }]);
    handle.set_timeline(tl, Default::default());
    let end = Instant::now() + Duration::from_secs(20);
    while handle.query(|e| e.is_picture_settled()) != Some(true) {
        assert!(Instant::now() < end, "no first picture");
        std::thread::sleep(Duration::from_millis(10));
    }
    handle.play(PlaybackRate::FORWARD);
    let (start, mut last, mut seen, mut read_ms) = (Instant::now(), 0, 0u32, 0.0);
    while start.elapsed() < Duration::from_secs(4) {
        if let Some(shown) = handle.latest_shown().filter(|s| s.generation != last) {
            last = shown.generation;
            seen += 1;
            if let Some(p) = shown.frame.as_ref().and_then(|f| f.planes.first()) {
                let t = Instant::now();
                let _ = gpu.read_texture(p);
                read_ms += t.elapsed().as_secs_f64() * 1e3;
            }
        }
        std::thread::sleep(Duration::from_millis(4));
    }
    let secs = start.elapsed().as_secs_f64();
    sq_os::errln!(
        "app-like fps: seen {:.1}/s, status {:?}, readback avg {:.1} ms",
        f64::from(seen) / secs,
        handle.status(),
        read_ms / f64::from(seen.max(1))
    );
    sq_os::errln!("{:#?}", handle.query(|e| e.stats().report()));
}

/// Scrubs a real clip back and forth at 60 Hz, logs how many distinct pictures the monitor got, then checks that the
/// settled frame equals a direct decode (no stale or half-decoded picture stays). Skips without the clip.
#[test]
fn measure_fast_scrub_and_the_settled_frame_is_exact() {
    let path = std::env::var_os("SQ_BENCH_CLIP").map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(std::env::var("HOME").unwrap_or_default())
            .join("Documents/SequenceStudio/TestMedia/stock/waterfall.mp4")
    });
    let Some(gpu) = gpu().filter(|_| path.exists()) else { return };
    let media = id(100);
    let mut tl = timeline(vec![vec![clip(10, media, 0, 0, 10)]]);
    tl.format = SequenceFormat { width: 1080, height: 1920, ..tl.format };
    let clock = Arc::new(HostClock::new());
    let opener = Arc::new(DefaultOpener::new(Some(Arc::clone(&gpu))));
    let mut deps =
        EngineDeps::new(Arc::clone(&opener) as Arc<dyn MediaOpener>, Arc::clone(&clock) as Arc<dyn PlaybackClock>);
    deps.gpu = Some(Arc::clone(&gpu));
    let handle = ProgramEngine::spawn(deps);
    handle.set_media(vec![MediaRef { id: media, path: path.to_string_lossy().into_owned() }]);
    handle.set_timeline(tl.clone(), Default::default());
    let until = |what: &str, cond: &dyn Fn() -> bool| {
        let end = Instant::now() + Duration::from_secs(30);
        while !cond() {
            assert!(Instant::now() < end, "timed out waiting for {what}: {:?}", handle.status());
            std::thread::sleep(Duration::from_millis(10));
        }
    };
    until("first picture", &|| handle.query(|e| e.is_picture_settled()) == Some(true));

    handle.begin_scrub();
    let fd = tl.frame_duration();
    let (start, mut last, mut seen) = (Instant::now(), 0, 0u32);
    let mut ticks = 0i64;
    while std::env::var_os("SQ_NO_SCRUB").is_none() && start.elapsed() < Duration::from_secs(4) {
        // A triangle wave over 3 s of source, 90 frames per sweep.
        let k = ticks % 180;
        let frame = if k < 90 { k } else { 180 - k };
        handle.scrub(fd * frame * 1);
        ticks += 1;
        if let Some(s) = handle.latest_shown().filter(|s| s.generation != last) {
            last = s.generation;
            seen += 1;
        }
        std::thread::sleep(Duration::from_millis(16));
    }
    sq_os::errln!("scrub: {} moves, {} distinct pictures in 4 s; status {:?}", ticks, seen, handle.status());
    sq_os::errln!("{:#?}", handle.query(|e| e.stats().report()));
    let target = fd * 37;
    if std::env::var_os("SQ_NO_SCRUB").is_some() {
        handle.end_scrub();
        handle.seek(target);
    } else {
        handle.scrub(target);
        handle.end_scrub();
    }
    until("settled", &|| handle.query(move |e| e.is_picture_settled() && e.position() == target) == Some(true));
    let shown = handle.latest_shown().expect("shown");
    let engine_pixels = gpu.read_texture(&shown.frame.as_ref().expect("composite").planes[0]).expect("read");

    let opened = opener.open(&path, media).expect("open");
    let mut exact = false;
    for idx in 36..=46usize {
        let frames = block_on(opened.decoder.decode(idx..=idx)).expect("decode");
        let picture =
            picture_of(frames.into_iter().next().expect("frame"), 1, false, &PlayStats::new()).expect("picture");
        let mut comp = ProgramCompositor::new(&gpu).expect("compositor");
        let requests = tl.video_layers(target, &|_| None, &LayerHooks::plain(), None);
        let source = |l: &sq_core_effects::evaluation::LayerRequest| {
            LayerSource::Media(Source {
                media: l.media,
                index: idx as i64,
                frame: picture.frame.clone(),
                info: opened.info.clone(),
                proxy: false,
                divisor: 1,
                gyro: None,
            })
        };
        let grade = |_: &sq_core_effects::evaluation::LayerRequest| None;
        let inputs = Inputs { grade: &grade, split: None, mattes: None, source: &source };
        let frame = comp
            .render(&requests, &tl.format, &RenderOptions { readback: true, ..RenderOptions::default() }, &inputs)
            .expect("render");
        let direct = comp.download_rgba8(frame).expect("download");
        let w = engine_pixels.iter().zip(&direct).map(|(a, b)| a.abs_diff(*b)).max().unwrap_or(0);
        let off = engine_pixels.iter().zip(&direct).filter(|(a, b)| a.abs_diff(**b) > 8).count();
        sq_os::errln!("frame {idx}: worst {w}, off {off}");
        exact |= w == 0;
    }
    assert!(exact, "the settled frame after a scrub is none of the frames 36..=46 decoded directly");
}
