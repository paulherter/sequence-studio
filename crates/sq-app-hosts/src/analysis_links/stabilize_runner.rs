//! Starts the Stabilizer analysis by itself: a clip whose enabled Standard Stabilizer has no analysis for what it shows
//! gets a [`StabilizationJob`]; the finished run re-plans the clip (Swift `EditorSession+Stabilize` `analyzeStabilizers`).
// Several clips (Start on each selected clip) wait in `clips` and run one after the other over the source range each clip
// shows; no queue for Rolling Shutter requests: the analysis always measures the rolling sample, so switching it on later needs no second run.
// Start / Stop of the Effect Controls row: `start_for` / `cancel`.

use super::magic_job::WakeFn;
use super::stabilization_analyzer::{StabilizationJob, StabilizationMessage, StabilizationRequest};
use super::stabilization_store::StabilizationStore;
use sq_analysis::stabilization_analyzing::StabilizationAnalyzing;
use sq_core_masks::stabilize_effect::{ClipEffectStabilizeExt, StabilizerMethod};
use sq_core_model::ClipEffect;
use sq_core_time::Id;
use sq_editor_session::EditorSession;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Builds the analyzer of a media file.
pub type MakeAnalyzer = Box<dyn Fn(&Path) -> Box<dyn StabilizationAnalyzing + Send>>;

/// The one run that is going; its progress lives here, so there is none without a run.
struct Running {
    job: StabilizationJob,
    clip: Id,
    /// 0...1, 0 before the first frame.
    progress: f64,
}

/// What a clip waits for besides the run; one entry per clip, so "requested" and "failed" cannot both hold.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClipStab {
    /// The row asked for Start (also when the clip is analyzed already: Start Again).
    Requested,
    /// The run failed or was stopped; the clip tries again once it stops needing an analysis (effect switched off).
    Failed,
}

/// Watches the session for clips that need an analysis and follows the job on the UI thread.
pub struct StabilizeRunner {
    store: StabilizationStore,
    cache_dir: Option<PathBuf>,
    make: MakeAnalyzer,
    wake: WakeFn,
    running: Option<Running>,
    /// Per clip: requested or failed, with the order of the requests (the second value).
    clips: BTreeMap<Id, (ClipStab, u64)>,
    next_order: u64,
}

impl StabilizeRunner {
    /// A runner writing into `store`; finished runs are kept in `cache_dir`.
    pub fn new(
        store: StabilizationStore,
        cache_dir: Option<PathBuf>,
        make: MakeAnalyzer,
        wake: WakeFn,
    ) -> StabilizeRunner {
        StabilizeRunner { store, cache_dir, make, wake, running: None, clips: BTreeMap::new(), next_order: 0 }
    }

    /// Runs `wake` on the job's thread after each message, so the window polls the runner.
    pub fn set_wake(&mut self, wake: WakeFn) {
        self.wake = wake;
    }

    /// 0...1 while a run is going.
    pub fn progress(&self) -> Option<f64> {
        self.running.as_ref().map(|r| r.progress)
    }

    /// Whether the clip waits for a start or failed; `None` = neither.
    pub fn clip_state(&self, clip: Id) -> Option<ClipStab> {
        self.clips.get(&clip).map(|(state, _)| *state)
    }

    /// The one place that marks a clip failed; a request that came in meanwhile stays (it runs next).
    fn mark_failed(&mut self, clip: Id) {
        self.clips.entry(clip).or_insert((ClipStab::Failed, 0));
    }

    /// The clip being analyzed and the share done (0 before the first frame), for the Effect Controls row.
    pub fn running(&self) -> Option<(Id, f64)> {
        self.running.as_ref().map(|r| (r.clip, r.progress))
    }

    /// The row's Start: this clip is analyzed next (again if it already is).
    pub fn start_for(&mut self, clip: Id) {
        if self.clips.get(&clip).is_some_and(|(state, _)| *state == ClipStab::Requested) {
            return;
        }
        self.clips.insert(clip, (ClipStab::Requested, self.next_order));
        self.next_order += 1;
    }

    /// The row's Stop: ends the run and keeps the clip from starting again until Start (or a settings change).
    pub fn cancel(&mut self) {
        self.clips.retain(|_, (state, _)| *state != ClipStab::Requested);
        if let Some(run) = self.running.take() {
            run.job.stop();
            self.mark_failed(run.clip);
        }
    }

    /// Reads the job's messages and starts the next analysis; returns status lines.
    pub fn poll(&mut self, session: &mut EditorSession) -> Vec<String> {
        let mut out = Vec::new();
        let heard = self.running.as_ref().map(|run| (run.clip, run.job.poll()));
        // The run ends with its Done message; anything after it in the same batch is ignored.
        for m in heard.into_iter().flat_map(|(clip, all)| all.into_iter().map(move |m| (clip, m))) {
            match m {
                (_, StabilizationMessage::Progress(p)) => {
                    if let Some(run) = self.running.as_mut() {
                        run.progress = p;
                    }
                }
                (clip, StabilizationMessage::Done(Ok(_))) => {
                    session.replan_stabilizers(&[clip], &self.store.lookup());
                    // A result that still leaves the clip wanting one would loop; the clip waits for a settings change.
                    if wanting_analysis(session).contains(&clip) {
                        self.mark_failed(clip);
                    }
                    out.push("Stabilizer analysis done.".to_string());
                    self.running = None;
                }
                (clip, StabilizationMessage::Done(Err(why))) => {
                    self.mark_failed(clip);
                    out.push(why);
                    self.running = None;
                }
            }
        }
        if self.running.is_none() {
            out.extend(self.start_next(session));
        }
        out
    }

    fn start_next(&mut self, session: &EditorSession) -> Option<String> {
        let wanted = wanting_analysis(session);
        self.clips.retain(|id, (state, _)| *state == ClipStab::Requested || wanted.contains(id));
        let mut requests: Vec<(u64, Id)> = self
            .clips
            .iter()
            .filter(|(_, (state, _))| *state == ClipStab::Requested)
            .map(|(id, (_, n))| (*n, *id))
            .collect();
        requests.sort();
        // Swift `takeNextQueuedStabilizerAnalysis`: a request waits for its turn; one whose clip is gone, locked or no
        // longer has an enabled Standard Stabilizer drops out.
        let mut asked = None;
        for (_, id) in requests {
            if can_analyze(session, id) {
                asked.get_or_insert(id);
            } else {
                self.clips.remove(&id);
            }
        }
        if let Some(id) = asked {
            self.clips.remove(&id);
        }
        let id = match asked {
            Some(id) => id,
            None => wanted.into_iter().find(|id| !self.clips.contains_key(id))?,
        };
        let clip = session.active_timeline()?.tracks.iter().find_map(|t| t.clip(id))?.clone();
        let media = session.project().media(clip.media)?;
        let video = media.info.as_ref()?.video.as_ref()?;
        let size = (video.display_width(), video.display_height());
        let request = StabilizationRequest {
            path: PathBuf::from(&media.path),
            range: EditorSession::stabilize_source_range(&clip, session.active_timeline()?.frame_duration())?,
            size,
        };
        let analyzer = (self.make)(&request.path);
        let job = StabilizationJob::spawn(
            analyzer,
            request,
            self.store.clone(),
            self.cache_dir.clone(),
            std::sync::Arc::clone(&self.wake),
        );
        self.running = Some(Running { job, clip: id, progress: 0.0 });
        Some("Analyzing the clip for the Stabilizer...".to_string())
    }
}

/// Whether the clip is on an unlocked track and carries an enabled Standard Stabilizer.
fn can_analyze(session: &EditorSession, id: Id) -> bool {
    let Some(timeline) = session.active_timeline() else { return false };
    timeline.tracks.iter().filter(|t| !t.is_locked).filter_map(|t| t.clip(id)).any(|c| {
        c.effect_of_kind(ClipEffect::STABILIZE_KIND)
            .is_some_and(|e| e.enabled && e.stabilize_method() == StabilizerMethod::Standard)
    })
}

/// Clips with an enabled Standard Stabilizer that has no analysis yet or whose analysis does not cover what they show.
fn wanting_analysis(session: &EditorSession) -> Vec<Id> {
    let Some(timeline) = session.active_timeline() else { return Vec::new() };
    let stale = session.stale_stabilizer_clips();
    timeline
        .tracks
        .iter()
        .filter(|t| !t.is_locked)
        .flat_map(|t| t.clips())
        .filter(|c| {
            let Some(e) = c.effect_of_kind(ClipEffect::STABILIZE_KIND) else { return false };
            e.enabled
                && e.stabilize_method() == StabilizerMethod::Standard
                && !c.is_generator()
                && c.sequence.is_none()
                && session.project().picture_size(c).is_some()
                && (!e.stabilize_is_analysed() || stale.contains(&c.id))
        })
        .map(|c| c.id)
        .collect()
}

#[cfg(test)]
mod tests;
