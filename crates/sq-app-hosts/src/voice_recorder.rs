// Swift: SQPlayback/VoiceRecorder.swift (`VoiceRecorder`: access check, countdown 3-2-1, then the microphone to a file)
//! The voice-over recorder of the shell over any microphone: a countdown on its own clock, then a `MicTake`. The shell
//! polls `state` (the countdown runs out by itself, nothing blocks the UI), `stop` hands back the take.

use sq_audio_out::input::{CpalMic, MicError, MicSource, MicTake, TAKE_RATE};
use sq_core_time::Time;
use sq_editor_session::{VoiceRecorder, VoiceRecorderError, VoiceRecorderState, VoiceRecordingTake};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Seconds counted down before the microphone opens (Swift `countdown: 3`).
pub const COUNTDOWN_SECONDS: u32 = 3;

enum Phase {
    Idle,
    Countdown {
        since: Duration,
        url: PathBuf,
        anchor: Time,
    },
    Recording {
        take: MicTake,
        url: PathBuf,
        anchor: Time,
    },
    /// The microphone did not open; `take_failure` hands the reason out once and frees the recorder.
    Failed(String),
}

/// The shell's microphone recorder.
pub struct MicRecorder {
    open: Box<dyn Fn() -> Box<dyn MicSource> + Send + Sync>,
    /// True when a microphone exists / the app may use it (Swift `requestAccess`).
    allowed: Box<dyn Fn() -> bool + Send + Sync>,
    now: Box<dyn Fn() -> Duration + Send + Sync>,
    phase: Mutex<Phase>,
}

impl MicRecorder {
    /// The system default input (cpal).
    pub fn system() -> MicRecorder {
        let epoch = Instant::now();
        MicRecorder::with(
            Box::new(|| Box::new(CpalMic::new())),
            Box::new(CpalMic::available),
            Box::new(move || epoch.elapsed()),
        )
    }

    /// Any microphone, access check and clock (tests inject fakes).
    pub fn with(
        open: Box<dyn Fn() -> Box<dyn MicSource> + Send + Sync>,
        allowed: Box<dyn Fn() -> bool + Send + Sync>,
        now: Box<dyn Fn() -> Duration + Send + Sync>,
    ) -> MicRecorder {
        MicRecorder { open, allowed, now, phase: Mutex::new(Phase::Idle) }
    }

    /// Whole seconds left of the countdown, 3 down to 1.
    pub fn countdown_left(&self) -> Option<u32> {
        self.advance();
        let phase = self.lock();
        let Phase::Countdown { since, .. } = &*phase else { return None };
        let passed = (self.now)().saturating_sub(*since).as_secs();
        Some(COUNTDOWN_SECONDS.saturating_sub(u32::try_from(passed).unwrap_or(u32::MAX)).max(1))
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Phase> {
        self.phase.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The reason the last take could not start (the microphone failed to open), once; `None` otherwise.
    pub fn take_failure(&self) -> Option<String> {
        self.advance();
        let mut phase = self.lock();
        if !matches!(&*phase, Phase::Failed(_)) {
            return None;
        }
        match std::mem::replace(&mut *phase, Phase::Idle) {
            Phase::Failed(reason) => Some(reason),
            _ => None,
        }
    }

    /// Opens the microphone when the countdown has run out. A microphone that fails to open ends the take (state
    /// `Idle`, the reason waits in `Failed` for `take_failure`).
    fn advance(&self) {
        let mut phase = self.lock();
        let Phase::Countdown { since, url, anchor } = &*phase else { return };
        if (self.now)().saturating_sub(*since) < Duration::from_secs(u64::from(COUNTDOWN_SECONDS)) {
            return;
        }
        let (url, anchor) = (url.clone(), *anchor);
        *phase = match MicTake::start((self.open)(), &url) {
            Ok(take) => Phase::Recording { take, url, anchor },
            Err(e) => Phase::Failed(match e {
                MicError::NoDevice => "no microphone".to_string(),
                MicError::Failed(text) => text,
            }),
        };
    }
}

impl VoiceRecorder for MicRecorder {
    fn state(&self) -> VoiceRecorderState {
        self.advance();
        match &*self.lock() {
            Phase::Idle | Phase::Failed(_) => VoiceRecorderState::Idle,
            Phase::Countdown { .. } => VoiceRecorderState::Countdown,
            Phase::Recording { .. } => VoiceRecorderState::Recording,
        }
    }

    fn start(&mut self, url: &Path, anchor: Time) -> Result<(), VoiceRecorderError> {
        if !matches!(&*self.lock(), Phase::Idle | Phase::Failed(_)) {
            return Err(VoiceRecorderError::Failed("busy".into()));
        }
        if !(self.allowed)() {
            return Err(VoiceRecorderError::AccessDenied);
        }
        *self.lock() = Phase::Countdown { since: (self.now)(), url: url.to_path_buf(), anchor };
        Ok(())
    }

    fn stop(&mut self) -> Result<VoiceRecordingTake, VoiceRecorderError> {
        self.advance();
        let old = std::mem::replace(&mut *self.lock(), Phase::Idle);
        let Phase::Recording { take, url, anchor } = old else {
            return Err(VoiceRecorderError::Failed("not recording".into()));
        };
        match take.finish() {
            Ok(frames) if frames > 0 => {
                Ok(VoiceRecordingTake { url, duration: Time::new(frames as i64, i64::from(TAKE_RATE)), anchor })
            }
            _ => {
                let _ = std::fs::remove_file(&url);
                Err(VoiceRecorderError::Failed("no sound recorded".into()))
            }
        }
    }

    fn cancel(&mut self) {
        let old = std::mem::replace(&mut *self.lock(), Phase::Idle);
        if let Phase::Recording { take, url, .. } = old {
            let _ = take.finish();
            let _ = std::fs::remove_file(url);
        }
    }
}

#[cfg(test)]
mod tests;
