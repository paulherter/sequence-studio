// Swift: TranscriptionService.swift (the async protocol is a blocking trait, PORTING section 9; `Locale` is reduced to the
// identifier text, `Task` cancellation is a `CancelToken` argument and the `Cancelled` error)
//! The speech engine seam.

use crate::transcript::Transcript;
use sq_core_model::AudioChannelMap;
use sq_core_time::IdSource;
use std::fmt;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// Why transcription did not produce words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TranscriptionError {
    /// The recognizer does not know this language (the identifier).
    LocaleUnsupported(String),
    /// There is no audio to transcribe.
    NoAudio,
    /// No speech engine on this system.
    Unavailable,
    /// The engine's library is missing or does not start (message for the status line).
    EngineMissing(String),
    /// The language model could not be downloaded.
    ModelDownloadFailed(String),
    /// The caller canceled (Swift `CancellationError`).
    Cancelled,
}

/// What the status line says.
impl fmt::Display for TranscriptionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TranscriptionError::LocaleUnsupported(id) => {
                write!(f, "Speech recognition does not support the language {id}.")
            }
            TranscriptionError::NoAudio => write!(f, "There is no audio to transcribe."),
            TranscriptionError::Unavailable => write!(f, "Transcription is not available on this system yet."),
            TranscriptionError::EngineMissing(why) => write!(f, "The speech engine is not available: {why}."),
            TranscriptionError::ModelDownloadFailed(why) => {
                write!(f, "The language model could not be downloaded: {why}.")
            }
            TranscriptionError::Cancelled => write!(f, "The job was canceled."),
        }
    }
}

impl std::error::Error for TranscriptionError {}

/// Shared flag a running job polls; clones share the flag.
#[derive(Clone, Debug, Default)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    /// A token that is not canceled.
    pub fn new() -> CancelToken {
        CancelToken::default()
    }

    /// Asks the job to stop.
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    /// Whether `cancel` was called.
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }

    /// `Err(Cancelled)` once canceled (Swift `Task.checkCancellation`).
    pub fn check(&self) -> Result<(), TranscriptionError> {
        if self.is_cancelled() { Err(TranscriptionError::Cancelled) } else { Ok(()) }
    }
}

/// A language identifier such as "de-DE" or "en_GB" (the part of Foundation's `Locale` the transcription code uses).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Locale(String);

impl Locale {
    /// The locale with this identifier.
    pub fn new(identifier: &str) -> Locale {
        Locale(identifier.to_string())
    }

    /// The identifier as given.
    pub fn identifier(&self) -> &str {
        &self.0
    }

    /// The language subtag, lowercased ("zh-Hans-CN" -> "zh"); `None` for an empty identifier.
    pub fn language_code(&self) -> Option<String> {
        let code = self.0.split(['-', '_']).next().unwrap_or_default();
        if code.is_empty() { None } else { Some(code.to_lowercase()) }
    }

    /// `identifier(.bcp47)`: underscores become hyphens.
    pub fn bcp47(&self) -> String {
        self.0.replace('_', "-")
    }
}

/// The speech engine seam (the Windows port plan, seam 5). Another system plugs its own engine in here. Implementations block;
/// the caller runs them on a worker thread.
pub trait TranscriptionService: Send + Sync {
    /// Transcribes the audio of `url`. `progress` reports 0...1 (analyzed time / file duration). New words get their ids from `ids`.
    fn transcribe(
        &self,
        url: &Path,
        locale: &Locale,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
        ids: &mut dyn IdSource,
    ) -> Result<Transcript, TranscriptionError>;

    /// Like `transcribe` for a media item whose clips play the channels `map` names (the item's Audio Channels): only those
    /// channels are heard. Without a map this is `transcribe`; an engine that cannot render channel maps fails with
    /// `Unavailable` (Swift renders the map through AVFoundation, the portable engines through the FFmpeg audio sources).
    fn transcribe_mapped(
        &self,
        url: &Path,
        map: Option<&AudioChannelMap>,
        locale: &Locale,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
        ids: &mut dyn IdSource,
    ) -> Result<Transcript, TranscriptionError> {
        match map {
            None => self.transcribe(url, locale, progress, cancel, ids),
            Some(_) => Err(TranscriptionError::Unavailable),
        }
    }

    /// Whether `Locale::new("auto")` makes the engine find the spoken language itself.
    fn detects_language(&self) -> bool {
        false
    }

    /// Megabytes `prepare` still has to download (`None`: nothing, or an engine without a download). The UI names the size
    /// while the model comes in.
    fn download_megabytes(&self) -> Option<u64> {
        None
    }

    /// Makes `locale` ready (on-device model download and install), reporting 0...1 while a model downloads (engines without
    /// a download ignore it). May take a while: the UI shows a note meanwhile. Swift has a second overload without progress;
    /// pass a no-op closure instead.
    fn prepare(
        &self,
        _locale: &Locale,
        _progress: &mut dyn FnMut(f64),
        _cancel: &CancelToken,
    ) -> Result<(), TranscriptionError> {
        Ok(())
    }

    /// BCP-47 identifiers of the languages the recognizer supports; empty = unknown (the UI keeps its defaults).
    fn supported_languages(&self) -> Vec<String> {
        Vec::new()
    }
}

/// Stand-in where no speech engine exists: every call fails with `Unavailable`.
pub struct UnavailableTranscriptionService;

impl TranscriptionService for UnavailableTranscriptionService {
    fn transcribe(
        &self,
        _url: &Path,
        _locale: &Locale,
        _progress: &mut dyn FnMut(f64),
        _cancel: &CancelToken,
        _ids: &mut dyn IdSource,
    ) -> Result<Transcript, TranscriptionError> {
        Err(TranscriptionError::Unavailable)
    }

    fn prepare(
        &self,
        _locale: &Locale,
        _progress: &mut dyn FnMut(f64),
        _cancel: &CancelToken,
    ) -> Result<(), TranscriptionError> {
        Err(TranscriptionError::Unavailable)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_case_reads_as_a_sentence_not_an_enum_dump() {
        for e in [
            TranscriptionError::Unavailable,
            TranscriptionError::NoAudio,
            TranscriptionError::LocaleUnsupported("de-DE".into()),
        ] {
            let text = e.to_string();
            assert!(!text.contains("TranscriptionError"));
            assert!(text.ends_with('.'));
        }
        assert_eq!(TranscriptionError::Unavailable.to_string(), "Transcription is not available on this system yet.");
    }

    #[test]
    fn locale_identifiers() {
        assert_eq!(Locale::new("zh-Hans-CN").language_code().as_deref(), Some("zh"));
        assert_eq!(Locale::new("EN_gb").language_code().as_deref(), Some("en"));
        assert_eq!(Locale::new("").language_code(), None);
        assert_eq!(Locale::new("de_DE").bcp47(), "de-DE");
    }

    #[test]
    fn the_stand_in_fails_every_call() {
        let s = UnavailableTranscriptionService;
        let l = Locale::new("de");
        assert_eq!(s.prepare(&l, &mut |_| {}, &CancelToken::new()), Err(TranscriptionError::Unavailable));
        assert!(s.supported_languages().is_empty());
    }
}
