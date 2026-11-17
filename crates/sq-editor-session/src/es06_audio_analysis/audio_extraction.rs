// Swift: AudioExtraction.swift
//! Extract Audio: the sound of a media item as its own M4A file, which then becomes a Project item ("Name (audio)").

use std::fmt;
use std::path::{Path, PathBuf};

use sq_core_model::{Clip, MediaRef, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{IdSource, Time, TimeRange};
use sq_export::core::error::{CancelToken, ExportError};
use sq_export::core::settings::{AudioFileFormat, AudioSettings};
use sq_export::core::traits::{AudioSource, ExportEncoding};

/// Why a sound could not be extracted.
// Swift: AudioExtraction.swift:6
#[derive(Clone, Debug, PartialEq)]
pub enum AudioExtractionFailure {
    NoAudio,
    Offline,
    /// The encoder failed or the run was canceled.
    Export(ExportError),
}

impl fmt::Display for AudioExtractionFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AudioExtractionFailure::NoAudio => f.write_str("This item has no sound."),
            AudioExtractionFailure::Offline => f.write_str("This item is offline."),
            AudioExtractionFailure::Export(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for AudioExtractionFailure {}

/// Builds the mix source of a one-clip sequence (the app's timeline audio source).
pub type AudioForTimeline<'a> = &'a mut dyn FnMut(&Timeline) -> Result<Box<dyn AudioSource>, ExportError>;

/// Namespace of Extract Audio (Swift `AudioExtraction`).
pub enum AudioExtraction {}

impl AudioExtraction {
    /// "Name (audio).m4a" in `folder`; "Name (audio 2).m4a"... when taken. The media's own extension is dropped.
    // Swift: AudioExtraction.swift:11
    pub fn destination(media: &MediaRef, folder: &Path) -> PathBuf {
        // Swift `deletingPathExtension`: a dot after the last slash and not first in its component.
        let name = &media.name;
        let component = name.rfind('/').map_or(0, |i| i + 1);
        let mut stem = match name.rfind('.') {
            Some(dot) if dot > component => name[..dot].to_string(),
            _ => name.clone(),
        };
        if stem.is_empty() {
            stem = "Audio".to_string();
        }
        let stem = stem.replace('/', "-");
        let mut n = 1;
        loop {
            let name = if n == 1 { format!("{stem} (audio).m4a") } else { format!("{stem} (audio {n}).m4a") };
            let url = folder.join(name);
            if !url.exists() {
                return url;
            }
            n += 1;
        }
    }

    /// The one-clip sequence the writer mixes: the whole sound of `media`, nothing else.
    pub(crate) fn timeline(
        media: &MediaRef,
        duration: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Timeline, AudioExtractionFailure> {
        let mut tracks = Timeline::default_tracks(1, 1, ids);
        let a = tracks.iter().position(|t| t.kind == TrackKind::Audio).ok_or(AudioExtractionFailure::NoAudio)?;
        let clip = Clip::new(
            ids.next_id(),
            &media.name,
            media.id,
            TrackKind::Audio,
            TimeRange::new(Time::ZERO, duration),
            Time::ZERO,
        );
        let track: &mut Track = &mut tracks[a];
        track.overwrite(clip, ids).map_err(|_| AudioExtractionFailure::NoAudio)?;
        let rate = media.info.as_ref().and_then(|i| i.audio.as_ref()).map_or(48_000, |a| a.sample_rate);
        let mut format = SequenceFormat::new(Time::new(1, 30));
        format.width = 16;
        format.height = 16;
        format.audio_sample_rate = if rate > 0 { rate } else { 48_000 };
        Ok(Timeline::new(ids.next_id(), &media.name, format, tracks))
    }

    /// Writes the sound of `media` to `url` (M4A, AAC 192 kbit/s, stereo). The file is removed again on failure or
    /// cancel. `audio_for` builds the mix source of the one-clip sequence (the app's timeline audio source).
    // Swift: AudioExtraction.swift:36
    #[allow(clippy::too_many_arguments)]
    pub fn write(
        media: &MediaRef,
        ids: &mut dyn IdSource,
        encoder: &dyn ExportEncoding,
        audio_for: AudioForTimeline<'_>,
        url: &Path,
        cancel: &CancelToken,
        progress: &mut dyn FnMut(f64),
    ) -> Result<(), AudioExtractionFailure> {
        let info = media.info.as_ref().filter(|i| i.audio.is_some()).ok_or(AudioExtractionFailure::NoAudio)?;
        let duration = media.duration.unwrap_or(info.duration);
        if duration.value() <= 0 {
            return Err(AudioExtractionFailure::NoAudio);
        }
        let t = Self::timeline(media, duration, ids)?;
        let settings = AudioSettings { sample_rate: t.format.audio_sample_rate, ..AudioSettings::default() };
        let run = (|| {
            let mut source = audio_for(&t)?;
            encoder.export_audio_file(source.as_mut(), AudioFileFormat::M4a, duration, &settings, url, cancel, progress)
        })();
        run.map(|_| ()).map_err(|e| {
            let _ = std::fs::remove_file(url);
            AudioExtractionFailure::Export(e)
        })
    }

    /// Extract Audio to a library item: writes "Name (audio).m4a" into `folder` (default: the project folder, else next
    /// to the source file) through `write`; the app imports the returned file into the current bin
    /// (`ProjectPanelModel.extractAudio`).
    // Swift: AudioExtraction.swift:59
    pub fn extract_audio(
        media: &MediaRef,
        is_offline: bool,
        folder: Option<&Path>,
        project_folder: Option<&Path>,
        write: impl FnOnce(&Path) -> Result<(), AudioExtractionFailure>,
    ) -> Result<PathBuf, AudioExtractionFailure> {
        if is_offline {
            return Err(AudioExtractionFailure::Offline);
        }
        let own = Path::new(&media.path).parent().map(Path::to_path_buf).unwrap_or_default();
        let dir = folder.or(project_folder).map_or(own, Path::to_path_buf);
        let url = Self::destination(media, &dir);
        write(&url)?;
        Ok(url)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;

    fn media(name: &str) -> MediaRef {
        MediaRef::new(SequentialIds::default().next_id(), name, "/m/a.mov", sq_core_model::MediaFingerprint::new(0))
    }

    #[test]
    fn destination_numbers_taken_names() {
        let dir = std::env::temp_dir().join(format!("sq-extract-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let m = media("Take 1/b.mov");
        let first = AudioExtraction::destination(&m, &dir);
        assert_eq!(first.file_name().and_then(|n| n.to_str()), Some("Take 1-b (audio).m4a"));
        std::fs::write(&first, b"x").expect("write");
        let second = AudioExtraction::destination(&m, &dir);
        assert_eq!(second.file_name().and_then(|n| n.to_str()), Some("Take 1-b (audio 2).m4a"));
        assert_eq!(
            AudioExtraction::destination(&media(""), &dir).file_name().and_then(|n| n.to_str()),
            Some("Audio (audio).m4a")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn offline_and_silent_items_are_refused() {
        let m = media("a.mov");
        let r = AudioExtraction::extract_audio(&m, true, None, None, |_| Ok(()));
        assert_eq!(r, Err(AudioExtractionFailure::Offline));
        let mut ids = SequentialIds::default();
        assert!(AudioExtraction::timeline(&m, Time::new(2, 1), &mut ids).is_ok());
        let url = AudioExtraction::extract_audio(&m, false, None, Some(Path::new("/p")), |u| {
            assert!(u.starts_with("/p"));
            Ok(())
        });
        assert_eq!(url.map(|u| u.starts_with("/p")), Ok(true));
    }
}
