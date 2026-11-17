//! Audio-only files: M4A (AAC), WAV (PCM) and FLAC.

use super::audio::AudioFeed;
use super::video::writer_error;
use crate::core::{AudioFileFormat, AudioSettings, AudioSource, CancelToken, ExportError, LoudnessReport};
use sq_core_time::Time;
use sq_media_ffmpeg::encode::{EncodeConfig, Encoder, Tags};
use std::path::Path;

const STEP: usize = 4096;

/// What the file says about itself: its kind, length and container tags.
pub(super) struct FileSpec<'a> {
    pub format: AudioFileFormat,
    pub duration: Time,
    pub tags: &'a Tags,
}

/// A file of `duration` at the mix's rate; silence pads a mix that ends early, a longer one is cut at `duration`.
pub(super) fn write(
    audio: &mut dyn AudioSource,
    spec: &FileSpec,
    settings: &AudioSettings,
    url: &Path,
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
) -> Result<Option<LoudnessReport>, ExportError> {
    // The Mac writer's rule: AAC can end a little above the true-peak ceiling; the file is measured and, on an overshoot,
    // written once more with the ceiling lowered by it. The report keeps the ceiling the user asked for.
    let format = spec.format;
    let mut s = settings.clone();
    let mut attempt = 0;
    loop {
        let mut report = write_once(audio, spec, &s, url, cancel, progress)?;
        let Some(r) = report.as_mut() else { return Ok(None) };
        r.verified = super::verify::measure_output_audio(url).ok().flatten();
        if let (Some(over), AudioFileFormat::M4a, 0, Some(l)) = (r.overshoot_db(), format, attempt, s.loudness.as_mut())
        {
            attempt += 1;
            if let Some(src) = audio.as_rewindable() {
                src.rewind()?;
            }
            l.true_peak_ceiling_db -= over + 0.1;
            continue;
        }
        r.ceiling_db = settings.loudness.map_or(r.ceiling_db, |l| l.true_peak_ceiling_db);
        return Ok(report);
    }
}

fn write_once(
    audio: &mut dyn AudioSource,
    spec: &FileSpec,
    settings: &AudioSettings,
    url: &Path,
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
) -> Result<Option<LoudnessReport>, ExportError> {
    let (format, duration, tags) = (spec.format, spec.duration, spec.tags);
    let mut s = settings.clone();
    s.codec = format.codec();
    if format == AudioFileFormat::Flac && ![16, 24].contains(&s.pcm_bit_depth) {
        s.pcm_bit_depth = if s.pcm_bit_depth > 24 { 24 } else { 16 };
    }
    let channels = s.channels.clamp(1, 2) as usize;
    let (mut feed, report) = AudioFeed::new(audio, &s, channels, cancel)?;
    let rate = feed.sample_rate();
    let _ = std::fs::remove_file(url);
    let cfg = EncodeConfig {
        path: url.to_path_buf(),
        no_video: true,
        flac: format == AudioFileFormat::Flac,
        pcm_bits: if format == AudioFileFormat::M4a { 0 } else { s.pcm_bit_depth as i32 },
        audio_rate: rate as i32,
        audio_channels: channels as i32,
        audio_bitrate: s.bitrate,
        tags: tags.clone(),
        ..EncodeConfig::default()
    };
    let mut enc = Encoder::open(&cfg).map_err(writer_error)?;
    let ts = i128::from(duration.timescale().max(1));
    let total = ((i128::from(duration.value()) * i128::from(rate) + ts / 2) / ts).max(1) as i64;
    let mut written: i64 = 0;
    while written < total {
        cancel.check()?;
        let want = (total - written).min(STEP as i64) as usize;
        let out = feed.read(want, true)?;
        enc.audio(&out).map_err(writer_error)?;
        written += (out.len() / channels) as i64;
        progress(written as f64 / total as f64);
    }
    enc.finish().map_err(writer_error)?;
    progress(1.0);
    Ok(report)
}
