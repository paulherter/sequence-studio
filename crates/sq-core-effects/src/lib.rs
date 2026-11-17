//! Effect evaluation, transitions, presets and sequence conform logic.
//!
//! See README.md for the module map; docs/rust/sq-core-split.md for the crate's place in the core split.

pub mod adjustment_clip;
pub mod adjustment_extend;
pub mod blurred_fill;
#[cfg(test)]
mod catalog_whole_clip_tests;
pub mod dynamic_zoom;
pub mod effect_preset;
pub mod effect_stack_preset;
pub mod effect_transform_stage;
pub mod effects_editing;
pub mod effects_evaluation;
pub mod evaluation;
pub mod keystone;
pub mod motion_effects;
pub mod motion_presets;
pub mod motion_recipes;
pub mod sequence_conform;
pub mod speed_ramp_preset;
pub mod style_effects;
pub mod style_kit;
pub mod temporal_effects;
pub mod transition;
pub mod transition_custom_curve;
pub mod transition_feel;
pub mod transition_layer;
pub mod user_preset_bake;
