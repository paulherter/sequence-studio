//! The Program engine: a 1:1 port of the Windows `WinProgramEngine` (cache, wanted / shown frames, clock hold, warm-up,
//! scrub, play / pause / shuttle, loop) running on its own render thread. See crates/sq-playback/README.md and
//! docs/rust/render-playback-export-design.md section 2.

pub mod activity;
pub mod caption_plan;
pub mod caption_preview;
mod clock_hold;
pub mod core;
pub mod display_pacing;
mod first_visible;
pub mod frame_trace;
mod gyro_gate;
pub mod handle;
pub mod key_strip;
pub mod lanes;
mod late_frames;
pub mod layer_rasters;
pub mod look_preview;
pub mod matte_look_ahead;
pub mod media_source;
pub mod memory_budget;
mod played_through;
pub mod power_policy;
pub mod preview_rate;
pub mod preview_size;
pub mod proxy_picture;
mod seek_coalesce;
pub mod state;
pub mod stats;
pub mod system_watch;
pub mod text_stand_ins;
pub mod types;

pub use caption_preview::CaptionPreview;
pub use core::{ProgramEngine, playback_layer_detail};
pub use display_pacing::{
    DisplayTick, DisplayTiming, LOOP_PERIOD_PERCENT, LOOP_PERIOD_SATURATED_PERCENT, PresentSlots,
};
pub use handle::{Command, EngineDeps, ProgramHandle, RasterProvider, Shown, Status};
pub use lanes::{CancelToken, LanePool};
pub use layer_rasters::LayerRasters;
pub use look_preview::LookPreview;
pub use media_source::{DefaultOpener, MediaSource};
pub use state::{CompositorSlot, EngineState, Event, InvalidTransition};
pub use types::{Key, MediaRef, Picture, WantGate, Wanted};

#[cfg(test)]
mod testkit;
#[cfg(test)]
mod tests;

#[cfg(test)]
mod tests_layers;

#[cfg(test)]
mod tests_loop;

#[cfg(test)]
mod tests_media;

#[cfg(test)]
mod tests_quality;

#[cfg(test)]
mod tests_shutter;

#[cfg(test)]
mod tests_gyro;
#[cfg(test)]
mod tests_state;
