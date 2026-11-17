//! Gyroflow in the app: one engine per process shared by the Program monitor, the export and the Inspector, and the
//! Inspector's hooks (`gyroflow_state_of`, `gyroflow_block_of`, Analyze, Cancel). Swift: `EditorSession+Gyroflow`.

use sq_analysis::gyro_analysis_state::GyroAnalysisState;
use sq_core_masks::stabilize_effect::{ClipEffectStabilizeExt, GyroflowOptions, StabilizerMethod};
use sq_core_model::{Clip, ClipEffect};
use sq_core_time::Id;
use sq_editor_session::SessionMediaResolving;
use sq_gyroflow::{GyroEngine, GyroState};
use sq_inspector_ui::ec::effect_controls_model::core::EffectControlsModel;
use sq_playback::engine::handle::GyroHook;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};

/// The file of a media id.
pub type PathOf = Arc<dyn Fn(Id) -> Option<String> + Send + Sync>;

/// The engine every part of the app shares (analyses and warp maps are cached in it, so a clip analyzed in the
/// Inspector is ready for playback and export).
pub fn shared_engine() -> Arc<GyroEngine> {
    static ENGINE: OnceLock<Arc<GyroEngine>> = OnceLock::new();
    Arc::clone(ENGINE.get_or_init(|| Arc::new(GyroEngine::new())))
}

/// What `EngineDeps::gyro` takes. Export waits for each clip's analysis (`wait`), playback shows the clip unwarped until
/// the engine's observer redraws.
pub fn hook(wait: bool) -> GyroHook {
    GyroHook { maps: shared_engine(), wait }
}

/// The paths of the session's media.
pub fn path_of(media: &Arc<dyn SessionMediaResolving>) -> PathOf {
    let media = Arc::clone(media);
    Arc::new(move |id| media.file_path(id).map(|p| p.to_string_lossy().into_owned()))
}

/// The engine's state as the Analyze row shows it.
pub fn analysis_state(s: GyroState) -> GyroAnalysisState {
    match s {
        GyroState::Idle => GyroAnalysisState::Idle,
        GyroState::Analysing(p) => GyroAnalysisState::Analysing(p),
        GyroState::Ready => GyroAnalysisState::Ready,
        GyroState::Failed(why) => GyroAnalysisState::Failed(why),
    }
}

/// The first Gyroflow Stabilizer of a clip.
pub fn gyro_effect(clip: &Clip) -> Option<&ClipEffect> {
    clip.effects
        .iter()
        .find(|e| e.kind == ClipEffect::STABILIZE_KIND && e.stabilize_method() == StabilizerMethod::Gyroflow)
}

/// The Inspector's side of the engine.
pub struct GyroflowLink {
    engine: Arc<GyroEngine>,
    /// Set by the engine's observer (any thread): the Analyze row reads the state again.
    moved: Arc<AtomicBool>,
    installed: bool,
}

impl GyroflowLink {
    pub fn new(engine: Arc<GyroEngine>) -> GyroflowLink {
        let moved = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&moved);
        engine.analyses().add_observer(Arc::new(move || flag.store(true, Ordering::Release)));
        GyroflowLink { engine, moved, installed: false }
    }

    /// Fills the model's hooks once, and bumps its revision when an analysis moved on.
    pub fn sync(&mut self, model: &mut EffectControlsModel, paths: &PathOf) {
        if !self.installed {
            self.installed = true;
            let (engine, p) = (Arc::clone(&self.engine), Arc::clone(paths));
            model.stabilize_hooks.gyroflow_state_of = Some(Box::new(move |c, o| match p(c.media) {
                Some(path) => analysis_state(engine.analyses().state(&path, o)),
                None => GyroAnalysisState::Idle,
            }));
            let p = Arc::clone(paths);
            model.stabilize_hooks.gyroflow_block_of =
                Some(Box::new(move |c| p(c.media).is_none().then(|| "The clip's file is not available.".to_string())));
        }
        if self.moved.swap(false, Ordering::AcqRel) {
            model.bump_gyroflow_revision();
        }
    }

    /// Analyze on a Gyroflow row: starts (or, after a failure, restarts) the analysis. False = not a Gyroflow clip.
    pub fn analyze(&self, clip: &Clip, paths: &PathOf) -> bool {
        let (Some(e), Some(path)) = (gyro_effect(clip), paths(clip.media)) else { return false };
        self.engine.analyses().prepare(&path, &GyroflowOptions::from_effect(e));
        true
    }

    /// Cancel on a running Gyroflow row.
    pub fn cancel(&self, clip: &Clip, options: &GyroflowOptions, paths: &PathOf) {
        if let Some(path) = paths(clip.media) {
            self.engine.analyses().cancel(&path, options);
        }
    }
}

#[cfg(test)]
mod tests;
