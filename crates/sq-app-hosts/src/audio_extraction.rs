// Swift: SQEditorSession/AudioExtraction.swift (`ProjectPanelModel.extractAudio`) and the host's messages
//! Extract Audio on the app's mixer and encoder: the portable part (name, one-clip sequence, M4A AAC 192 kbit/s stereo)
//! is `sq_editor_session::AudioExtraction`; this runs it with the stem mixer (`ExportSetup::make_stem_audio`) and the
//! encoder (`stem_encoder`), blocking, so the caller puts it on a worker.

use sq_core_model::MediaRef;
use sq_core_time::{IdSource, Time, TimeRange};
use sq_editor_session::{AudioExtraction, AudioExtractionFailure, StemAudioProvider};
use sq_export::core::error::CancelToken;
use sq_export::core::stems::Stem;
use sq_export::core::traits::ExportEncoding;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// The detail of the "Extract Audio" message for `failure` (the Swift host's `presentMessage` texts).
pub fn failure_text(failure: &AudioExtractionFailure) -> String {
    match failure {
        AudioExtractionFailure::NoAudio => "This item has no sound.".to_string(),
        AudioExtractionFailure::Offline => "The item is offline. Reconnect it first.".to_string(),
        AudioExtractionFailure::Export(e) => format!("Extract Audio failed: {e}"),
    }
}

/// Writes the sound of `media` as "Name (audio).m4a" into `folder` and returns the file; removed again on failure.
pub fn extract(
    media: &MediaRef,
    folder: &Path,
    ids: &mut dyn IdSource,
    mix: &StemAudioProvider,
    encoder: &Arc<dyn ExportEncoding>,
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
) -> Result<PathBuf, AudioExtractionFailure> {
    let duration = media.duration.or(media.info.as_ref().map(|i| i.duration)).unwrap_or(Time::ZERO);
    let mut audio_for = |t: &sq_core_model::Timeline| {
        let stem =
            Stem { id: "extract".into(), title: media.name.clone(), file_suffix: "audio".into(), timeline: t.clone() };
        mix(t.id, &stem, TimeRange::new(Time::ZERO, duration))
    };
    AudioExtraction::extract_audio(media, false, None, Some(folder), |url| {
        AudioExtraction::write(media, ids, encoder.as_ref(), &mut audio_for, url, cancel, progress)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::MediaFingerprint;
    use sq_core_time::{Id, SequentialIds};
    use sq_export::core::error::ExportError;
    use sq_export::core::settings::{AudioFileFormat, AudioSettings};
    use sq_export::core::traits::SineAudioSource;
    use std::sync::Mutex;

    fn media(name: &str, with_audio: bool) -> MediaRef {
        let mut r = MediaRef::new(Id::from_u128(7), name, "/x/clip.mov", MediaFingerprint::new(1));
        r.duration = Some(Time::seconds(2));
        if with_audio {
            r.info = Some(sq_core_model::MediaInfo {
                duration: Time::seconds(2),
                video: None,
                audio: Some(sq_core_model::AudioTrackInfo {
                    sample_rate: 44_100,
                    channels: 2,
                    codec: "aac".to_string(),
                    channel_map: None,
                    first_track_channels: None,
                }),
                detected_color_space: None,
                embedded_lut_name: None,
                is_still: false,
                sound_probed: None,
                created: None,
                camera_model: None,
                shoot_probed: None,
            });
        }
        r
    }

    /// Records what the writer got and writes a stand-in file.
    struct Recorder(Mutex<Vec<(AudioFileFormat, i64, i64, PathBuf)>>);

    impl ExportEncoding for Recorder {
        fn export(
            &self,
            _: &mut dyn sq_export::core::traits::FrameSource,
            _: Option<&mut dyn sq_export::core::traits::AudioSource>,
            _: &sq_export::core::settings::ExportSettings,
            _: &Path,
            _: &CancelToken,
            _: &mut dyn FnMut(f64),
        ) -> Result<Option<sq_export::core::loudness::LoudnessReport>, ExportError> {
            Err(ExportError::Other("no video".into()))
        }

        fn export_audio_file(
            &self,
            audio: &mut dyn sq_export::core::traits::AudioSource,
            format: AudioFileFormat,
            _: Time,
            settings: &AudioSettings,
            url: &Path,
            _: &CancelToken,
            _: &mut dyn FnMut(f64),
        ) -> Result<Option<sq_export::core::loudness::LoudnessReport>, ExportError> {
            let mut frames = 0;
            while let Some(c) = audio.next_chunk(4096)? {
                frames += c.samples.len() / c.channels.max(1);
            }
            assert!(frames > 0, "the mix delivers the sound");
            std::fs::write(url, b"m4a").map_err(|e| ExportError::WriterFailed(e.to_string()))?;
            self.0.lock().expect("lock").push((format, settings.bitrate, settings.channels, url.to_path_buf()));
            Ok(None)
        }
    }

    #[test]
    fn extract_writes_an_m4a_with_the_swift_settings_next_to_the_name() {
        let dir = crate::test_rig::test_dir("sq-extract");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        let r = media("Take.mov", true);
        let mix: StemAudioProvider = Arc::new(|_, s, range| {
            Ok(Box::new(SineAudioSource::new(s.timeline.format.audio_sample_rate, 2, range.duration, 440, 0.25)))
        });
        let recorder = Arc::new(Recorder(Mutex::default()));
        let encoder: Arc<dyn ExportEncoding> = Arc::clone(&recorder) as Arc<dyn ExportEncoding>;
        let url =
            extract(&r, &dir, &mut SequentialIds::default(), &mix, &encoder, &CancelToken::default(), &mut |_| {})
                .expect("extracted");
        assert_eq!(url, dir.join("Take (audio).m4a"));
        assert!(url.exists());
        assert_eq!(recorder.0.lock().expect("lock")[0].0, AudioFileFormat::M4a);
        assert_eq!(recorder.0.lock().expect("lock")[0].1, 192_000);
        let again =
            extract(&r, &dir, &mut SequentialIds::default(), &mix, &encoder, &CancelToken::default(), &mut |_| {})
                .expect("second");
        assert_eq!(again, dir.join("Take (audio 2).m4a"));
    }

    #[test]
    fn an_item_without_sound_is_refused() {
        let r = media("Still.png", false);
        let mix: StemAudioProvider = Arc::new(|_, _, _| Err(ExportError::NoAudio));
        let encoder: Arc<dyn ExportEncoding> = Arc::new(Recorder(Mutex::default()));
        let got = extract(
            &r,
            Path::new("/f"),
            &mut SequentialIds::default(),
            &mix,
            &encoder,
            &CancelToken::default(),
            &mut |_| {},
        );
        assert_eq!(got, Err(AudioExtractionFailure::NoAudio));
    }
}
