// Swift: EditorSession+Reframe.swift
//! Auto Reframe (W4.2, W7.1): analyzes the selected clips' pictures and writes an Auto Reframe effect (Position keys plus
//! a cover Scale, as a transform stage on top of Motion) that keeps the subject in the active sequence's frame. The
//! user's Motion values and keys are left alone; one undo step. With a format variant active (W5.1) the frame is the
//! variant's and the values go into that variant's effect overrides.
//!
//! Swift's `async autoReframe` is split for the worker model: [`EditorSession::reframe_run`] captures what the analysis
//! needs, [`ReframeRun::analyze`] is the blocking part (a worker runs it), [`EditorSession::finish_reframe`] writes the
//! plans. [`EditorSession::auto_reframe`] chains the three on the calling thread.

use std::collections::BTreeMap;

use sq_analysis::analysis_turn::{CancelToken, Cancelled};
use sq_analysis::reframe::{
    DetectError, ReframeAnalyzer, ReframeGeometry, ReframeOptions, ReframePlan, ReframePlanner, ReframeSample,
    ReframeSampling, SubjectDetecting,
};
use sq_core_edit::timeline_replace::TimelineReplaceExt;
use sq_core_effects::effect_transform_stage::EffectTransformStage;
use sq_core_graphics::format_variants_view::{ClipVariantExt, TimelineVariantsExt};
use sq_core_model::{Clip, ClipEffect, EditError, MediaRef, SequenceFormat};
use sq_core_time::{Id, IdSource};

use crate::EditorSession;

/// What an Auto Reframe run did.
// Swift: EditorSession+Reframe.swift:6
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct ReframeOutcome {
    // Swift: EditorSession+Reframe.swift:7
    pub reframed: i64,
    /// Clips in which no face, person or salient object was found (left alone).
    // Swift: EditorSession+Reframe.swift:9
    pub no_subject: i64,
    /// Clips whose frames could not be read (offline, unreadable).
    // Swift: EditorSession+Reframe.swift:11
    pub failed: i64,
    /// Clips whose picture already fills the frame exactly (same shape): nothing to reframe, left alone.
    // Swift: EditorSession+Reframe.swift:13
    pub already_framed: i64,
    /// Clips whose read hung: given up, left alone.
    // Swift: EditorSession+Reframe.swift:15
    pub stalled: i64,
}

impl ReframeOutcome {
    // Swift: EditorSession+Reframe.swift:16
    pub fn new(reframed: i64, no_subject: i64, failed: i64, already_framed: i64, stalled: i64) -> ReframeOutcome {
        ReframeOutcome { reframed, no_subject, failed, already_framed, stalled }
    }
}

/// The error text a subject detector answers with when its read hung (Swift `BlockingLane.Stalled`).
pub const DETECTOR_STALLED: &str = "stalled";

/// Lets a boxed detector run where a sized `SubjectDetecting` is wanted.
struct Boxed<'a>(&'a (dyn SubjectDetecting<Error = String> + Send));

impl SubjectDetecting for Boxed<'_> {
    type Error = String;
    fn subjects(&self, source_time: sq_core_time::Time) -> Result<Vec<sq_analysis::reframe::SubjectBox>, String> {
        self.0.subjects(source_time)
    }
}

/// A subject detector for one media (what `AnalysisBackend::subject_detector` gives).
pub type BoxedSubjectDetector = Box<dyn SubjectDetecting<Error = String> + Send>;

/// What an Auto Reframe run captured when it started: the clips with their geometry and samples.
#[derive(Clone, Debug)]
pub struct ReframeRun {
    timeline: Id,
    variant: Option<Id>,
    format: SequenceFormat,
    options: ReframeOptions,
    jobs: Vec<(Clip, ReframeGeometry, Vec<ReframeSample>, MediaRef)>,
    already_framed: i64,
}

/// The plans of an analysis and its counts so far.
#[derive(Clone, Debug, PartialEq)]
pub struct ReframeAnalysis {
    pub plans: BTreeMap<Id, ReframePlan>,
    pub outcome: ReframeOutcome,
}

impl ReframeRun {
    /// How many clips the analysis reads.
    pub fn clip_count(&self) -> usize {
        self.jobs.len()
    }

    /// Analyzes every target clip with the detector `detector(media)` returns (`None` = skip as failed). `progress` gets
    /// 0...1 over the whole run. `Err(Cancelled)` when canceled; nothing is applied then.
    pub fn analyze(
        &self,
        detector: &dyn Fn(&MediaRef) -> Option<BoxedSubjectDetector>,
        progress: Option<&(dyn Fn(f64) + Sync)>,
        cancel: &CancelToken,
        ids: &mut dyn IdSource,
    ) -> Result<ReframeAnalysis, Cancelled> {
        let mut outcome = ReframeOutcome { already_framed: self.already_framed, ..ReframeOutcome::default() };
        let mut plans = BTreeMap::new();
        let n = self.jobs.len().max(1) as f64;
        for (i, (clip, geometry, samples, media)) in self.jobs.iter().enumerate() {
            let Some(d) = detector(media) else {
                outcome.failed += 1;
                continue;
            };
            let base = i as f64;
            let report = |p: f64| {
                if let Some(f) = progress {
                    f((base + p) / n);
                }
            };
            match ReframeAnalyzer::detect(samples, &Boxed(d.as_ref()), Some(&report), cancel) {
                Ok(found) => match ReframePlanner::plan(&found, geometry, &self.options, ids) {
                    Some(plan) => {
                        plans.insert(clip.id, plan);
                    }
                    None => outcome.no_subject += 1,
                },
                Err(DetectError::Cancelled) => return Err(Cancelled),
                Err(DetectError::Detector(e)) if e == DETECTOR_STALLED => outcome.stalled += 1,
                Err(DetectError::Detector(_)) => outcome.failed += 1,
            }
        }
        cancel.check()?;
        Ok(ReframeAnalysis { plans, outcome })
    }
}

impl EditorSession {
    /// Clips Auto Reframe works on: the command clips (selection, else under the playhead) that show media video with a
    /// known picture size, on unlocked tracks. Generators, nested sequences, stills and held frames are skipped.
    // Swift: EditorSession+Reframe.swift:29
    pub fn reframe_targets(&self) -> Vec<Clip> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        let locked: Vec<Id> =
            t.tracks.iter().filter(|tr| tr.is_locked).flat_map(|tr| tr.clips().iter().map(|c| c.id)).collect();
        self.command_clips(Some(sq_core_model::TrackKind::Video))
            .into_iter()
            .filter(|c| {
                !c.is_generator()
                    && c.sequence.is_none()
                    && !c.is_still
                    && c.hold_frame.is_none()
                    && !locked.contains(&c.id)
                    && self.project().picture_size(c).is_some()
            })
            .collect()
    }

    /// Crop-window geometry of `clip` in the active sequence, in the active variant's frame when one is shown (its
    /// current static anchor, as that variant shows it, is kept).
    // Swift: EditorSession+Reframe.swift:40
    pub fn reframe_geometry(&self, clip: &Clip, options: &ReframeOptions) -> Option<ReframeGeometry> {
        let t = self.active_timeline()?;
        let (pw, ph) = self.project().picture_size(clip)?;
        let v = self.active_variant_id();
        let frame = t.format_for(v);
        let anchor = {
            let r = t.resolved_clip(clip, v);
            r.transform(clip.start).anchor
        };
        Some(ReframeGeometry {
            picture_width: pw,
            picture_height: ph,
            frame_width: frame.width,
            frame_height: frame.height,
            anchor,
            zoom: options.zoom,
        })
    }

    /// Captures the clips an Auto Reframe run reads; `None` without an active sequence.
    pub fn reframe_run(&self, options: &ReframeOptions) -> Option<ReframeRun> {
        let timeline = self.active_timeline()?;
        let variant = self.active_variant_id();
        let mut already_framed = 0;
        let mut jobs = Vec::new();
        for c in self.reframe_targets() {
            let (Some(g), Some(m)) = (self.reframe_geometry(&c, options), self.project().media(c.media)) else {
                continue;
            };
            if g.is_already_framed() {
                already_framed += 1;
                continue;
            }
            let samples = ReframeSampling::samples(&c, timeline.frame_duration(), options.sample_interval);
            jobs.push((c, g, samples, m.clone()));
        }
        Some(ReframeRun {
            timeline: timeline.id,
            variant,
            format: timeline.format_for(variant),
            options: *options,
            jobs,
            already_framed,
        })
    }

    /// Writes the plans of an analysis as one undo step and completes the counts.
    pub fn finish_reframe(&mut self, run: &ReframeRun, analysis: ReframeAnalysis) -> ReframeOutcome {
        let snapshot: BTreeMap<Id, Clip> = run.jobs.iter().map(|j| (j.0.id, j.0.clone())).collect();
        let (applied, stale) = self.apply_reframe_checked(
            &analysis.plans,
            Some(run.timeline),
            Some(&snapshot),
            Some(&run.format),
            run.variant,
        );
        let mut outcome = analysis.outcome;
        outcome.reframed = applied;
        outcome.failed += stale;
        outcome
    }

    /// Analyzes every target clip with the detector `detector(media)` returns (`None` = skip as failed), then applies all
    /// plans as one undo step, all on the calling thread. `Err(Cancelled)` when canceled; nothing is applied then.
    // Swift: EditorSession+Reframe.swift:51
    pub fn auto_reframe(
        &mut self,
        options: &ReframeOptions,
        progress: Option<&(dyn Fn(f64) + Sync)>,
        cancel: &CancelToken,
        detector: &dyn Fn(&MediaRef) -> Option<BoxedSubjectDetector>,
    ) -> Result<ReframeOutcome, Cancelled> {
        let Some(run) = self.reframe_run(options) else { return Ok(ReframeOutcome::default()) };
        let analysis = self.with_ids(|_, ids| run.analyze(detector, progress, cancel, ids))?;
        Ok(self.finish_reframe(&run, analysis))
    }

    /// The plan of `old` still fits `live`: same timing, time mapping and anchor (keys are clip-local, framing uses the
    /// anchor; in a variant also the variant's anchor override). Anything else means the clip was edited while it was
    /// analyzed.
    pub(crate) fn reframe_still_fits(live: &Clip, old: &Clip, variant: Option<Id>) -> bool {
        live.start == old.start
            && live.duration() == old.duration()
            && live.source == old.source
            && live.speed == old.speed
            && live.reversed == old.reversed
            && live.speed_keys == old.speed_keys
            && live.hold_frame == old.hold_frame
            && live.animation.anchor == old.animation.anchor
            && variant.is_none_or(|v| {
                live.variant_overrides().get(&v).map(|o| &o.anchor)
                    == old.variant_overrides().get(&v).map(|o| &o.anchor)
            })
    }

    /// Writes the plans (Position, uniform Scale) into the clips' Auto Reframe stage as one undo step "Auto Reframe".
    /// Clips that are gone or now sit on a locked track are skipped. False when nothing was written. `timeline`: the
    /// active one by default. The Motion fx toggle is left as it is (the stage renders either way).
    // Swift: EditorSession+Reframe.swift:103
    pub fn apply_reframe(&mut self, plans: &BTreeMap<Id, ReframePlan>, timeline: Option<Id>) -> bool {
        self.apply_reframe_checked(plans, timeline, None, None, None).0 > 0
    }

    /// `expecting`: the clips as they were when the analysis started; a clip that differs now (see
    /// `reframe_still_fits`), or every clip when the sequence format is no longer `format`, is skipped and counted as
    /// stale (so are clips that are gone or now on a locked track). `variant`: the keys go into that variant's override
    /// and `format` is compared with the variant's canvas; a variant that is gone makes every clip stale.
    pub(crate) fn apply_reframe_checked(
        &mut self,
        plans: &BTreeMap<Id, ReframePlan>,
        timeline: Option<Id>,
        expecting: Option<&BTreeMap<Id, Clip>>,
        format: Option<&SequenceFormat>,
        variant: Option<Id>,
    ) -> (i64, i64) {
        let Some(tid) = timeline.or(self.active_timeline_id) else { return (0, 0) };
        if plans.is_empty() {
            return (0, 0);
        }
        let n = plans.len() as i64;
        if let Some(v) = variant
            && self.project().timeline(tid).and_then(|t| t.variant(Some(v))).is_none()
        {
            return (0, n);
        }
        if let Some(f) = format
            && self.project().timeline(tid).map(|t| t.format_for(variant)).as_ref() != Some(f)
        {
            return (0, n);
        }
        let mut applied = 0;
        let r = self.with_ids(|s, ids| {
            s.try_perform("Auto Reframe", None, |p| {
                applied = 0;
                p.edit(tid, |t| {
                    let shown: Vec<(usize, Vec<Clip>)> = t
                        .tracks
                        .iter()
                        .enumerate()
                        .filter(|(_, tr)| !tr.is_locked)
                        .map(|(i, tr)| (i, tr.clips().to_vec()))
                        .collect();
                    for (_, clips) in shown {
                        for c in clips {
                            let Some(plan) = plans.get(&c.id) else { continue };
                            if let Some(old) = expecting.and_then(|e| e.get(&c.id))
                                && !Self::reframe_still_fits(&c, old, variant)
                            {
                                continue;
                            }
                            let mut n = c.clone();
                            // W7.1: the framing is an Auto Reframe effect stage on top of Motion; the user's Motion
                            // values and keys stay. A second run replaces the clip's stage (keeps its id, so variant
                            // overrides of it keep pointing at it).
                            let existing = n.effects.iter().position(|e| e.kind == ClipEffect::REFRAME_KIND);
                            let id = existing.map_or_else(|| ids.next_id(), |i| n.effects[i].id);
                            let shown_clip = variant.map_or_else(|| c.clone(), |v| t.resolved_clip(&c, Some(v)));
                            let base = shown_clip.transform(shown_clip.start);
                            let stage =
                                EffectTransformStage::reframe_effect(plan.scale, &plan.position, &base, id, ids);
                            if let Some(v) = variant {
                                // The variant's own framing (effect-parameter overrides); the base clip and the other
                                // variants keep theirs. A new stage on the base starts at identity.
                                if existing.is_none() {
                                    let mut e = stage.clone();
                                    e.parameters = ClipEffect::default_parameters(&e.kind);
                                    n.effects.push(e);
                                }
                                let mut overrides = n.variant_overrides();
                                overrides.entry(v).or_default().effect_parameters.insert(id, stage.parameters.clone());
                                n.set_variant_overrides(overrides);
                            } else if let Some(i) = existing {
                                n.effects[i] = stage;
                            } else {
                                n.effects.push(stage);
                            }
                            if n != c {
                                t.replace_clip(n)?;
                            }
                            applied += 1;
                        }
                    }
                    Ok::<(), EditError>(())
                })
            })
        });
        if let Err(e) = r {
            self.set_error(e.to_string());
            return (0, 0);
        }
        // Clips deleted or moved to a locked track meanwhile count as stale too.
        (applied, n - applied)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outcome_constructor_keeps_the_counts() {
        let o = ReframeOutcome::new(1, 2, 3, 4, 5);
        assert_eq!((o.reframed, o.no_subject, o.failed, o.already_framed, o.stalled), (1, 2, 3, 4, 5));
        assert_eq!(ReframeOutcome::default().reframed, 0);
    }
}
