//! Loudness measuring off the UI thread: Match Loudness, the Voice Chain readout and the Audio Gain readout hand their
//! one-track sequences to the worker pool one by one and continue when the numbers are there (Swift awaits
//! `measureLoudness` in a task; the UI stays free meanwhile).

use crate::shell_flow_env::LoudnessMeasurer;
use crate::shell_flows::ShellRoot;
use crate::shell_host::ShellHost;
use sq_core_edit::voice_chain_readout::VoiceChainReadout;
use sq_editor_session::LoudnessJob;
use sq_export::core::error::CancelToken;
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;

/// Where a loudness measurement stands.
#[derive(Clone, Debug, Default)]
pub enum LoudnessState {
    /// Nothing is measured.
    #[default]
    Idle,
    /// `done` of `total` sequences are measured; `cancel` stops the one that runs.
    Measuring {
        /// Sequences finished.
        done: usize,
        /// Sequences asked for.
        total: usize,
        /// Cancels the run; the flow then ends without applying anything.
        cancel: CancelToken,
    },
}

/// Puts the state back to `Idle` however the flow ends (finished, canceled or its task dropped).
struct IdleOnDrop<R: ShellRoot + ?Sized>(UiRef<R>);

impl<R: ShellRoot + ?Sized> Drop for IdleOnDrop<R> {
    fn drop(&mut self) {
        let _ = self.0.with(|r| r.shell_parts().shell.flow_env.loudness = LoudnessState::Idle);
    }
}

impl ShellHost {
    /// Whether a loudness measurement runs.
    pub fn is_measuring_loudness(&self) -> bool {
        matches!(self.flow_env.loudness, LoudnessState::Measuring { .. })
    }

    /// Stops the running measurement (the flow that waits for it ends without a result).
    pub fn cancel_loudness(&self) {
        if let LoudnessState::Measuring { cancel, .. } = &self.flow_env.loudness {
            cancel.cancel();
        }
    }

    /// Measures `jobs` one after the other on the worker pool; entry `i` answers job `i` (`None` = silence or a
    /// failure). `None` as a whole when another measurement runs, it was canceled or the UI is gone.
    pub(crate) async fn measure_loudness_jobs<R: ShellRoot + ?Sized>(
        h: &UiRef<R>,
        jobs: Vec<Option<LoudnessJob>>,
    ) -> Option<Vec<Option<f64>>> {
        let (pool, measurer, cancel) = h.with(|r| {
            let p = r.shell_parts();
            if p.shell.is_measuring_loudness() {
                p.shell.flash("Still measuring loudness...");
                return None;
            }
            let media: Vec<_> = p.session.project().media.iter().cloned().collect();
            let sequences: Vec<_> = p.session.project().timelines.iter().cloned().collect();
            let cancel = CancelToken::new();
            p.shell.flow_env.loudness = LoudnessState::Measuring { done: 0, total: jobs.len(), cancel: cancel.clone() };
            Some((
                p.shell.flow_env.services.worker_pool(),
                p.shell.flow_env.services.loudness_measurer(media, sequences),
                cancel,
            ))
        })??;
        let _idle = IdleOnDrop(h.clone());
        let Some(measurer) = measurer else { return Some(vec![None; jobs.len()]) };
        let mut out = Vec::with_capacity(jobs.len());
        for job in jobs {
            let lufs = match job {
                None => None,
                Some(LoudnessJob { timeline, range }) => {
                    let (measurer, token) = (LoudnessMeasurer::clone(&measurer), cancel.clone());
                    match &pool {
                        Some(pool) => pool.run(move |_| measurer(&timeline, range, &token)).await.ok().flatten(),
                        // shortcut: no worker pool, the sequence is measured on the UI thread; upgrade when the app
                        // always provides one.
                        None => measurer(&timeline, range, &token),
                    }
                    .filter(|l| l.is_finite())
                }
            };
            if cancel.is_cancelled() {
                return None;
            }
            out.push(lufs);
            let done = out.len();
            h.with(|r| {
                if let LoudnessState::Measuring { done: d, .. } = &mut r.shell_parts().shell.flow_env.loudness {
                    *d = done;
                }
            })?;
        }
        Some(out)
    }

    /// Clip > Match Loudness: measures the selected clips' runs, then sets the gains.
    pub(crate) async fn run_match_loudness<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(plan) = h.with(|r| {
            let p = r.shell_parts();
            p.shell.flash("Measuring loudness...");
            p.session.match_loudness_plan()
        }) else {
            return;
        };
        let jobs = plan.iter().map(|run| run.job.clone()).collect();
        let Some(measured) = Self::measure_loudness_jobs(&h, jobs).await else { return };
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let mut targets: Vec<f64> = Vec::new();
            for run in &plan {
                if !targets.contains(&run.target) {
                    targets.push(run.target);
                }
            }
            let n = p.session.apply_match_loudness(&plan, &measured) as i64;
            let to = match targets.as_slice() {
                [t] => SQL10n::format(" to %@ LUFS", &[&format!("{t}")]),
                _ => String::new(),
            };
            let line = if n == 0 {
                "The audio is silent: nothing to match.".to_string()
            } else {
                SQL10n::plural(n, "Matched %@ clip", "Matched %@ clips") + &to + "."
            };
            p.shell.flash(&line);
        });
    }

    /// The status line after Voice Chain went on: the selected clips' loudness against the Dialogue target.
    pub(crate) async fn run_voice_chain_readout<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(jobs) = h.with(|r| r.shell_parts().session.voice_chain_jobs()) else { return };
        let Some(values) = Self::measure_loudness_jobs(&h, jobs).await else { return };
        let _ = h.with(|r| {
            if let Some(readout) = VoiceChainReadout::for_dialogue(&values) {
                let line = Self::voice_chain_text(&readout);
                r.shell_parts().shell.flash(&line);
            }
        });
    }
}
