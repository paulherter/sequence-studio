//! Mac-only oracle tests against the `ffmpeg` command line (they skip with a message elsewhere, without ffmpeg, an encoder
//! or a GPU): clips are made with it, and the planes this crate decodes through VideoToolbox must equal what
//! `ffmpeg -f framecrc` hashes (Adler-32 of the packed planes) for H.264 and HEVC, in order and after random seeks.
//! ProRes is not bit-exact between decoders: PSNR against FFmpeg's decode must be at least 50 dB.

#![cfg(target_os = "macos")]

use crate::VtVideoDecoder;
use crate::codec::StreamRange;
use sq_core_time::Id;
use sq_gpu::frames::GpuFrame;
use sq_gpu::gpu::Gpu;
use sq_media::demuxing::Demuxing;
use sq_media::video_decoding::{DecodedFrame, VideoDecoding};
use sq_media_ffmpeg::decode::{FFmpegDemuxer, flagged_full_range, frame_color};
use sq_media_ffmpeg::shim;
use std::future::Future;
use std::ops::RangeInclusive;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::task::{Context, Poll, Waker};
use std::time::Instant;

fn block_on<T>(fut: impl Future<Output = T>) -> T {
    let mut fut = std::pin::pin!(fut);
    let mut cx = Context::from_waker(Waker::noop());
    loop {
        if let Poll::Ready(v) = fut.as_mut().poll(&mut cx) {
            return v;
        }
    }
}

fn ffmpeg() -> Command {
    let bundled = std::env::var_os("SQ_FFMPEG").map(|r| PathBuf::from(r).join("bin").join("ffmpeg"));
    Command::new(bundled.filter(|p| p.exists()).unwrap_or_else(|| "ffmpeg".into()))
}

/// The GPU and the FFmpeg shim/command, or `None` with the reason printed.
fn ready() -> Option<Arc<Gpu>> {
    if !shim::AVAILABLE || !ffmpeg().arg("-version").output().is_ok_and(|o| o.status.success()) {
        sq_os::errln!("skipped: the FFmpeg shim is not linked or no ffmpeg command is available");
        return None;
    }
    match Gpu::new() {
        Ok(gpu) => Some(gpu),
        Err(e) => {
            sq_os::errln!("skipped: no GPU adapter ({e})");
            None
        }
    }
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("sq-video-hw-tests-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

/// FFmpeg's `av_adler32_update(0, ...)`, the framecrc hash (seed 0, not zlib's 1).
fn adler32(data: &[u8]) -> u32 {
    let (mut a, mut b) = (0u32, 0u32);
    for chunk in data.chunks(5552) {
        for byte in chunk {
            a += u32::from(*byte);
            b += a;
        }
        a %= 65521;
        b %= 65521;
    }
    b << 16 | a
}

/// A `seconds` long 30 fps clip with B-frames and a keyframe every 10 frames; `None` (with a message) when ffmpeg lacks the encoder.
fn make_clip(name: &str, size: &str, seconds: u32, encode: &[&str]) -> Option<PathBuf> {
    let path = scratch(name);
    let run = |mut cmd: Command| {
        cmd.args(["-y", "-v", "error", "-f", "lavfi", "-i"])
            .arg(format!("testsrc2=size={size}:rate=30:duration={seconds}"))
            .args(encode)
            .arg(&path)
            .output()
            .ok()
    };
    // The bundled LGPL build has no libx264: a system ffmpeg on the PATH makes the clip when it has.
    let out = run(ffmpeg()).filter(|o| o.status.success()).or_else(|| run(Command::new("ffmpeg")))?;
    if !out.status.success() || !path.exists() {
        sq_os::errln!("skipped {name}: ffmpeg cannot encode with {encode:?}: {}", String::from_utf8_lossy(&out.stderr));
        return None;
    }
    Some(path)
}

/// Adler-32 of every decoded frame in presentation order, from ffmpeg's framecrc muxer.
fn oracle(clip: &Path, pix_fmt: &str) -> Vec<u32> {
    let out = ffmpeg()
        .args(["-v", "error", "-i"])
        .arg(clip)
        .args(["-pix_fmt", pix_fmt, "-fps_mode", "passthrough", "-f", "framecrc", "-"])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let mut rows: Vec<(i64, u32)> = String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .filter(|l| !l.starts_with('#'))
        .map(|l| {
            let f: Vec<&str> = l.split(',').map(str::trim).collect();
            (f[2].parse().unwrap(), u32::from_str_radix(f[5].trim_start_matches("0x"), 16).unwrap())
        })
        .collect();
    rows.sort_by_key(|r| r.0);
    rows.into_iter().map(|r| r.1).collect()
}

/// The planes of a decoded frame read back from the GPU, packed one after the other (ffmpeg's nv12 / p010le / p210le layout).
fn planes(gpu: &Arc<Gpu>, frame: &DecodedFrame) -> Vec<u8> {
    let storage = frame.frame.storage_as::<GpuFrame>().expect("a GpuFrame");
    assert!(storage.keep.is_some(), "the CVPixelBuffer must stay alive in `keep`");
    storage.planes.iter().flat_map(|p| gpu.read_texture(p).unwrap()).collect()
}

fn open(gpu: &Arc<Gpu>, clip: &Path) -> (Arc<FFmpegDemuxer>, VtVideoDecoder) {
    try_open(gpu, clip).unwrap_or_else(|e| panic!("{e}"))
}

/// Opens the way the app's opener does (range flags from the stream), so full-range clips ask for the full-range layout.
fn try_open(
    gpu: &Arc<Gpu>,
    clip: &Path,
) -> Result<(Arc<FFmpegDemuxer>, VtVideoDecoder), sq_media::media_error::MediaError> {
    let demuxer = Arc::new(FFmpegDemuxer::open(clip).unwrap());
    let info = demuxer.track_info();
    let range =
        StreamRange { flagged_full: flagged_full_range(demuxer.raw()), read_full: frame_color(demuxer.raw()).1 };
    let dec =
        VtVideoDecoder::new(Arc::clone(&demuxer) as Arc<dyn Demuxing>, info, Id::from_u128(1), Arc::clone(gpu), range)?;
    assert!(dec.is_hardware());
    Ok((demuxer, dec))
}

fn decode(gpu: &Arc<Gpu>, dec: &VtVideoDecoder, range: RangeInclusive<usize>) -> Vec<Vec<u8>> {
    let frames = block_on(dec.decode(range.clone())).unwrap_or_else(|e| panic!("decode {range:?}: {e}"));
    assert_eq!(frames.len(), range.count(), "one frame per requested index");
    assert!(frames.windows(2).all(|w| w[0].pts() < w[1].pts()), "presentation order");
    frames.iter().map(|f| planes(gpu, f)).collect()
}

fn hashes(gpu: &Arc<Gpu>, dec: &VtVideoDecoder, range: RangeInclusive<usize>) -> Vec<u32> {
    decode(gpu, dec, range).iter().map(|p| adler32(p)).collect()
}

fn check_clip(name: &str, encode: &[&str], out_fmt: &str) {
    check_clip_on(name, encode, out_fmt, false);
}

/// `optional`: the chip may lack a hardware decoder for the stream (H.264 4:2:2); the test then skips with a message.
fn check_clip_on(name: &str, encode: &[&str], out_fmt: &str, optional: bool) {
    let Some(gpu) = ready() else { return };
    let Some(clip) = make_clip(name, "640x360", 2, encode) else { return };
    let expected = oracle(&clip, out_fmt);
    let (demuxer, dec) = match try_open(&gpu, &clip) {
        Ok(opened) => opened,
        Err(e) if optional => {
            sq_os::errln!("skipped {name}: no hardware decoder on this machine ({e})");
            return;
        }
        Err(e) => panic!("{e}"),
    };
    let n = demuxer.index().count();
    assert_eq!(n, expected.len());

    // Every frame in order, in one call.
    assert_eq!(hashes(&gpu, &dec, 0..=n - 1), expected);
    // Ten pseudo-random seeks, exact (the step-back retry covers B-frame HEVC).
    let mut seed = 0x2545_F491_4F6C_DD1Du64;
    for _ in 0..10 {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        let i = usize::try_from(seed >> 33).unwrap() % n;
        assert_eq!(hashes(&gpu, &dec, i..=i), vec![expected[i]], "seek to frame {i}");
    }
    // Forward playback in chunks continues without a seek and stays exact.
    dec.invalidate();
    for start in (0..n).step_by(4) {
        let end = (start + 3).min(n - 1);
        assert_eq!(hashes(&gpu, &dec, start..=end), expected[start..=end], "chunk {start}..={end}");
    }
    // Backward after forward, and after invalidate.
    dec.invalidate();
    assert_eq!(hashes(&gpu, &dec, 27..=29), expected[27..=29]);
    assert_eq!(hashes(&gpu, &dec, 12..=13), expected[12..=13]);
}

#[test]
fn h264_8_bit_frames_equal_ffmpeg() {
    check_clip("h264.mp4", &["-c:v", "libx264", "-pix_fmt", "yuv420p", "-bf", "2", "-g", "10"], "nv12");
}

#[test]
fn hevc_8_bit_frames_equal_ffmpeg() {
    check_clip(
        "hevc8.mp4",
        &["-c:v", "libx265", "-pix_fmt", "yuv420p", "-bf", "2", "-g", "10", "-tag:v", "hvc1"],
        "nv12",
    );
}

#[test]
fn hevc_10_bit_frames_equal_ffmpeg() {
    check_clip(
        "hevc10.mp4",
        &["-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-bf", "2", "-g", "10", "-tag:v", "hvc1"],
        "p010le",
    );
}

/// Sony-style footage: 10-bit 4:2:2 flagged full range. The full-range layout (xf22) must deliver the codes unscaled, equal to
/// FFmpeg's software p210le planes (stricter than the 2/255 the color path needs).
const FULL: [&str; 6] = ["-vf", "scale=out_range=full,format=yuv422p10le", "-color_range", "pc", "-bf", "2"];

#[test]
fn hevc_422_10_bit_full_range_frames_equal_ffmpeg() {
    let mut enc = vec!["-c:v", "libx265", "-g", "10", "-tag:v", "hvc1"];
    enc.extend(FULL);
    check_clip("hevc422f.mp4", &enc, "p210le");
}

#[test]
fn hevc_422_10_bit_video_range_frames_equal_ffmpeg() {
    let enc = ["-c:v", "libx265", "-pix_fmt", "yuv422p10le", "-bf", "2", "-g", "10", "-tag:v", "hvc1"];
    check_clip("hevc422.mp4", &enc, "p210le");
}

#[test]
fn h264_422_10_bit_full_range_frames_equal_ffmpeg() {
    let mut enc = vec!["-c:v", "libx264", "-g", "10"];
    enc.extend(FULL);
    check_clip_on("h264422f.mp4", &enc, "p210le", true);
}

#[test]
fn prores_422_is_within_50_db_of_ffmpeg() {
    let Some(gpu) = ready() else { return };
    let Some(clip) =
        make_clip("prores.mov", "640x360", 1, &["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le"])
    else {
        return;
    };
    let raw = ffmpeg()
        .args(["-v", "error", "-i"])
        .arg(&clip)
        .args(["-pix_fmt", "p210le", "-fps_mode", "passthrough", "-f", "rawvideo", "-"])
        .output()
        .unwrap();
    assert!(raw.status.success());
    let (demuxer, dec) = open(&gpu, &clip);
    let n = demuxer.index().count();
    let frame_bytes = raw.stdout.len() / n;
    assert_eq!(frame_bytes * n, raw.stdout.len());
    for (i, ours) in decode(&gpu, &dec, 0..=n - 1).iter().enumerate() {
        let theirs = &raw.stdout[i * frame_bytes..(i + 1) * frame_bytes];
        assert_eq!(ours.len(), theirs.len(), "same packed size");
        let word = |b: &[u8], k: usize| f64::from(u16::from_le_bytes([b[2 * k], b[2 * k + 1]]) >> 6);
        let words = ours.len() / 2;
        let mse = (0..words).map(|k| (word(ours, k) - word(theirs, k)).powi(2)).sum::<f64>() / words as f64;
        let psnr = if mse == 0.0 { f64::INFINITY } else { 10.0 * (1023.0f64 * 1023.0 / mse).log10() };
        assert!(psnr >= 50.0, "frame {i}: {psnr:.1} dB");
    }
}

#[test]
fn hidden_frames_and_early_frames_stay_out() {
    let Some(gpu) = ready() else { return };
    let Some(clip) =
        make_clip("needed.mp4", "640x360", 1, &["-c:v", "libx264", "-pix_fmt", "yuv420p", "-bf", "2", "-g", "10"])
    else {
        return;
    };
    let expected = oracle(&clip, "nv12");
    let (_, dec) = open(&gpu, &clip);
    let delivered = Arc::new(std::sync::Mutex::new(Vec::new()));
    let sink = {
        let delivered = Arc::clone(&delivered);
        Box::new(move |f: DecodedFrame| delivered.lock().unwrap().push(f)) as sq_media::video_decoding::FrameSink
    };
    let rest = block_on(dec.decode_needed_from(5..=8, Some(7), sink)).unwrap();
    assert!(rest.is_empty(), "delivered frames are not returned again");
    let mut got: Vec<(sq_core_time::Time, u32)> =
        delivered.lock().unwrap().iter().map(|f| (f.pts(), adler32(&planes(&gpu, f)))).collect();
    got.sort_by_key(|g| g.0);
    assert_eq!(got.iter().map(|g| g.1).collect::<Vec<_>>(), expected[7..=8]);
}

/// `SQ_VIDEO_HW_BENCH=1 cargo test -p sq-video-hw bench -- --nocapture`: 4K HEVC 10-bit decode time per frame (G1 direct route:
/// 1.6-2.1 ms end to end, Swift reference 1.5-1.7 ms decode).
#[test]
fn bench_4k_hevc_10_bit() {
    if std::env::var_os("SQ_VIDEO_HW_BENCH").is_none() {
        sq_os::errln!("skipped: set SQ_VIDEO_HW_BENCH=1");
        return;
    }
    let Some(gpu) = ready() else { return };
    let enc = [
        "-c:v",
        "libx265",
        "-preset",
        "ultrafast",
        "-pix_fmt",
        "yuv420p10le",
        "-bf",
        "2",
        "-g",
        "30",
        "-tag:v",
        "hvc1",
    ];
    let Some(clip) = make_clip("bench4k.mp4", "3840x2160", 4, &enc) else { return };
    let (demuxer, dec) = open(&gpu, &clip);
    let n = demuxer.index().count();
    let mut per_frame = Vec::new();
    for _ in 0..3 {
        dec.invalidate();
        for start in (0..n).step_by(30) {
            let end = (start + 29).min(n - 1);
            let t = Instant::now();
            let frames = block_on(dec.decode(start..=end)).unwrap();
            per_frame.push(t.elapsed().as_secs_f64() * 1000.0 / frames.len() as f64);
        }
    }
    per_frame.sort_by(f64::total_cmp);
    sq_os::errln!(
        "4K HEVC 10-bit via sq-video-hw: median {:.2} ms/frame, best {:.2}, worst {:.2} ({} chunks)",
        per_frame[per_frame.len() / 2],
        per_frame[0],
        per_frame[per_frame.len() - 1],
        per_frame.len()
    );
}

/// X1: a B-frame clip (libx264 defaults (one GOP), last frame 89) decoded to its very end, many times on fresh decoders and frame by
/// frame as an export does, failed now and then with `truncated` for the last frames.
#[test]
fn b_frame_clip_end_frames_decode_every_time() {
    let Some(gpu) = ready() else { return };
    let Some(clip) = make_clip("tail.mp4", "1280x720", 3, &["-c:v", "libx264", "-pix_fmt", "yuv420p", "-bf", "3"])
    else {
        return;
    };
    let (demuxer, _) = open(&gpu, &clip);
    let n = demuxer.index().count();
    for run in 0..40 {
        let (_, dec) = open(&gpu, &clip);
        // Export order: one frame per call, start to end.
        for i in (0..n).filter(|i| run % 2 == 0 || *i >= n - 6) {
            let frames = block_on(dec.decode(i..=i)).unwrap_or_else(|e| panic!("run {run}: decode {i}..={i}: {e}"));
            assert_eq!(frames.len(), 1, "run {run}: frame {i}");
        }
        // A fresh seek straight to the last frames.
        let (_, dec) = open(&gpu, &clip);
        for i in [n - 2, n - 1, n - 3] {
            let frames = block_on(dec.decode(i..=i)).unwrap_or_else(|e| panic!("run {run}: seek {i}..={i}: {e}"));
            assert_eq!(frames.len(), 1, "run {run}: seek {i}");
        }
    }
}

/// Regression (graveyard SIGSEGV in CVMetalTexture::finalize, 2026-11-22): cached frames outlive the decoder that made
/// them (a quality step or clip change drops the decoder and its texture cache first); dropping the frames afterwards
/// on another thread must not touch a freed CVMetalTextureCache.
#[test]
fn frames_dropped_after_their_decoder_do_not_crash() {
    let Some(gpu) = ready() else { return };
    let Some(clip) = make_clip("outlive.mp4", "640x360", 1, &["-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "10"])
    else {
        return;
    };
    for _ in 0..20 {
        let (_demuxer, dec) = open(&gpu, &clip);
        let frames = block_on(dec.decode(0..=9)).unwrap();
        drop(dec);
        std::thread::spawn(move || drop(frames)).join().unwrap();
    }
}

/// Frames dropped on another thread while the decoder keeps importing (and flushing its texture cache every 64 imports).
#[test]
fn frames_dropped_on_another_thread_while_decoding_do_not_crash() {
    let Some(gpu) = ready() else { return };
    let Some(clip) = make_clip("race.mp4", "640x360", 10, &["-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "10"])
    else {
        return;
    };
    let (demuxer, dec) = open(&gpu, &clip);
    let n = demuxer.index().count();
    let (tx, rx) = std::sync::mpsc::channel::<Vec<DecodedFrame>>();
    let graveyard = std::thread::spawn(move || rx.into_iter().for_each(drop));
    for _ in 0..6 {
        for start in (0..n).step_by(70) {
            let end = (start + 69).min(n - 1);
            tx.send(block_on(dec.decode(start..=end)).unwrap()).unwrap();
        }
    }
    drop(tx);
    graveyard.join().unwrap();
}

/// Two decoders (two Importers on the one shared cache) import on their own threads while a third thread drops the frames.
#[test]
fn two_decoders_import_while_a_third_thread_drops_frames() {
    let Some(gpu) = ready() else { return };
    let Some(clip) = make_clip("two.mp4", "640x360", 10, &["-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "10"])
    else {
        return;
    };
    let (tx, rx) = std::sync::mpsc::channel::<Vec<DecodedFrame>>();
    let graveyard = std::thread::spawn(move || rx.into_iter().for_each(drop));
    let workers: Vec<_> = (0..2)
        .map(|_| {
            let (tx, gpu, clip) = (tx.clone(), Arc::clone(&gpu), clip.clone());
            std::thread::spawn(move || {
                let (demuxer, dec) = open(&gpu, &clip);
                let n = demuxer.index().count();
                for _ in 0..4 {
                    for start in (0..n).step_by(70) {
                        let end = (start + 69).min(n - 1);
                        tx.send(block_on(dec.decode(start..=end)).unwrap()).unwrap();
                    }
                }
            })
        })
        .collect();
    drop(tx);
    for w in workers {
        w.join().unwrap();
    }
    graveyard.join().unwrap();
}
