//! `OutputAudioVerifier` (Swift AudioDelivery.swift): decodes the audio of a written file again and measures its
//! loudness and true peak, so the export can confirm what the file really holds.

use crate::core::{ExportError, LoudnessMeasurement};
use sq_audiofx::loudness::LoudnessMeter;
use sq_media_ffmpeg::shim::decode_audio;
use std::path::Path;

/// `None` when the file has no audio stream. The audio is read at 48 kHz, one or two channels (as the Mac verifier).
pub fn measure_output_audio(path: &Path) -> Result<Option<LoudnessMeasurement>, ExportError> {
    let probe = sq_media_ffmpeg::shim::probe_audio(path).map_err(|e| ExportError::WriterFailed(e.to_string()))?;
    let Some((_, source_channels, _)) = probe.audio else { return Ok(None) };
    let channels = source_channels.clamp(1, 2);
    let pcm = match decode_audio(path, 48_000, channels) {
        Ok(p) => p,
        Err(_) => return Ok(None),
    };
    let n = channels as usize;
    let mut meter = LoudnessMeter::new(48_000, n, None);
    for block in pcm.samples.chunks(4096 * n) {
        let planar: Vec<Vec<f32>> = (0..n).map(|c| block.iter().skip(c).step_by(n).copied().collect()).collect();
        meter.process(&planar);
    }
    let peak = meter.true_peak_db().into_iter().fold(f64::NEG_INFINITY, f64::max);
    Ok(Some(LoudnessMeasurement { integrated_lufs: meter.integrated(), true_peak_db: peak }))
}
