// Swift: EffectControlsModel.swift
//! The Effect Controls model.

pub mod clip_sync;
pub mod core;
pub mod editing;
pub mod fx;
pub mod keys;
pub mod lane_geometry;
pub mod layout;
pub mod mask_keys;
pub mod premiere;
pub mod property;
pub mod reading;
pub mod section;

pub use core::{EffectControlsEvent, EffectControlsModel, ItemHost, TwirlState};
pub use lane_geometry::KeyframeLaneGeometry;
pub use layout::{
    EffectControlsLayout, EffectControlsSwitch, EffectGroup, EffectRow, EffectRowKind, EffectRowsRequest,
    GraphProjection, GraphProjectionComponent, SpeedControl,
};
pub use property::{EffectComponent, EffectProperty, EffectPropertyKind, MaskParam, StopwatchOutcome};
pub use section::EffectSectionExt;

/// Key of the "All Parameters" disclosure of a Multiband Compressor.
pub const MULTIBAND_PARAMETERS_KEY: &str = "all-parameters";

#[cfg(test)]
mod tests;
