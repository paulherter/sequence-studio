//! Times the REAL Stabilizer analysis and the REAL subject-mask tracking (EdgeTAM) on a media file; no UI.
//!   fxreal_bench <media> [seconds=5] [models-folder]   (ONNX runtime: LD_LIBRARY_PATH or beside the exe)
//! Prints seconds of work per second of video and the process CPU time, one line per stage.
#![allow(clippy::expect_used)] // a measuring tool: a missing argument or file should stop it with a message
use sq_analysis::analysis_turn::CancelToken;
use sq_analysis::frame_matte_store::FrameMatteStore;
use sq_analysis::stabilization_analyzing::StabilizationAnalyzing;
use sq_app_hosts::{EdgeTamTracker, FfmpegStabilizationAnalyzer, FfmpegTrackFrames, TrackFrames, Tracker, run_track};
use sq_core_time::{Time, TimeRange, Vec2};
use std::path::Path;
use std::time::Instant;

fn cpu_secs() -> f64 {
    // utime + stime of this process in clock ticks (100/s on Linux).
    let s = std::fs::read_to_string("/proc/self/stat").unwrap_or_default();
    let f: Vec<&str> = s.rsplit(')').next().unwrap_or("").split_whitespace().collect();
    let t = |i: usize| f.get(i).and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0);
    (t(11) + t(12)) / 100.0
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let media = Path::new(a.get(1).expect("media"));
    let secs: i64 = a.get(2).and_then(|s| s.parse().ok()).unwrap_or(5);
    let range = TimeRange::new(Time::ZERO, Time::new(secs, 1));
    let (c0, t0) = (cpu_secs(), Instant::now());
    let probe = FfmpegTrackFrames::open(media, Time::ZERO, Time::new(secs, 1)).expect("open");
    let frames = probe.count();
    drop(probe);
    let (w, h) = {
        let mut f = FfmpegTrackFrames::open(media, Time::ZERO, Time::new(1, 30)).expect("open");
        let (_, fr) = f.frame(0).expect("frame");
        (fr.width as i64, fr.height as i64)
    };
    let _ = (c0, t0, w, h);
    // Stabilizer analysis (the app measures in the clip's own size; the frames are read at MEASURE_SIDE).
    let (c0, t0) = (cpu_secs(), Instant::now());
    let r = FfmpegStabilizationAnalyzer::new(media).analyze(range, 3840, 2160, None, &CancelToken::new());
    let wall = t0.elapsed().as_secs_f64();
    println!(
        "stabilize {:?} frames~{frames} wall {wall:.2}s = {:.2}x per video second, cpu {:.2}s ({:.0}%)",
        r.as_ref().map(|x| x.motions.len()).map_err(|e| e.to_string()),
        wall / secs as f64,
        cpu_secs() - c0,
        (cpu_secs() - c0) / wall * 100.0
    );
    // Decode-only cost of the tracking frames (what the tracker waits for).
    let (c0, t0) = (cpu_secs(), Instant::now());
    let mut fr = FfmpegTrackFrames::open(media, Time::ZERO, range.end()).expect("open");
    let n = fr.count();
    for i in 0..n {
        fr.frame(i);
    }
    let wall = t0.elapsed().as_secs_f64();
    println!(
        "track-frames decode+scale {n} frames wall {wall:.2}s = {:.2}x per video second, cpu {:.0}%",
        wall / secs as f64,
        (cpu_secs() - c0) / wall * 100.0
    );
    // EdgeTAM tracking.
    let Some(models) = a.get(3) else { return };
    let (c0, t0) = (cpu_secs(), Instant::now());
    let mut tracker = match EdgeTamTracker::load(Path::new(models)) {
        Ok(t) => t,
        Err(e) => return println!("track: model load failed: {e}"),
    };
    println!("track: model load {:.2}s", t0.elapsed().as_secs_f64());
    let _: &mut dyn Tracker = &mut tracker;
    let store = FrameMatteStore::new(None);
    let mut fr = FfmpegTrackFrames::open(media, Time::ZERO, range.end()).expect("open");
    let (c1, t1) = (cpu_secs(), Instant::now());
    let out = run_track(
        &mut fr,
        &mut tracker,
        &store,
        "bench",
        &[(Vec2::new(0.5, 0.5), false)],
        &CancelToken::new(),
        &mut |_| {},
    );
    let wall = t1.elapsed().as_secs_f64();
    println!(
        "track {} frames error={:?} wall {wall:.2}s = {:.2}x per video second ({:.2} s/frame), cpu {:.0}%",
        out.frames,
        out.error,
        wall / secs as f64,
        wall / out.frames.max(1) as f64,
        (cpu_secs() - c1) / wall * 100.0
    );
    let _ = (c0, t0);
}
