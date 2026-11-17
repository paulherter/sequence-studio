// Swift: EditorSession+Stabilize.swift
//! Stabilize (W9.7): measures the camera shake of the selected clips (`StabilizationAnalyzing`), smooths it
//! (`Stabilizer`) and writes a Stabilizer effect: a transform stage with Position / Rotation / Scale keys, applied to the
//! clip's own picture before Motion. The user's Motion stays; one undo step. A second run replaces the clip's
//! Stabilizer (same id) and uses the settings stored on it, so changing them in Effect Controls and running Stabilize
//! again re-plans.
//!
//! Swift's `async stabilize` is split for the worker model like Auto Reframe: [`EditorSession::stabilize_run`] captures
//! the clips, [`StabilizeRun::analyze`] is the blocking part, [`EditorSession::finish_stabilize`] writes the effects;
//! [`EditorSession::stabilize`] chains the three on the calling thread.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::time::Duration;

use sq_analysis::analysis_turn::{CancelToken, Cancelled};
use sq_analysis::stabilization_analyzing::{StabilizationAnalyzing, StabilizationError};
use sq_core_edit::timeline_replace::TimelineReplaceExt;
use sq_core_effects::effects_editing::{ClipEffectsEditingExt, stabilizer_effect, stabilizer_insertion_index};
use sq_core_masks::stabilize_effect::{ClipEffectStabilizeExt, ClipStabilizeExt, StabilizerMethod};
use sq_core_masks::stabilizer::{StabilizationAnalysis, StabilizationPlan, Stabilizer, StabilizerOptions};
use sq_core_model::{AnimatedProperty, Clip, ClipEffect, EditError, MediaRef};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use sq_runtime::{JoinHandle, UiRef, sleep, spawn_local};

use crate::{EditorSession, SessionEvent, SessionRoot};

/// What a Stabilize run did.
// Swift: EditorSession+Stabilize.swift:6
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct StabilizeOutcome {
    // Swift: EditorSession+Stabilize.swift:7
    pub stabilized: i64,
    /// Clips whose frames could not be read (offline, unreadable) or that were edited while they were analyzed.
    // Swift: EditorSession+Stabilize.swift:9
    pub failed: i64,
    /// Locked ("No Motion") clips that move too far to hold: some frames show the picture's edge.
    // Swift: EditorSession+Stabilize.swift:11
    pub uncovered: i64,
    /// The largest auto-scale crop written (share of each picture side), 0 when nothing was written.
    // Swift: EditorSession+Stabilize.swift:13
    pub max_crop: f64,
    /// Clips left as shot because the measurement could not be trusted (too little detail) or would have added shake.
    // Swift: EditorSession+Stabilize.swift:15
    pub left_as_shot: i64,
    /// Clips steadied only in parts (some shots / stretches left as shot for the same reason).
    // Swift: EditorSession+Stabilize.swift:17
    pub partly: i64,
    /// Clips whose Stabilizer uses Gyroflow: not analyzed by the picture analysis (their engine runs elsewhere).
    // Swift: EditorSession+Stabilize.swift:19
    pub gyroflow: i64,
}

impl StabilizeOutcome {
    // Swift: EditorSession+Stabilize.swift:20
    pub fn new(
        stabilized: i64,
        failed: i64,
        uncovered: i64,
        max_crop: f64,
        left_as_shot: i64,
        partly: i64,
        gyroflow: i64,
    ) -> StabilizeOutcome {
        StabilizeOutcome { stabilized, failed, uncovered, max_crop, left_as_shot, partly, gyroflow }
    }
}

/// Reads a cached analysis for a media file and source range (picture size as given); `None` = not cached. The app
/// passes its `StabilizationCache`.
// Swift: EditorSession+Stabilize.swift:38
pub type StabilizationLookup =
    Arc<dyn Fn(&MediaRef, TimeRange, i64, i64) -> Option<StabilizationAnalysis> + Send + Sync>;

/// An analyzer for one media (what `AnalysisBackend::stabilization_analyzer` gives).
pub type BoxedStabilizationAnalyzer = Box<dyn StabilizationAnalyzing + Send>;

/// A planned Stabilizer: the effect to write and its plan.
pub type BuiltStabilizer = (ClipEffect, StabilizationPlan);

/// What a Stabilize run captured when it started.
#[derive(Clone, Debug)]
pub struct StabilizeRun {
    timeline: Id,
    options: Option<StabilizerOptions>,
    targets: Vec<Id>,
    jobs: Vec<(Clip, TimeRange, MediaRef, (i64, i64))>,
    gyroflow: i64,
}

/// What the analysis of a run produced.
#[derive(Clone, Debug)]
pub struct StabilizeAnalysis {
    effects: BTreeMap<Id, BuiltStabilizer>,
    failed: i64,
}

impl StabilizeAnalysis {
    /// An analysis of nothing (no sequence, no targets).
    pub fn empty() -> StabilizeAnalysis {
        StabilizeAnalysis { effects: BTreeMap::new(), failed: 0 }
    }
}

impl StabilizeRun {
    /// The sequence the run belongs to.
    pub fn timeline(&self) -> Id {
        self.timeline
    }

    /// How many clips the analysis reads.
    pub fn clip_count(&self) -> usize {
        self.jobs.len()
    }

    /// Analyzes every job with the analyzer `analyzer(media)` returns (`None` = skip as failed) and plans the
    /// Stabilizers. `progress` gets 0...1 over the whole run. `Err(Cancelled)` when canceled; nothing is written then.
    pub fn analyze(
        &self,
        analyzer: &dyn Fn(&MediaRef) -> Option<BoxedStabilizationAnalyzer>,
        progress: Option<&(dyn Fn(f64) + Sync)>,
        cancel: &CancelToken,
        fd: Time,
        ids: &mut dyn IdSource,
    ) -> Result<StabilizeAnalysis, Cancelled> {
        let mut out = StabilizeAnalysis { effects: BTreeMap::new(), failed: 0 };
        let n = self.jobs.len().max(1) as f64;
        for (i, (clip, range, media, (w, h))) in self.jobs.iter().enumerate() {
            let Some(a) = analyzer(media) else {
                out.failed += 1;
                continue;
            };
            let base = i as f64;
            let o = self.options.unwrap_or_else(|| {
                clip.effect_of_kind(ClipEffect::STABILIZE_KIND).map(StabilizerOptions::from_effect).unwrap_or_default()
            });
            let report = |p: f64| {
                if let Some(f) = progress {
                    f((base + p) / n);
                }
            };
            match a.analyze_rolling(*range, *w, *h, o.rolling_shutter, Some(&report), cancel) {
                Ok(analysis) => {
                    let id = clip.effect_of_kind(ClipEffect::STABILIZE_KIND).map_or_else(|| ids.next_id(), |e| e.id);
                    match EditorSession::build_stabilizer(&analysis, &o, clip, fd, id, ids) {
                        Some(built) => {
                            out.effects.insert(clip.id, built);
                        }
                        None => out.failed += 1,
                    }
                }
                Err(StabilizationError::Cancelled) => return Err(Cancelled),
                Err(_) => out.failed += 1,
            }
        }
        cancel.check()?;
        Ok(out)
    }
}

impl EditorSession {
    /// Same clips Auto Reframe works on: media video with a known picture size on unlocked tracks.
    // Swift: EditorSession+Stabilize.swift:34
    pub fn stabilize_targets(&self) -> Vec<Clip> {
        self.reframe_targets()
    }

    /// Clips of the active sequence (unlocked tracks, media video) that carry a Stabilizer whose analysis does not cover
    /// what they show now (trimmed longer): the new frames would hold the last correction until Stabilize runs again.
    // Swift: EditorSession+Stabilize.swift:42
    pub fn stale_stabilizer_clips(&self) -> Vec<Id> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        let fd = t.frame_duration();
        t.tracks
            .iter()
            .filter(|tr| !tr.is_locked)
            .flat_map(|tr| tr.clips().iter())
            .filter(|c| {
                let Some(e) = c.effect_of_kind(ClipEffect::STABILIZE_KIND) else { return false };
                e.enabled
                    && e.stabilize_method() == StabilizerMethod::Standard
                    && !c.is_generator()
                    && c.sequence.is_none()
                    && Self::stabilize_source_range(c, fd).is_some_and(|r| e.stabilize_needs_analysis(r, fd))
            })
            .map(|c| c.id)
            .collect()
    }

    /// The effect and options a re-plan of `id` would use, with its analysis from the cache: `(clip, old effect id,
    /// options, effect or needs-analysis)`.
    fn replan_one(
        &self,
        timeline: &sq_core_model::Timeline,
        id: Id,
        lookup: &StabilizationLookup,
        ids: &mut dyn IdSource,
    ) -> Option<(Clip, ReplanResult)> {
        let fd = timeline.frame_duration();
        let clip = timeline.tracks.iter().find_map(|t| t.clip(id))?.clone();
        let old = clip.effect_of_kind(ClipEffect::STABILIZE_KIND)?;
        if old.stabilize_method() != StabilizerMethod::Standard {
            return None;
        }
        let media = self.project().media(clip.media)?;
        let (w, h) = self.project().picture_size(&clip)?;
        let range = Self::stabilize_source_range(&clip, fd)?;
        let options = StabilizerOptions::from_effect(old);
        let analysis = lookup(media, range, w, h)?;
        // Rolling Shutter switched on over an analysis from before the option: it has no row motion, analyze again
        // (job center, cancelable); the result then carries it and plans the correction.
        if options.rolling_shutter && analysis.rolling.is_empty() && analysis.frame_times.len() > 1 {
            return Some((clip, ReplanResult::NeedsAnalysis));
        }
        let built = Self::build_stabilizer(&analysis, &options, &clip, fd, old.id, ids)?;
        Some((clip, ReplanResult::Planned(Box::new(built.0))))
    }

    /// Re-plans a clip's Stabilizer from the cached analysis with the settings now stored on it (Result, Smoothness,
    /// Crop Limit), so changing them in Effect Controls takes effect at once without a new analysis. One undo step with
    /// the settings edit that caused it. False when nothing was written (no Stabilizer, analysis not cached, clip
    /// edited meanwhile).
    // Swift: EditorSession+Stabilize.swift:57
    pub fn replan_stabilizer(&mut self, id: Id, lookup: &StabilizationLookup) -> bool {
        !self.replan_stabilizers(&[id], lookup).is_empty()
    }

    /// Re-plans several clips from their cached analyses with the settings now stored on them, written as one undo step
    /// with the settings edit that caused it. Returns the clips written.
    // Swift: EditorSession+Stabilize.swift:82
    pub fn replan_stabilizers(&mut self, clips: &[Id], lookup: &StabilizationLookup) -> BTreeSet<Id> {
        let Some(timeline) = self.active_timeline().cloned() else { return BTreeSet::new() };
        let mut effects: BTreeMap<Id, ClipEffect> = BTreeMap::new();
        let mut snapshot: BTreeMap<Id, Clip> = BTreeMap::new();
        let mut need_analysis: BTreeSet<Id> = BTreeSet::new();
        for id in clips {
            let planned = self.with_ids(|s, ids| s.replan_one(&timeline, *id, lookup, ids));
            match planned {
                Some((clip, ReplanResult::NeedsAnalysis)) => {
                    need_analysis.insert(clip.id);
                }
                Some((clip, ReplanResult::Planned(effect))) => {
                    effects.insert(*id, *effect);
                    snapshot.insert(*id, clip);
                }
                None => {}
            }
        }
        if !need_analysis.is_empty() {
            self.rolling_shutter_requests.entry(timeline.id).or_default().extend(need_analysis.iter().copied());
            self.emit(SessionEvent::StabilizerNeedsAnalysis { timeline: timeline.id, clips: need_analysis });
        }
        if effects.is_empty() {
            return BTreeSet::new();
        }
        let key = if clips.len() == 1 {
            format!("clip:{}:{}", clips[0], self.gesture_counter)
        } else {
            format!("clips:{}", self.gesture_counter)
        };
        self.apply_stabilizer(&effects, Some(timeline.id), Some(&snapshot), Some(&key))
    }

    /// Clips whose Stabilizer asked for an analysis while another one ran (Rolling Shutter switched on, an Analyze row):
    /// they wait here, per sequence, and run when it ends, so the option is never left on without its correction. The
    /// queue does not depend on which sequence is open.
    // Swift: EditorSession+Stabilize.swift:114
    pub fn queue_stabilizer_analysis(&mut self, ids: &BTreeSet<Id>, timeline: Option<Id>) {
        let Some(tid) = timeline.or(self.active_timeline_id) else { return };
        self.queued_stabilizer_analysis.entry(tid).or_default().extend(ids.iter().copied());
    }

    /// Hands out the queued clips of one sequence (default: the open one) and forgets them: those that still want the
    /// analysis (an unlocked track, an enabled Standard Stabilizer). Deleted clips and removed effects drop out.
    // Swift: EditorSession+Stabilize.swift:121
    pub fn take_queued_stabilizer_analysis(&mut self, timeline: Option<Id>) -> BTreeSet<Id> {
        let Some(tid) = timeline.or(self.active_timeline_id) else { return BTreeSet::new() };
        match self.queued_stabilizer_analysis.remove(&tid) {
            Some(queued) => self.wanting_stabilizer_analysis(&queued, tid),
            None => BTreeSet::new(),
        }
    }

    /// The next sequence with queued clips that still want the analysis; the other sequences stay queued.
    // Swift: EditorSession+Stabilize.swift:127
    pub fn take_next_queued_stabilizer_analysis(&mut self) -> Option<(Id, BTreeSet<Id>)> {
        let keys: Vec<Id> = self.queued_stabilizer_analysis.keys().copied().collect();
        for tid in keys {
            let Some(queued) = self.queued_stabilizer_analysis.remove(&tid) else { continue };
            let wanted = self.wanting_stabilizer_analysis(&queued, tid);
            if !wanted.is_empty() {
                return Some((tid, wanted));
            }
        }
        None
    }

    fn wanting_stabilizer_analysis(&mut self, queued: &BTreeSet<Id>, tid: Id) -> BTreeSet<Id> {
        let Some(t) = self.project().timeline(tid).filter(|_| !queued.is_empty()) else {
            self.rolling_shutter_requests.remove(&tid);
            return BTreeSet::new();
        };
        let wanted: BTreeSet<Id> = t
            .tracks
            .iter()
            .filter(|tr| !tr.is_locked)
            .flat_map(|tr| tr.clips().iter())
            .filter(|c| {
                queued.contains(&c.id)
                    && c.effect_of_kind(ClipEffect::STABILIZE_KIND)
                        .is_some_and(|e| e.enabled && e.stabilize_method() == StabilizerMethod::Standard)
            })
            .map(|c| c.id)
            .collect();
        // A clip that leaves the queue without running no longer waits for a correction.
        if let Some(r) = self.rolling_shutter_requests.get_mut(&tid) {
            for id in queued.difference(&wanted) {
                r.remove(id);
            }
        }
        wanted
    }

    /// Forgets the queue (the running analysis was canceled: nothing follows by itself) and switches Rolling Shutter
    /// back off for the clips that waited for it.
    // Swift: EditorSession+Stabilize.swift:149
    pub fn drop_queued_stabilizer_analysis(&mut self) {
        self.queued_stabilizer_analysis.clear();
        self.withdraw_rolling_shutter_requests(None);
    }

    /// A canceled (or failed) analysis leaves Rolling Shutter on without its correction, and the next Smoothness edit
    /// would start the analysis again: Cancel switches the option back off for the clips that asked for it (`None` = all
    /// of them, in every sequence), one undo step. The cached analysis stays, so settings re-plan at once.
    // Swift: EditorSession+Stabilize.swift:157
    pub fn withdraw_rolling_shutter_requests(&mut self, clips: Option<&BTreeSet<Id>>) {
        let requests: BTreeMap<Id, BTreeSet<Id>> = self
            .rolling_shutter_requests
            .iter()
            .map(|(tid, ids)| {
                let picked = match clips {
                    Some(c) => ids.intersection(c).copied().collect(),
                    None => ids.clone(),
                };
                (*tid, picked)
            })
            .filter(|(tid, v): &(Id, BTreeSet<Id>)| !v.is_empty() && self.project().timeline(*tid).is_some())
            .collect();
        match clips {
            Some(c) => {
                for ids in self.rolling_shutter_requests.values_mut() {
                    for id in c {
                        ids.remove(id);
                    }
                }
            }
            None => self.rolling_shutter_requests.clear(),
        }
        if requests.is_empty() {
            return;
        }
        let r = self.try_perform("Rolling Shutter", None, |p| {
            for (tid, ids) in &requests {
                p.edit(*tid, |t| {
                    let edits: Vec<Clip> = t
                        .tracks
                        .iter()
                        .filter(|tr| !tr.is_locked)
                        .flat_map(|tr| tr.clips().iter())
                        .filter(|c| ids.contains(&c.id))
                        .cloned()
                        .collect();
                    for c in edits {
                        let mut n = c;
                        let Some(i) = n.effects.iter().position(|e| e.kind == ClipEffect::STABILIZE_KIND) else {
                            continue;
                        };
                        if n.effects[i].parameters.get(ClipEffect::ROLLING_SHUTTER_KEY).map_or(0.0, |p| p.value) < 0.5 {
                            continue;
                        }
                        n.effects[i]
                            .parameters
                            .insert(ClipEffect::ROLLING_SHUTTER_KEY.to_string(), AnimatedProperty::new(0.0));
                        t.replace_clip(n)?;
                    }
                    Ok::<(), EditError>(())
                })?;
            }
            Ok::<(), EditError>(())
        });
        if let Err(e) = r {
            self.set_error(e.to_string());
        }
    }

    /// Re-plans after a short pause (a slider drag changes the settings many times); a newer call replaces the pending
    /// one. Runs on the UI executor; `lookup` reads the cache on the UI thread.
    /// shortcut: the cache read is not moved to a worker; upgrade when a cached analysis is large enough to stall a frame.
    // Swift: EditorSession+Stabilize.swift:184
    pub fn schedule_stabilizer_replan<R: SessionRoot + 'static + ?Sized>(
        h: UiRef<R>,
        clip: Id,
        lookup: StabilizationLookup,
    ) {
        Self::schedule_replan(h, vec![clip], lookup);
    }

    /// Several clips at once: one pause, one write, one undo step.
    // Swift: EditorSession+Stabilize.swift:194
    pub fn schedule_stabilizer_replan_clips<R: SessionRoot + 'static + ?Sized>(
        h: UiRef<R>,
        clips: Vec<Id>,
        lookup: StabilizationLookup,
    ) {
        Self::schedule_replan(h, clips, lookup);
    }

    fn schedule_replan<R: SessionRoot + 'static + ?Sized>(h: UiRef<R>, clips: Vec<Id>, lookup: StabilizationLookup) {
        let again = h.clone();
        let task: JoinHandle<()> = spawn_local(async move {
            if sleep(Duration::from_millis(250)).await.is_err() {
                return; // a newer call replaced this one
            }
            again.with(|r| {
                r.session().replan_stabilizers(&clips, &lookup);
            });
        });
        h.with(|r| {
            if let Some(old) = r.session().stabilizer_replan_task.replace(task) {
                old.cancel();
            }
        });
    }

    /// The source range a clip shows (through speed, reverse and time remapping), one sequence frame longer than the
    /// last source time shown so its frame is read.
    // Swift: EditorSession+Stabilize.swift:206
    pub fn stabilize_source_range(clip: &Clip, fd: Time) -> Option<TimeRange> {
        let frames = clip.duration().frame_index(fd);
        if frames <= 0 {
            return None;
        }
        let first = clip.source_time(clip.start, fd);
        let (mut lo, mut hi) = (first, first);
        for i in 1..frames.max(1) {
            let s = clip.source_time(clip.start + fd * i, fd);
            lo = lo.min(s);
            hi = hi.max(s);
        }
        if lo.is_negative() {
            lo = Time::ZERO;
        }
        Some(TimeRange::from_end(lo, hi.max(lo) + fd))
    }

    /// Captures the clips a Stabilize run reads. `options`: `None` = each clip's stored settings (defaults for a clip
    /// without a Stabilizer). `only`: restrict to these clips (an Effect Controls Analyze row), in `timeline`.
    pub fn stabilize_run(
        &self,
        options: Option<StabilizerOptions>,
        only: Option<&BTreeSet<Id>>,
        timeline: Option<Id>,
    ) -> Option<StabilizeRun> {
        // A target sequence that is gone ends the run; only "no sequence given" means the open one.
        let found = match timeline {
            Some(id) => self.project().timeline(id),
            None => self.active_timeline(),
        }?;
        let fd = found.frame_duration();
        let targets: Vec<Clip> = match only {
            Some(ids) => {
                let locked: BTreeSet<Id> =
                    found.tracks.iter().filter(|t| t.is_locked).flat_map(|t| t.clips().iter().map(|c| c.id)).collect();
                found
                    .tracks
                    .iter()
                    .flat_map(|t| t.clips().iter())
                    .filter(|c| {
                        ids.contains(&c.id)
                            && !locked.contains(&c.id)
                            && !c.is_generator()
                            && c.sequence.is_none()
                            && !c.is_still
                            && c.hold_frame.is_none()
                    })
                    .cloned()
                    .collect()
            }
            None => self.stabilize_targets(),
        };
        // A Gyroflow Stabilizer is never re-planned from the picture analysis (explicit Standard options still switch
        // it back).
        let gyro: BTreeSet<Id> = targets
            .iter()
            .filter(|c| {
                options.is_none()
                    && c.effect_of_kind(ClipEffect::STABILIZE_KIND)
                        .is_some_and(|e| e.stabilize_method() == StabilizerMethod::Gyroflow)
            })
            .map(|c| c.id)
            .collect();
        let jobs = targets
            .iter()
            .filter(|c| !gyro.contains(&c.id))
            .filter_map(|c| {
                let m = self.project().media(c.media)?;
                let size = self.project().picture_size(c)?;
                let range = Self::stabilize_source_range(c, fd)?;
                Some((c.clone(), range, m.clone(), size))
            })
            .collect();
        Some(StabilizeRun {
            timeline: found.id,
            options,
            targets: targets.iter().map(|c| c.id).collect(),
            jobs,
            gyroflow: gyro.len() as i64,
        })
    }

    /// Writes the effects of an analysis as one undo step "Stabilize" and completes the counts.
    pub fn finish_stabilize(&mut self, run: &StabilizeRun, analysis: StabilizeAnalysis) -> StabilizeOutcome {
        let mut outcome =
            StabilizeOutcome { gyroflow: run.gyroflow, failed: analysis.failed, ..StabilizeOutcome::default() };
        let snapshot: BTreeMap<Id, Clip> = run.jobs.iter().map(|j| (j.0.id, j.0.clone())).collect();
        let effects: BTreeMap<Id, ClipEffect> = analysis.effects.iter().map(|(k, v)| (*k, v.0.clone())).collect();
        let written = self.apply_stabilizer(&effects, Some(run.timeline), Some(&snapshot), None);
        outcome.stabilized = written.len() as i64;
        // Written clips have their correction. A clip that asked for Rolling Shutter but failed or was skipped keeps the
        // option on without it: switch it back off (one undo step) so the next edit does not analyze again.
        let targets: BTreeSet<Id> = run.targets.iter().copied().collect();
        let asked: BTreeSet<Id> = self
            .rolling_shutter_requests
            .get(&run.timeline)
            .map(|r| r.intersection(&targets).copied().collect())
            .unwrap_or_default();
        if let Some(r) = self.rolling_shutter_requests.get_mut(&run.timeline) {
            for id in &asked {
                r.remove(id);
            }
        }
        let unwritten: BTreeSet<Id> = asked.difference(&written).copied().collect();
        if !unwritten.is_empty() {
            self.rolling_shutter_requests.entry(run.timeline).or_default().extend(unwritten.iter().copied());
            self.withdraw_rolling_shutter_requests(Some(&unwritten));
        }
        outcome.failed += effects.len() as i64 - written.len() as i64;
        for id in &written {
            let Some((_, plan)) = analysis.effects.get(id) else { continue };
            outcome.max_crop = outcome.max_crop.max(plan.crop());
            if !plan.fully_covered {
                outcome.uncovered += 1;
            }
            if plan.uncorrected_frames >= plan.corrections.len() {
                outcome.left_as_shot += 1;
            } else if plan.uncorrected_frames > 0 {
                outcome.partly += 1;
            }
        }
        outcome
    }

    /// Analyzes every target clip with the analyzer `analyzer(media)` returns (`None` = skip as failed), then writes all
    /// Stabilizer effects as one undo step "Stabilize", on the calling thread. `Err(Cancelled)` when canceled; nothing
    /// is written then.
    // Swift: EditorSession+Stabilize.swift:222
    pub fn stabilize(
        &mut self,
        options: Option<StabilizerOptions>,
        only: Option<&BTreeSet<Id>>,
        timeline: Option<Id>,
        progress: Option<&(dyn Fn(f64) + Sync)>,
        cancel: &CancelToken,
        analyzer: &dyn Fn(&MediaRef) -> Option<BoxedStabilizationAnalyzer>,
    ) -> Result<StabilizeOutcome, Cancelled> {
        let Some(run) = self.stabilize_run(options, only, timeline) else { return Ok(StabilizeOutcome::default()) };
        let fd = self.project().timeline(run.timeline).map_or(Time::new(1, 30), |t| t.frame_duration());
        let analysis = self.with_ids(|_, ids| run.analyze(analyzer, progress, cancel, fd, ids))?;
        Ok(self.finish_stabilize(&run, analysis))
    }

    /// Stabilize dropped from the Effects panel (or Effect Controls): adds a fresh Stabilizer where a clip has none (one
    /// undo step "Add Stabilizer"). It does NOT start an analysis: the clip waits idle until the user presses Start (they
    /// may choose Gyroflow instead, and a default analysis would be wasted). True when a target can carry one.
    // Swift: EditorSession+Stabilize.swift:293
    pub fn add_stabilizer(&mut self, ids: &BTreeSet<Id>) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let locked: BTreeSet<Id> =
            t.tracks.iter().filter(|tr| tr.is_locked).flat_map(|tr| tr.clips().iter().map(|c| c.id)).collect();
        let targets: Vec<Clip> = t
            .tracks
            .iter()
            .flat_map(|tr| tr.clips().iter())
            .filter(|c| ids.contains(&c.id) && c.can_stabilize() && !locked.contains(&c.id))
            .cloned()
            .collect();
        if targets.is_empty() {
            return false;
        }
        let defaults = self.effect_defaults.clone();
        if targets.iter().any(|c| c.stabilizer_id().is_none()) {
            let changed = self.attempt_ids("Add Stabilizer", |tl, new_ids| {
                for c in targets.iter().filter(|c| c.stabilizer_id().is_none()) {
                    let Some(mut n) = tl.tracks.iter().find_map(|tr| tr.clip(c.id)).cloned() else { continue };
                    if n.add_effect(ClipEffect::STABILIZE_KIND, Some(&defaults), new_ids).is_none() {
                        continue;
                    }
                    tl.replace_clip(n)?;
                }
                Ok(())
            });
            if !changed {
                return false;
            }
        }
        true
    }

    /// True when a running analysis has nothing left to write: a clip that carried a Stabilizer when it started lost it,
    /// or is gone (effect removed, clip deleted), in any sequence. `watching` are the clips that carried one.
    // Swift: EditorSession+Stabilize.swift:313
    pub fn stabilize_run_is_obsolete(&self, _clips: &BTreeSet<Id>, watching: &BTreeSet<Id>) -> bool {
        if watching.is_empty() {
            return false;
        }
        let live: BTreeSet<Id> = self
            .project()
            .timelines
            .iter()
            .flat_map(|t| t.tracks.iter())
            .flat_map(|tr| tr.clips().iter())
            .filter(|c| c.stabilizer_id().is_some())
            .map(|c| c.id)
            .collect();
        watching.is_disjoint(&live)
    }

    /// Plans the correction and builds the Stabilizer effect (decimated keys). Pure, so a run does it off the UI
    /// thread. `None` when the analysis is too short to plan.
    pub(crate) fn build_stabilizer(
        analysis: &StabilizationAnalysis,
        options: &StabilizerOptions,
        clip: &Clip,
        fd: Time,
        id: Id,
        ids: &mut dyn IdSource,
    ) -> Option<BuiltStabilizer> {
        let plan = Stabilizer::plan(analysis, options)?;
        let effect = stabilizer_effect(&plan, analysis, clip, fd, options, id, ids);
        Some((effect, plan))
    }

    /// Writes the Stabilizer effects as one undo step "Stabilize": replaces a clip's Stabilizer, else inserts it before
    /// the clip's first other transform stage. Clips that are gone, on a locked track, or no longer match `expecting`
    /// (see `reframe_still_fits`: keys are per clip frame), or whose Stabilizer changed since the snapshot are skipped.
    /// A replaced Stabilizer keeps its `enabled` flag. Returns the clips written.
    // Swift: EditorSession+Stabilize.swift:352
    pub(crate) fn apply_stabilizer(
        &mut self,
        effects: &BTreeMap<Id, ClipEffect>,
        timeline: Option<Id>,
        expecting: Option<&BTreeMap<Id, Clip>>,
        coalescing: Option<&str>,
    ) -> BTreeSet<Id> {
        let Some(tid) = timeline.or(self.active_timeline_id) else { return BTreeSet::new() };
        if effects.is_empty() {
            return BTreeSet::new();
        }
        let mut written: BTreeSet<Id> = BTreeSet::new();
        let r = self.try_perform("Stabilize", coalescing, |p| {
            written.clear();
            p.edit(tid, |t| {
                let clips: Vec<Clip> =
                    t.tracks.iter().filter(|tr| !tr.is_locked).flat_map(|tr| tr.clips().iter()).cloned().collect();
                for c in clips {
                    let Some(e) = effects.get(&c.id) else { continue };
                    if let Some(old) = expecting.and_then(|m| m.get(&c.id)) {
                        if !Self::reframe_still_fits(&c, old, None) {
                            continue;
                        }
                        // The Stabilizer was changed (settings, removed, added) while it was analyzed: the plan used
                        // the old settings, so leave the user's edit alone.
                        if c.effect_of_kind(ClipEffect::STABILIZE_KIND)
                            != old.effect_of_kind(ClipEffect::STABILIZE_KIND)
                        {
                            continue;
                        }
                    }
                    let mut n = c.clone();
                    if let Some(i) = n.effects.iter().position(|x| x.kind == ClipEffect::STABILIZE_KIND) {
                        let mut e = e.clone();
                        e.enabled = n.effects[i].enabled; // a re-run never switches a disabled Stabilizer back on
                        // A keyframed Rolling Shutter Strength keeps its keys (the plan only knows its value).
                        if let Some(strength) = n.effects[i].parameters.get(ClipEffect::ROLLING_SHUTTER_STRENGTH_KEY)
                            && strength.is_animated()
                        {
                            e.parameters.insert(ClipEffect::ROLLING_SHUTTER_STRENGTH_KEY.to_string(), strength.clone());
                        }
                        n.effects[i] = e;
                    } else {
                        let at = stabilizer_insertion_index(&n.effects);
                        n.effects.insert(at, e.clone());
                    }
                    if n != c {
                        t.replace_clip(n)?;
                    }
                    written.insert(c.id);
                }
                Ok::<(), EditError>(())
            })
        });
        if let Err(e) = r {
            self.set_error(e.to_string());
            return BTreeSet::new();
        }
        written
    }
}

/// What re-planning one clip came to.
enum ReplanResult {
    Planned(Box<ClipEffect>),
    NeedsAnalysis,
}
