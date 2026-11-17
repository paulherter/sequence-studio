//! Text to speech for Voiceover from Text (Swift `SpeechRenderer`): the voices a system offers and a render of one
//! script into an audio file. The engine trait is portable; the backends sit behind `cfg`:
//! - Mac: `AVSpeechSynthesizer` (`mac.rs`), the same engine as the Swift app.
//! - Windows: the WinRT `SpeechSynthesizer` (`win.rs`).
//! - Linux: the `espeak-ng` program (`linux.rs`, GPL-3.0-or-later, run as a separate process, not linked).
//!
//! Nothing is sent anywhere. The result is an ordinary WAV file the project imports like any other media.

mod fake;
mod job;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod mac;
#[cfg(test)]
mod tests;
mod wav;
#[cfg(windows)]
mod win;

pub use fake::ToneSpeech;
pub use job::{JobState, SpeechJob};
pub use wav::{WavWriter, wav_frames};

use sq_core_audio::voiceover::Voiceover;
use sq_core_time::Time;
use std::path::Path;
use std::sync::Arc;

/// One installed system voice, as the voiceover dialog lists it (Swift `SpeechVoice`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpeechVoice {
    pub id: String,
    pub name: String,
    pub language: String,
    /// Enhanced or premium quality.
    pub enhanced: bool,
}

impl SpeechVoice {
    /// The dialog's popup title (Swift `SharedUIController.voiceoverBackend`).
    pub fn title(&self) -> String {
        format!("{} ({}){}", self.name, self.language, if self.enhanced { " - enhanced" } else { "" })
    }
}

/// Why a script could not be spoken (Swift `SpeechError`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SpeechError {
    NoVoice,
    EmptyText,
    /// The voice produced no sound.
    NoAudio,
    TimedOut,
    Failed(String),
}

/// What an engine wrote: a mono or interleaved PCM file of `frames` sample frames.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rendered {
    pub frames: i64,
    pub sample_rate: i32,
}

impl Rendered {
    /// The length of the speech.
    pub fn length(self) -> Time {
        Time::new(self.frames, i64::from(self.sample_rate))
    }
}

/// A text-to-speech engine. Both calls block: run them off the UI thread (see [`SpeechJob`]).
pub trait SpeechEngine: Send + Sync {
    /// Installed voices, the current language first, then by language and name.
    fn voices(&self) -> Vec<SpeechVoice>;
    /// Speaks the (already cleaned, non-empty) `text` with `voice_id` at `rate` (0...1, 0.5 = normal) into the WAV file
    /// at `out`.
    fn synthesize(&self, text: &str, voice_id: &str, rate: f64, out: &Path) -> Result<Rendered, SpeechError>;
}

/// The engine of this system; `None` where the build has none.
pub fn system_engine() -> Option<Arc<dyn SpeechEngine>> {
    #[cfg(target_os = "macos")]
    return Some(Arc::new(mac::MacSpeech));
    #[cfg(windows)]
    return Some(Arc::new(win::WinSpeech));
    #[cfg(target_os = "linux")]
    return Some(Arc::new(linux::EspeakSpeech));
    #[cfg(not(any(target_os = "macos", windows, target_os = "linux")))]
    return None;
}

/// Voices sorted as Swift lists them: the language of `own` first, then by language and name.
pub fn sort_voices(list: &mut [SpeechVoice], own: &str) {
    list.sort_by(|a, b| {
        let (x, y) = (a.language.starts_with(own), b.language.starts_with(own));
        y.cmp(&x).then_with(|| (&a.language, &a.name).cmp(&(&b.language, &b.name)))
    });
}

/// The language code of the user's locale (`en` when unknown).
pub fn own_language() -> String {
    let raw = ["LC_ALL", "LC_MESSAGES", "LANG"].iter().filter_map(|k| std::env::var(k).ok()).find(|v| !v.is_empty());
    raw.and_then(|v| v.split(['_', '.', '-']).next().map(str::to_lowercase))
        .filter(|l| l.len() >= 2 && l != "c" && l != "posix")
        .unwrap_or_else(|| "en".to_string())
}

/// Swift `SpeechRenderer.render`: cleans the script, makes room for the file, runs the engine, and removes the partial
/// file on a failure. Blocking.
pub fn render(
    engine: &dyn SpeechEngine,
    text: &str,
    voice_id: &str,
    rate: f64,
    out: &Path,
) -> Result<Time, SpeechError> {
    let script = Voiceover::cleaned(text);
    if script.is_empty() {
        return Err(SpeechError::EmptyText);
    }
    if let Some(dir) = out.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::remove_file(out);
    let result = engine
        .synthesize(&script, voice_id, Voiceover::clamped_rate(rate), out)
        .and_then(|r| if r.frames > 0 && r.sample_rate > 0 { Ok(r.length()) } else { Err(SpeechError::NoAudio) });
    if result.is_err() {
        let _ = std::fs::remove_file(out);
    }
    result
}
