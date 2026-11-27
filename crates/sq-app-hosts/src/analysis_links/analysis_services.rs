//! The shell's analysis services: the `AnalysisFlows` (Auto Reframe, Find Scene Changes, Stabilize) over a backend, a launcher
//! that runs their work on its own thread, and the pump that routes the workers' messages back (the Swift `AnalysisFlows`
//! held the session and awaited tasks; here the worker posts to an inbox the app root reads each pump).

use super::anonymize_runner::AnonymizeRunner;
use super::magic_job::WakeFn;
use super::picture_sampler::PictureSampler;
use crate::speech::RandomIds;
use crate::voice_recorder::MicRecorder;
use sq_core_model::{MediaRef, Timeline};
use sq_core_time::{Id, Time};
use sq_draw_shell::MediaProbe as ProbeFn;
use sq_draw_shell::{AnonymizeEvent, LoudnessMeasurer, MogrtRead, ShellServices, ShellVoiceoverError, WaveformLookup};
use sq_editor_session::{
    AnalysisBackend, AnalysisFlows, AnalysisFlowsMessage, AnalysisLauncher, AnalysisPoster, AnalysisWork,
    AnonymizeChoice, EditorSession, VoiceRecorder, VoiceRecorderState, VoiceRecordingStep, VoiceRecordingTake,
};
use sq_library::preset_store::PresetStore;
use sq_media::waveform_data::WaveformData;
use sq_platform_tts::{JobState, SpeechEngine, SpeechError, SpeechJob};
use sq_runtime::{ModalAnswer, ModalAsk, modal};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// The capture key of Match Color to Clip (`AnalysisFlows` asks under it).
const COLOR_MATCH_KEY: &str = "color.match.clip";

/// Where a launcher's wake-up goes once the app has set it.
type WakeSlot = Arc<Mutex<Option<WakeFn>>>;

/// Runs each piece of work on a new thread; messages come back through the channel and wake the app.
pub struct ThreadLauncher {
    tx: Sender<AnalysisFlowsMessage>,
    wake: WakeSlot,
}

impl AnalysisLauncher for ThreadLauncher {
    fn poster(&self) -> AnalysisPoster {
        let tx = Mutex::new(self.tx.clone());
        let wake = Arc::clone(&self.wake);
        Arc::new(move |message| {
            if let Ok(tx) = tx.lock() {
                let _ = tx.send(message);
            }
            let wake = wake.lock().ok().and_then(|w| w.clone());
            if let Some(wake) = wake {
                wake();
            }
        })
    }

    fn launch(&mut self, work: AnalysisWork) {
        let spawned = std::thread::Builder::new().name("sq-analysis".into()).spawn(move || {
            // Ids from the system's random source: the session's sequential ones are not safe on this thread.
            let mut ids = RandomIds;
            work(&mut ids);
        });
        if let Err(e) = spawned {
            sq_os::errln!("analysis worker did not start: {e}");
        }
    }
}

/// A probe on a worker: where its result arrives and the answer the shell flow waits on.
type RunningProbe = (Receiver<Option<MediaRef>>, ModalAnswer<Option<MediaRef>>);

/// The analysis flows with their launcher and inbox: what the shell asks for through `ShellServices::analysis`.
pub struct AnalysisServices {
    flows: AnalysisFlows,
    launcher: ThreadLauncher,
    inbox: Receiver<AnalysisFlowsMessage>,
    anonymize: Option<AnonymizeRunner>,
    /// Record Voice-Over: the microphone and the folder its takes are written in.
    voice: Option<(MicRecorder, PathBuf)>,
    /// Match Color to Clip: the sampler over the monitor picture and the run waiting with its deadline.
    sampler: Option<PictureSampler>,
    color_match: Option<(i64, Instant)>,
    /// The timeline's waveform cache, handed over by the app root.
    waveforms: Option<WaveformLookup>,
    /// Voiceover from Text: the system's speech engine and the renders running on workers, each with the answer the
    /// shell flow waits on.
    speech: Option<Arc<dyn SpeechEngine>>,
    speech_jobs: Vec<(SpeechJob, ModalAnswer<Result<Time, ShellVoiceoverError>>)>,
    wake: Option<WakeFn>,
    /// The app's shared pool for blocking shell work (Match Loudness, Collect Files, imports, angle sync).
    pool: Option<Arc<sq_runtime::WorkerPool>>,
    /// The Looks Add Title styles with (the one the app root holds).
    looks: Option<Arc<sq_editor_session::LookStore>>,
    /// The folder `presets.json` lives below, and the handle the import flows write through (see `preset_store`).
    preset_support: Option<PathBuf>,
    presets: Option<PresetStore>,
    /// The app's media probe (the FFmpeg probe on every platform) and the probes running on workers.
    prober: Option<ProbeFn>,
    probes: Vec<RunningProbe>,
}

impl AnalysisServices {
    /// Flows over `backend`.
    pub fn new(backend: Box<dyn AnalysisBackend>) -> AnalysisServices {
        let (tx, inbox) = channel();
        AnalysisServices {
            flows: AnalysisFlows::new(Some(backend)),
            launcher: ThreadLauncher { tx, wake: WakeSlot::default() },
            inbox,
            anonymize: None,
            voice: None,
            sampler: None,
            color_match: None,
            waveforms: None,
            speech: None,
            speech_jobs: Vec::new(),
            wake: None,
            pool: None,
            looks: None,
            preset_support: None,
            presets: None,
            prober: None,
            probes: Vec::new(),
        }
    }

    /// Gives Add Title the Looks the app root holds.
    pub fn with_looks(mut self, looks: Arc<sq_editor_session::LookStore>) -> AnalysisServices {
        self.looks = Some(looks);
        self
    }

    /// Lets the preset imports (Premiere presets, .mogrt) write the user preset library below `support`.
    pub fn with_preset_support(mut self, support: PathBuf) -> AnalysisServices {
        self.preset_support = Some(support);
        self
    }

    /// Hands the shell flows the app's worker pool (`ShellServices::worker_pool`).
    pub fn with_worker_pool(mut self, pool: Arc<sq_runtime::WorkerPool>) -> AnalysisServices {
        self.pool = Some(pool);
        self
    }

    /// Adds Record Voice-Over over `recorder`; takes go into `folder` (Swift `Sequence Studio/Voiceovers`).
    pub fn with_voice_recorder(mut self, recorder: MicRecorder, folder: PathBuf) -> AnalysisServices {
        self.voice = Some((recorder, folder));
        self
    }

    /// Adds Voiceover from Text over `engine` (`None`: the command says it is not available).
    pub fn with_speech(mut self, engine: Option<Arc<dyn SpeechEngine>>) -> AnalysisServices {
        self.speech = engine;
        self
    }

    /// Gives the flows a frame sampler over the monitor picture (Match Color to Clip).
    pub fn with_frame_sampler(mut self, sampler: PictureSampler) -> AnalysisServices {
        self.flows.frame_sampler = Some(Box::new(sampler.clone()));
        self.sampler = Some(sampler);
        self
    }

    /// Adds Clip > Video Options > Anonymize over `runner`.
    pub fn with_anonymize(mut self, runner: AnonymizeRunner) -> AnalysisServices {
        self.anonymize = Some(runner);
        self
    }
}

/// The wall clock for the preset store's recovery stamp.
fn wall_now() -> sq_core_time::Timestamp {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64());
    sq_core_time::Timestamp::from_unix_seconds(secs)
}

impl AnalysisServices {
    /// Answers the flows whose voice render ended; a flow that was canceled meanwhile drops its job.
    fn pump_speech(&mut self) {
        self.speech_jobs.retain_mut(|(job, answer)| {
            if answer.asker_gone() {
                return false;
            }
            match job.poll() {
                JobState::Running => true,
                JobState::Done(length) => {
                    answer.answer(Ok(*length));
                    false
                }
                JobState::Failed(e) => {
                    let e = if *e == SpeechError::NoAudio {
                        ShellVoiceoverError::NoAudio
                    } else {
                        ShellVoiceoverError::Failed
                    };
                    answer.answer(Err(e));
                    false
                }
            }
        });
    }

    /// Hands a finished capture to the run, or ends the run once its time is up.
    fn pump_color_match(&mut self, session: &mut EditorSession) {
        let Some((run, deadline)) = self.color_match else { return };
        if let Some(samples) = self.sampler.as_ref().and_then(|s| s.take_ready(COLOR_MATCH_KEY)) {
            self.flows.handle_color_samples(session, samples);
        } else if Instant::now() >= deadline {
            if let Some(s) = &self.sampler {
                s.cancel(COLOR_MATCH_KEY);
            }
            self.flows.expire_color_match(session, run);
            self.color_match = None;
        }
        if !self.flows.is_color_matching() {
            self.color_match = None;
        }
    }
}

impl ShellServices for AnalysisServices {
    fn worker_pool(&self) -> Option<Arc<sq_runtime::WorkerPool>> {
        self.pool.clone()
    }

    fn look_store(&self) -> Option<&sq_editor_session::LookStore> {
        self.looks.as_deref()
    }

    // shortcut: the Library model keeps its own PresetStore, so the import flows get a fresh handle on the same file per
    // call (every write is atomic and immediate) and the model re-reads the file on `PresetsChanged`; upgrade when
    // the Library model shares one store.
    fn preset_store(&mut self) -> Option<&mut PresetStore> {
        let support = self.preset_support.as_ref()?;
        self.presets = PresetStore::open_in_support(support, false, wall_now()).ok();
        self.presets.as_mut()
    }

    fn attach_probe(&mut self, probe: ProbeFn) {
        self.prober = Some(probe);
    }

    fn probe(&mut self, url: &Path) -> Option<ModalAsk<Option<MediaRef>>> {
        let prober = Arc::clone(self.prober.as_ref()?);
        let (ask, answer) = modal();
        let (tx, rx) = channel();
        let (path, wake) = (url.to_path_buf(), self.wake.clone());
        let work = move || {
            let _ = tx.send(prober(&path));
            if let Some(wake) = wake {
                wake();
            }
        };
        match &self.pool {
            Some(pool) => pool.execute(work),
            None => {
                if let Err(e) = std::thread::Builder::new().name("sq-probe".into()).spawn(work) {
                    sq_os::errln!("probe worker did not start: {e}");
                    answer.answer(None);
                    return Some(ask);
                }
            }
        }
        self.probes.push((rx, answer));
        Some(ask)
    }

    fn analysis(&mut self) -> Option<(&mut AnalysisFlows, &mut dyn AnalysisLauncher)> {
        Some((&mut self.flows, &mut self.launcher))
    }

    fn analysis_flows(&self) -> Option<&AnalysisFlows> {
        Some(&self.flows)
    }

    fn attach_waveforms(&mut self, lookup: WaveformLookup) {
        self.waveforms = Some(lookup);
    }

    fn waveform(&self, media: Id) -> Option<Arc<WaveformData>> {
        self.waveforms.as_ref().and_then(|w| w(media))
    }

    fn has_waveforms(&self) -> bool {
        self.waveforms.is_some()
    }

    fn loudness_measurer(&self, media: Vec<MediaRef>, sequences: Vec<Timeline>) -> Option<LoudnessMeasurer> {
        Some(Arc::new(move |timeline, range, cancel| {
            super::audio_services::measure_lufs(&media, &sequences, timeline, range, cancel)
        }))
    }

    fn read_mogrt(&mut self, url: &Path) -> Result<MogrtRead, String> {
        super::audio_services::read_mogrt(url)
    }

    fn pump(&mut self, session: &mut EditorSession) {
        while let Ok(message) = self.inbox.try_recv() {
            self.flows.handle_message(session, &mut self.launcher, message);
        }
        if let Some(a) = &mut self.anonymize {
            a.pump(session);
        }
        self.pump_color_match(session);
        self.pump_speech();
        self.probes.retain(|(rx, answer)| {
            if answer.asker_gone() {
                return false;
            }
            match rx.try_recv() {
                Ok(found) => {
                    answer.answer(found);
                    false
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => true,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    answer.answer(None);
                    false
                }
            }
        });
    }

    fn voices(&self) -> Option<Vec<(String, String)>> {
        Some(self.speech.as_ref()?.voices().iter().map(|v| (v.id.clone(), v.title())).collect())
    }

    fn render_voiceover(
        &mut self,
        text: &str,
        voice_id: &str,
        rate: f64,
        url: &Path,
    ) -> Option<ModalAsk<Result<Time, ShellVoiceoverError>>> {
        let engine = Arc::clone(self.speech.as_ref()?);
        let (ask, answer) = modal();
        let job = SpeechJob::spawn(
            engine,
            text.to_string(),
            voice_id.to_string(),
            rate,
            url.to_path_buf(),
            self.wake.clone(),
        );
        self.speech_jobs.push((job, answer));
        Some(ask)
    }

    fn color_match_started(&mut self, run: i64) {
        self.color_match = Some((run, Instant::now() + self.flows.color_match_timeout));
    }

    fn run_anonymize(&mut self, session: &mut EditorSession) -> bool {
        let Some(a) = &mut self.anonymize else { return false };
        a.request(session);
        true
    }

    fn anonymize_running(&self) -> bool {
        self.anonymize.as_ref().is_some_and(AnonymizeRunner::is_running)
    }

    fn anonymize_answer(&mut self, _session: &mut EditorSession, choice: Option<AnonymizeChoice>) {
        if let Some(a) = &mut self.anonymize {
            a.answer(choice);
        }
    }

    fn take_anonymize_events(&mut self) -> Vec<AnonymizeEvent> {
        self.anonymize.as_mut().map(AnonymizeRunner::take_events).unwrap_or_default()
    }

    fn voice_recorder_state(&self) -> Option<VoiceRecorderState> {
        self.voice.as_ref().map(|(r, _)| r.state())
    }

    fn voice_countdown_left(&self) -> Option<u32> {
        self.voice.as_ref().and_then(|(r, _)| r.countdown_left())
    }

    fn voice_take_failure(&mut self) -> Option<String> {
        self.voice.as_ref().and_then(|(r, _)| r.take_failure())
    }

    fn voiceover_folder(&self) -> PathBuf {
        self.voice.as_ref().map_or_else(|| std::env::temp_dir().join("Sequence Studio/Voiceovers"), |(_, f)| f.clone())
    }

    fn toggle_voice_recording(&mut self, session: &mut EditorSession, folder: &Path) -> Option<VoiceRecordingStep> {
        let (recorder, _) = self.voice.as_mut()?;
        // A stop goes through `stop_voice_take` (the shell imports the take); here the importer is never asked.
        Some(session.toggle_voice_recording(recorder, folder, &mut |_| None))
    }

    fn stop_voice_take(
        &mut self,
        session: &mut EditorSession,
    ) -> Option<Result<VoiceRecordingTake, VoiceRecordingStep>> {
        let (recorder, _) = self.voice.as_mut()?;
        Some(session.stop_voice_take(recorder))
    }

    fn set_wake(&mut self, wake: WakeFn) {
        self.wake = Some(Arc::clone(&wake));
        if let Some(a) = &self.anonymize
            && let Ok(mut slot) = a.wake_slot().lock()
        {
            *slot = Some(Arc::clone(&wake));
        }
        if let Ok(mut slot) = self.launcher.wake.lock() {
            *slot = Some(wake);
        }
    }
}

#[cfg(test)]
pub(crate) mod tests;
