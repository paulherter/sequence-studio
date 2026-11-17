// Swift: MacMagicMasks+Track.swift (trackMask), EffectControlsModel+Masks.swift (trackMask)
//! Tracking a drawn (path) mask over its clip: a background thread follows the outline with the portable point tracker
//! (`sq_analysis::mask_point_tracker`) segment by segment (user keys re-anchor, as in the Swift app), the UI thread writes the
//! path keys with `apply_mask_track_segments` when the run is done or stopped.

use sq_analysis::analysis_turn::CancelToken;
use sq_analysis::mask_point_tracker::{Gray, track_region};
use sq_core_masks::mask_motion::{MaskMotion, MaskTrackMode};
use sq_core_masks::mask_path_editing::MaskTrackingExt;
use sq_core_masks::masks::ClipMasksExt;
use sq_core_model::Clip;
use sq_core_time::{Id, Time};
use std::ops::Range;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, channel};

/// Pictures of the clip's media for tracking, by source time.
pub trait MaskFrameSource: Send {
    /// The luma picture shown at `source`; `None` = unreadable (the run is lost there).
    fn gray_at(&mut self, source: Time) -> Option<Gray>;
}

/// What the thread reports.
pub enum MaskTrackMessage {
    /// 0...1.
    Progress(f64),
    /// The run ended.
    Done(MaskTrackResult),
}

/// The finished (or stopped) run, ready for `apply_mask_track_segments`.
pub struct MaskTrackResult {
    /// The tracked clip.
    pub clip: Id,
    /// The tracked mask.
    pub mask: Id,
    /// Clip-local frame times of the run.
    pub times: Vec<Time>,
    /// Ranges of `times`, per segment, as far as they were tracked.
    pub segments: Vec<Range<usize>>,
    /// Motions per segment range.
    pub motions: Vec<Vec<Option<MaskMotion>>>,
    /// The user stopped the run.
    pub stopped: bool,
    /// The frames could not be read.
    pub error: Option<String>,
}

/// One running track.
pub struct MaskTrackJob {
    inbox: Receiver<MaskTrackMessage>,
    cancel: CancelToken,
    finished: bool,
}

/// What a run needs.
pub struct MaskTrackPlan {
    /// The clip as it was when the run started.
    pub clip: Clip,
    /// The mask to track.
    pub mask: Id,
    /// Clip-local frame times in tracking order.
    pub times: Vec<Time>,
    /// What to follow.
    pub mode: MaskTrackMode,
}

impl MaskTrackJob {
    /// Starts the run; `open` makes the frame source on the thread.
    pub fn spawn(
        plan: MaskTrackPlan,
        open: Box<dyn FnOnce() -> Result<Box<dyn MaskFrameSource>, String> + Send>,
        wake: Arc<dyn Fn() + Send + Sync>,
    ) -> MaskTrackJob {
        let (tx, inbox) = channel();
        let cancel = CancelToken::new();
        let token = cancel.clone();
        std::thread::spawn(move || {
            let (ptx, pwake) = (tx.clone(), Arc::clone(&wake));
            let result = match open() {
                Ok(mut source) => run(&plan, &mut *source, &token, &mut |p| {
                    // The receiver is gone when the app quits.
                    let _ = ptx.send(MaskTrackMessage::Progress(p));
                    pwake();
                }),
                Err(why) => MaskTrackResult {
                    clip: plan.clip.id,
                    mask: plan.mask,
                    times: plan.times.clone(),
                    segments: Vec::new(),
                    motions: Vec::new(),
                    stopped: false,
                    error: Some(why),
                },
            };
            let _ = tx.send(MaskTrackMessage::Done(result));
            wake();
        });
        MaskTrackJob { inbox, cancel, finished: false }
    }

    /// Asks the run to stop; the frames so far are kept.
    pub fn stop(&self) {
        self.cancel.cancel();
    }

    /// True once `Done` was read.
    pub fn is_finished(&self) -> bool {
        self.finished
    }

    /// Everything that arrived since the last call.
    pub fn poll(&mut self) -> Vec<MaskTrackMessage> {
        let all: Vec<MaskTrackMessage> = self.inbox.try_iter().collect();
        self.finished |= all.iter().any(|m| matches!(m, MaskTrackMessage::Done(_)));
        all
    }
}

/// The run itself: per segment the outline at the segment's first frame is followed over the segment's frames.
fn run(
    plan: &MaskTrackPlan,
    source: &mut dyn MaskFrameSource,
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
) -> MaskTrackResult {
    let clip = &plan.clip;
    let mut result = MaskTrackResult {
        clip: clip.id,
        mask: plan.mask,
        times: plan.times.clone(),
        segments: Vec::new(),
        motions: Vec::new(),
        stopped: false,
        error: None,
    };
    let Some(mask) = clip.mask(plan.mask) else { return result };
    let segments = clip.mask_track_segments(plan.mask, &plan.times);
    let total = plan.times.len().max(1) as f64;
    for seg in segments {
        let base = mask.path.value_at_local(plan.times[seg.start]);
        let region = base.polygon();
        let (start, len) = (seg.start, seg.len());
        let mut frames = |k: usize| {
            progress((start + k) as f64 / total);
            source.gray_at(clip.source_instant(plan.times[start + k]))
        };
        let motions = track_region(&region, plan.mode, &mut frames, len, &mut |_| cancel.is_cancelled());
        let lost = motions.iter().any(Option::is_none);
        let stopped = motions.len() < len;
        if stopped {
            result.stopped = true;
            // A stopped run keeps its frames only when it got past the first.
            if motions.len() > 1 {
                result.segments.push(start..start + motions.len());
                result.motions.push(motions);
            }
            break;
        }
        result.segments.push(seg);
        result.motions.push(motions);
        if lost {
            break;
        }
    }
    progress(1.0);
    result
}
