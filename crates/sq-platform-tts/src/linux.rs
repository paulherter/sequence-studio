//! Linux: the `espeak-ng` program (GPL-3.0-or-later; started as a separate process, never linked). Without it the
//! voice list is empty and the dialog says so.

use crate::{Rendered, SpeechEngine, SpeechError, SpeechVoice, wav_frames};
use sq_core_audio::voiceover::Voiceover;
use std::path::Path;
use std::process::Command;

pub(crate) struct EspeakSpeech;

/// espeak-ng's normal speed in words per minute.
const NORMAL_WPM: f64 = 175.0;

impl SpeechEngine for EspeakSpeech {
    fn voices(&self) -> Vec<SpeechVoice> {
        let Ok(out) = Command::new("espeak-ng").arg("--voices").output() else { return Vec::new() };
        let mut list = parse_voices(&String::from_utf8_lossy(&out.stdout));
        crate::sort_voices(&mut list, &crate::own_language());
        list
    }

    fn synthesize(&self, text: &str, voice_id: &str, rate: f64, out: &Path) -> Result<Rendered, SpeechError> {
        let wpm = (NORMAL_WPM * Voiceover::speed_factor(rate)).round() as i64;
        let status = Command::new("espeak-ng")
            .args(["-v", voice_id, "-s", &wpm.to_string(), "-w"])
            .arg(out)
            .arg("--")
            .arg(text)
            .status()
            .map_err(|e| SpeechError::Failed(e.to_string()))?;
        if !status.success() {
            return Err(SpeechError::NoVoice);
        }
        let (sample_rate, frames) = wav_frames(out).map_err(|e| SpeechError::Failed(e.to_string()))?;
        Ok(Rendered { frames, sample_rate })
    }
}

/// `Pty Language Age/Gender VoiceName File Other Languages` columns of `espeak-ng --voices`.
fn parse_voices(listing: &str) -> Vec<SpeechVoice> {
    listing
        .lines()
        .skip(1)
        .filter_map(|line| {
            let c: Vec<&str> = line.split_whitespace().collect();
            let (language, name, file) = (c.get(1)?, c.get(3)?, c.get(4)?);
            Some(SpeechVoice {
                id: (*file).to_string(),
                name: name.replace('_', " "),
                language: (*language).to_string(),
                enhanced: false,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_voice_table() {
        let listing = "Pty Language       Age/Gender VoiceName          File                 Other Languages\n 5  af              --/M      Afrikaans          gmw/af               \n 5  en-us           --/M      English_(America)  gmw/en-US            (en 3)\n";
        let v = parse_voices(listing);
        assert_eq!(v.len(), 2);
        assert_eq!(
            (v[1].id.as_str(), v[1].name.as_str(), v[1].language.as_str()),
            ("gmw/en-US", "English (America)", "en-us")
        );
    }
}
