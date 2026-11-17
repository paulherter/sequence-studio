// Swift: EffectControlsModel+Stabilize.swift
//! Stabilize as an effect (DECISIONS 2026-10-06): Method, then Analyze (progress + cancel), then the method's parameters.

use std::collections::{BTreeMap, BTreeSet};

use sq_analysis::gyro_analysis_state::GyroAnalysisState;
use sq_core_masks::stabilize_effect::{ClipEffectStabilizeExt, GyroflowOptions, StabilizerMethod};
use sq_core_model::{Clip, ClipEffect};
use sq_core_time::Id;

use crate::ec::effect_controls_model::core::{EffectControlsEvent, EffectControlsModel};
use crate::ec::effect_controls_model::property::EffectProperty;

/// A Stabilize analysis in flight (the host runs it; one at a time).
#[derive(Clone, Debug, PartialEq)]
pub struct StabilizeRunState {
    pub clips: BTreeSet<Id>,
    /// 0...1 over the whole run.
    pub progress: f64,
}

/// What the Stabilizer's Analyze row shows.
#[derive(Clone, Debug, PartialEq)]
pub enum StabilizeRowStatus {
    NotAnalysed,
    Analysing(f64),
    /// Running without a measurable share yet (starting, reading gyro data, smoothing): the text says which step.
    Working(String),
    Analysed,
    /// Analyzed, but the clip now shows frames beyond the analyzed range; Start Again measures the whole range.
    NeedsAnalysis,
    /// The chosen method cannot run here (Gyroflow: no gyro data, engine not built); the reason is shown.
    Blocked(String),
    /// The last analysis failed (the reason is shown); Analyze tries again.
    Failed(String),
}

impl StabilizeRowStatus {
    pub fn is_running(&self) -> bool {
        matches!(self, StabilizeRowStatus::Analysing(_) | StabilizeRowStatus::Working(_))
    }
}

/// Why Gyroflow cannot run on a clip.
pub type GyroflowBlockOf = Box<dyn Fn(&Clip) -> Option<String>>;
/// The clip shows frames beyond its analysis.
pub type StabilizeStaleOf = Box<dyn Fn(&Clip) -> bool>;
/// The Gyroflow engine's analysis state of a clip with these options.
pub type GyroflowStateOf = Box<dyn Fn(&Clip, &GyroflowOptions) -> GyroAnalysisState>;

/// The hooks the host fills for the Stabilizer rows (Swift `gyroflowBlockOf`, `stabilizeStaleOf`, `gyroflowStateOf`).
#[derive(Default)]
pub struct StabilizeHooks {
    /// Why Gyroflow cannot run on a clip (None = it can).
    pub gyroflow_block_of: Option<GyroflowBlockOf>,
    /// The clip shows source frames its Stabilizer's analysis does not cover (trimmed longer): the row says so.
    pub stabilize_stale_of: Option<StabilizeStaleOf>,
    /// The Gyroflow engine's analysis of a clip with these options (progress / ready / failed for the Analyze row).
    pub gyroflow_state_of: Option<GyroflowStateOf>,
}

impl EffectControlsModel {
    /// Gyroflow's engine reports only its steps (reading the gyro data until 0.6, then smoothing).
    pub(crate) const GYRO_READING_TEXT: &'static str = "Reading gyro data\u{2026}";
    pub(crate) const GYRO_SMOOTHING_TEXT: &'static str = "Smoothing the motion\u{2026}";
    pub(crate) const STARTING_TEXT: &'static str = "Starting\u{2026}";

    /// Method of every Stabilizer on the shown clip (the layout shows only that method's rows).
    pub fn stabilizer_methods(&self) -> BTreeMap<Id, StabilizerMethod> {
        self.clip
            .as_ref()
            .map(|c| {
                c.effects
                    .iter()
                    .filter(|e| e.kind == ClipEffect::STABILIZE_KIND)
                    .map(|e| (e.id, e.stabilize_method()))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Why Gyroflow cannot stabilize the shown clip (nil = it can, or the host did not say).
    pub fn gyroflow_block(&self) -> Option<String> {
        let c = self.clip.as_ref()?;
        self.stabilize_hooks.gyroflow_block_of.as_ref().and_then(|f| f(c))
    }

    pub fn stabilize_status(&self, effect: Id) -> StabilizeRowStatus {
        let Some(c) = &self.clip else { return StabilizeRowStatus::NotAnalysed };
        let Some(e) = c.effects.iter().find(|e| e.id == effect) else { return StabilizeRowStatus::NotAnalysed };
        if e.stabilize_method() == StabilizerMethod::Gyroflow {
            // A picture analysis still running on this clip (started before the method changed) is not this method's.
            if let Some(why) = self.gyroflow_block() {
                return StabilizeRowStatus::Blocked(why);
            }
            let state = self
                .stabilize_hooks
                .gyroflow_state_of
                .as_ref()
                .map_or(GyroAnalysisState::Idle, |f| f(c, &GyroflowOptions::from_effect(e)));
            return match state {
                GyroAnalysisState::Idle => StabilizeRowStatus::NotAnalysed,
                GyroAnalysisState::Analysing(p) => StabilizeRowStatus::Working(
                    (if p < 0.6 { Self::GYRO_READING_TEXT } else { Self::GYRO_SMOOTHING_TEXT }).to_string(),
                ),
                GyroAnalysisState::Ready => StabilizeRowStatus::Analysed,
                GyroAnalysisState::Failed(why) => StabilizeRowStatus::Failed(why),
            };
        }
        if let Some(run) = &self.stabilize_run
            && run.clips.contains(&c.id)
        {
            // Before the first frame is measured (opening the file, waiting for another analysis) there is no share yet.
            return if run.progress > 0.0 {
                StabilizeRowStatus::Analysing(run.progress)
            } else {
                StabilizeRowStatus::Working(Self::STARTING_TEXT.to_string())
            };
        }
        if e.stabilize_is_analysed() {
            let stale = self.stabilize_hooks.stabilize_stale_of.as_ref().is_some_and(|f| f(c));
            return if stale { StabilizeRowStatus::NeedsAnalysis } else { StabilizeRowStatus::Analysed };
        }
        StabilizeRowStatus::NotAnalysed
    }

    /// The running analysis (set by the host).
    pub fn stabilize_run(&self) -> Option<&StabilizeRunState> {
        self.stabilize_run.as_ref()
    }

    pub fn set_stabilize_run(&mut self, run: Option<StabilizeRunState>) {
        if self.stabilize_run != run {
            self.stabilize_run = run;
            self.version += 1;
        }
    }

    /// Bumped by the host when a Gyroflow analysis moved on: the Analyze row reads `gyroflow_state_of` again.
    pub fn gyroflow_revision(&self) -> u64 {
        self.gyroflow_revision
    }

    pub fn bump_gyroflow_revision(&mut self) {
        self.gyroflow_revision += 1;
        self.version += 1;
    }

    /// Analyze (or Cancel while the shown clip is analyzed). Nothing while the method is blocked.
    pub fn analyze_or_cancel_stabilizer(&mut self, effect: Id) {
        let Some(c) = self.clip.clone() else { return };
        let Some(e) = c.effects.iter().find(|e| e.id == effect).cloned() else { return };
        let gyro = e.stabilize_method() == StabilizerMethod::Gyroflow;
        match self.stabilize_status(effect) {
            StabilizeRowStatus::Analysing(_) | StabilizeRowStatus::Working(_) => {
                if gyro {
                    self.events.push(EffectControlsEvent::GyroflowCancel {
                        clip: c,
                        options: GyroflowOptions::from_effect(&e),
                    });
                    self.bump_gyroflow_revision(); // the row reads the engine again now
                } else {
                    self.events.push(EffectControlsEvent::StabilizeCancel);
                }
            }
            StabilizeRowStatus::Blocked(_) => {}
            StabilizeRowStatus::NotAnalysed
            | StabilizeRowStatus::Analysed
            | StabilizeRowStatus::NeedsAnalysis
            | StabilizeRowStatus::Failed(_) => {
                self.events.push(EffectControlsEvent::StabilizeAnalyze(c.id));
                if gyro {
                    self.bump_gyroflow_revision(); // shows the started analysis at once
                }
            }
        }
    }

    /// Choice items shown but not selectable (index -> reason): Gyroflow while it cannot run on the shown clip.
    pub fn disabled_choices(&self, p: &EffectProperty) -> BTreeMap<i64, String> {
        let EffectProperty::Fx { kind, key, .. } = p else { return BTreeMap::new() };
        if kind != ClipEffect::STABILIZE_KIND || key != ClipEffect::STABILIZE_METHOD_KEY {
            return BTreeMap::new();
        }
        let Some(why) = self.gyroflow_block() else { return BTreeMap::new() };
        BTreeMap::from([(StabilizerMethod::Gyroflow as i64, why)])
    }
}
