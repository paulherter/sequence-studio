// Swift: SQTranscribe `FFmpegAudioSource.monoSamples` (the Windows audio input), `TimelineTranscription` (the job), SpeechTranscription
//! Speech to text on a worker: the FFmpeg audio reader (16 kHz mono floats, the item's channel map applied), the platform's
//! transcription service and the job that runs one Transcribe request of the captions panel (download the model, transcribe
//! the sequence, report). The Mac keeps Apple's Speech framework in the Swift app only; this crate's engine is Whisper on
//! ONNX Runtime wherever the runtime is installed.

use sq_core_model::AudioChannelMap;
#[cfg(test)]
use sq_core_time::{Id, IdSource};
use sq_inspector_ui::captions::panel_model::TranscribeRequest;
use sq_media::media_error::MediaError;
use sq_media::memory_audio_source::AudioSource;
use sq_media_ffmpeg::decode::FFmpegAudioSource;
use sq_transcribe::onnx_whisper::OnnxWhisperService;
use sq_transcribe::timeline_transcription::TimelineTranscription;
use sq_transcribe::transcript::Transcript;
use sq_transcribe::transcription_service::{CancelToken, Locale, TranscriptionError, TranscriptionService};
use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, channel};

/// What Whisper wants.
const RATE: i32 = 16_000;
/// Frames read per call while mixing a mapped source down.
const CHUNK: usize = 16_384;

fn failure(e: MediaError) -> TranscriptionError {
    TranscriptionError::EngineMissing(e.to_string())
}

/// The best audio stream of `path` as 16 kHz mono floats. `NoAudio` for a file without sound.
pub fn read_mono(path: &Path) -> Result<Vec<f32>, TranscriptionError> {
    match FFmpegAudioSource::stream_info(path) {
        Ok(None) => return Err(TranscriptionError::NoAudio),
        Ok(Some(_)) => {}
        Err(e) => return Err(failure(e)),
    }
    FFmpegAudioSource::mono_samples(path, RATE).map_err(failure)
}

/// The audio of `path` as the media item's Audio Channels `map` plays it (only the chosen channels), at 16 kHz mono.
pub fn read_mapped(path: &Path, map: &AudioChannelMap) -> Result<Vec<f32>, TranscriptionError> {
    let source = FFmpegAudioSource::open_mapped(path, RATE, Some(map)).map_err(failure)?;
    mix_down(source.as_ref())
}

/// Left and right averaged into one channel (a mono source is delivered on both sides: its channel as it is).
pub fn mix_down(source: &dyn AudioSource) -> Result<Vec<f32>, TranscriptionError> {
    let (mut left, mut right) = (vec![0.0f32; CHUNK], vec![0.0f32; CHUNK]);
    let mut out = Vec::new();
    let mut at = 0i64;
    loop {
        let n = source.read(at, &mut left, 0).map_err(failure)?;
        if n == 0 {
            return Ok(out);
        }
        if source.is_mono() {
            out.extend_from_slice(&left[..n]);
        } else {
            let m = source.read(at, &mut right, 1).map_err(failure)?.min(n);
            out.extend((0..n).map(|i| if i < m { (left[i] + right[i]) / 2.0 } else { left[i] / 2.0 }));
        }
        at += i64::try_from(n).unwrap_or(0);
    }
}

/// The app's transcription service: Whisper on ONNX Runtime (`SQ_WHISPER_ONNX_SIZE`, small by default), the model downloaded
/// on first use, the audio from FFmpeg. Without the runtime a run fails with "the speech engine is not available".
pub fn platform_service() -> Arc<dyn TranscriptionService> {
    let env = |k: &str| std::env::var(k).ok();
    Arc::new(OnnxWhisperService::standard(env, Box::new(read_mono)).with_mapped_audio(Box::new(read_mapped)))
}

pub use sq_core_time::RandomIds;

/// What the worker tells the UI thread.
pub(crate) enum SpeechMessage {
    /// The model downloads: 0...1.
    Preparing(f64),
    /// The model is ready.
    PreparationDone,
    /// Transcription progress 0...1.
    Progress(f64),
    /// The run ended.
    Done(Result<Transcript, TranscriptionError>),
}

/// Where a Transcribe run is, for the status line: one value, one `next` (the panel keeps its own model of the same run).
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub(crate) enum TranscribeState {
    #[default]
    Idle,
    /// The model downloads (`megabytes`: its size, `None` when it is there already).
    DownloadingModel {
        percent: u32,
        megabytes: Option<u64>,
    },
    Transcribing {
        percent: u32,
    },
    Done {
        words: usize,
    },
    /// The engine, the model download or the audio failed (the status text).
    Failed(String),
    Canceled(String),
}

/// The rounded whole percent the status line shows for a 0...1 share.
fn whole_percent(p: f64) -> u32 {
    format!("{:.0}", p * 100.0).parse().unwrap_or(0)
}

impl TranscribeState {
    /// The state after one worker message; `megabytes` is the model download size of the run.
    pub(crate) fn next(self, message: &SpeechMessage, megabytes: Option<u64>) -> TranscribeState {
        match message {
            SpeechMessage::Preparing(p) => TranscribeState::DownloadingModel { percent: whole_percent(*p), megabytes },
            SpeechMessage::PreparationDone => TranscribeState::Transcribing { percent: 0 },
            SpeechMessage::Progress(p) => TranscribeState::Transcribing { percent: whole_percent(*p) },
            SpeechMessage::Done(Ok(t)) => TranscribeState::Done { words: t.words.len() },
            SpeechMessage::Done(Err(TranscriptionError::Cancelled)) => {
                TranscribeState::Canceled(TranscriptionError::Cancelled.to_string())
            }
            SpeechMessage::Done(Err(e)) => TranscribeState::Failed(e.to_string()),
        }
    }

    /// The status line of this state; `None` for `Idle` and the silent `PreparationDone` step.
    pub(crate) fn line(&self) -> Option<String> {
        match self {
            TranscribeState::Idle => None,
            TranscribeState::DownloadingModel { percent, megabytes } => {
                let size = megabytes.map_or(String::new(), |mb| format!(" ({mb} MB)"));
                Some(format!("Downloading the speech model{size}: {percent} %"))
            }
            TranscribeState::Transcribing { percent: 0 } => None,
            TranscribeState::Transcribing { percent } => Some(format!("Transcribing: {percent} %")),
            TranscribeState::Done { words } => Some(format!("Transcribed {words} words.")),
            TranscribeState::Failed(text) | TranscribeState::Canceled(text) => Some(text.clone()),
        }
    }
}

/// One Transcribe request of the captions panel running on a worker thread.
pub(crate) struct SpeechJob {
    rx: Receiver<SpeechMessage>,
    cancel: CancelToken,
    /// The panel's run number: reports carry it back.
    pub run: u64,
    /// Megabytes the model download takes (`None`: the model is there already).
    pub megabytes: Option<u64>,
}

impl SpeechJob {
    /// Starts `request` on `service`. With `auto_language` and an engine that detects the language, the spoken language is
    /// found by the engine (Swift re-runs with the language it guesses from the text); otherwise the chosen one is used.
    pub(crate) fn start(
        service: Arc<dyn TranscriptionService>,
        request: TranscribeRequest,
        auto_language: bool,
    ) -> SpeechJob {
        let (tx, rx) = channel();
        let cancel = CancelToken::new();
        let token = cancel.clone();
        let megabytes = service.download_megabytes();
        let run = request.run;
        std::thread::spawn(move || {
            let send = |m: SpeechMessage| tx.send(m).is_ok();
            let locale = if auto_language && service.detects_language() { Locale::new("auto") } else { request.locale };
            let prepared = service.prepare(&locale, &mut |p| _ = send(SpeechMessage::Preparing(p)), &token);
            if let Err(e) = prepared {
                send(SpeechMessage::Done(Err(e)));
                return;
            }
            send(SpeechMessage::PreparationDone);
            let mut ids = RandomIds;
            let mut progress = |p: f64| _ = send(SpeechMessage::Progress(p));
            let result = match (&request.sequence, &request.url) {
                (Some(s), _) => TimelineTranscription::transcribe(
                    &s.timeline,
                    &s.urls,
                    &s.channel_maps,
                    &s.expected_channels,
                    service.as_ref(),
                    &locale,
                    &mut progress,
                    &token,
                    &mut ids,
                ),
                (None, Some(url)) => service.transcribe(url, &locale, &mut progress, &token, &mut ids),
                (None, None) => Err(TranscriptionError::NoAudio),
            };
            send(SpeechMessage::Done(result));
        });
        SpeechJob { rx, cancel, run, megabytes }
    }

    /// Asks the worker to stop; its end still arrives (the panel ignores it: the run number moved on).
    pub(crate) fn cancel(&self) {
        self.cancel.cancel();
    }

    /// The messages since the last call.
    pub(crate) fn poll(&self) -> Vec<SpeechMessage> {
        self.rx.try_iter().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_media::memory_audio_source::MemoryAudioSource;
    use sq_transcribe::transcript::TranscriptWord;

    #[test]
    fn a_stereo_source_mixes_down_to_the_mean_and_a_mono_one_stays_as_it_is() {
        let stereo = MemoryAudioSource::new(vec![1.0; 20_000], vec![0.0; 20_000]);
        let mixed = mix_down(&stereo).expect("mix");
        assert_eq!(mixed.len(), 20_000);
        assert!(mixed.iter().all(|s| (*s - 0.5).abs() < 1e-6));
        let mono = MemoryAudioSource::mono(vec![0.25; 100]);
        assert_eq!(mix_down(&mono).expect("mix"), vec![0.25; 100]);
        assert!(mix_down(&MemoryAudioSource::new(Vec::new(), Vec::new())).expect("mix").is_empty());
    }

    fn transcript(words: usize) -> Transcript {
        let range = sq_core_time::TimeRange::new(sq_core_time::Time::ZERO, sq_core_time::Time::seconds(1));
        let words = (0..words).map(|i| TranscriptWord::new(Id::from_u128(i as u128 + 1), "w", range)).collect();
        Transcript::new("en-US", words)
    }

    #[test]
    fn a_run_goes_download_then_transcribe_then_done() {
        let mut s = TranscribeState::default();
        assert_eq!(s.line(), None);
        s = s.next(&SpeechMessage::Preparing(0.5), Some(75));
        assert_eq!(s.line().as_deref(), Some("Downloading the speech model (75 MB): 50 %"));
        s = s.next(&SpeechMessage::PreparationDone, Some(75));
        assert_eq!(s.line(), None, "the step between the two is silent");
        s = s.next(&SpeechMessage::Progress(0.25), Some(75));
        assert_eq!(s.line().as_deref(), Some("Transcribing: 25 %"));
        s = s.next(&SpeechMessage::Done(Ok(transcript(3))), Some(75));
        assert_eq!(s, TranscribeState::Done { words: 3 });
        assert_eq!(s.line().as_deref(), Some("Transcribed 3 words."));
    }

    #[test]
    fn a_model_that_is_there_has_no_size_and_no_stale_percent_survives_the_end() {
        let s = TranscribeState::default().next(&SpeechMessage::Preparing(0.1), None);
        assert_eq!(s.line().as_deref(), Some("Downloading the speech model: 10 %"));
        let failed = s.next(&SpeechMessage::Done(Err(TranscriptionError::ModelDownloadFailed("offline".into()))), None);
        assert!(matches!(&failed, TranscribeState::Failed(t) if t.contains("offline")), "{failed:?}");
        let canceled = TranscribeState::Transcribing { percent: 40 }
            .next(&SpeechMessage::Done(Err(TranscriptionError::Cancelled)), None);
        assert!(matches!(canceled, TranscribeState::Canceled(_)));
        assert!(canceled.line().is_some());
    }

    #[test]
    fn random_ids_differ() {
        let mut ids = RandomIds;
        assert_ne!(ids.next_id(), ids.next_id());
    }

    /// Real model and real media: `SQ_SPEECH_CLIP` is a media file with English speech, ONNX Runtime and FFmpeg are on the
    /// PATH, `SQ_WHISPER_MODELS` / `SQ_WHISPER_ONNX_SIZE` name the model cache. Skips without them.
    #[test]
    fn a_real_clip_is_transcribed_through_ffmpeg_with_language_detection_and_a_channel_map() {
        let Ok(clip) = std::env::var("SQ_SPEECH_CLIP") else {
            eprintln!("skipped: SQ_SPEECH_CLIP (a media file with English speech) is not set");
            return;
        };
        let service = platform_service();
        let auto = Locale::new("auto");
        if let Err(e) = service.prepare(&auto, &mut |_| {}, &CancelToken::new()) {
            assert!(matches!(e, TranscriptionError::EngineMissing(_)), "{e}");
            eprintln!("skipped: {e}");
            return;
        }
        let path = Path::new(&clip);
        let text =
            |t: &Transcript| t.words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" ").to_lowercase();
        let t = service.transcribe(path, &auto, &mut |_| {}, &CancelToken::new(), &mut RandomIds).expect("transcribe");
        eprintln!("detected {} -> {}", t.language, text(&t));
        assert!(t.language.starts_with("en"), "{}", t.language);
        assert!(text(&t).contains("country"), "{}", text(&t));
        // The same clip through the item's channel map (first channel only).
        let map = AudioChannelMap::mono(0).expect("map");
        let m = service
            .transcribe_mapped(
                path,
                Some(&map),
                &Locale::new("en-US"),
                &mut |_| {},
                &CancelToken::new(),
                &mut RandomIds,
            )
            .expect("mapped");
        assert!(text(&m).contains("country"), "{}", text(&m));
    }
}
