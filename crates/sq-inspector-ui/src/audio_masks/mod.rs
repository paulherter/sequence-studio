//! Audio and masks of the inspector (Swift SQInspectorUI: track audio, Multiband Compressor setup, mask tracking state,
//! transition controls and their `Draw/` counterparts).

pub mod audio_effects_tab;
pub mod compressor_bands_geometry;
pub mod compressor_curve;
pub(crate) mod draw_support;
pub mod effect_controls_multiband_model;
pub mod magic_steps;
pub mod magic_track_control;
pub mod mask_track_activity;
pub mod multiband_editor_draw;
pub mod multiband_host;
pub mod subject_mask_quality_menu;
pub mod track_audio_draw;
pub mod track_audio_inspector_model;
pub mod transition_controls_draw;
pub mod transition_controls_model;
