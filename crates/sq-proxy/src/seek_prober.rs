// Swift: AVSourceSeekProber.swift (the one FFmpeg prober all systems share; the Mac sample-cursor walk is not needed)
//! The seek prober every system uses: FFmpeg reads the codec and the sync flags of the first video packets. It decodes
//! nothing and never indexes the whole file, so it answers quickly on a 4K camera file.

use crate::proxy_policy::{SourceSeekInfo, SourceSeekProbing};
use crate::proxy_transcoding::ProxyTranscodeError;
use sq_media_ffmpeg::shim;
use std::path::Path;

/// Payload a container that must be read (not a plain mov/mp4) may cost before the probe stops, once 16 packets are in.
const PAYLOAD_BUDGET: i64 = 48 << 20;

/// Reads how a source seeks from its first packets (Swift `AVSourceSeekProber`).
#[derive(Clone, Copy, Debug)]
pub struct FfmpegSeekProber {
    /// How many video packets the walk reads at most.
    pub max_samples: usize,
}

impl Default for FfmpegSeekProber {
    fn default() -> FfmpegSeekProber {
        FfmpegSeekProber { max_samples: SourceSeekInfo::DEFAULT_MAX_SAMPLES }
    }
}

impl SourceSeekProbing for FfmpegSeekProber {
    fn probe(&self, url: &Path) -> Result<SourceSeekInfo, ProxyTranscodeError> {
        let probe = shim::seek_probe(url, self.max_samples, PAYLOAD_BUDGET).map_err(|e| {
            if e.code == shim::STREAM_NOT_FOUND {
                ProxyTranscodeError::NoVideoTrack
            } else {
                ProxyTranscodeError::ReaderFailed(e.to_string())
            }
        })?;
        let four_cc = SourceSeekInfo::four_cc_for_ffmpeg_codec(&probe.codec);
        Ok(SourceSeekInfo::from_sync_flags(&four_cc, probe.keys, self.max_samples))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::ProxyKind;
    use crate::model::test_support::*;
    use crate::proxy_cache::ProxyCache;
    use crate::proxy_policy::{ProxyAutoGenerator, ProxyDecision, ProxyPolicy, SkipReason};
    use crate::proxy_queue::ProxyQueue;
    use sq_core_time::{SequentialIds, Timestamp};
    use std::path::PathBuf;
    use std::process::Command;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    /// The ffmpeg commands that may make clips, best first: SQ_TEST_FFMPEG (a complete one; it brings its own libraries),
    /// the bundled one, the one on PATH. The bundled Linux build has no libx264, the system's has.
    fn ffmpeg_commands() -> Vec<Command> {
        let mut all = Vec::new();
        if let Some(own) = std::env::var_os("SQ_TEST_FFMPEG") {
            let mut command = Command::new(own);
            command.env_remove("LD_LIBRARY_PATH");
            all.push(command);
        }
        let bundled = std::env::var_os("SQ_FFMPEG").map(|r| PathBuf::from(r).join("bin").join("ffmpeg"));
        all.extend(bundled.filter(|p| p.exists() || p.with_extension("exe").exists()).map(Command::new));
        all.push(Command::new("ffmpeg"));
        all
    }

    /// True when clips can be made; prints why not.
    fn ready() -> bool {
        let ok = shim::AVAILABLE
            && ffmpeg_commands().iter_mut().any(|c| c.arg("-version").output().is_ok_and(|o| o.status.success()));
        if !ok {
            eprintln!("skipped: the FFmpeg shim is not linked or no ffmpeg command is available");
        }
        ok
    }

    /// A `size` testsrc clip of `frames` frames at 30 fps encoded with `args`; `None` when no ffmpeg has the encoder.
    fn clip(dir: &TempDir, name: &str, size: &str, frames: u32, args: &[&str]) -> Option<PathBuf> {
        let path = dir.join(name);
        let input = format!("testsrc=size={size}:rate=30");
        ffmpeg_commands().into_iter().find_map(|mut command| {
            let out = command
                .args(["-y", "-v", "error", "-f", "lavfi", "-i", &input, "-frames:v", &frames.to_string()])
                .args(args)
                .arg(&path)
                .output()
                .ok()?;
            (out.status.success() && path.exists()).then(|| path.clone())
        })
    }

    /// A long-GOP clip: H.264 (x264) with a keyframe every 60 frames and B-frames, else MPEG-4 with the same shape.
    fn long_gop(dir: &TempDir, name: &str, size: &str, frames: u32, extra: &[&str]) -> Option<PathBuf> {
        let x264 = ["-c:v", "libx264", "-preset", "ultrafast", "-g", "60", "-bf", "2", "-x264-params", "scenecut=0"];
        let mpeg4 = ["-c:v", "mpeg4", "-g", "60", "-bf", "2", "-sc_threshold", "0"];
        [x264.as_slice(), mpeg4.as_slice()].into_iter().find_map(|enc| {
            let args: Vec<&str> = enc.iter().chain(extra).copied().collect();
            clip(dir, name, size, frames, &args)
        })
    }

    fn decision(path: &Path) -> (SourceSeekInfo, ProxyDecision) {
        let info = FfmpegSeekProber::default().probe(path).unwrap_or_else(|e| panic!("{}: {e:?}", path.display()));
        let decision = ProxyPolicy::default().decide(&info);
        (info, decision)
    }

    #[test]
    fn long_gop_in_every_container_needs_a_proxy() {
        if !ready() {
            return;
        }
        let dir = TempDir::new();
        // A plain mp4 (answered from the header), Matroska and a fragmented mp4 (packets are read).
        let clips = [
            long_gop(&dir, "plain.mp4", "320x180", 150, &[]),
            long_gop(&dir, "long.mkv", "320x180", 150, &[]),
            long_gop(&dir, "frag.mp4", "320x180", 150, &["-movflags", "frag_keyframe+empty_moov"]),
        ];
        for path in clips {
            let path = path.expect("ffmpeg makes a long-GOP clip");
            let (info, decision) = decision(&path);
            assert!(["avc1", "mp4v"].contains(&info.codec_four_cc.as_str()), "{}: {info:?}", path.display());
            assert!(info.max_sync_distance.is_some_and(|d| (50..=60).contains(&d)), "{}: {info:?}", path.display());
            assert_eq!(decision, ProxyDecision::NeedsProxy(ProxyKind::ProxyHalf), "{}", path.display());
        }
    }

    #[test]
    fn intra_only_codecs_are_skipped_as_intra() {
        if !ready() {
            return;
        }
        let dir = TempDir::new();
        let clips = [
            clip(&dir, "prores.mov", "320x180", 60, &["-c:v", "prores_ks", "-profile:v", "3"]),
            clip(&dir, "mjpeg.mov", "320x180", 60, &["-c:v", "mjpeg", "-q:v", "3"]),
            clip(&dir, "mjpeg.mkv", "320x180", 60, &["-c:v", "mjpeg", "-q:v", "3"]),
        ];
        for path in clips {
            let path = path.expect("ffmpeg makes an intra-only clip");
            let (info, decision) = decision(&path);
            assert_eq!(decision, ProxyDecision::Skip(SkipReason::IntraOnlyCodec), "{}: {info:?}", path.display());
        }
    }

    #[test]
    fn unreadable_files_fail_the_probe() {
        if !shim::AVAILABLE {
            return;
        }
        let dir = TempDir::new();
        let (garbage, empty) = (dir.join("garbage.mp4"), dir.join("empty.mov"));
        write_file(&garbage, 4096, 7);
        write_file(&empty, 0, 0);
        for path in [garbage, empty, dir.join("missing.mp4")] {
            assert!(FfmpegSeekProber::default().probe(&path).is_err(), "{}", path.display());
        }
    }

    /// The generator built the way the app builds it gets the real prober: a long-GOP clip queues a proxy, an intra clip
    /// and an unreadable file do not (the stand-in prober failed every probe, so no proxy was ever made).
    #[test]
    fn the_platform_prober_makes_the_auto_generator_queue_long_gop_clips() {
        if !ready() {
            return;
        }
        let dir = TempDir::new();
        let long = long_gop(&dir, "long.mp4", "320x180", 150, &[]).expect("long-GOP clip");
        let intra = clip(&dir, "intra.mov", "320x180", 60, &["-c:v", "mjpeg"]).expect("intra clip");
        let broken = dir.join("broken.mp4");
        write_file(&broken, 500, 3);
        let mut queue = ProxyQueue::new(Arc::new(ProxyCache::new(dir.join("cache"))), 1);
        let generator = ProxyAutoGenerator::new();
        let (mut ids, now) = (SequentialIds::default(), Timestamp::from_unix_seconds(1.0));
        assert_eq!(
            generator.source_imported(&mut queue, &long, &mut ids, now),
            ProxyDecision::NeedsProxy(ProxyKind::ProxyHalf)
        );
        assert_eq!(
            generator.source_imported(&mut queue, &intra, &mut ids, now),
            ProxyDecision::Skip(SkipReason::IntraOnlyCodec)
        );
        assert_eq!(
            generator.source_imported(&mut queue, &broken, &mut ids, now),
            ProxyDecision::Skip(SkipReason::Unknown)
        );
        assert_eq!(queue.all_jobs().len(), 1);
    }

    #[test]
    fn a_4k_long_gop_clip_is_probed_in_under_200_ms() {
        if !ready() {
            return;
        }
        let dir = TempDir::new();
        let Some(path) = long_gop(&dir, "uhd.mp4", "3840x2160", 90, &[]) else { panic!("ffmpeg makes a 4K clip") };
        let mkv = long_gop(&dir, "uhd.mkv", "3840x2160", 90, &[]).expect("4K Matroska clip");
        for file in [path, mkv] {
            // The first probe loads the FFmpeg libraries; the best of three is the cost of the probe itself.
            let (best, four_cc) = (0..3)
                .map(|_| {
                    let began = Instant::now();
                    let probed = FfmpegSeekProber::default().probe(&file);
                    let took = began.elapsed();
                    let info = probed.unwrap_or_else(|e| panic!("{}: {e:?}", file.display()));
                    assert!(
                        info.max_sync_distance.is_some_and(|d| (50..=60).contains(&d)),
                        "{}: {info:?}",
                        file.display()
                    );
                    (took, info.codec_four_cc)
                })
                .min()
                .unwrap_or((Duration::MAX, String::new()));
            eprintln!("seek probe of {} ({four_cc}): {best:?}", file.display());
            assert!(best < Duration::from_millis(200), "{}: {best:?}", file.display());
        }
    }
}
