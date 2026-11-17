// Swift: AnalysisFlows+ColorMatch.swift
//! Clip > Video Options > Match Color to Clip: each clip is shown on its own (raw file + grade) in the Program engine
//! for one frame capture, then the session solves and writes Exposure + Color Wheels on the target as one undo step.

use super::analysis_flows::AnalysisFlows;
use crate::EditorSession;
use crate::es04_effects::{ColorMatchToClipOutcome, ColorMatchToClipPlan};
use sq_core_color::ColorMatchPair;

impl AnalysisFlows {
    // Swift: AnalysisFlows+ColorMatch.swift:16
    pub fn is_matching_color(&self) -> bool {
        self.color_match_busy
    }

    /// Display-encoded RGB (BT.709 per channel, 0...1) of linear samples: what Color Match measures.
    // Swift: AnalysisFlows+ColorMatch.swift:21
    pub fn display_rgb(linear: &[[f32; 3]]) -> Vec<[f32; 3]> {
        super::frame_sampler::FrameSampler::display_rgb(linear)
    }

    /// True while a Match Color to Clip run waits for its captures.
    pub fn is_color_matching(&self) -> bool {
        self.color_match_busy
    }

    /// Match Color to Clip: plan, solo capture of both clips on the engine's render loop, apply. The captures answer later
    /// through [`AnalysisFlows::handle_color_samples`]; the host calls [`AnalysisFlows::expire_color_match`] with the
    /// returned run number after `color_match_timeout`.
    // Swift: AnalysisFlows+ColorMatch.swift:29
    pub fn request_color_match_to_clip(&mut self, session: &mut EditorSession) -> Option<i64> {
        if self.color_match_busy {
            return None;
        }
        match session.color_match_to_clip_plan() {
            ColorMatchToClipPlan::Blocked(why) => {
                self.flash(why, 4.0);
                None
            }
            ColorMatchToClipPlan::Ready(pair) => {
                if self.frame_sampler.is_none() {
                    self.flash(Self::unavailable("Match Color to Clip"), 5.0);
                    return None;
                }
                session.stop_playback();
                self.color_match_busy = true;
                self.color_match_run += 1;
                let run = self.color_match_run;
                self.sample_solo(
                    session,
                    ColorMatchStep { pair, stage: ColorMatchStage::ReferenceFirst, reference: None },
                );
                Some(run)
            }
        }
    }

    /// The timeout of run `run`: a capture that never arrived must not leave the monitor on the solo view.
    // Swift: AnalysisFlows+ColorMatch.swift:40
    pub fn expire_color_match(&mut self, session: &mut EditorSession, run: i64) {
        if !self.color_match_busy || self.color_match_run != run {
            return;
        }
        self.color_match_busy = false;
        self.color_match_run += 1;
        self.color_match_step = None;
        session.end_color_match_solo();
        self.flash("Could not read the clips' frames.", 4.0);
    }

    /// The answer of a `sample_linear(96, "color.match.clip")` capture: working-linear samples, `None` without a picture.
    // Swift: AnalysisFlows+ColorMatch.swift:54
    pub fn handle_color_samples(&mut self, session: &mut EditorSession, samples: Option<Vec<[f32; 3]>>) {
        if !self.color_match_busy {
            return;
        }
        let Some(mut step) = self.color_match_step.take() else { return };
        let Some(samples) = samples else {
            self.finish_color_match(session, None, None, step);
            return;
        };
        match step.stage {
            ColorMatchStage::ReferenceFirst => {
                step.stage = ColorMatchStage::ReferenceSecond;
                self.request_capture(step);
            }
            ColorMatchStage::ReferenceSecond => {
                step.reference = Some(Self::display_rgb(&samples));
                step.stage = ColorMatchStage::TargetFirst;
                self.sample_solo(session, step);
            }
            ColorMatchStage::TargetFirst => {
                step.stage = ColorMatchStage::TargetSecond;
                self.request_capture(step);
            }
            ColorMatchStage::TargetSecond => {
                let reference = step.reference.clone();
                self.finish_color_match(session, reference, Some(Self::display_rgb(&samples)), step);
            }
        }
    }

    fn request_capture(&mut self, step: ColorMatchStep) {
        self.color_match_step = Some(step);
        if let Some(s) = self.frame_sampler.as_mut() {
            s.sample_linear(96, COLOR_MATCH_KEY);
        }
    }

    /// Shows the step's clip alone at its time and captures it. Captured twice: the first capture can come from a render
    /// that still waited for the decode; the second is the settled frame.
    // Swift: AnalysisFlows+ColorMatch.swift:73
    fn sample_solo(&mut self, session: &mut EditorSession, step: ColorMatchStep) {
        let (id, at) = match step.stage {
            ColorMatchStage::ReferenceFirst | ColorMatchStage::ReferenceSecond => {
                (step.pair.reference, step.pair.reference_time)
            }
            _ => (step.pair.target, step.pair.target_time),
        };
        if !session.show_color_match_solo(id, at) {
            self.finish_color_match(session, None, None, step);
            return;
        }
        self.request_capture(step);
    }

    fn finish_color_match(
        &mut self,
        session: &mut EditorSession,
        reference: Option<Vec<[f32; 3]>>,
        target: Option<Vec<[f32; 3]>>,
        step: ColorMatchStep,
    ) {
        session.end_color_match_solo();
        self.color_match_busy = false;
        self.color_match_step = None;
        let (Some(reference), Some(target)) = (reference, target) else {
            self.flash("Could not read the clips' frames.", 4.0);
            return;
        };
        match session.apply_color_match_to_clip(&step.pair, &reference, &target) {
            ColorMatchToClipOutcome::Applied => {
                self.flash("Matched: Exposure and Wheels & Match are set in the clip's Color effect.", 4.0)
            }
            ColorMatchToClipOutcome::AlreadyMatches => self.flash("The clip already matches.", 4.0),
            ColorMatchToClipOutcome::Unreadable => {
                self.flash("Could not read the clips' frames (black or offline).", 4.0)
            }
        }
    }
}

/// The capture key of both Match Color captures.
const COLOR_MATCH_KEY: &str = "color.match.clip";

/// Where a Match Color run waits: which clip is shown and which capture comes next.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ColorMatchStage {
    ReferenceFirst,
    ReferenceSecond,
    TargetFirst,
    TargetSecond,
}

/// One Match Color run in flight.
#[derive(Clone, Debug)]
pub(crate) struct ColorMatchStep {
    pair: ColorMatchPair,
    stage: ColorMatchStage,
    reference: Option<Vec<[f32; 3]>>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_rgb_follows_the_bt709_curve() {
        let out = AnalysisFlows::display_rgb(&[[0.0, 0.0018, 1.0], [0.18, 2.0, -1.0]]);
        assert_eq!(out[0][0], 0.0);
        assert!((out[0][1] - 0.0081).abs() < 1e-4); // linear toe
        assert!((out[0][2] - 1.0).abs() < 1e-5);
        assert!((out[1][0] - 0.4090).abs() < 1e-3);
        assert_eq!((out[1][1], out[1][2]), (1.0, 0.0)); // clamped before the curve
    }
}
