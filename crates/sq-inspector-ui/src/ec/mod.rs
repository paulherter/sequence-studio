//! Effect Controls model and drawing.

pub mod animation;
pub mod color_match;
pub mod color_range_mask;
pub mod controls_metrics;
pub mod ease_sources;
pub mod effect_controls_model;
pub mod eq_curve;
pub mod grade_range;
pub mod graph_editor;
pub mod key_lane;
pub mod key_loop_bake;
pub mod key_nudge;
pub mod key_tools;
pub mod masks;
pub mod motion_curve;
pub mod picture_mask;
pub mod speed_graph;
pub mod stabilize;
pub mod text_align;
pub mod track_mask;

pub mod inspector_text_formats;
pub mod magic_check;
pub mod magic_tracked_frames;
pub mod multi;
pub mod prelude;

pub use effect_controls_model::MULTIBAND_PARAMETERS_KEY;

#[cfg(test)]
mod key_tools_tests;
