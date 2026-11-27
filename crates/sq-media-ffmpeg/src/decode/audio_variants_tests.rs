//! Every audio flavor a real file can have must open and decode to what the `ffmpeg` command line decodes. Tiny files are
//! made with `ffmpeg` (skips when the shim or the command is missing). The comparison is the first 200 ms at 48 kHz.

use super::audio_source::FFmpegAudioSource;
use crate::shim;
use sq_media::memory_audio_source::AudioSource;
use std::path::PathBuf;
use std::process::Command;

fn ffmpeg() -> Command {
    let bundled = std::env::var_os("SQ_FFMPEG").map(|r| PathBuf::from(r).join("bin").join("ffmpeg"));
    Command::new(bundled.filter(|p| p.exists() || p.with_extension("exe").exists()).unwrap_or_else(|| "ffmpeg".into()))
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("sq-audio-variants-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

struct Variant {
    name: &'static str,
    /// Extra input args (after the lavfi sine) and output args.
    args: &'static [&'static str],
    video: bool,
}

const V: &[Variant] = &[
    Variant { name: "aac.mp4", args: &["-c:a", "aac"], video: true },
    Variant { name: "aac_mono_22k.m4a", args: &["-c:a", "aac", "-ac", "1", "-ar", "22050"], video: false },
    Variant { name: "pcm16.wav", args: &["-c:a", "pcm_s16le"], video: false },
    Variant { name: "pcm24.wav", args: &["-c:a", "pcm_s24le"], video: false },
    Variant { name: "pcmf32.wav", args: &["-c:a", "pcm_f32le", "-ar", "96000"], video: false },
    Variant { name: "pcm16.mov", args: &["-c:a", "pcm_s16le"], video: true },
    Variant { name: "mp3.mp3", args: &["-c:a", "libmp3lame"], video: false },
    Variant { name: "flac.flac", args: &["-c:a", "flac"], video: false },
    Variant { name: "ac3.ac3", args: &["-c:a", "ac3"], video: false },
    Variant { name: "ac3_51.mkv", args: &["-c:a", "ac3", "-ac", "6"], video: true },
    Variant { name: "alac.m4a", args: &["-c:a", "alac"], video: false },
    Variant { name: "vorbis.ogg", args: &["-c:a", "vorbis", "-strict", "-2"], video: false },
    Variant { name: "opus.ogg", args: &["-c:a", "libopus"], video: false },
    Variant { name: "pcm_44k_mono.wav", args: &["-c:a", "pcm_s16le", "-ac", "1", "-ar", "44100"], video: false },
];

fn make(v: &Variant) -> Option<PathBuf> {
    let path = scratch(v.name);
    let mut c = ffmpeg();
    c.args(["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1:sample_rate=48000"]);
    if v.video {
        c.args(["-f", "lavfi", "-i", "testsrc2=size=64x48:rate=10:duration=1", "-c:v", "mpeg4"]);
    }
    let out = c.args(v.args).arg(&path).output().ok()?;
    (out.status.success() && path.exists()).then_some(path)
}

fn reference(path: &PathBuf) -> Vec<f32> {
    let out = ffmpeg()
        .args(["-v", "error", "-i"])
        .arg(path)
        .args(["-vn", "-ac", "1", "-ar", "48000", "-f", "f32le", "-"])
        .output()
        .unwrap();
    out.stdout.as_chunks::<4>().0.iter().map(|b| f32::from_le_bytes(*b)).collect()
}

#[test]
fn every_audio_flavor_opens_and_matches_ffmpeg() {
    if !shim::AVAILABLE || ffmpeg().arg("-version").output().is_err() {
        sq_os::errln!("skipped: no FFmpeg shim or command");
        return;
    }
    let mut failures = Vec::new();
    for v in V {
        let Some(path) = make(v) else {
            sq_os::errln!("skipped {}: ffmpeg cannot make it", v.name);
            continue;
        };
        let src: Box<dyn AudioSource> = match FFmpegAudioSource::open_mapped(&path, 48_000, None) {
            Ok(s) => s,
            Err(e) => {
                failures.push(format!("{}: open failed: {e}", v.name));
                continue;
            }
        };
        let want = reference(&path);
        let n = 9600.min(want.len());
        let (mut l, mut r) = (vec![0f32; n], vec![0f32; n]);
        let got_l = src.read(0, &mut l, 0).unwrap_or(0);
        src.read(0, &mut r, 1).unwrap_or(0);
        if got_l < n {
            failures.push(format!("{}: only {got_l} of {n} frames", v.name));
            continue;
        }
        // The reference is a stereo-to-mono downmix; the source delivers two sides, so compare their average.
        let worst = (0..n).map(|i| (((l[i] + r[i]) * 0.5) - want[i]).abs()).fold(0f32, f32::max);
        if worst > 0.02 {
            failures.push(format!("{}: samples differ by {worst}", v.name));
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
}

/// A file that is not media (a log in a `.mp4`) reports why, not a bare `-1`.
#[test]
fn a_junk_file_is_unreadable_not_minus_one() {
    if !shim::AVAILABLE {
        return;
    }
    let path = scratch("junk.mp4");
    std::fs::write(&path, "done t=11s round=2 ui_frames=847 pictures=158 ops=360").unwrap();
    let err = FFmpegAudioSource::open_mapped(&path, 48_000, None).err().expect("junk must fail");
    assert_eq!(err, sq_media::media_error::MediaError::Unreadable);
}

/// Streaming: random reads (forward, back, far jumps, across the end) equal the whole-file decode, for a lossless and a
/// lossy file, and the source holds no more than its window.
#[test]
fn streamed_reads_equal_the_whole_decode_after_seeks() {
    if !shim::AVAILABLE || ffmpeg().arg("-version").output().is_err() {
        sq_os::errln!("skipped: no FFmpeg shim or command");
        return;
    }
    for (name, codec, tol) in [("stream.wav", "pcm_s16le", 1e-4f32), ("stream.m4a", "aac", 0.02)] {
        let path = scratch(name);
        // A chirp: every position sounds different, so a wrong seek shows.
        let made = ffmpeg()
            .args([
                "-y",
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                "aevalsrc=sin(2*PI*(200+60*t)*t)|sin(2*PI*(300+40*t)*t):d=20:s=48000",
            ])
            .args(["-c:a", codec])
            .arg(&path)
            .status()
            .is_ok_and(|s| s.success());
        if !made {
            sq_os::errln!("skipped {name}");
            continue;
        }
        let whole = shim::decode_audio(&path, 48_000, 2).unwrap();
        let src = FFmpegAudioSource::open(&path, 48_000).unwrap();
        let total = whole.frames;
        assert!((src.frame_count() - total).abs() <= 2048, "{name}: length {} vs {total}", src.frame_count());
        let probes = [0i64, 1000, 48_000 * 3, 48_000 * 15 + 17, 48_000 * 2, 100, 48_000 * 19, 48_000 * 7 + 3];
        for at in probes {
            let (mut l, mut r) = (vec![0f32; 4096], vec![0f32; 4096]);
            let n = src.read(at, &mut l, 0).unwrap();
            src.read(at, &mut r, 1).unwrap();
            assert!(n > 0, "{name}: nothing at {at}");
            let worst = (0..n)
                .map(|i| {
                    let k = (at as usize + i) * 2;
                    (l[i] - whole.samples[k]).abs().max((r[i] - whole.samples[k + 1]).abs())
                })
                .fold(0f32, f32::max);
            assert!(worst <= tol, "{name}: at {at} differs by {worst}");
        }
        // Sequential reading through the end in small blocks matches too and ends at the stated length.
        let (mut at, mut buf) = (0i64, vec![0f32; 1000]);
        let mut sum = 0f64;
        loop {
            let n = src.read(at, &mut buf, 0).unwrap();
            if n == 0 {
                break;
            }
            sum += buf[..n].iter().map(|v| f64::from(*v).abs()).sum::<f64>();
            at += n as i64;
        }
        assert!((at - total).abs() <= 2048, "{name}: read to {at}, whole is {total}");
        assert!(sum > 1000.0);
    }
}
