//! Real exports through this computer's encoders (hardware: VA-API on Linux, NVENC / AMF / Quick Sync / Media Foundation
//! on Windows; software: OpenH264 and Kvazaar of the LGPL builds), read back with ffprobe and decoded: the codec,
//! profile, pixel format, bitrate, duration and frame count are the ones the settings asked for and no frame is
//! corrupt. The hardware test skips with a message when FFmpeg is not linked, ffprobe is missing, or this machine has no
//! hardware encoder; run it against the LGPL libraries (`LD_LIBRARY_PATH=$SQ_FFMPEG/lib`), not a system FFmpeg.

use super::FfmpegExportEncoder;
use crate::core::*;
use sq_core_time::Time;
use sq_frame::sqframe::{SQFrame, SQFrameColorSpace, SQFramePixelFormat};
use sq_media_ffmpeg::decode::MemoryFrame;
use sq_media_ffmpeg::encode::{Probe, ProbeKind, probe};
use sq_media_ffmpeg::shim;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

/// 8 x 8 pixel blocks of changing noise over a gradient: detailed enough that every target below is a real limit, and
/// not so extreme that no rate control could reach it (a hardware encoder stops at its highest quantizer).
struct Noise {
    w: usize,
    h: usize,
    frames: usize,
}

const BLOCK: usize = 8;

impl FrameSource for Noise {
    fn frame_count(&self) -> usize {
        self.frames
    }

    fn frame_duration(&self) -> Time {
        Time::new(1, 30)
    }

    fn frame(&mut self, index: usize) -> Result<ExportFrame, ExportError> {
        let (width, height) = (self.w, self.h);
        let mut bytes = vec![255u8; width * height * 4];
        for by in 0..height / BLOCK {
            for bx in 0..width / BLOCK {
                let mut h = (bx as u32).wrapping_mul(0x9E37_79B1)
                    ^ (by as u32).wrapping_mul(0x85EB_CA6B)
                    ^ (index as u32).wrapping_mul(0xC2B2_AE35);
                h ^= h >> 15;
                let (gx, gy) = (bx * 160 / (width / BLOCK), by * 160 / (height / BLOCK));
                let px = [
                    (40 + gx + (h & 0x1F) as usize) as u8,
                    (40 + gy + ((h >> 5) & 0x1F) as usize) as u8,
                    (60 + ((h >> 10) & 0x3F) as usize) as u8,
                ];
                for y in 0..BLOCK {
                    for x in 0..BLOCK {
                        let o = ((by * BLOCK + y) * width + bx * BLOCK + x) * 4;
                        bytes[o..o + 3].copy_from_slice(&px);
                    }
                }
            }
        }
        Ok(SQFrame::new(
            width,
            height,
            SQFramePixelFormat::Rgba8,
            SQFrameColorSpace::Rec709,
            Time::new(index as i64, 30),
            Arc::new(MemoryFrame { bytes, bytes_per_row: width * 4 }),
        ))
    }
}

/// `ffprobe` / `ffmpeg` of the FFmpeg build the shim was linked against.
fn tool(name: &str) -> Option<PathBuf> {
    let root = std::env::var_os("SQ_FFMPEG").map(PathBuf::from)?;
    let exe = root.join("bin").join(name);
    (exe.exists() || exe.with_extension("exe").exists()).then_some(exe)
}

fn settings(case: &Case) -> ExportSettings {
    let mut s = ExportSettings::default();
    s.video.codec = case.codec;
    s.video.width = case.w as i64;
    s.video.height = case.h as i64;
    s.video.frame_duration = Time::new(1, 30);
    s.video.hardware_encoding = case.hardware;
    s.video.keyframe_interval = 30;
    s.video.bitrate = BitrateMode::Average(case.kbps * 1000);
    s.video.set_bitrate_kind(if case.cbr { BitrateKind::Cbr } else { BitrateKind::Vbr });
    if case.ten_bit {
        s.video.profile = VideoProfile::Main10;
    }
    s.audio.enabled = false;
    s
}

fn ffprobe(path: &Path, args: &[&str]) -> serde_json::Value {
    let out = Command::new(tool("ffprobe").unwrap())
        .args(["-v", "error", "-of", "json"])
        .args(args)
        .arg(path)
        .output()
        .unwrap();
    serde_json::from_slice(&out.stdout).unwrap()
}

/// A string or a number of an ffprobe entry, as text.
fn text(v: &serde_json::Value, key: &str) -> String {
    v[key].as_str().map(str::to_string).or_else(|| v[key].as_f64().map(|n| n.to_string())).unwrap_or_default()
}

fn number(v: &serde_json::Value, key: &str) -> f64 {
    text(v, key).parse().unwrap_or(0.0)
}

struct Case {
    name: &'static str,
    codec: VideoCodec,
    ten_bit: bool,
    kbps: i64,
    cbr: bool,
    w: usize,
    h: usize,
    /// 30 pictures per second, so the file lasts `frames / 30` seconds.
    frames: usize,
    hardware: bool,
    /// How far the file's bitrate may be from the target (a fraction).
    tolerance: f64,
}

impl Case {
    fn kind(&self) -> ProbeKind {
        ProbeKind { hevc: self.codec == VideoCodec::Hevc, ten_bit: self.ten_bit, hardware: self.hardware }
    }
}

fn run(case: &Case, probe_of: &Probe) {
    // One folder per case: the tests run in parallel and each removes its folder at the end (a shared one made the other
    // test's file vanish mid-write: "finish: trailer: No such file or directory").
    let dir = std::env::temp_dir().join(format!("sq-encode-proof-{}-{}", std::process::id(), case.name));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(format!("{}.mp4", case.name));
    let s = settings(case);
    let encoder = FfmpegExportEncoder::new();
    encoder
        .export(
            &mut Noise { w: case.w, h: case.h, frames: case.frames },
            None,
            &s,
            &path,
            &CancelToken::new(),
            &mut |_| {},
        )
        .unwrap();
    let used = encoder.last_video_encoder();
    eprintln!("{}: encoder {used}, {} bytes", case.name, std::fs::metadata(&path).unwrap().len());
    assert_eq!(used, probe_of.name, "{}: the export used another encoder than the probe", case.name);

    let info = ffprobe(
        &path,
        &[
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name,profile,pix_fmt,codec_tag_string,has_b_frames,nb_frames:format=duration,size",
        ],
    );
    let (stream, format) = (&info["streams"][0], &info["format"]);
    let want_codec = if case.codec == VideoCodec::Hevc { "hevc" } else { "h264" };
    assert_eq!(text(stream, "codec_name"), want_codec, "{}", case.name);
    assert_eq!(text(stream, "pix_fmt"), if case.ten_bit { "yuv420p10le" } else { "yuv420p" }, "{}", case.name);
    if case.ten_bit {
        assert_eq!(text(stream, "profile"), "Main 10", "{}", case.name);
    }
    if case.codec == VideoCodec::Hevc {
        assert_eq!(text(stream, "codec_tag_string"), "hvc1", "{}", case.name);
    }
    assert_eq!(number(stream, "nb_frames") as usize, case.frames, "{}", case.name);
    let duration = number(format, "duration");
    let want = case.frames as f64 / 30.0;
    assert!((duration - want).abs() < 0.05, "{}: duration {duration} against {want}", case.name);
    let bits = number(format, "size") * 8.0 / duration;
    let target = case.kbps as f64 * 1e3;
    eprintln!(
        "{}: {:.2} Mbit/s for a {:.2} target, has_b_frames {}",
        case.name,
        bits / 1e6,
        target / 1e6,
        text(stream, "has_b_frames")
    );
    assert!((bits - target).abs() <= case.tolerance * target, "{}: {bits} bit/s against {target}", case.name);
    // The measured B-frame ability is what the file shows.
    assert_eq!(
        number(stream, "has_b_frames") > 0.0,
        probe_of.caps.b_frames,
        "{}: B-frames against the probe",
        case.name
    );

    // Decoded back: no error line, and every picture arrives.
    let decode = Command::new(tool("ffmpeg").unwrap())
        .args(["-v", "error", "-i"])
        .arg(&path)
        .args(["-f", "null", "-"])
        .output()
        .unwrap();
    assert!(
        decode.status.success() && decode.stderr.is_empty(),
        "{}: {}",
        case.name,
        String::from_utf8_lossy(&decode.stderr)
    );
    let counted =
        ffprobe(&path, &["-count_frames", "-select_streams", "v:0", "-show_entries", "stream=nb_read_frames"]);
    assert_eq!(number(&counted["streams"][0], "nb_read_frames") as usize, case.frames, "{}", case.name);
    let _ = std::fs::remove_dir_all(&dir);
}

fn ready() -> bool {
    if !shim::AVAILABLE || tool("ffprobe").is_none() || tool("ffmpeg").is_none() {
        eprintln!("skipped: FFmpeg is not linked or SQ_FFMPEG has no ffprobe / ffmpeg");
        return false;
    }
    true
}

#[test]
fn hardware_exports_of_a_10_second_1080p_sequence_hold_codec_profile_bitrate_and_decode_clean() {
    if !ready() {
        return;
    }
    let hw = |name, codec, ten_bit, kbps, cbr| Case {
        name,
        codec,
        ten_bit,
        kbps,
        cbr,
        w: 1920,
        h: 1080,
        frames: 300,
        hardware: true,
        tolerance: 0.15,
    };
    let cases = [
        hw("h264-8m", VideoCodec::H264, false, 8000, false),
        hw("h264-20m", VideoCodec::H264, false, 20_000, false),
        hw("h264-8m-cbr", VideoCodec::H264, false, 8000, true),
        hw("hevc-8m", VideoCodec::Hevc, false, 8000, false),
        hw("hevc10-8m", VideoCodec::Hevc, true, 8000, false),
    ];
    // What this computer's encoders answered for every kind of file the sheet can ask for (the table of the report).
    for hardware in [true, false] {
        for (hevc, ten_bit) in [(false, false), (true, false), (true, true)] {
            let kind = ProbeKind { hevc, ten_bit, hardware };
            eprintln!("probe {kind:?} -> {:?}", probe(kind));
        }
    }
    let only = std::env::var("SQ_PROOF_ONLY").unwrap_or_default();
    for case in cases.into_iter().filter(|c| only.is_empty() || c.name.contains(only.as_str())) {
        let Some(found) = probe(case.kind()).filter(|p| p.caps.hardware) else {
            eprintln!("skipped {}: this computer has no hardware encoder for it", case.name);
            continue;
        };
        if case.ten_bit && !found.caps.ten_bit {
            eprintln!("skipped {}: {} does not take 10-bit here", case.name, found.name);
            continue;
        }
        run(&case, &found);
    }
}

/// The profile the sheet shows is the profile of the file: Baseline, Main and High through the hardware encoder of this
/// computer and through its software one (they all wrote Main or the encoder's default before the profile was passed on).
#[test]
fn the_h264_profile_of_the_sheet_is_the_profile_of_the_file() {
    if !ready() {
        return;
    }
    for hardware in [true, false] {
        let case = Case {
            name: "profile",
            codec: VideoCodec::H264,
            ten_bit: false,
            kbps: 4000,
            cbr: false,
            w: 1280,
            h: 720,
            frames: 90,
            hardware,
            tolerance: 1.0,
        };
        let Some(found) = probe(case.kind()) else { continue };
        if found.caps.hardware != hardware || !found.caps.profile {
            eprintln!(
                "skipped hardware {hardware}: the encoder here is {} (profile {})",
                found.name, found.caps.profile
            );
            continue;
        }
        let dir = std::env::temp_dir().join(format!("sq-encode-profile-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for profile in [VideoProfile::Baseline, VideoProfile::Main, VideoProfile::High] {
            let path = dir.join(format!("{hardware}-{profile:?}.mp4"));
            let mut s = settings(&case);
            s.video.profile = profile;
            let encoder = FfmpegExportEncoder::new();
            let source = &mut Noise { w: case.w, h: case.h, frames: case.frames };
            encoder.export(source, None, &s, &path, &CancelToken::new(), &mut |_| {}).unwrap();
            assert_eq!(encoder.last_video_encoder(), found.name, "{profile:?}");
            let info = ffprobe(&path, &["-select_streams", "v:0", "-show_entries", "stream=profile,has_b_frames"]);
            let stream = &info["streams"][0];
            let got = text(stream, "profile");
            eprintln!("{} {profile:?}: ffprobe says {got}, has_b_frames {}", found.name, text(stream, "has_b_frames"));
            let want: &[&str] = match profile {
                VideoProfile::Baseline => &["Baseline", "Constrained Baseline"],
                VideoProfile::Main => &["Main"],
                _ => &["High"],
            };
            assert!(want.contains(&got.as_str()), "{} asked for {profile:?}, the file is {got}", found.name);
            if profile == VideoProfile::Baseline {
                assert_eq!(number(stream, "has_b_frames"), 0.0, "{}: Baseline with B-frames", found.name);
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// The software encoders of the LGPL builds (OpenH264 for H.264, Kvazaar for HEVC) honor the bitrate and write clean files.
#[test]
fn software_exports_hold_the_bitrate_and_decode_clean() {
    if !ready() {
        return;
    }
    let sw = |name, codec, kbps| Case {
        name,
        codec,
        ten_bit: false,
        kbps,
        cbr: false,
        w: 640,
        h: 360,
        frames: 90,
        hardware: false,
        tolerance: 0.30,
    };
    for case in [sw("sw-h264-1m", VideoCodec::H264, 1000), sw("sw-hevc-1m", VideoCodec::Hevc, 1000)] {
        let Some(found) = probe(case.kind()) else { continue };
        if !["libopenh264", "libkvazaar", "libx264", "libx265"].contains(&found.name.as_str()) {
            eprintln!("skipped {}: the software encoder here is {}", case.name, found.name);
            continue;
        }
        run(&case, &found);
    }
}
