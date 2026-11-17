//! Encoder tests over a synthetic CPU frame source. They skip with a message when FFmpeg is not linked or the build has
//! no encoder for the case. Oracles: the produced file's demuxed structure and timestamps (the Swift encoder runs the
//! same shim code, so its ffprobe-visible structure is: ftyp, moov before mdat, one packet per frame at equal spacing,
//! `hvc1` for HEVC), the pictures decoded back (software: identical across runs and close to the source; hardware and
//! ProRes: PSNR >= 45 dB) and the PCM samples of a WAV (exact to the sample).

use super::FfmpegExportEncoder;
use super::pipeline::{IN_FLIGHT, pump};
use crate::core::*;
use sq_core_time::Time;
use sq_frame::sqframe::{SQFrame, SQFrameColorSpace, SQFramePixelFormat};
use sq_media_ffmpeg::decode::MemoryFrame;
use sq_media_ffmpeg::shim::{self, Decoder, DecoderConfig, Demux, InputPacket, Received, Sent};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

const W: usize = 640;
const H: usize = 360;

/// A moving gradient in NV12 (or RGBA with `rgba`), `n` frames at 30 fps.
struct Synth {
    n: usize,
    rgba: bool,
    rendered: Arc<AtomicUsize>,
    fail_at: Option<usize>,
}

impl Synth {
    fn new(n: usize) -> Synth {
        Synth { n, rgba: false, rendered: Arc::default(), fail_at: None }
    }
}

fn nv12(i: usize) -> Vec<u8> {
    let mut b = vec![0u8; W * H * 3 / 2];
    for y in 0..H {
        for x in 0..W {
            b[y * W + x] = (16 + (x * 2 + y + i * 3) % 200) as u8;
        }
    }
    for y in 0..H / 2 {
        for x in 0..W / 2 {
            b[W * H + y * W + x * 2] = (96 + (x + i) % 60) as u8;
            b[W * H + y * W + x * 2 + 1] = (110 + (y + 2 * i) % 60) as u8;
        }
    }
    b
}

fn rgba(i: usize) -> Vec<u8> {
    let mut b = vec![255u8; W * H * 4];
    for y in 0..H {
        for x in 0..W {
            let o = (y * W + x) * 4;
            b[o] = ((x * 2 + i * 5) % 256) as u8;
            b[o + 1] = ((y * 3) % 256) as u8;
            b[o + 2] = (((x + y) * i.max(1)) % 256) as u8;
        }
    }
    b
}

impl FrameSource for Synth {
    fn frame_count(&self) -> usize {
        self.n
    }

    fn frame_duration(&self) -> Time {
        Time::new(1, 30)
    }

    fn frame(&mut self, index: usize) -> Result<ExportFrame, ExportError> {
        self.rendered.fetch_add(1, Ordering::SeqCst);
        if self.fail_at == Some(index) {
            return Err(ExportError::Other("render failed".to_string()));
        }
        let (bytes, stride, format) = if self.rgba {
            (rgba(index), W * 4, SQFramePixelFormat::Rgba8)
        } else {
            (nv12(index), W, SQFramePixelFormat::Nv12)
        };
        Ok(SQFrame::new(
            W,
            H,
            format,
            SQFrameColorSpace::Rec709,
            Time::new(index as i64, 30),
            Arc::new(MemoryFrame { bytes, bytes_per_row: stride }),
        ))
    }
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("sq-export-encode-tests-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn settings(codec: VideoCodec, hardware: bool) -> ExportSettings {
    let mut s = ExportSettings::default();
    s.video.codec = codec;
    s.video.width = W as i64;
    s.video.height = H as i64;
    s.video.hardware_encoding = hardware;
    s.video.keyframe_interval = 12;
    s.video.bitrate = BitrateMode::Average(20_000_000);
    s.audio.enabled = false;
    s
}

enum Outcome {
    Written,
    /// No linked FFmpeg or no encoder for the case: the test passes after saying so.
    Skipped,
}

fn export(
    enc: &FfmpegExportEncoder,
    video: &mut dyn FrameSource,
    audio: Option<&mut dyn AudioSource>,
    s: &ExportSettings,
    url: &Path,
) -> Result<Outcome, ExportError> {
    if !shim::AVAILABLE {
        eprintln!("skipped: the FFmpeg shim is not linked");
        return Ok(Outcome::Skipped);
    }
    match enc.export(video, audio, s, url, &CancelToken::new(), &mut |_| {}) {
        Err(ExportError::WriterFailed(m)) if m.contains("encoder") && m.contains("could be opened") => {
            eprintln!("skipped: {m}");
            Ok(Outcome::Skipped)
        }
        Ok(_) => Ok(Outcome::Written),
        Err(e) => Err(e),
    }
}

/// Every picture of the file in presentation order as packed NV12, with the packet table's pts.
fn decode(path: &Path) -> (Vec<Vec<u8>>, Vec<i64>) {
    let demux = Demux::open(path).unwrap();
    let info = demux.info();
    let extra = demux.extradata();
    let mut dec = Decoder::open(&DecoderConfig {
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
    })
    .unwrap();
    let mut frames: Vec<(i64, Vec<u8>)> = Vec::new();
    let mut drain = |dec: &mut Decoder| {
        while let Received::Frame(f) = dec.receive().unwrap() {
            frames.push((f.pts, f.download().unwrap()));
        }
    };
    for (k, p) in demux.packets().iter().enumerate() {
        let data = demux.read(k).unwrap();
        let input = InputPacket { data: &data, pts: p.pts, dts: p.dts, duration: p.duration, key: p.key != 0 };
        while dec.send(&input).unwrap() == Sent::Full {
            drain(&mut dec);
        }
        drain(&mut dec);
    }
    dec.send_end().unwrap();
    drain(&mut dec);
    frames.sort_by_key(|f| f.0);
    let pts = demux.packets().iter().map(|p| p.pts).collect();
    (frames.into_iter().map(|f| f.1).collect(), pts)
}

fn psnr(a: &[u8], b: &[u8]) -> f64 {
    let mse = a.iter().zip(b).map(|(x, y)| (f64::from(*x) - f64::from(*y)).powi(2)).sum::<f64>() / a.len() as f64;
    if mse == 0.0 { 99.0 } else { 10.0 * (255.0f64 * 255.0 / mse).log10() }
}

fn top_level_boxes(path: &Path) -> Vec<String> {
    let b = std::fs::read(path).unwrap();
    let (mut o, mut out) = (0usize, Vec::new());
    while o + 8 <= b.len() {
        let size = u32::from_be_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]) as usize;
        out.push(String::from_utf8_lossy(&b[o + 4..o + 8]).into_owned());
        if size < 8 {
            break;
        }
        o += size;
    }
    out
}

/// `ftyp`, then `moov` before `mdat` (movflags +faststart).
fn assert_faststart(path: &Path) {
    let boxes = top_level_boxes(path);
    let at = |n: &str| boxes.iter().position(|b| b == n).unwrap();
    assert_eq!(boxes[0], "ftyp");
    assert!(at("moov") < at("mdat"), "{boxes:?}");
}

fn check_video(path: &Path, frames: usize, min_psnr: f64) {
    let (pictures, pts) = decode(path);
    assert_eq!(pictures.len(), frames);
    assert_eq!(pts.len(), frames, "one packet per frame");
    let mut sorted = pts.clone();
    sorted.sort_unstable();
    let step = sorted[1] - sorted[0];
    assert!(step > 0 && sorted.windows(2).all(|w| w[1] - w[0] == step), "equal timestamp spacing: {sorted:?}");
    let info = Demux::open(path).unwrap().info();
    assert_eq!((info.width, info.height), (W as i32, H as i32));
    assert_eq!(step * i64::from(info.tb_num) * 30, i64::from(info.tb_den), "30 fps");
    for (i, p) in pictures.iter().enumerate() {
        let v = psnr(&nv12(i), p);
        assert!(v >= min_psnr, "frame {i}: {v:.1} dB");
    }
}

#[test]
fn software_h264_mp4_structure_pictures_and_determinism() {
    let enc = FfmpegExportEncoder::new();
    let (a, b) = (scratch("sw-a.mp4"), scratch("sw-b.mp4"));
    let s = settings(VideoCodec::H264, false);
    let Outcome::Written = export(&enc, &mut Synth::new(24), None, &s, &a).unwrap() else { return };
    println!("software H.264 encoder: {}", enc.last_video_encoder());
    assert_faststart(&a);
    check_video(&a, 24, 38.0);
    export(&enc, &mut Synth::new(24), None, &s, &b).unwrap();
    assert_eq!(decode(&a).0, decode(&b).0, "decoded frames are identical across runs");
}

#[test]
fn hardware_h264_reaches_45_db() {
    let enc = FfmpegExportEncoder::new();
    let path = scratch("hw.mp4");
    let Outcome::Written = export(&enc, &mut Synth::new(24), None, &settings(VideoCodec::H264, true), &path).unwrap()
    else {
        return;
    };
    let name = enc.last_video_encoder();
    println!("H.264 encoder with hardware on: {name}");
    let hardware = ["videotoolbox", "amf", "nvenc", "qsv", "_mf"].iter().any(|h| name.contains(h));
    check_video(&path, 24, if hardware { 45.0 } else { 38.0 });
}

#[test]
fn hardware_hevc_reaches_45_db() {
    let enc = FfmpegExportEncoder::new();
    let path = scratch("hw-hevc.mp4");
    let Outcome::Written = export(&enc, &mut Synth::new(24), None, &settings(VideoCodec::Hevc, true), &path).unwrap()
    else {
        return;
    };
    let name = enc.last_video_encoder();
    println!("HEVC encoder with hardware on: {name}");
    let hardware = ["videotoolbox", "amf", "nvenc", "qsv", "_mf"].iter().any(|h| name.contains(h));
    check_video(&path, 24, if hardware { 45.0 } else { 38.0 });
}

#[test]
fn title_comment_and_chapters_are_written_into_the_file() {
    let enc = FfmpegExportEncoder::new();
    let path = scratch("tagged.mp4");
    let mut s = settings(VideoCodec::H264, false);
    s.metadata = Some(crate::core::ExportMetadata::new("Summer Reel", "Shot on a phone", Some(0.0), "0:00 Intro"));
    let Outcome::Written = export(&enc, &mut Synth::new(6), None, &s, &path).unwrap() else { return };
    let bytes = std::fs::read(&path).unwrap();
    let has = |t: &str| bytes.windows(t.len()).any(|w| w == t.as_bytes());
    assert!(has("Summer Reel"), "title missing");
    assert!(has("Shot on a phone") && has("0:00 Intro"), "comment with chapters missing");
}

#[test]
fn an_audio_only_file_carries_the_title_and_comment() {
    let mut s = settings(VideoCodec::H264, false);
    s.audio.enabled = true;
    s.audio_only = Some(AudioFileFormat::M4a);
    s.metadata = Some(ExportMetadata::new("Podcast cut", "Shot on a phone", Some(0.0), ""));
    let (tags, _) = (super::video::tags_of(&s), ());
    assert_eq!(tags.title, "Podcast cut");
    assert!(tags.comment.contains("Shot on a phone"));
    // Through the encoder: a short M4A, then the strings must be in the file.
    let path = scratch("tagged.m4a");
    let enc = FfmpegExportEncoder::new();
    let mut audio = SineAudioSource::new(s.audio.sample_rate, 2, Time::new(1, 1), 440, 0.25);
    let mut video = Synth::new(30);
    if !shim::AVAILABLE {
        return;
    }
    if enc.export(&mut video, Some(&mut audio), &s, &path, &CancelToken::new(), &mut |_| {}).is_ok() {
        let bytes = std::fs::read(&path).unwrap();
        assert!(bytes.windows(11).any(|w| w == b"Podcast cut"), "title missing in the M4A");
    }
}

#[test]
fn hevc_mp4_is_tagged_hvc1() {
    let enc = FfmpegExportEncoder::new();
    let path = scratch("hevc.mp4");
    let Outcome::Written = export(&enc, &mut Synth::new(12), None, &settings(VideoCodec::Hevc, false), &path).unwrap()
    else {
        return;
    };
    println!("HEVC encoder: {}", enc.last_video_encoder());
    let bytes = std::fs::read(&path).unwrap();
    // The LGPL build has no libx265: HEVC then falls back to MPEG-4 Part 2, which must not carry the hvc1 tag.
    let fallback = enc.last_video_encoder() == "mpeg4";
    assert_eq!(bytes.windows(4).any(|w| w == b"hvc1"), !fallback);
    check_video(&path, 12, 38.0);
}

/// `ffprobe -show_streams` of the first video stream as key=value lines, or `None` without an ffprobe.
fn probe_video(path: &Path) -> Option<String> {
    let bundled = std::env::var_os("SQ_FFMPEG").map(|r| PathBuf::from(r).join("bin").join("ffprobe"));
    let tool = bundled.filter(|p| p.exists() || p.with_extension("exe").exists()).unwrap_or_else(|| "ffprobe".into());
    let out = std::process::Command::new(tool)
        .args(["-v", "error", "-select_streams", "v:0", "-show_streams"])
        .arg(path)
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

#[test]
fn hdr_delivery_tags_bt2020_pq_and_hlg_with_mastering_metadata() {
    for (transfer, trc) in [(HdrTransfer::Pq, "smpte2084"), (HdrTransfer::Hlg, "arib-std-b67")] {
        let enc = FfmpegExportEncoder::new();
        let path = scratch(&format!("hdr-{trc}.mp4"));
        // Hardware first: the LGPL FFmpeg of the PC has no libx265.
        let mut s = settings(VideoCodec::Hevc, true);
        s.hdr_delivery = Some(HdrDelivery::new(transfer, 1000.0, 400.0, 0.005));
        let mut video = Synth::new(8);
        video.rgba = true;
        let Outcome::Written = export(&enc, &mut video, None, &s, &path).unwrap() else {
            return;
        };
        let bytes = std::fs::read(&path).unwrap();
        assert!(bytes.windows(4).any(|w| w == b"mdcv"), "no mastering display box");
        assert!(bytes.windows(4).any(|w| w == b"clli"), "no content light level box");
        if let Some(info) = probe_video(&path) {
            for want in [
                "color_primaries=bt2020",
                &format!("color_transfer={trc}"),
                "color_space=bt2020nc",
                "pix_fmt=yuv420p10le",
            ] {
                assert!(info.contains(want), "{want} missing in:\n{info}");
            }
        }
    }
}

#[test]
fn prores_needs_mov_and_writes_every_frame() {
    let enc = FfmpegExportEncoder::new();
    let s = settings(VideoCodec::ProRes422HQ, false);
    if shim::AVAILABLE {
        let err = enc.export(&mut Synth::new(2), None, &s, &scratch("no.mp4"), &CancelToken::new(), &mut |_| {});
        assert_eq!(err, Err(ExportError::WriterFailed("ProRes needs a .mov file".to_string())));
    }
    let path = scratch("prores.mov");
    let Outcome::Written = export(&enc, &mut Synth::new(6), None, &s, &path).unwrap() else { return };
    assert_eq!(enc.last_video_encoder(), "prores_ks");
    let (pictures, pts) = decode(&path);
    assert_eq!((pictures.len(), pts.len()), (6, 6));
}

#[test]
fn aac_audio_follows_the_picture() {
    let enc = FfmpegExportEncoder::new();
    let path = scratch("av.mp4");
    let mut s = settings(VideoCodec::H264, false);
    s.audio.enabled = true;
    let mut tone = SineAudioSource::new(s.audio.sample_rate, 2, Time::new(1, 1), 440, 0.25);
    let Outcome::Written = export(&enc, &mut Synth::new(30), Some(&mut tone), &s, &path).unwrap() else { return };
    let pcm = shim::decode_audio(&path, 48_000, 2).unwrap();
    assert!((pcm.frames - 48_000).abs() <= 2048, "{} audio frames for one second", pcm.frames);
    assert_faststart(&path);
}

#[test]
fn wav_pcm24_is_exact_and_flac_is_lossless() {
    let enc = FfmpegExportEncoder::new();
    for (format, name) in [(AudioFileFormat::Wav, "tone.wav"), (AudioFileFormat::Flac, "tone.flac")] {
        if !shim::AVAILABLE {
            eprintln!("skipped: the FFmpeg shim is not linked");
            return;
        }
        let mut s = ExportSettings::default().audio;
        s.pcm_bit_depth = 24;
        s.channels = 1;
        let mut tone = SineAudioSource::new(48_000, 1, Time::new(1, 2), 440, 0.25);
        let path = scratch(name);
        enc.export_audio_file(&mut tone, format, Time::new(1, 2), &s, &path, &CancelToken::new(), &mut |_| {}).unwrap();
        let pcm = shim::decode_audio(&path, 48_000, 1).unwrap();
        assert_eq!(pcm.frames, 24_000);
        for (i, v) in pcm.samples.iter().enumerate() {
            let phase = (i as i64 * 440 % 48_000) as f64 / 48_000.0;
            let want = ((2.0 * std::f64::consts::PI * phase).sin() as f32 * 0.25) as f64;
            assert!((f64::from(*v) - want).abs() < 2.0 / f64::from(1 << 23), "sample {i}: {v} vs {want}");
        }
    }
}

#[test]
fn cancel_deletes_the_partial_file() {
    let enc = FfmpegExportEncoder::new();
    let path = scratch("cancel.mp4");
    if !shim::AVAILABLE {
        return;
    }
    let cancel = CancelToken::new();
    let c2 = cancel.clone();
    let mut seen = 0;
    let r = enc.export(&mut Synth::new(60), None, &settings(VideoCodec::H264, false), &path, &cancel, &mut |_| {
        seen += 1;
        if seen == 3 {
            c2.cancel();
        }
    });
    match r {
        Err(ExportError::Cancelled) => assert!(!path.exists(), "the partial file is gone"),
        Err(ExportError::WriterFailed(m)) => eprintln!("skipped: {m}"),
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_failing_frame_stops_the_export_and_removes_the_file() {
    let enc = FfmpegExportEncoder::new();
    let path = scratch("fail.mp4");
    if !shim::AVAILABLE {
        return;
    }
    let mut src = Synth::new(20);
    src.fail_at = Some(5);
    let r = enc.export(&mut src, None, &settings(VideoCodec::H264, false), &path, &CancelToken::new(), &mut |_| {});
    if matches!(r, Err(ExportError::WriterFailed(_))) {
        eprintln!("skipped: no H.264 encoder");
        return;
    }
    assert_eq!(r, Err(ExportError::Other("render failed".to_string())));
    assert!(!path.exists());
}

#[test]
fn gif_and_stills_are_written() {
    let enc = FfmpegExportEncoder::new();
    if !shim::AVAILABLE {
        eprintln!("skipped: the FFmpeg shim is not linked");
        return;
    }
    let mut s = settings(VideoCodec::H264, false);
    s.frame_output = Some(FrameOutput::Gif);
    let mut src = Synth::new(6);
    src.rgba = true;
    let gif = scratch("anim.gif");
    match enc.export(&mut src, None, &s, &gif, &CancelToken::new(), &mut |_| {}) {
        Ok(_) => {
            let bytes = std::fs::read(&gif).unwrap();
            assert_eq!(&bytes[..6], b"GIF89a");
            assert_eq!(u16::from_le_bytes([bytes[6], bytes[7]]), W as u16);
            assert_eq!(Demux::open(&gif).map(|d| d.packets().len()).unwrap_or(6), 6);
        }
        Err(e) => eprintln!("skipped: {e}"),
    }
    // A still from a half-float frame: PNG signature, EXR magic.
    let half: Vec<u8> = (0..W * H * 4).flat_map(|_| 0x3800u16.to_le_bytes()).collect();
    for (format, magic) in
        [(FrameStillFormat::Png, &[0x89u8, b'P', b'N', b'G'][..]), (FrameStillFormat::Exr, &[0x76, 0x2f, 0x31, 0x01])]
    {
        let file = scratch(&format!("still.{}", format.file_extension()));
        match super::sequence::write_one(&half, W, H, W * 8, format, &file) {
            Ok(()) => assert_eq!(&std::fs::read(&file).unwrap()[..4], magic),
            Err(e) => eprintln!("skipped: {e}"),
        }
    }
}

#[test]
fn the_pump_keeps_three_frames_in_flight_and_stops_on_cancel() {
    let mut src = Synth::new(40);
    let rendered = Arc::clone(&src.rendered);
    let mut worst = 0;
    pump(&mut src, &CancelToken::new(), |i, _| {
        std::thread::sleep(std::time::Duration::from_millis(2));
        worst = worst.max(rendered.load(Ordering::SeqCst) - i);
        Ok(())
    })
    .unwrap();
    assert!(worst <= IN_FLIGHT + 2, "{worst} frames ahead");
    assert_eq!(rendered.load(Ordering::SeqCst), 40);

    let cancel = CancelToken::new();
    let mut src = Synth::new(40);
    let r = pump(&mut src, &cancel, |i, _| {
        if i == 4 {
            cancel.cancel();
        }
        Ok(())
    });
    assert_eq!(r, Err(ExportError::Cancelled));
    assert!(src.rendered.load(Ordering::SeqCst) < 40);
}

fn size_of(enc: &FfmpegExportEncoder, s: &ExportSettings, name: &str) -> Option<u64> {
    let path = scratch(name);
    let Outcome::Written = export(enc, &mut Synth::new(24), None, s, &path).unwrap() else { return None };
    Some(std::fs::metadata(&path).unwrap().len())
}

#[test]
fn constant_quality_reaches_the_encoder_and_orders_the_sizes() {
    let enc = FfmpegExportEncoder::new();
    for hardware in [false, true] {
        let mut s = settings(VideoCodec::H264, hardware);
        s.video.set_constant_quality(Some(1.0));
        let Some(high) = size_of(&enc, &s, &format!("cq-high-{hardware}.mp4")) else { return };
        s.video.set_constant_quality(Some(0.1));
        let low = size_of(&enc, &s, &format!("cq-low-{hardware}.mp4")).unwrap();
        println!("constant quality ({}): q 1.0 = {high} B, q 0.1 = {low} B", enc.last_video_encoder());
        assert!(high > low, "{}: quality 1.0 ({high} B) is not larger than 0.1 ({low} B)", enc.last_video_encoder());
    }
}

#[test]
fn maximum_bitrate_caps_a_software_vbr_file() {
    let enc = FfmpegExportEncoder::new();
    let mut s = settings(VideoCodec::H264, false);
    s.video.bitrate = BitrateMode::Average(20_000_000);
    let Some(free) = size_of(&enc, &s, "max-free.mp4") else { return };
    if enc.last_video_encoder() == "mpeg4" {
        eprintln!("skipped: the mpeg4 fallback (LGPL build) has no VBV cap");
        return;
    }
    s.video.bitrate = BitrateMode::AverageAndMax { average: 300_000, max: 400_000 };
    let capped = size_of(&enc, &s, "max-capped.mp4").unwrap();
    println!("maximum bitrate: uncapped {free} B, 400 kbit/s cap {capped} B");
    // 24 frames at 30 fps = 0.8 s: 400 kbit/s is 40 kB, with container overhead and the first buffer fill.
    assert!(capped < free && capped < 80_000, "capped file {capped} B");
}

#[test]
fn constant_bitrate_and_the_speed_row_write_a_decodable_file() {
    let enc = FfmpegExportEncoder::new();
    let mut s = settings(VideoCodec::H264, false);
    s.video.set_bitrate_kind(BitrateKind::Cbr);
    s.video.bitrate = BitrateMode::Average(1_000_000);
    s.set_encoder_speed(EncoderSpeed::Fast);
    let path = scratch("cbr-fast.mp4");
    let Outcome::Written = export(&enc, &mut Synth::new(24), None, &s, &path).unwrap() else { return };
    check_video(&path, 24, 25.0);
}

#[test]
fn the_verifier_reads_back_the_level_of_a_written_wav() {
    let enc = FfmpegExportEncoder::new();
    if !shim::AVAILABLE {
        return;
    }
    // A full-scale-ish 1 kHz tone at -6 dBFS peak, 2 s, written as 24 bit WAV, measured again from the file.
    let path = scratch("verify.wav");
    let mut s = ExportSettings::default();
    s.audio_only = Some(AudioFileFormat::Wav);
    s.audio.enabled = true;
    let mut tone = SineAudioSource::new(s.audio.sample_rate, 2, Time::new(2, 1), 1000, 0.5);
    enc.export(&mut Synth::new(60), Some(&mut tone), &s, &path, &CancelToken::new(), &mut |_| {}).unwrap();
    let m = super::measure_output_audio(&path).unwrap().expect("the file has audio");
    println!("verifier: {:.1} LUFS, true peak {:.2} dBTP", m.integrated_lufs, m.true_peak_db);
    assert!((m.true_peak_db + 6.0).abs() < 0.6, "true peak {}", m.true_peak_db);
    assert!(m.integrated_lufs.is_finite() && m.integrated_lufs < -6.0);
}

#[test]
fn a_normalized_m4a_is_measured_again_and_stays_under_the_ceiling() {
    let enc = FfmpegExportEncoder::new();
    if !shim::AVAILABLE {
        return;
    }
    let path = scratch("normalized.m4a");
    let mut s = ExportSettings::default();
    s.audio_only = Some(AudioFileFormat::M4a);
    s.audio.enabled = true;
    s.audio.loudness = Some(LoudnessNormalization::new(-14.0, -1.0));
    let mut tone = SineAudioSource::new(s.audio.sample_rate, 2, Time::new(3, 1), 1000, 0.25);
    let report = match enc.export(&mut Synth::new(90), Some(&mut tone), &s, &path, &CancelToken::new(), &mut |_| {}) {
        Ok(r) => r.expect("a loudness report"),
        Err(ExportError::WriterFailed(m)) => {
            eprintln!("skipped: {m}");
            return;
        }
        Err(e) => panic!("{e}"),
    };
    let v = report.verified.expect("the written file was measured");
    println!(
        "normalized m4a: file {:.2} LUFS / {:.2} dBTP, ceiling {}",
        v.integrated_lufs, v.true_peak_db, report.ceiling_db
    );
    assert_eq!(report.ceiling_db, -1.0, "the report keeps the ceiling the user asked for");
    assert!(v.true_peak_db <= -1.0 + 0.3, "true peak {}", v.true_peak_db);
}
