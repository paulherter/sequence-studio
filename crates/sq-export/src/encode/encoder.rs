//! `FfmpegExportEncoder`: the `ExportEncoding` over the FFmpeg shim.

use super::{audio_file, gif, sequence, video};
use crate::core::{
    AudioFileFormat, AudioSettings, AudioSource, CancelToken, ExportEncoding, ExportError, ExportSettings, FrameOutput,
    FrameSource, LoudnessReport,
};
use sq_core_time::Time;
use sq_media_ffmpeg::encode::Tags;
use std::path::Path;
use std::sync::Mutex;

/// Writes through `sq_media_ffmpeg::encode`: video files (H.264, HEVC, every ProRes), audio-only files, animated GIF and
/// image sequences, by the settings.
#[derive(Default)]
pub struct FfmpegExportEncoder {
    last_video_encoder: Mutex<String>,
}

impl FfmpegExportEncoder {
    /// An encoder.
    pub fn new() -> FfmpegExportEncoder {
        FfmpegExportEncoder::default()
    }

    /// Name of the video encoder the last export used ("h264_videotoolbox", "libx264", ...), for tests and diagnostics.
    pub fn last_video_encoder(&self) -> String {
        self.last_video_encoder.lock().map(|g| g.clone()).unwrap_or_default()
    }
}

impl ExportEncoding for FfmpegExportEncoder {
    fn export(
        &self,
        video: &mut dyn FrameSource,
        audio: Option<&mut dyn AudioSource>,
        settings: &ExportSettings,
        url: &Path,
        cancel: &CancelToken,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Option<LoudnessReport>, ExportError> {
        let issues = settings.validate();
        if !issues.is_empty() {
            return Err(ExportError::InvalidSettings(issues));
        }
        if let Some(format) = settings.audio_only {
            // The Mac writer's rule: the length is the sequence frame duration times the frame count.
            let audio = audio.ok_or(ExportError::NoAudio)?;
            let fd = settings.video.frame_duration;
            let duration = Time::new(fd.value() * video.frame_count() as i64, fd.timescale());
            return audio_file::write(
                audio,
                &audio_file::FileSpec { format, duration, tags: &video::tags_of(settings) },
                &settings.effective_audio(),
                url,
                cancel,
                progress,
            );
        }
        if let Some(output) = settings.frame_output {
            if video.frame_count() == 0 {
                return Err(ExportError::EmptySource);
            }
            match output {
                FrameOutput::Gif => gif::write(video, url, cancel, progress)?,
                FrameOutput::Sequence(f) => {
                    sequence::write(video, f, url, 0, cancel, progress)?;
                }
            }
            progress(1.0);
            return Ok(None);
        }
        let (report, name) = video::write(video, audio, settings, url, cancel, progress)?;
        if let Ok(mut last) = self.last_video_encoder.lock() {
            *last = name;
        }
        Ok(report)
    }

    fn export_audio_file(
        &self,
        audio: &mut dyn AudioSource,
        format: AudioFileFormat,
        duration: Time,
        settings: &AudioSettings,
        url: &Path,
        cancel: &CancelToken,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Option<LoudnessReport>, ExportError> {
        audio_file::write(
            audio,
            &audio_file::FileSpec { format, duration, tags: &Tags::default() },
            settings,
            url,
            cancel,
            progress,
        )
    }
}
