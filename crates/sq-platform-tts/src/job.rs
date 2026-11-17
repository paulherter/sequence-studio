//! One render on its own thread. The UI polls [`SpeechJob::poll`] on its pump and never blocks.

use crate::{SpeechEngine, SpeechError, render};
use sq_core_time::Time;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, TryRecvError, channel};

/// The state of a voiceover job; the UI shows each one (progress line, result, failure).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum JobState {
    /// The voice is being made.
    Running,
    /// The file is written; its length.
    Done(Time),
    Failed(SpeechError),
}

/// A render running on a worker thread.
pub struct SpeechJob {
    rx: Receiver<Result<Time, SpeechError>>,
    state: JobState,
}

impl SpeechJob {
    /// Starts the render; `wake` runs on the worker when it ends, so the app can post a redraw.
    pub fn spawn(
        engine: Arc<dyn SpeechEngine>,
        text: String,
        voice_id: String,
        rate: f64,
        out: PathBuf,
        wake: Option<Arc<dyn Fn() + Send + Sync>>,
    ) -> SpeechJob {
        let (tx, rx) = channel();
        let spawned = std::thread::Builder::new().name("voiceover".into()).spawn({
            let tx = tx.clone();
            move || {
                let _ = tx.send(render(engine.as_ref(), &text, &voice_id, rate, &out));
                if let Some(wake) = wake {
                    wake();
                }
            }
        });
        let state = match spawned {
            Ok(_) => JobState::Running,
            Err(e) => JobState::Failed(SpeechError::Failed(e.to_string())),
        };
        SpeechJob { rx, state }
    }

    /// The current state; takes the worker's answer once it is there.
    pub fn poll(&mut self) -> &JobState {
        if self.state == JobState::Running {
            match self.rx.try_recv() {
                Ok(Ok(length)) => self.state = JobState::Done(length),
                Ok(Err(e)) => self.state = JobState::Failed(e),
                Err(TryRecvError::Empty) => {}
                Err(TryRecvError::Disconnected) => {
                    self.state = JobState::Failed(SpeechError::Failed("the voice worker stopped".into()));
                }
            }
        }
        &self.state
    }
}
