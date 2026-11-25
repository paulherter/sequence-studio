//! Oracle tests against the `ffmpeg` command line: tiny synthetic clips are made with it, and the pictures this crate
//! decodes (NV12 / P010 planes) must equal what `ffmpeg -f framecrc` hashes (Adler-32 of the packed planes) for the
//! same clip, in order and after random seeks. They skip with a message when the shim is not linked or `ffmpeg`
//! is not on PATH (or in `SQ_FFMPEG/bin`) or lacks an encoder.

use super::{FFmpegAudioSource, FFmpegDemuxer, FFmpegFrame, FFmpegVideoDecoder};
use crate::shim;
use sq_core_model::FieldOrder;
use sq_core_time::Id;
use sq_media::demuxing::Demuxing;
use sq_media::memory_audio_source::AudioSource;
use sq_media::video_decoding::{DecodedFrame, VideoDecoding};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::task::{Context, Poll, Waker};

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
    // SQ_TEST_FFMPEG: a complete ffmpeg command for making clips (the Linux deps build has no libx264/libx265; the system's
    // has). It brings its own libraries, so the library path cargo sets for the linked FFmpeg is dropped for it.
    if let Some(own) = std::env::var_os("SQ_TEST_FFMPEG") {
        let mut command = Command::new(own);
        command.env_remove("LD_LIBRARY_PATH");
        return command;
    }
    let bundled = std::env::var_os("SQ_FFMPEG").map(|r| PathBuf::from(r).join("bin").join("ffmpeg"));
    Command::new(bundled.filter(|p| p.exists() || p.with_extension("exe").exists()).unwrap_or_else(|| "ffmpeg".into()))
}

/// True when the tests can run; prints why not.
fn ready() -> bool {
    let ok = shim::AVAILABLE && ffmpeg().arg("-version").output().is_ok_and(|o| o.status.success());
    if !ok {
        eprintln!("skipped: the FFmpeg shim is not linked or no ffmpeg command is available");
    }
    ok
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("sq-media-ffmpeg-tests-{}", std::process::id()));
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

/// A 1 s, 30 fps, 128x96 clip with B-frames and a keyframe every 10 frames; `None` (with a message) when ffmpeg lacks
/// the encoder.
fn make_clip(name: &str, encoder: &str, pix_fmt: &str) -> Option<PathBuf> {
    let path = scratch(name);
    let out = ffmpeg()
        .args(["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=128x96:rate=30:duration=1"])
        .args(["-c:v", encoder, "-pix_fmt", pix_fmt, "-bf", "2", "-g", "10"])
        .arg(&path)
        .output()
        .ok()?;
    if !out.status.success() || !path.exists() {
        eprintln!("skipped {name}: ffmpeg has no working {encoder} encoder");
        return None;
    }
    Some(path)
}

/// Adler-32 of every decoded frame in presentation order, from ffmpeg's framecrc muxer (`pix_fmt` = the layout under test).
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

fn hash(frame: &DecodedFrame) -> u32 {
    let storage = frame.frame.storage_as::<FFmpegFrame>().unwrap();
    adler32(&storage.download().unwrap())
}

fn decode(dec: &FFmpegVideoDecoder, range: std::ops::RangeInclusive<usize>) -> Vec<u32> {
    block_on(dec.decode(range)).unwrap().iter().map(hash).collect()
}

fn check_clip(name: &str, encoder: &str, pix_fmt: &str, out_fmt: &str) {
    if !ready() {
        return;
    }
    let Some(clip) = make_clip(name, encoder, pix_fmt) else { return };
    let expected = oracle(&clip, out_fmt);
    let demuxer = Arc::new(FFmpegDemuxer::open(&clip).unwrap());
    let n = demuxer.index().count();
    assert_eq!(n, expected.len());
    assert_eq!(demuxer.track_info().bit_depth, if out_fmt == "p010le" { 10 } else { 8 });
    let dec = FFmpegVideoDecoder::new(demuxer, Id::from_u128(1), false, 0).unwrap();
    assert!(!dec.is_hardware());

    // Every frame in order, in one call.
    assert_eq!(decode(&dec, 0..=n - 1), expected);
    // Ten pseudo-random seeks, exact.
    let mut seed = 0x2545_F491_4F6C_DD1Du64;
    for _ in 0..10 {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        let i = usize::try_from(seed >> 33).unwrap() % n;
        assert_eq!(decode(&dec, i..=i), vec![expected[i]], "seek to frame {i}");
    }
    // Forward playback in chunks continues without a seek and stays exact.
    for start in (0..n).step_by(4) {
        let end = (start + 3).min(n - 1);
        assert_eq!(decode(&dec, start..=end), expected[start..=end], "chunk {start}..={end}");
    }
    // Backward after forward, and after invalidate.
    dec.invalidate();
    assert_eq!(decode(&dec, 7..=9), expected[7..=9]);
    assert_eq!(decode(&dec, 2..=3), expected[2..=3]);
}

#[test]
fn h264_8_bit_frames_equal_ffmpeg() {
    check_clip("h264.mp4", "libx264", "yuv420p", "nv12");
}

#[test]
fn mpeg4_8_bit_frames_equal_ffmpeg() {
    check_clip("mpeg4.mp4", "mpeg4", "yuv420p", "nv12");
}

#[test]
fn hevc_10_bit_frames_equal_ffmpeg() {
    check_clip("hevc10.mp4", "libx265", "yuv420p10le", "p010le");
}

#[test]
fn demuxer_reads_samples_in_decode_order() {
    if !ready() {
        return;
    }
    let Some(clip) = make_clip("samples.mp4", "mpeg4", "yuv420p") else { return };
    let d = FFmpegDemuxer::open(&clip).unwrap();
    assert_eq!(d.format_description().codec, "mpeg4");
    assert_eq!(d.rotation(), 0);
    let n = d.index().count();
    // The last frame needs its GOP from the sync sample on; samples arrive in decode order with the sync flag first.
    let samples = block_on(d.samples_for(n - 1..=n - 1)).unwrap();
    assert!(samples[0].is_sync && samples.iter().any(|s| s.data.len() > 4));
    assert!(samples.windows(2).all(|w| w[0].dts <= w[1].dts));
    // The streaming reader hands out the same bytes, continuing from a decode ordinal.
    let start = d.index().sync_decode_ordinal(n - 1);
    let mut reader = d.sample_reader(n - 1..=n - 1, start).unwrap().unwrap();
    assert_eq!(reader.count(), samples.len());
    assert_eq!(reader.next().unwrap(), samples[0]);
    let heads = d.sample_heads(3, 4).unwrap();
    assert_eq!(heads.len(), 3);
    assert!(d.sample(n + 5).is_err());
    assert!(FFmpegDemuxer::open(&scratch("missing.mp4")).is_err());
}

#[test]
fn audio_matches_ffmpeg_resampling() {
    if !ready() {
        return;
    }
    let wav = scratch("tone.wav");
    let made = ffmpeg()
        .args(["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=1"])
        .args(["-c:a", "pcm_s16le"])
        .arg(&wav)
        .output()
        .unwrap();
    assert!(made.status.success());
    let reference = ffmpeg()
        .args(["-v", "error", "-i"])
        .arg(&wav)
        .args(["-ar", "48000", "-ac", "1", "-f", "f32le", "-"])
        .output()
        .unwrap()
        .stdout;
    // The tone is mono: Swift plays a mono file duplicated onto both sides at unity (AVAssetReader), so the oracle is the
    // one-channel decode copied to both sides. `-ac 2` would apply the resampler's -3 dB mono-to-stereo mix instead.
    let expected: Vec<f32> =
        reference.as_chunks::<4>().0.iter().map(|b| f32::from_le_bytes(*b)).flat_map(|v| [v, v]).collect();
    let src = FFmpegAudioSource::open(&wav, 48_000).unwrap();
    assert!(src.is_mono());
    assert_eq!(src.sample_rate(), 48_000);
    assert_eq!(usize::try_from(src.frame_count()).unwrap(), expected.len() / 2);
    let mut left = vec![0.0f32; expected.len() / 2];
    assert_eq!(src.read(0, &mut left, 0).unwrap(), left.len());
    let mut right = vec![0.0f32; 100];
    assert_eq!(src.read(1000, &mut right, 1).unwrap(), 100);
    assert_eq!(right, left[1000..1100]);
    assert!(left.iter().zip(expected.as_chunks::<2>().0).all(|(l, e)| *l == e[0]));
    // Past the end, and a short tail.
    let mut tail = vec![0.0f32; 50];
    assert_eq!(src.read(src.frame_count() - 20, &mut tail, 0).unwrap(), 20);
    assert_eq!(src.read(src.frame_count(), &mut tail, 0).unwrap(), 0);
    assert_eq!(FFmpegAudioSource::mono_samples(&wav, 16_000).unwrap().len(), 16_000);
}

/// The VP9/WebM samples from TestMedia decode their first frames (skips when a file or the shim is missing).
#[test]
fn vp9_webm_samples_decode_their_first_frames() {
    if !shim::AVAILABLE {
        eprintln!("skipped: the FFmpeg shim is not linked");
        return;
    }
    let Some(home) = std::env::var_os("HOME") else { return };
    for name in ["sample-vp9-vorbis.webm", "sample-vp9-vorbis-long.webm"] {
        let path = PathBuf::from(&home).join("Documents/SequenceStudio/TestMedia").join(name);
        if !path.exists() {
            eprintln!("skipped {name}: not present");
            continue;
        }
        let demuxer = Arc::new(FFmpegDemuxer::open(&path).unwrap());
        let n = demuxer.index().count();
        assert!(n > 0, "{name}: no frames indexed");
        let dec = FFmpegVideoDecoder::new(demuxer, Id::from_u128(1), false, 0).unwrap();
        let frames = block_on(dec.decode(0..=4.min(n - 1))).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(frames.len(), 5.min(n), "{name}");
    }
}

// MARK: Hardware (D3D11VA on Windows, VA-API on Linux) against software

/// A clip of `size` ("1280x720"), `secs` seconds at 30 fps, a keyframe every 30 frames. `encoders` are tried in order (the LGPL
/// FFmpeg build has no libx264/libx265, the PC's GPU encoders stand in); each first with B-frames, then without.
fn make_sized_clip(name: &str, encoders: &[&str], pix_fmt: &str, size: &str, secs: u32) -> Option<PathBuf> {
    let path = scratch(name);
    let src = format!("testsrc2=size={size}:rate=30:duration={secs}");
    for encoder in encoders {
        for bframes in ["2", "0"] {
            let out = ffmpeg()
                .args([
                    "-y", "-v", "error", "-f", "lavfi", "-i", &src, "-c:v", encoder, "-pix_fmt", pix_fmt, "-bf",
                    bframes,
                ])
                .args(["-g", "30"])
                .arg(&path)
                .output()
                .ok()?;
            if out.status.success() && path.exists() {
                return Some(path);
            }
        }
    }
    eprintln!("skipped {name}: ffmpeg has no working encoder of {encoders:?}");
    None
}

fn open_decoder(clip: &Path, hardware: bool) -> (Arc<FFmpegDemuxer>, FFmpegVideoDecoder) {
    let demuxer = Arc::new(FFmpegDemuxer::open(clip).unwrap());
    let dec = FFmpegVideoDecoder::new(Arc::clone(&demuxer), Id::from_u128(1), hardware, 4).unwrap();
    (demuxer, dec)
}

/// Decodes `clip` with the GPU decoder and the software decoder and compares the downloaded planes (NV12 / P010) and how
/// each reads them (layout with its range, color space): one picture from either path. Prints the real differences. Windows
/// and Linux only: elsewhere FFmpegVideoDecoder never opens hardware.
fn check_hw_equals_software(name: &str, encoders: &[&str], pix_fmt: &str, sixteen_bit: bool) {
    if !ready() || !super::hardware::HARDWARE_PATH {
        return;
    }
    // 2560x1440: big enough for the GPU decoder where small streams stay on the CPU (`big_enough_for_hardware`).
    let Some(clip) = make_sized_clip(name, encoders, pix_fmt, "2560x1440", 1) else { return };
    let (demuxer, hw) = open_decoder(&clip, true);
    if !hw.is_hardware() {
        eprintln!("skipped {name}: the GPU decoder did not open ({})", hw.decoder_name());
        return;
    }
    let (_, sw) = open_decoder(&clip, false);
    assert!(!sw.is_hardware());
    let n = demuxer.index().count();
    let planes = |dec: &FFmpegVideoDecoder| -> Vec<(Vec<u8>, String)> {
        // Chunks of four, as playback asks: decoded hardware frames hold their pool texture until dropped.
        (0..n)
            .step_by(4)
            .flat_map(|from| block_on(dec.decode(from..=(from + 3).min(n - 1))).unwrap())
            .map(|f| {
                let layout = format!("{:?} {:?}", f.frame.pixel_format, f.frame.color_space);
                (f.frame.storage_as::<FFmpegFrame>().unwrap().download().unwrap(), layout)
            })
            .collect()
    };
    let (a, b) = (planes(&hw), planes(&sw));
    assert!(hw.is_hardware(), "{name}: the hardware decoder fell back to software while decoding");
    assert_eq!(a.len(), b.len());
    let (mut max, mut sum, mut count, mut differing) = (0i32, 0u64, 0u64, 0u64);
    for ((x, hw_layout), (y, sw_layout)) in a.iter().zip(&b) {
        assert_eq!(hw_layout, sw_layout, "{name}: the two paths read their planes as different layouts");
        assert_eq!(x.len(), y.len());
        let step = if sixteen_bit { 2 } else { 1 };
        for (p, q) in x.chunks_exact(step).zip(y.chunks_exact(step)) {
            let (u, v) = if sixteen_bit {
                // P010 samples are MSB-aligned: compare the 10-bit values.
                (i32::from(u16::from_le_bytes([p[0], p[1]]) >> 6), i32::from(u16::from_le_bytes([q[0], q[1]]) >> 6))
            } else {
                (i32::from(p[0]), i32::from(q[0]))
            };
            let d = (u - v).abs();
            max = max.max(d);
            sum += d as u64;
            count += 1;
            differing += u64::from(d > 0);
        }
    }
    eprintln!(
        "{name}: {} frames, hw {} vs sw: max diff {max}, mean {:.5}, {differing} of {count} samples differ",
        a.len(),
        hw.decoder_name(),
        sum as f64 / count as f64
    );
    assert!(max <= 2, "{name}: hardware and software frames differ by up to {max} levels");
}

#[test]
fn hardware_h264_frames_match_software() {
    check_hw_equals_software("hw-h264.mp4", &["libx264", "h264_amf"], "yuv420p", false);
}

/// A full-range stream: the codes must reach the picture unscaled on either path (the layout says full range).
#[test]
fn hardware_h264_full_range_frames_match_software() {
    check_hw_equals_software("hw-h264-full.mp4", &["libx264"], "yuvj420p", false);
}

#[test]
fn hardware_hevc_10_bit_frames_match_software() {
    check_hw_equals_software("hw-hevc10.mp4", &["libx265", "hevc_amf"], "p010le", true);
}

#[test]
fn hardware_hevc_8_bit_frames_match_software() {
    check_hw_equals_software("hw-hevc8.mp4", &["libx265", "hevc_amf"], "yuv420p", false);
}

/// Throughput benchmark (not run by default): `SQ_BENCH_CLIP=<file> SQ_BENCH_HW=1|0 cargo test -p sq-media-ffmpeg --release
/// bench_decode -- --ignored --nocapture`. Decodes every frame in chunks of 4 (as playback does) and prints frames per second;
/// the caller measures CPU time around the process.
#[test]
#[ignore]
fn bench_decode() {
    let Some(clip) = std::env::var_os("SQ_BENCH_CLIP").map(PathBuf::from) else { return };
    let hardware = std::env::var("SQ_BENCH_HW").is_ok_and(|v| v == "1");
    let download = std::env::var("SQ_BENCH_DOWNLOAD").is_ok_and(|v| v == "1");
    let (demuxer, dec) = open_decoder(&clip, hardware);
    let limit = std::env::var("SQ_BENCH_FRAMES").ok().and_then(|v| v.parse::<usize>().ok());
    let n = limit.map_or(demuxer.index().count(), |l| l.min(demuxer.index().count()));
    let start = std::time::Instant::now();
    let mut done = 0;
    for from in (0..n).step_by(4) {
        let frames = block_on(dec.decode(from..=(from + 3).min(n - 1))).unwrap();
        for f in &frames {
            if download {
                std::hint::black_box(f.frame.storage_as::<FFmpegFrame>().unwrap().download().unwrap());
            }
        }
        done += frames.len();
    }
    let secs = start.elapsed().as_secs_f64();
    println!(
        "test result: BENCH {} hw={} frames={done} wall={secs:.2}s fps={:.1}",
        dec.decoder_name(),
        dec.is_hardware(),
        done as f64 / secs
    );
}

/// An interlaced clip (two fields of different moments woven into each frame) with the given field order.
fn make_interlaced_clip(name: &str, order: &str) -> Option<PathBuf> {
    let path = scratch(name);
    let out = ffmpeg()
        .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=1"])
        .args(["-vf", &format!("tinterlace=interleave_top,setfield={order}")])
        .args(["-c:v", "mpeg2video", "-flags", "+ildct+ilme", "-pix_fmt", "yuv420p"])
        .arg(&path)
        .output()
        .ok()?;
    if out.status.success() && path.exists() {
        return Some(path);
    }
    eprintln!("skipped {name}: ffmpeg cannot write an interlaced MPEG-2 clip");
    None
}

#[test]
fn the_demuxer_reports_the_field_order_of_an_interlaced_stream() {
    if !ready() {
        return;
    }
    for (order, expected) in [("tff", FieldOrder::TopFirst), ("bff", FieldOrder::BottomFirst)] {
        let Some(clip) = make_interlaced_clip(&format!("fields-{order}.mov"), order) else { return };
        let info = FFmpegDemuxer::open(&clip).unwrap().track_info();
        assert_eq!(info.field_order, Some(expected), "{order}");
    }
}

#[test]
fn a_deinterlacing_decoder_hands_out_the_progressive_picture_of_the_stored_one() {
    if !ready() {
        return;
    }
    let Some(clip) = make_interlaced_clip("deint.mov", "tff") else { return };
    let demuxer = Arc::new(FFmpegDemuxer::open(&clip).unwrap());
    let order = demuxer.track_info().field_order;
    assert_eq!(order, Some(FieldOrder::TopFirst));
    let download = |order: Option<FieldOrder>| -> Vec<u8> {
        let dec =
            FFmpegVideoDecoder::new(Arc::clone(&demuxer), Id::from_u128(1), false, 0).unwrap().with_deinterlace(order);
        let frames = block_on(dec.decode(3..=3)).unwrap();
        frames[0].frame.storage_as::<FFmpegFrame>().unwrap().download().unwrap()
    };
    let (stored, clean) = (download(None), download(order));
    assert_eq!(stored.len(), clean.len());
    assert_ne!(stored, clean, "the woven fields comb and must be rebuilt");
    let expected =
        sq_media::deinterlacer::deinterlace_biplanar_420(&stored, 320, 240, 320, false, FieldOrder::TopFirst);
    assert_eq!(Some(clean.clone()), expected);
    // The field first in time (top: even rows) stays as stored.
    for row in (0..240).step_by(2) {
        assert_eq!(stored[row * 320..(row + 1) * 320], clean[row * 320..(row + 1) * 320], "row {row}");
    }
}

#[test]
fn a_variable_frame_rate_clip_is_conformed_to_the_planned_constant_slots() {
    if !ready() {
        return;
    }
    // Frames 0,1,2 of every five survive: presentation times 0,1,2,5,6,7,... frames (gaps of two frames).
    let src = scratch("vfr-src.mp4");
    let made = ffmpeg()
        .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=25:duration=2"])
        .args(["-f", "lavfi", "-i", "sine=frequency=440:duration=2"])
        .args(["-vf", "select='lt(mod(n,5),3)'", "-fps_mode", "vfr", "-c:v", "mpeg4", "-c:a", "aac", "-shortest"])
        .arg(&src)
        .output()
        .ok()
        .filter(|o| o.status.success());
    if made.is_none() {
        eprintln!("skipped: ffmpeg cannot write the VFR clip");
        return;
    }
    // The clip is rotated by its display matrix: the conform keeps it.
    let rotated = scratch("vfr-rot.mp4");
    let turned = ffmpeg()
        .args(["-v", "error", "-y", "-display_rotation", "90", "-i"])
        .arg(&src)
        .args(["-c", "copy"])
        .arg(&rotated)
        .output()
        .ok()
        .filter(|o| o.status.success());
    let src = if turned.is_some() { rotated } else { src };
    let source = FFmpegDemuxer::open(&src).unwrap();
    let rotation = source.track_info().rotation;
    let fd = sq_core_time::Time::new(1, 25);
    let pts: Vec<_> = source.index().entries().iter().map(|e| e.pts).collect();
    let last = source.index().entries().last().unwrap();
    let planned: i64 =
        sq_media::vfr_conform::plan(&pts, last.pts + last.duration, fd).iter().map(|r| r.end - r.start).sum();
    assert!(source.track_info().is_variable_frame_rate);

    let dst = scratch("vfr-out.mov");
    let seen = std::cell::Cell::new(0.0);
    let result = crate::conform::conform_to_constant_frame_rate(&src, &dst, fd, &|p| seen.set(p), &|| false);
    if let Err(e) = &result {
        eprintln!("skipped: no ProRes encoder? {e}");
        return;
    }
    assert_eq!(seen.get(), 1.0);
    let out = FFmpegDemuxer::open(&dst).unwrap();
    let info = out.track_info();
    assert!(!info.is_variable_frame_rate);
    assert_eq!(info.nominal_frame_duration, fd);
    assert_eq!(info.rotation, rotation);
    // The source carries no color tags: the file gets the encoder's Rec. 709 default.
    assert_eq!(info.color_primaries.as_deref(), Some("ITU_R_709_2"));
    assert_eq!(out.index().count() as i64, planned);
    assert!(out.index().entries().iter().enumerate().all(|(i, e)| e.pts == fd * (i as i64)));
    assert!(FFmpegAudioSource::stream_info(&dst).unwrap().is_some_and(|a| a.sample_rate == 44_100)); // the source track's own rate (lavfi sine default)
}

/// Swift writes every usable audio track of the source as its own PCM track with its own rate and channel count.
#[test]
fn conform_keeps_every_audio_track_with_its_rate_and_channels() {
    if !ready() {
        return;
    }
    let src = scratch("conform-multi.mov");
    let made = ffmpeg()
        .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=25:duration=1"])
        .args(["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=1"])
        .args(["-f", "lavfi", "-i", "sine=frequency=330:sample_rate=22050:duration=1"])
        .args(["-f", "lavfi", "-i", "sine=frequency=220:sample_rate=48000:duration=1"])
        .args(["-map", "0", "-map", "1", "-map", "2", "-map", "3", "-ac:a:0", "2", "-ac:a:1", "1", "-ac:a:2", "6"])
        .args(["-c:v", "mpeg4", "-c:a", "pcm_s16le"])
        .arg(&src)
        .output()
        .ok()
        .filter(|o| o.status.success());
    if made.is_none() {
        eprintln!("skipped: ffmpeg cannot write the three-track clip");
        return;
    }
    assert_eq!(FFmpegAudioSource::track_channels(&src).unwrap(), vec![2, 1, 6]);
    let dst = scratch("conform-multi-out.mov");
    let fd = sq_core_time::Time::new(1, 25);
    if let Err(e) = crate::conform::conform_to_constant_frame_rate(&src, &dst, fd, &|_| (), &|| false) {
        eprintln!("skipped: no ProRes encoder? {e}");
        return;
    }
    assert_eq!(FFmpegAudioSource::track_channels(&dst).unwrap(), vec![2, 1, 6]);
    assert_eq!(shim::audio_track_rates(&dst).unwrap(), vec![44_100, 22_050, 48_000]);
    // Each track holds about a second of sound (not just the first one).
    for (ordinal, rate) in [(0usize, 44_100i64), (1, 22_050), (2, 48_000)] {
        let t = FFmpegAudioSource::open_track(&dst, rate as i32, ordinal).unwrap();
        assert!((t.frame_count() - rate).abs() <= rate / 10, "track {ordinal}: {} frames", t.frame_count());
        let mut b = vec![0f32; 1000];
        assert_eq!(t.read(5000, &mut b, 0).unwrap(), 1000);
        assert!(b.iter().any(|v| v.abs() > 0.05), "track {ordinal} is silent");
    }
}

#[test]
fn a_four_mono_track_file_plays_the_channels_the_map_names() {
    if !ready() {
        return;
    }
    // Four mono tracks of constant levels 0.1 .. 0.4 (a camera with four microphones).
    let src = scratch("four-mono.mov");
    let mut cmd = ffmpeg();
    cmd.args(["-v", "error", "-y"]);
    for level in ["0.1", "0.2", "0.3", "0.4"] {
        cmd.args(["-f", "lavfi", "-i", &format!("aevalsrc={level}:s=48000:d=1")]);
    }
    cmd.args(["-map", "0", "-map", "1", "-map", "2", "-map", "3", "-c:a", "pcm_s16le"]).arg(&src);
    if !cmd.output().is_ok_and(|o| o.status.success()) {
        eprintln!("skipped: ffmpeg cannot write the four-track file");
        return;
    }
    assert_eq!(FFmpegAudioSource::track_channels(&src).unwrap(), vec![1, 1, 1, 1]);
    // Mono tracks are copied to both sides at unity, as Swift plays them (see `FFmpegAudioSource::load`).
    const MONO_MIX: f32 = 1.0;
    let mean = |source: &dyn AudioSource, channel: usize| {
        let mut b = vec![0f32; 4000];
        assert_eq!(source.read(10_000, &mut b, channel).unwrap(), 4000);
        b.iter().sum::<f32>() / 4000.0
    };
    // Channels 1 and 3 (0-based) to the left and right: tracks 2 and 4 only.
    let map = sq_core_model::AudioChannelMap::stereo(1, 3).unwrap();
    let source = FFmpegAudioSource::open_mapped(&src, 48_000, Some(&map)).unwrap();
    let (l, r) = (mean(&*source, 0), mean(&*source, 1));
    assert!((l - 0.2 * MONO_MIX).abs() < 0.01 && (r - 0.4 * MONO_MIX).abs() < 0.01, "left {l} right {r}");
    // Two microphones on one clip, both in the center: their sum on both sides.
    let both = sq_core_model::AudioChannelMap::dual_mono(0, 2).unwrap();
    let centered = FFmpegAudioSource::open_mapped(&src, 48_000, Some(&both)).unwrap();
    assert!(centered.is_mono());
    assert!(
        (mean(&*centered, 0) - 0.4 * MONO_MIX).abs() < 0.02,
        "sum of 0.1 and 0.3 (map gain aside): {}",
        mean(&*centered, 0)
    );
}

/// The streamed speech read gives the samples the whole-file decode gives (a 3 s stereo tone, 44.1 kHz to 16 kHz).
#[test]
fn streamed_mono_samples_equal_the_whole_decode() {
    if !ready() {
        return;
    }
    let wav = scratch("speech-stereo.wav");
    let made = ffmpeg()
        .args(["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=300:sample_rate=44100:duration=3"])
        .args(["-ac", "2", "-c:a", "pcm_s16le"])
        .arg(&wav)
        .output()
        .unwrap();
    assert!(made.status.success());
    let whole = super::audio_source::decode_for_test(&wav, 16_000, 1).unwrap();
    let streamed = FFmpegAudioSource::mono_samples(&wav, 16_000).unwrap();
    assert_eq!(streamed.len(), whole.len());
    assert!(streamed.len() >= 47_900 && streamed.len() <= 48_100, "3 s at 16 kHz, got {}", streamed.len());
    let worst = streamed.iter().zip(&whole).map(|(a, b)| (a - b).abs()).fold(0.0f32, f32::max);
    assert!(worst < 1e-4, "worst difference {worst}");
}

/// P34: the demuxer's codec FourCC reaches the decoder, so ProRes 4444 opens with its real profile (no "Unknown prores
/// profile 0", 12 bit 4:4:4 + alpha instead of the 10 bit 4:2:2 a guessed tag gives).
#[test]
fn prores_4444_carries_its_fourcc_to_the_decoder() {
    if !ready() {
        return;
    }
    let src = scratch("prores4444.mov");
    let made = ffmpeg()
        .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=25:duration=1"])
        .args(["-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le"])
        .arg(&src)
        .output()
        .ok()
        .filter(|o| o.status.success());
    if made.is_none() {
        eprintln!("skipped: ffmpeg cannot write ProRes 4444");
        return;
    }
    let demux = shim::Demux::open(&src).unwrap();
    let info = demux.info();
    let fourcc = |s: &[u8; 4]| u32::from_le_bytes(*s);
    assert_eq!(info.codec_tag, fourcc(b"ap4h"), "the container's FourCC of ProRes 4444");
    let extra = demux.extradata();
    let mut dec = shim::Decoder::open(&shim::DecoderConfig {
        codec: &info.codec,
        extradata: &extra,
        width: info.width,
        height: info.height,
        bits_per_coded_sample: info.bits_per_coded_sample,
        codec_tag: info.codec_tag,
        tb_num: info.tb_num,
        tb_den: info.tb_den,
        hardware: false,
        extra_hw_frames: 0,
        sw_threads: 0,
    })
    .unwrap();
    let data = demux.read(0).unwrap();
    let p = &demux.packets()[0];
    let input = shim::InputPacket { data: &data, pts: p.pts, dts: p.dts, duration: p.duration, key: true };
    dec.send(&input).unwrap();
    dec.send_end().unwrap();
    let shim::Received::Frame(f) = dec.receive().unwrap() else { panic!("a frame") };
    assert_eq!((f.width, f.height), (64, 48));
}

/// A stream-copy excerpt cut between key frames starts at a negative time (edit list): it must open quickly, index every
/// frame from time 0 and decode frame 0. `SQ_NEG_START_FILE` points the same checks at a real camera excerpt.
#[test]
fn a_negative_start_clip_opens_fast_and_decodes_its_first_shown_frame() {
    let Some(ffmpeg) = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        .iter()
        .map(|d| format!("{d}/ffmpeg"))
        .find(|p| Path::new(p).exists())
    else {
        return;
    };
    let dir = std::env::temp_dir().join(format!("sq-negstart-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let src = dir.join("src.mp4");
    let cut = dir.join("cut.mp4");
    let run = |args: &[&str]| {
        std::process::Command::new(&ffmpeg).args(["-v", "error", "-y"]).args(args).status().is_ok_and(|s| s.success())
    };
    let from_env = std::env::var("SQ_NEG_START_FILE").ok().map(std::path::PathBuf::from);
    let clip = if let Some(f) = from_env {
        f
    } else {
        let make = "-f lavfi -i testsrc2=size=128x96:rate=30:duration=8 -f lavfi -i sine=duration=8 -c:v libx264 \
            -preset ultrafast -bf 2 -g 60 -x264-params open-gop=1 -pix_fmt yuv420p -c:a aac -shortest";
        let args: Vec<&str> = make.split_whitespace().chain([src.to_str().unwrap()]).collect();
        if !run(&args) {
            eprintln!("skipped: this ffmpeg has no libx264 (LGPL build)");
            let _ = std::fs::remove_dir_all(&dir);
            return;
        }
        assert!(run(&["-ss", "4.1", "-i", src.to_str().unwrap(), "-t", "3", "-c", "copy", cut.to_str().unwrap()]));
        cut
    };
    let began = std::time::Instant::now();
    let demuxer = Arc::new(FFmpegDemuxer::open(&clip).expect("open"));
    let n = demuxer.index().count();
    assert!(n > 0);
    let first = demuxer.index().frame_at(sq_core_time::Time::ZERO).expect("a frame at time 0");
    let dec = FFmpegVideoDecoder::new(Arc::clone(&demuxer), Id::from_u128(1), false, 0).unwrap();
    let frames = block_on(dec.decode(first..=first)).expect("first shown frame");
    assert_eq!(frames.len(), 1);
    assert!(began.elapsed().as_secs_f64() < 2.0, "open + frame 0 took {:?}", began.elapsed());
    let _ = std::fs::remove_dir_all(&dir);
}
