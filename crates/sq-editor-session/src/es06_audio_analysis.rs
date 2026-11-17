// Swift: AnalysisFlows*.swift, AnalysisJob.swift, EditorSession+Stabilize.swift, EditorSession+Reframe.swift,
// MagicMaskSession.swift, FrameSampler.swift, EditorSession+Audio*.swift, EditorSession+LiveDucking.swift,
// EditorSession+Voice*.swift, EditorSession+Anonymize.swift and the other ES6 files of TASKS.md.
//! ES6: audio, voice, analysis flows, stabilize, reframe, Magic mask (ONNX path).
//!
//! One submodule per Swift file group (see `notes/es06.md` for the design of the async flows). `AnalysisFlows` keeps no
//! session reference (Swift `let session`): every method takes `&mut EditorSession`. Its UI callbacks
//! (`AnalysisFlowUI.setJob/flash`) and `onStabilizeProgress` are [`AnalysisFlowsEvent`]s; its workers answer with
//! [`AnalysisFlowsMessage`]s.

mod analysis_flows;
mod analysis_job;
mod anonymize;
mod anonymize_text;
mod audio_channels_menu;
mod audio_edits;
mod audio_extraction;
mod audio_role_defaults;
mod audio_shortform;
mod color_match;
mod disguise_voice;
#[cfg(test)]
mod flow_tests;
mod frame_sampler;
mod helpers;
mod live_ducking;
mod magic_mask_session;
mod magic_track_health_cache;
mod nv12_reduce;
mod reframe;
mod settings;
mod silence_settings;
mod stabilize;
#[cfg(test)]
mod tests;
mod voice_recording;

pub use analysis_flows::*;
pub use analysis_job::*;
pub use anonymize::*;
pub use anonymize_text::*;
pub use audio_channels_menu::*;
pub use audio_edits::MeasureLoudness;
pub use audio_extraction::*;
pub use audio_role_defaults::*;
pub use audio_shortform::*;
pub use disguise_voice::*;
pub use frame_sampler::*;
pub use live_ducking::*;
pub use magic_mask_session::*;
pub use magic_track_health_cache::*;
pub use nv12_reduce::*;
pub use reframe::*;
pub use silence_settings::*;
pub use stabilize::*;
pub use voice_recording::*;
