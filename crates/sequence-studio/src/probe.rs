//! The media probe of imports: FFmpeg reads the picture stream and the sound (channels, rate, codec) into a `MediaRef`; a
//! sound-only file takes its length from the container. A still image gets the default still length and no sound; a video's
//! color space, shoot date and camera are read at import (Swift `MediaImporter.probe`).
//! shortcut: a sound-only file whose container states no length is decoded completely. The Dolby Vision record comes from
//! FFmpeg's stream side data (`FFmpegDemuxer::dolby_vision_record`), not the raw `dvcC` / `dvvC` atom.

use sq_core_model::{AudioTrackInfo, MediaFingerprint, MediaInfo, MediaRef};
use sq_core_time::{Id, Time, Timestamp};
use sq_editor_session::{ImportBackend, ImportError};
use sq_media::canon_metadata::CameraMetadata;
use sq_media::color_tag_detection::ColorTagDetection;
use sq_media::embedded_lut::EmbeddedMeta;
use sq_media::media_diagnosis::{ImportNotes, MediaDiagnosis};
use sq_media::media_error::MediaError;
use sq_media::media_file_ops::MediaFileOps;
use sq_media::shoot_metadata::ShootMetadata;
use sq_media::still_image;
use sq_media_ffmpeg::decode::FFmpegDemuxer;
use sq_media_ffmpeg::decode::{AudioStreamInfo, FFmpegAudioSource};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Rate the length of a sound-only file is measured at.
const AUDIO_RATE: i32 = 48_000;

/// `ImportBackend` over FFmpeg.
#[derive(Default)]
pub struct FfmpegProbe {
    counter: AtomicU64,
    /// Where animated imports are cached: `<support>/Animated Imports` of the app's own support folder, else of the real one.
    support: Option<std::path::PathBuf>,
}

fn info(duration: Time) -> MediaInfo {
    MediaInfo {
        duration,
        video: None,
        audio: None,
        detected_color_space: None,
        embedded_lut_name: None,
        is_still: false,
        sound_probed: None,
        created: None,
        camera_model: None,
        shoot_probed: None,
    }
}

fn fingerprint(path: &Path) -> MediaFingerprint {
    let meta = std::fs::metadata(path).ok();
    let mut f = MediaFingerprint::new(meta.as_ref().map_or(0, |m| i64::try_from(m.len()).unwrap_or(i64::MAX)));
    f.modified = meta
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| Timestamp::from_unix_seconds(d.as_secs_f64()));
    f
}

impl FfmpegProbe {
    /// An id no session id can equal: the session counts up from 1, these start at the wall-clock nanoseconds.
    fn fresh_id(&self) -> Id {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_nanos());
        Id::from_u128((nanos << 64) | u128::from(self.counter.fetch_add(1, Ordering::Relaxed)))
    }

    pub(crate) fn media_info(path: &Path) -> Result<MediaInfo, ImportError> {
        let _span = sq_os::trace::span_args("open", "media probe", || format!("file={}", path.display()));
        if still_image::is_still(path) {
            return Self::still_info(path);
        }
        let sound = FFmpegAudioSource::stream_info(path).ok().flatten();
        match FFmpegDemuxer::open_shared(path) {
            Ok(demuxer) => {
                let mut i = info(demuxer.table().index.duration());
                i.video = Some(demuxer.track_info());
                i.audio = Self::playable_sound(path, sound, FFmpegAudioSource::decoder_check);
                i.sound_probed = Some(true);
                // Sony and Canon metadata in one walk over the boxes (best effort); the tags decide the rest.
                let video = demuxer.track_info();
                let (sony, canon) = CameraMetadata::read_for_clip(path, true);
                i.detected_color_space = Some(ColorTagDetection::detect(
                    video.color_primaries.as_deref(),
                    video.transfer.as_deref(),
                    sony.as_ref(),
                    demuxer
                        .dolby_vision_record()
                        .and_then(|r| sq_media::codec_config::CodecConfig::dolby_vision(&r))
                        .as_ref(),
                    canon.as_ref(),
                ));
                let shoot = ShootMetadata::read(path, sony.as_ref().and_then(|s| s.model_name.as_deref()));
                i.created = shoot.created_unix.map(Timestamp::from_unix_seconds);
                i.camera_model = shoot.camera_model;
                i.shoot_probed = Some(true);
                // The resolver applies a camera look only for media that says it carries one.
                i.embedded_lut_name = EmbeddedMeta::lut_header_in_clip(path)
                    .ok()
                    .flatten()
                    .map(|h| h.name.unwrap_or_else(|| "Camera LUT".into()));
                Ok(i)
            }
            Err(video_error) => {
                let sound = sound.ok_or_else(|| ImportError::Failed(video_error.to_string()))?;
                let duration = match sound.duration_us {
                    Some(us) => Time::new(us, 1_000_000),
                    None => {
                        let decoded = FFmpegAudioSource::open(path, AUDIO_RATE)
                            .map_err(|_| ImportError::Failed(video_error.to_string()))?;
                        Time::new(decoded.frame_count(), i64::from(AUDIO_RATE))
                    }
                };
                let mut i = info(duration);
                i.audio = Some(track(sound, path));
                Ok(i)
            }
        }
    }
}

impl FfmpegProbe {
    /// The sound of a video file, or `None` when it has none or no decoder here can play it: then the file imports without
    /// sound and `ImportNotes` remembers the codec for the "imported without sound" notice (Swift `MediaImporter.probe`).
    /// `decoder` is `FFmpegAudioSource::decoder_check`; a test passes its own.
    fn playable_sound(
        path: &Path,
        sound: Option<AudioStreamInfo>,
        decoder: impl FnOnce(&Path) -> Result<(), MediaError>,
    ) -> Option<AudioTrackInfo> {
        let sound = sound?;
        if let Err(MediaError::UnsupportedCodec(_)) = decoder(path) {
            ImportNotes::note_audio_dropped(path, &sound.codec);
            return None;
        }
        Some(track(sound, path))
    }

    /// A still image: the picture's size, the default still length, no sound.
    fn still_info(path: &Path) -> Result<MediaInfo, ImportError> {
        let demuxer = FFmpegDemuxer::open_shared(path).map_err(|e| ImportError::Failed(e.to_string()))?;
        let mut i = info(still_image::DEFAULT_STILL_DURATION);
        i.video = Some(demuxer.track_info());
        i.is_still = true;
        let shoot = ShootMetadata::read(path, None);
        i.created = shoot.created_unix.map(Timestamp::from_unix_seconds);
        i.camera_model = shoot.camera_model;
        i.shoot_probed = Some(true);
        Ok(i)
    }
}

/// The sound of a file: the channels count across all audio tracks (so "Audio Channels" can name any of them), and
/// `first_track_channels` says where the first track ends when there are several (Swift `MultiTrackAudio`).
fn track(s: AudioStreamInfo, path: &Path) -> AudioTrackInfo {
    let counts = FFmpegAudioSource::track_channels(path).unwrap_or_default();
    let many = counts.len() > 1;
    AudioTrackInfo {
        sample_rate: s.sample_rate,
        channels: if many { counts.iter().sum() } else { s.channels },
        codec: s.codec,
        channel_map: None,
        first_track_channels: many.then(|| counts[0]),
    }
}

fn is_animation_candidate(path: &Path) -> bool {
    path.extension().is_some_and(|e| ["gif", "png", "apng", "webp"].iter().any(|x| e.eq_ignore_ascii_case(x)))
}

/// Frame rate of an image sequence (Swift `MediaImporter.defaultSequenceFPS`).
const SEQUENCE_FPS: i64 = sq_media::animated_image::DEFAULT_SEQUENCE_FPS;

impl ImportBackend for FfmpegProbe {
    fn probe(&self, path: &Path) -> Result<MediaRef, ImportError> {
        self.probe_in(path, &self.strip_cache())
    }

    fn file_identity(&self, path: &Path) -> Option<String> {
        MediaFileOps::file_identity(path)
    }

    fn failure_reason(&self, path: &Path, error: &ImportError) -> Option<String> {
        let media_error = match error {
            ImportError::UnsupportedCodec(codec) => Some(MediaError::UnsupportedCodec(codec.clone())),
            ImportError::Failed(_) => None,
        };
        Some(MediaDiagnosis::reason(path, media_error.as_ref()))
    }

    fn take_audio_dropped(&self, path: &Path) -> Option<String> {
        ImportNotes::take_audio_dropped(path)
    }

    fn image_sequences(&self, files: &[std::path::PathBuf]) -> Vec<Vec<std::path::PathBuf>> {
        sq_media::animated_image::sequence_groups(files, sq_editor_session::ProjectPanelModel::MIN_SEQUENCE_FRAMES)
    }

    fn probe_sequence(&self, frames: &[std::path::PathBuf]) -> Result<MediaRef, ImportError> {
        self.probe_sequence_in(frames, &self.strip_cache())
    }
}

impl FfmpegProbe {
    /// A probe whose animated imports are cached under `support`: an offscreen run keeps them in its own folder instead of
    /// the user's real support folder.
    pub(crate) fn in_support(support: &Path) -> Self {
        FfmpegProbe { support: Some(support.to_path_buf()), ..Self::default() }
    }

    fn strip_cache(&self) -> std::path::PathBuf {
        let support = self.support.clone().unwrap_or_else(crate::paths::app_support_dir);
        support.join("Animated Imports")
    }

    /// Numbered stills as one clip: it points at the cached strip and is named like "fx_[001-004].png".
    pub(crate) fn probe_sequence_in(
        &self,
        frames: &[std::path::PathBuf],
        cache: &Path,
    ) -> Result<MediaRef, ImportError> {
        let strip = sq_media_ffmpeg::animated::probe_sequence(frames, SEQUENCE_FPS, cache)
            .map_err(|e| ImportError::Failed(e.to_string()))?;
        let name = sq_media::animated_image::sequence_display_name(frames);
        self.ref_for(&name, &strip)
    }

    fn ref_for(&self, name: &str, path: &Path) -> Result<MediaRef, ImportError> {
        let media = Self::media_info(path)?;
        let mut m = MediaRef::new(self.fresh_id(), name, &sq_os::paths::stored(path), fingerprint(path));
        m.duration = Some(media.duration);
        m.info = Some(media);
        Ok(m)
    }

    /// `probe` with the folder the animated strips are cached in.
    pub(crate) fn probe_in(&self, path: &Path, cache: &Path) -> Result<MediaRef, ImportError> {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        // An animated GIF or APNG plays from a cached ProRes 4444 strip (Swift `probeAnimated`): the clip points at the
        // strip and keeps the picture's own name.
        let animated = is_animation_candidate(path)
            .then(|| sq_media_ffmpeg::animated::probe_animated(path, cache))
            .and_then(Result::ok)
            .flatten();
        self.ref_for(&name, animated.as_deref().unwrap_or(path))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};

    /// Makes `name` in a fresh temp folder with `ffmpeg -f lavfi` inputs; `None` (skip) without ffmpeg or the linked shim.
    fn fixture(name: &str, args: &[&str]) -> Option<std::path::PathBuf> {
        if !sq_media_ffmpeg::shim::AVAILABLE {
            return None;
        }
        let dir = std::env::temp_dir().join(format!("sq-probe-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).ok()?;
        let out = dir.join(name);
        let made = Command::new("ffmpeg")
            .args(["-v", "error", "-y"])
            .args(args)
            .arg(&out)
            .stdin(Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        made.then_some(out)
    }

    /// A fresh folder for one test (removed by the caller).
    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-probe-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch folder");
        dir
    }

    #[test]
    fn two_paths_to_one_file_share_an_identity_and_a_missing_file_has_none() {
        let dir = scratch("identity");
        let (a, link, other) = (dir.join("a.mov"), dir.join("hard.mov"), dir.join("b.mov"));
        std::fs::write(&a, b"same bytes").expect("write");
        std::fs::write(&other, b"same bytes").expect("write");
        std::fs::hard_link(&a, &link).expect("hard link");
        let probe = FfmpegProbe::default();
        let id = probe.file_identity(&a);
        assert!(id.is_some());
        assert_eq!(probe.file_identity(&link), id, "a hard link is the same file");
        assert_ne!(probe.file_identity(&other), id, "a copy with equal bytes is another file");
        #[cfg(unix)]
        {
            let sym = dir.join("sym.mov");
            std::os::unix::fs::symlink(&a, &sym).expect("symlink");
            assert_eq!(probe.file_identity(&sym), id, "a symlink is the same file");
        }
        assert_eq!(probe.file_identity(&dir.join("gone.mov")), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_file_that_cannot_be_probed_gets_a_plain_reason() {
        let dir = scratch("reason");
        let (empty, avi) = (dir.join("empty.mp4"), dir.join("clip.avi"));
        std::fs::write(&empty, b"").expect("write");
        std::fs::write(&avi, b"RIFF\0\0\0\0AVI LIST").expect("write");
        let probe = FfmpegProbe::default();
        let failed = ImportError::Failed("ffmpeg: invalid data".into());
        let reason = |p: &Path, e: &ImportError| probe.failure_reason(p, e).unwrap_or_default();
        assert!(reason(&empty, &failed).contains("empty (0 bytes)"));
        assert!(reason(&avi, &failed).starts_with("AVI files are not supported."));
        assert_eq!(reason(&dir.join("gone.mov"), &failed), "The file is no longer there.");
        assert!(reason(&empty, &ImportError::UnsupportedCodec("braw".into())).starts_with("Blackmagic RAW (BRAW)"));
        assert!(reason(&empty, &ImportError::UnsupportedCodec("av01".into())).starts_with("Uses av01"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn sound_without_a_decoder_is_dropped_once_and_the_codec_is_remembered() {
        let path = Path::new("/sq-probe-test/dts-sound.mkv");
        let sound =
            || AudioStreamInfo { sample_rate: 48_000, channels: 6, codec: "dts".into(), duration_us: Some(1_000_000) };
        let probe = FfmpegProbe::default();
        let kept = FfmpegProbe::playable_sound(path, Some(sound()), |_| Ok(()));
        assert_eq!(kept.map(|a| (a.codec, a.channels)), Some(("dts".to_string(), 6)));
        assert_eq!(probe.take_audio_dropped(path), None, "playable sound leaves no note");
        let dropped =
            FfmpegProbe::playable_sound(path, Some(sound()), |_| Err(MediaError::UnsupportedCodec(String::new())));
        assert!(dropped.is_none());
        assert_eq!(probe.take_audio_dropped(path).as_deref(), Some("dts"));
        assert_eq!(probe.take_audio_dropped(path), None, "the note is given out once");
        assert!(
            FfmpegProbe::playable_sound(path, None, |_| Err(MediaError::Unreadable)).is_none(),
            "no sound, no note"
        );
        assert_eq!(probe.take_audio_dropped(path), None);
    }

    #[test]
    fn a_dolby_vision_record_from_the_shim_names_the_base_layer() {
        // Profile 8, level 6, rpu + base layer, compatibility id 4 (HLG): the bytes `demux.cpp` writes.
        let bits: u16 = (8 << 9) | (6 << 3) | 5;
        let record = [1, 0, (bits >> 8) as u8, bits as u8, 4 << 4];
        let dv = sq_media::codec_config::CodecConfig::dolby_vision(&record);
        assert_eq!(
            ColorTagDetection::detect(None, None, None, dv.as_ref(), None),
            sq_core_model::ColorSpaceID::HlgBT2020
        );
    }

    #[test]
    fn a_still_image_imports_with_the_default_length_and_no_sound() {
        let Some(path) = fixture("pic.png", &["-f", "lavfi", "-i", "testsrc=d=1:s=64x48:r=1", "-frames:v", "1"]) else {
            return;
        };
        let m = FfmpegProbe::default().probe_in(&path, &path.with_extension("strips")).map_err(|e| format!("{e:?}"));
        let _ = std::fs::remove_dir_all(path.parent().unwrap_or(&path));
        let i = m.ok().and_then(|m| m.info);
        assert!(i.as_ref().is_some_and(|i| i.is_still && i.audio.is_none()));
        assert_eq!(i.as_ref().map(|i| i.duration), Some(still_image::DEFAULT_STILL_DURATION));
        assert_eq!(i.and_then(|i| i.video).map(|v| (v.width, v.height)), Some((64, 48)));
    }

    #[test]
    fn a_video_import_records_color_space_and_the_probe_flags() {
        let Some(path) = fixture("tagged.mp4", &["-f", "lavfi", "-i", "testsrc=d=1:s=64x64:r=25", "-c:v", "mpeg4"])
        else {
            return;
        };
        let m = FfmpegProbe::default().probe_in(&path, &path.with_extension("strips")).map_err(|e| format!("{e:?}"));
        let _ = std::fs::remove_dir_all(path.parent().unwrap_or(&path));
        let i = m.ok().and_then(|m| m.info);
        assert_eq!(i.as_ref().and_then(|i| i.detected_color_space), Some(sq_core_model::ColorSpaceID::Rec709));
        assert_eq!(i.as_ref().map(|i| (i.sound_probed, i.shoot_probed)), Some((Some(true), Some(true))));
        assert!(i.is_some_and(|i| !i.needs_color_detection()));
    }

    #[test]
    fn video_file_reports_its_sound() {
        let Some(path) = fixture(
            "clip.mp4",
            &[
                "-f",
                "lavfi",
                "-i",
                "testsrc=d=1:s=64x64:r=25",
                "-f",
                "lavfi",
                "-i",
                "sine=d=1:r=44100",
                "-ac",
                "2",
                "-c:v",
                "mpeg4",
                "-c:a",
                "aac",
                "-shortest",
            ],
        ) else {
            return;
        };
        let m = FfmpegProbe::default().probe_in(&path, &path.with_extension("strips")).map_err(|e| format!("{e:?}"));
        let _ = std::fs::remove_dir_all(path.parent().unwrap_or(&path));
        let info = m.ok().and_then(|m| m.info).map(|i| (i.video.is_some(), i.audio));
        let (has_video, audio) = info.unwrap_or_default();
        let audio = audio.unwrap_or(track(
            AudioStreamInfo { sample_rate: 0, channels: 0, codec: String::new(), duration_us: None },
            Path::new(""),
        ));
        assert!(has_video);
        assert_eq!((audio.sample_rate, audio.channels, audio.codec.as_str()), (44_100, 2, "aac"));
    }

    #[test]
    fn animated_gif_imports_as_a_strip_under_its_own_name() {
        let Some(path) = fixture("anim.gif", &["-f", "lavfi", "-i", "testsrc=d=1:s=64x48:r=5"]) else { return };
        let cache = path.with_file_name("cache");
        let m = FfmpegProbe::default().probe_in(&path, &cache);
        let _ = std::fs::remove_file(&path);
        let Ok(m) = m else { panic!("probe failed") };
        assert_eq!(m.name, "anim.gif");
        assert!(m.path.contains("/cache/") && m.path.ends_with(".mov"), "{}", m.path);
        assert!(m.info.is_some_and(|i| i.video.is_some()));
        let _ = std::fs::remove_dir_all(&cache);
    }

    #[test]
    fn numbered_stills_import_as_one_named_clip() {
        let Some(first) = fixture("fx_0001.png", &["-f", "lavfi", "-i", "color=c=red:s=32x24", "-frames:v", "1"])
        else {
            return;
        };
        let dir = first.parent().map(Path::to_path_buf).unwrap_or_default();
        let mut frames = vec![first];
        for i in 2..=4 {
            let f = dir.join(format!("fx_{i:04}.png"));
            let made = Command::new("ffmpeg")
                .args(["-v", "error", "-y", "-f", "lavfi", "-i", "color=c=blue:s=32x24", "-frames:v", "1"])
                .arg(&f)
                .stdin(Stdio::null())
                .status()
                .is_ok_and(|s| s.success());
            assert!(made);
            frames.push(f);
        }
        let backend = FfmpegProbe::default();
        let groups = backend.image_sequences(&frames);
        assert_eq!(groups, vec![frames.clone()]);
        let m = backend.probe_sequence_in(&frames, &dir.join("cache"));
        let _ = std::fs::remove_dir_all(&dir);
        let Ok(m) = m else { panic!("sequence probe failed") };
        assert_eq!(m.name, "fx_[0001-0004].png");
        assert!(m.path.ends_with(".mov"));
        assert!(m.info.is_some_and(|i| i.video.is_some()));
    }

    #[test]
    fn video_without_sound_has_no_audio_track() {
        let Some(path) = fixture("mute.mp4", &["-f", "lavfi", "-i", "testsrc=d=1:s=64x64:r=25", "-c:v", "mpeg4"])
        else {
            return;
        };
        let m = FfmpegProbe::default().probe_in(&path, &path.with_extension("strips"));
        let _ = std::fs::remove_dir_all(path.parent().unwrap_or(&path));
        assert!(m.is_ok_and(|m| m.info.is_some_and(|i| i.video.is_some() && i.audio.is_none())));
    }

    #[test]
    fn sound_only_file_takes_its_length_from_the_container() {
        let Some(path) = fixture("tone.wav", &["-f", "lavfi", "-i", "sine=d=2:r=22050", "-ac", "1"]) else {
            return;
        };
        let m = FfmpegProbe::default().probe_in(&path, &path.with_extension("strips"));
        let _ = std::fs::remove_dir_all(path.parent().unwrap_or(&path));
        let Some(info) = m.ok().and_then(|m| m.info) else { panic!("probe failed") };
        assert!(info.video.is_none());
        assert_eq!(info.duration, Time::new(2_000_000, 1_000_000));
        assert_eq!(info.audio.map(|a| (a.sample_rate, a.channels)), Some((22_050, 1)));
    }

    #[test]
    fn a_file_with_several_audio_tracks_counts_the_channels_of_all_of_them() {
        let Some(path) = fixture(
            "tracks.mov",
            &[
                "-f",
                "lavfi",
                "-i",
                "sine=d=1:r=48000",
                "-f",
                "lavfi",
                "-i",
                "sine=d=1:r=48000",
                "-f",
                "lavfi",
                "-i",
                "sine=d=1:r=48000",
                "-map",
                "0",
                "-map",
                "1",
                "-map",
                "2",
                "-c:a",
                "pcm_s16le",
            ],
        ) else {
            return;
        };
        let m = FfmpegProbe::default()
            .probe_in(&path, &path.with_extension("strips"))
            .map_err(|e| format!("{e:?}"))
            .unwrap();
        let _ = std::fs::remove_dir_all(path.parent().unwrap_or(&path));
        let audio = m.info.and_then(|i| i.audio).unwrap();
        assert_eq!((audio.channels, audio.first_track_channels), (3, Some(1)));
    }
}
