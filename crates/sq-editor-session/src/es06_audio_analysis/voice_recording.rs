// Swift: EditorSession+VoiceRecording.swift
//! Record Voice-Over, one command: idle starts (access, countdown, record from the playhead while the sequence plays),
//! during the countdown it cancels, while recording it stops, imports the take and places it as a voiceover at the time
//! recording began.
//!
//! The microphone is the shell's: [`VoiceRecorder`] is the seam (Swift's `voiceRecorder`), passed into the commands
//! because the session stores no platform objects.

use std::path::{Path, PathBuf};

use sq_core_audio::voiceover::VoiceoverPlacement;
use sq_core_time::{Id, Time};

use crate::EditorSession;

/// Where the recorder is in a take.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VoiceRecorderState {
    Idle,
    RequestingAccess,
    Countdown,
    Recording,
}

/// Why a recorder did not start or stop.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VoiceRecorderError {
    Canceled,
    AccessDenied,
    Failed(String),
}

/// A finished take.
#[derive(Clone, Debug, PartialEq)]
pub struct VoiceRecordingTake {
    pub url: PathBuf,
    pub duration: Time,
    /// The sequence time recording began at.
    pub anchor: Time,
}

/// The microphone recorder of the shell.
pub trait VoiceRecorder {
    fn state(&self) -> VoiceRecorderState;
    /// A countdown or a take is going.
    fn is_busy(&self) -> bool {
        self.state() != VoiceRecorderState::Idle
    }
    /// Asks for access, counts down and records to `url`; returns when recording runs (or why it does not).
    fn start(&mut self, url: &Path, anchor: Time) -> Result<(), VoiceRecorderError>;
    /// Stops the take.
    fn stop(&mut self) -> Result<VoiceRecordingTake, VoiceRecorderError>;
    /// Drops a countdown or a take (and its file).
    fn cancel(&mut self);
}

/// What one press of Record Voice-Over did.
// Swift: EditorSession+VoiceRecording.swift:6
#[derive(Clone, Debug, PartialEq)]
pub enum VoiceRecordingStep {
    /// The countdown ran out and the microphone is recording. `play`: the sequence should play along (voice-over to
    /// picture, unless the start point is the very end): the caller runs `play_pause`.
    Started {
        play: bool,
    },
    /// The take was imported and placed.
    Placed(VoiceoverPlacement),
    /// A countdown or recording was dropped.
    Canceled,
    /// The microphone is not allowed (System Settings > Privacy & Security > Microphone).
    Denied,
    Failed(String),
}

impl EditorSession {
    /// Shortest take that is kept.
    // Swift: EditorSession+VoiceRecording.swift:21
    pub const MINIMUM_VOICE_RECORDING: Time = Time::new(1, 10);

    /// Record Voice-Over, one command. `importer` imports the take's file into the project and returns the new media id
    /// (it may block on the import step).
    // Swift: EditorSession+VoiceRecording.swift:26
    pub fn toggle_voice_recording(
        &mut self,
        recorder: &mut dyn VoiceRecorder,
        folder: &Path,
        importer: &mut dyn FnMut(&Path) -> Option<Id>,
    ) -> VoiceRecordingStep {
        match recorder.state() {
            VoiceRecorderState::Recording => self.finish_voice_recording(recorder, importer),
            VoiceRecorderState::RequestingAccess | VoiceRecorderState::Countdown => {
                recorder.cancel();
                VoiceRecordingStep::Canceled
            }
            VoiceRecorderState::Idle => self.start_voice_recording(recorder, folder),
        }
    }

    /// Drops a countdown or a running take (and its file).
    // Swift: EditorSession+VoiceRecording.swift:36
    pub fn cancel_voice_recording(&mut self, recorder: &mut dyn VoiceRecorder) {
        if !recorder.is_busy() {
            return;
        }
        recorder.cancel();
        self.stop_playback();
    }

    fn start_voice_recording(&mut self, recorder: &mut dyn VoiceRecorder, folder: &Path) -> VoiceRecordingStep {
        if self.active_timeline_id.is_none() {
            self.set_error("Open a sequence first.");
            return VoiceRecordingStep::Failed("Open a sequence first.".to_string());
        }
        self.stop_playback();
        let mut taken: std::collections::BTreeSet<String> = self
            .project()
            .media
            .iter()
            .filter_map(|m| Path::new(&m.path).file_name().map(|n| n.to_string_lossy().into_owned()))
            .collect();
        if let Ok(dir) = std::fs::read_dir(folder) {
            taken.extend(dir.flatten().map(|e| e.file_name().to_string_lossy().into_owned()));
        }
        let (mut name, mut n) = ("Voice-Over.wav".to_string(), 2);
        while taken.contains(&name) {
            name = format!("Voice-Over {n}.wav");
            n += 1;
        }
        let anchor = self.playhead;
        match recorder.start(&folder.join(name), anchor) {
            Ok(()) => {}
            Err(VoiceRecorderError::Canceled) => return VoiceRecordingStep::Canceled,
            Err(VoiceRecorderError::AccessDenied) => return VoiceRecordingStep::Denied,
            Err(VoiceRecorderError::Failed(_)) => {
                self.set_error("Could not start the microphone.");
                return VoiceRecordingStep::Failed("Could not start the microphone.".to_string());
            }
        }
        // Voice-over to picture: the sequence plays from the start point while the take runs (unless it is at the end).
        let duration = self.active_timeline().map_or(Time::ZERO, |t| t.duration());
        VoiceRecordingStep::Started { play: anchor < duration }
    }

    fn finish_voice_recording(
        &mut self,
        recorder: &mut dyn VoiceRecorder,
        importer: &mut dyn FnMut(&Path) -> Option<Id>,
    ) -> VoiceRecordingStep {
        let take = match self.stop_voice_take(recorder) {
            Ok(t) => t,
            Err(failed) => return failed,
        };
        if let Some(failed) = self.reject_short_take(&take) {
            return failed;
        }
        let Some(media) = importer(&take.url) else { return self.import_failed() };
        self.place_voice_take(&take, media)
    }

    /// Stops playback and the recorder; the take, or the failure step. First half of a finish for a shell that imports the
    /// take on its own: then `reject_short_take`, the import, `place_voice_take`.
    pub fn stop_voice_take(
        &mut self,
        recorder: &mut dyn VoiceRecorder,
    ) -> Result<VoiceRecordingTake, VoiceRecordingStep> {
        self.stop_playback();
        recorder.stop().map_err(|_| {
            self.set_error("The recording failed.");
            VoiceRecordingStep::Failed("The recording failed.".to_string())
        })
    }

    /// The "too short" failure (and the file dropped) for a take under `MINIMUM_VOICE_RECORDING`; `None` = long enough.
    /// For a shell that imports the take on its own (asynchronously) between this check and `place_voice_take`.
    pub fn reject_short_take(&mut self, take: &VoiceRecordingTake) -> Option<VoiceRecordingStep> {
        if take.duration >= Self::MINIMUM_VOICE_RECORDING {
            return None;
        }
        let _ = std::fs::remove_file(&take.url);
        self.set_error("The recording was too short.");
        Some(VoiceRecordingStep::Failed("The recording was too short.".to_string()))
    }

    /// The failure when the take's file could not be imported.
    pub fn import_failed(&mut self) -> VoiceRecordingStep {
        self.set_error("Could not import the recording.");
        VoiceRecordingStep::Failed("Could not import the recording.".to_string())
    }

    /// Places the imported `take` (media `media`) as a voiceover at the time recording began.
    pub fn place_voice_take(&mut self, take: &VoiceRecordingTake, media: Id) -> VoiceRecordingStep {
        let clip_name = take.url.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        match self.place_voiceover(media, &clip_name, take.duration, Some(take.anchor)) {
            Some(placed) => VoiceRecordingStep::Placed(placed),
            None => {
                VoiceRecordingStep::Failed(self.last_error().unwrap_or("Could not place the recording.").to_string())
            }
        }
    }
}
