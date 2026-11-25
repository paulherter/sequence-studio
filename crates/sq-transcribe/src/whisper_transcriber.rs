// Swift: WhisperTranscriber.swift (blocking; the caller runs `transcribe` on a worker thread, which replaces the detached task)
//! `TranscriptionService` over a local Whisper model.

use crate::transcript::Transcript;
use crate::transcription_service::{CancelToken, Locale, TranscriptionError, TranscriptionService};
use crate::whisper_languages::WhisperLanguages;
use crate::whisper_model_store::{ModelDownloader, WhisperModelStore};
use crate::whisper_words::{self, WhisperToken};
use sq_core_time::IdSource;
use std::path::Path;

/// The recognizer behind `WhisperTranscriber`: blocking, runs on a background thread. `WhisperRuntime` (whisper.cpp, loaded at
/// run time) is the real one, tests use a fake.
pub trait WhisperEngine: Send + Sync {
    /// `None` when the engine can run, else a short reason for the status line ("whisper.dll not found").
    fn unavailable_reason(&self) -> Option<String>;

    /// Recognizes 16 kHz mono `samples` in `language` (a Whisper code). `progress` reports 0...1, `is_cancelled` is polled and
    /// ends the run (`Err(Cancelled)`). Words come back as tokens with word-level timing. `is_cancelled` may be called from
    /// the engine's own threads, hence `Sync`.
    fn recognize(
        &self,
        model_path: &str,
        samples: &[f32],
        language: &str,
        progress: &mut dyn FnMut(f64),
        is_cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<Vec<WhisperToken>, TranscriptionError>;
}

/// Reads a file's audio as 16 kHz mono floats (FFmpeg on Windows).
pub type AudioReader = Box<dyn Fn(&Path) -> Result<Vec<f32>, TranscriptionError> + Send + Sync>;

/// `TranscriptionService` over a local Whisper model (the Windows port plan, seam 5): the model downloads once into
/// `WhisperModelStore`, the audio comes from `audio`, the words get their timing from `whisper_words::words`. Used by Auto
/// Captions, the transcript search and Remove Silences' word cuts.
pub struct WhisperTranscriber {
    /// Where the model lives.
    pub store: WhisperModelStore,
    engine: Box<dyn WhisperEngine>,
    downloader: Option<Box<dyn ModelDownloader>>,
    audio: AudioReader,
}

impl WhisperTranscriber {
    /// A transcriber; without a `downloader` a missing model cannot be fetched.
    pub fn new(
        store: WhisperModelStore,
        engine: Box<dyn WhisperEngine>,
        downloader: Option<Box<dyn ModelDownloader>>,
        audio: AudioReader,
    ) -> WhisperTranscriber {
        WhisperTranscriber { store, engine, downloader, audio }
    }
}

impl TranscriptionService for WhisperTranscriber {
    fn supported_languages(&self) -> Vec<String> {
        WhisperLanguages::supported()
    }

    fn prepare(
        &self,
        locale: &Locale,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
    ) -> Result<(), TranscriptionError> {
        if WhisperLanguages::code(locale).is_none() {
            return Err(TranscriptionError::LocaleUnsupported(locale.identifier().to_string()));
        }
        if let Some(why) = self.engine.unavailable_reason() {
            return Err(TranscriptionError::EngineMissing(why));
        }
        if self.store.is_installed() {
            return Ok(());
        }
        let Some(downloader) = &self.downloader else {
            return Err(TranscriptionError::ModelDownloadFailed("no connection".into()));
        };
        self.store.install(downloader.as_ref(), progress, cancel)
    }

    fn transcribe(
        &self,
        url: &Path,
        locale: &Locale,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
        ids: &mut dyn IdSource,
    ) -> Result<Transcript, TranscriptionError> {
        let Some(code) = WhisperLanguages::code(locale) else {
            return Err(TranscriptionError::LocaleUnsupported(locale.identifier().to_string()));
        };
        self.prepare(locale, &mut |_| {}, cancel)?;
        let model_path = self.store.model_url().to_string_lossy().into_owned();
        let samples = (self.audio)(url)?;
        if samples.is_empty() {
            return Err(TranscriptionError::NoAudio);
        }
        let tokens =
            self.engine.recognize(&model_path, &samples, &code, &mut |p| progress(p.clamp(0.0, 1.0)), &|| {
                cancel.is_cancelled()
            })?;
        progress(1.0);
        let voiced = crate::whisper_align::voiced_frames_chunked(&samples);
        Ok(Transcript::new(&locale.bcp47(), whisper_words::words_in_voice(&tokens, Some(&voiced), ids)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::whisper_model_store::WhisperModel;
    use crate::whisper_model_store::tests::{Fake, TempFolder, model};
    use sq_core_time::SequentialIds;
    use std::fs;
    use std::sync::Mutex;
    use std::time::Duration;

    #[derive(Default)]
    struct FakeEngine {
        available: Option<String>,
        tokens: Vec<WhisperToken>,
        wait_for_cancel: bool,
        saw: Mutex<(String, usize, String)>,
    }

    impl WhisperEngine for FakeEngine {
        fn unavailable_reason(&self) -> Option<String> {
            self.available.clone()
        }

        fn recognize(
            &self,
            model_path: &str,
            samples: &[f32],
            language: &str,
            progress: &mut dyn FnMut(f64),
            is_cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<Vec<WhisperToken>, TranscriptionError> {
            *self.saw.lock().unwrap() = (language.to_string(), samples.len(), model_path.to_string());
            progress(0.5);
            if self.wait_for_cancel {
                while !is_cancelled() {
                    std::thread::sleep(Duration::from_millis(5));
                }
                return Err(TranscriptionError::Cancelled);
            }
            Ok(self.tokens.clone())
        }
    }

    fn installed() -> (WhisperModelStore, TempFolder) {
        let dir = TempFolder::new();
        let m = WhisperModel {
            name: "t".into(),
            file_name: "m.bin".into(),
            url: "https://example.com/m.bin".into(),
            byte_count: 4,
        };
        let store = WhisperModelStore::new(dir.0.clone(), m);
        fs::create_dir_all(&dir.0).unwrap();
        fs::write(store.model_url(), [0u8; 4]).unwrap();
        (store, dir)
    }

    fn audio(samples: usize) -> AudioReader {
        Box::new(move |_| Ok(vec![0.0; samples]))
    }

    fn run(t: &WhisperTranscriber, id: &str, progress: &mut dyn FnMut(f64)) -> Result<Transcript, TranscriptionError> {
        t.transcribe(
            Path::new("/x.wav"),
            &Locale::new(id),
            progress,
            &CancelToken::new(),
            &mut SequentialIds::default(),
        )
    }

    #[test]
    fn words_language_and_progress_come_through() {
        let (store, _dir) = installed();
        let engine = FakeEngine {
            tokens: vec![WhisperToken {
                bytes: b" Hallo".to_vec(),
                is_special: false,
                start_cs: 0,
                end_cs: 50,
                probability: 0.9,
            }],
            ..Default::default()
        };
        let t = WhisperTranscriber::new(store, Box::new(engine), None, audio(16_000));
        let mut seen: Vec<f64> = Vec::new();
        let r = run(&t, "de-DE", &mut |p| seen.push(p)).unwrap();
        assert_eq!(r.words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>(), ["Hallo"]);
        assert_eq!(r.language, "de-DE");
        assert!(seen.contains(&0.5) && seen.last() == Some(&1.0));
    }

    #[test]
    fn the_engine_sees_language_samples_and_model_path() {
        struct Spy(std::sync::Arc<FakeEngine>);
        impl WhisperEngine for Spy {
            fn unavailable_reason(&self) -> Option<String> {
                self.0.unavailable_reason()
            }
            fn recognize(
                &self,
                m: &str,
                s: &[f32],
                l: &str,
                p: &mut dyn FnMut(f64),
                c: &(dyn Fn() -> bool + Sync),
            ) -> Result<Vec<WhisperToken>, TranscriptionError> {
                self.0.recognize(m, s, l, p, c)
            }
        }
        let (store, _dir) = installed();
        let engine = std::sync::Arc::new(FakeEngine::default());
        let path = store.model_url().to_string_lossy().into_owned();
        let t = WhisperTranscriber::new(store, Box::new(Spy(std::sync::Arc::clone(&engine))), None, audio(16_000));
        run(&t, "de-DE", &mut |_| {}).unwrap();
        assert_eq!(*engine.saw.lock().unwrap(), ("de".to_string(), 16_000, path));
    }

    #[test]
    fn empty_audio_is_no_audio_and_an_unknown_language_is_refused() {
        let (store, _dir) = installed();
        let t = WhisperTranscriber::new(store, Box::new(FakeEngine::default()), None, audio(0));
        assert_eq!(run(&t, "de", &mut |_| {}), Err(TranscriptionError::NoAudio));
        assert_eq!(run(&t, "tlh", &mut |_| {}), Err(TranscriptionError::LocaleUnsupported("tlh".into())));
    }

    #[test]
    fn a_missing_engine_says_so_in_prepare() {
        let (store, _dir) = installed();
        let engine = FakeEngine { available: Some("whisper.dll not found".into()), ..Default::default() };
        let t = WhisperTranscriber::new(store, Box::new(engine), None, audio(1));
        let e = t.prepare(&Locale::new("de-DE"), &mut |_| {}, &CancelToken::new());
        assert_eq!(e, Err(TranscriptionError::EngineMissing("whisper.dll not found".into())));
    }

    #[test]
    fn prepare_downloads_a_missing_model_with_progress() {
        let dir = TempFolder::new();
        let store = WhisperModelStore::new(dir.0.clone(), model(100));
        let installed_check = store.clone();
        let t = WhisperTranscriber::new(
            store,
            Box::new(FakeEngine::default()),
            Some(Box::new(Fake { bytes: 100, fail: false })),
            audio(1),
        );
        let mut seen: Vec<f64> = Vec::new();
        t.prepare(&Locale::new("en-US"), &mut |p| seen.push(p), &CancelToken::new()).unwrap();
        assert!(installed_check.is_installed() && seen.last() == Some(&1.0));
    }

    #[test]
    fn a_missing_model_without_a_downloader_fails() {
        let dir = TempFolder::new();
        let t = WhisperTranscriber::new(
            WhisperModelStore::new(dir.0.clone(), model(100)),
            Box::new(FakeEngine::default()),
            None,
            audio(1),
        );
        let e = t.prepare(&Locale::new("en-US"), &mut |_| {}, &CancelToken::new());
        assert_eq!(e, Err(TranscriptionError::ModelDownloadFailed("no connection".into())));
    }

    #[test]
    fn canceling_stops_the_engine() {
        let (store, _dir) = installed();
        let engine = FakeEngine { wait_for_cancel: true, ..Default::default() };
        let t = WhisperTranscriber::new(store, Box::new(engine), None, audio(2));
        let cancel = CancelToken::new();
        let result = std::thread::scope(|s| {
            let job = s.spawn(|| {
                t.transcribe(Path::new("/x"), &Locale::new("de"), &mut |_| {}, &cancel, &mut SequentialIds::default())
            });
            std::thread::sleep(Duration::from_millis(100));
            cancel.cancel();
            job.join().unwrap()
        });
        assert_eq!(result, Err(TranscriptionError::Cancelled));
    }
}
