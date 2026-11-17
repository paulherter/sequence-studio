//! What the app root runs each pump for the analysis: the Magic Mask requests and job, and the Stabilizer analysis.

use super::magic_flow::{FlowRequest, MagicFlow, MagicRunner};
use super::magic_job::WakeFn;
use super::stabilize_runner::StabilizeRunner;
use sq_editor_session::EditorSession;

/// The flow the panels fill, and the two runners that carry it out.
pub struct AnalysisLinks {
    flow: MagicFlow,
    magic: MagicRunner,
    stabilize: StabilizeRunner,
}

/// What one pump found out.
#[derive(Debug, Default, PartialEq)]
pub struct AnalysisTurn {
    /// Status lines, oldest first.
    pub lines: Vec<String>,
    /// Average progress of the running jobs (`None`: nothing runs).
    pub progress: Option<f64>,
    /// The Standard Stabilizer analysis in flight `(clip, share 0...1)`, for the Effect Controls row.
    pub stabilize_run: Option<(sq_core_time::Id, f64)>,
}

impl AnalysisLinks {
    /// Runners over the `flow` the monitor and inspector hosts share.
    pub fn new(flow: MagicFlow, magic: MagicRunner, stabilize: StabilizeRunner) -> AnalysisLinks {
        AnalysisLinks { flow, magic, stabilize }
    }

    /// Runs `wake` on a job's thread after each of its messages.
    pub fn set_wake(&mut self, wake: WakeFn) {
        self.magic.set_wake(std::sync::Arc::clone(&wake));
        self.stabilize.set_wake(wake);
    }

    /// The session asked for these clips' Standard Stabilizer analysis (`SessionEvent::StabilizerNeedsAnalysis`, Swift
    /// `onStabilizerNeedsAnalysis` -> `analyzeStabilizers`): they run next, one at a time, a clip that failed before too.
    pub fn analyze_stabilizers(&mut self, clips: &std::collections::BTreeSet<sq_core_time::Id>) {
        for clip in clips {
            self.stabilize.start_for(*clip);
        }
    }

    /// Whether the clip waits for a Stabilizer analysis start or failed.
    pub fn stabilizer_state(&self, clip: sq_core_time::Id) -> Option<super::stabilize_runner::ClipStab> {
        self.stabilize.clip_state(clip)
    }

    /// Carries out the panels' requests, reads both jobs and starts a Stabilizer analysis a clip needs.
    pub fn pump(&mut self, session: &mut EditorSession) -> AnalysisTurn {
        let mut requests = self.flow.take_requests();
        requests.retain(|r| match r {
            FlowRequest::StabilizeStart(clip) => {
                self.stabilize.start_for(*clip);
                false
            }
            FlowRequest::StabilizeStop => {
                self.stabilize.cancel();
                false
            }
            _ => true,
        });
        let mut lines = self.magic.handle(session, requests);
        lines.extend(self.magic.poll());
        lines.extend(self.magic.poll_masks(session));
        lines.extend(self.stabilize.poll(session));
        let running: Vec<f64> = [self.magic.progress(), self.stabilize.progress()].into_iter().flatten().collect();
        let progress = (!running.is_empty()).then(|| running.iter().sum::<f64>() / running.len() as f64);
        AnalysisTurn { lines, progress, stabilize_run: self.stabilize.running() }
    }
}

#[cfg(test)]
mod tests;
