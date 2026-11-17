//! A stand-in engine for tests of the flow above it: one voice, a tone as long as the text.

use crate::{Rendered, SpeechEngine, SpeechError, SpeechVoice, WavWriter};
use std::path::Path;

/// 48 kHz tone, 50 ms per character; the voice id `none` makes no sound and `broken` fails.
pub struct ToneSpeech;

const RATE: u32 = 48_000;

impl SpeechEngine for ToneSpeech {
    fn voices(&self) -> Vec<SpeechVoice> {
        vec![SpeechVoice { id: "tone".into(), name: "Tone".into(), language: "en-US".into(), enhanced: false }]
    }

    fn synthesize(&self, text: &str, voice_id: &str, _rate: f64, out: &Path) -> Result<Rendered, SpeechError> {
        let frames = if voice_id == "none" { 0 } else { text.chars().count() as i64 * i64::from(RATE) / 20 };
        if voice_id == "broken" {
            return Err(SpeechError::Failed("broken".into()));
        }
        let mut w = WavWriter::create(out, 1, RATE).map_err(|e| SpeechError::Failed(e.to_string()))?;
        let samples: Vec<f32> =
            (0..frames).map(|i| 0.3 * (i as f32 * 440.0 * std::f32::consts::TAU / RATE as f32).sin()).collect();
        w.write_f32(&samples).map_err(|e| SpeechError::Failed(e.to_string()))?;
        let frames = w.finish().map_err(|e| SpeechError::Failed(e.to_string()))?;
        Ok(Rendered { frames, sample_rate: RATE as i32 })
    }
}
