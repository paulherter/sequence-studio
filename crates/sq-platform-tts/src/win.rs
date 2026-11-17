//! Windows: the WinRT `SpeechSynthesizer` (the voices of Settings > Time & language > Speech). It answers a WAV stream
//! that is written to the file as it is.

use crate::{Rendered, SpeechEngine, SpeechError, SpeechVoice, sort_voices, wav_frames};
use sq_core_audio::voiceover::Voiceover;
use std::path::Path;
use windows::Media::SpeechSynthesis::SpeechSynthesizer;
use windows::Storage::Streams::DataReader;
use windows::core::HSTRING;

pub(crate) struct WinSpeech;

fn failed(e: windows::core::Error) -> SpeechError {
    SpeechError::Failed(e.message())
}

impl SpeechEngine for WinSpeech {
    fn voices(&self) -> Vec<SpeechVoice> {
        let Ok(all) = SpeechSynthesizer::AllVoices() else { return Vec::new() };
        let mut list: Vec<SpeechVoice> = all
            .into_iter()
            .filter_map(|v| {
                Some(SpeechVoice {
                    id: v.Id().ok()?.to_string(),
                    name: v.DisplayName().ok()?.to_string(),
                    language: v.Language().ok()?.to_string(),
                    // Windows lists "Natural" voices as the better ones.
                    enhanced: v.DisplayName().ok()?.to_string().contains("Natural"),
                })
            })
            .collect();
        sort_voices(&mut list, &crate::own_language());
        list
    }

    fn synthesize(&self, text: &str, voice_id: &str, rate: f64, out: &Path) -> Result<Rendered, SpeechError> {
        let voice = SpeechSynthesizer::AllVoices()
            .map_err(failed)?
            .into_iter()
            .find(|v| v.Id().is_ok_and(|id| id == voice_id))
            .ok_or(SpeechError::NoVoice)?;
        let synth = SpeechSynthesizer::new().map_err(failed)?;
        synth.SetVoice(&voice).map_err(failed)?;
        // SpeakingRate: 1 is normal, 0.5...6; the dialog's speed is 0.5...2.
        synth.Options().map_err(failed)?.SetSpeakingRate(Voiceover::speed_factor(rate)).map_err(failed)?;
        let stream = synth.SynthesizeTextToStreamAsync(&HSTRING::from(text)).map_err(failed)?.join().map_err(failed)?;
        let size = u32::try_from(stream.Size().map_err(failed)?).map_err(|_| SpeechError::Failed("too long".into()))?;
        let reader = DataReader::CreateDataReader(&stream.GetInputStreamAt(0).map_err(failed)?).map_err(failed)?;
        reader.LoadAsync(size).map_err(failed)?.join().map_err(failed)?;
        let mut bytes = vec![0u8; size as usize];
        reader.ReadBytes(&mut bytes).map_err(failed)?;
        std::fs::write(out, &bytes).map_err(|e| SpeechError::Failed(e.to_string()))?;
        let (sample_rate, frames) = wav_frames(out).map_err(|e| SpeechError::Failed(e.to_string()))?;
        Ok(Rendered { frames, sample_rate })
    }
}
