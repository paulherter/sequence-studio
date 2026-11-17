// SPDX-License-Identifier: GPL-3.0-or-later
//! The Sequence Studio project model (port of the saved types of Swift `SQCore`): `Project`, `Timeline`, `Track`,
//! `Clip` and every type stored inside them, with their serde coding. Logic that only reads or edits these types
//! lives here when Swift keeps it next to the type; edit verbs live in higher `sq-core-*` crates.
//!
//! Type modules are re-exported flat (`sq_core_model::Clip`). Logic modules (`pub mod`) start empty and are filled by
//! the model tasks without touching this file; their new types are re-exported flat when the wave is merged.

mod affine2;
mod unknown_keys;
pub use unknown_keys::{FileExtras, UnknownKeys};
pub mod anchored_animation;
mod angles;
mod animation_zones;
pub mod animation_zones_lengths;
mod bin;
mod blend_mode;
mod captions;
mod clip_animation;
mod clip_attachment;
mod clip_color;
mod clip_effect;
mod clip_rebase;
mod clip_speed;
mod color_grade_effect;
mod color_graph;
mod cow_vec;
pub mod curve_math;
mod delivery_target;
pub mod effect_defaults;
mod effects_catalog;
mod error;
mod fades;
pub mod fades_curve;
mod format_variants;
mod graphics;
pub mod graphics_item_range;
mod grouping;
pub mod hidden_catalog;
pub mod keyframes_clipboard;
mod keyframes_ease_selection;
pub mod keyframes_editing;
pub mod keyframes_graph;
pub mod keyframes_hue;
pub mod keyframes_loop_bake;
pub mod keyframes_pair;
pub mod keyframes_pair_ease;
pub mod keyframes_premiere;
pub mod keyframes_relative_ops;
pub mod keyframes_roving;
pub mod keyframes_speed_hill;
pub mod keyframes_speed_overlay;
pub mod keyframes_spring_bake;
mod labels;
mod live_ducking;
pub mod lut_space_hint;
mod marker;
mod masks;
mod media_info;
mod media_management;
mod media_policy;
mod model;
pub mod motion_easing;
pub mod nesting;
mod pixel_aspect;
mod project;
pub mod project_media_ops;
mod project_smart_bins;
mod render_cache_substitution;
mod sequence_channels;
pub mod sequence_pixel_shape;
pub mod sequence_settings;
mod sequence_timecode;
mod serde_defaults;
mod source_marks;
mod source_patch;
mod speed_keys;
pub mod speed_keys_ease;
pub mod speed_keys_editing;
pub mod speed_keys_key_value;
pub mod speed_keys_points;
pub mod speed_keys_timeline;
mod style_kit;
mod subclip;
mod timeline;
mod title_template;
mod track_pan;
mod transition;
mod user_preset_bake;

pub use affine2::*;
pub use angles::*;
pub use animation_zones::*;
pub use bin::*;
pub use blend_mode::*;
pub use captions::*;
pub use clip_animation::*;
pub use clip_attachment::*;
pub use clip_color::*;
pub use clip_effect::*;
pub use clip_speed::*;
pub use color_grade_effect::*;
pub use color_graph::*;
pub use cow_vec::CowVec;
pub use delivery_target::*;
pub use effects_catalog::*;
pub use error::*;
pub use fades::*;
pub use format_variants::*;
pub use graphics::*;
pub use grouping::*;
pub use keyframes_ease_selection::*;
pub use labels::*;
pub use live_ducking::*;
pub use marker::*;
pub use masks::*;
pub use media_info::*;
pub use media_management::*;
pub use media_policy::*;
pub use model::*;
pub use pixel_aspect::*;
pub use project::*;
pub use project_smart_bins::*;
pub use render_cache_substitution::*;
pub use sequence_channels::*;
pub use sequence_timecode::*;
pub use source_marks::*;
pub use source_patch::*;
pub use speed_keys::*;
pub use style_kit::*;
pub use subclip::*;
pub use timeline::*;
pub use title_template::*;
pub use track_pan::*;
pub use transition::*;
pub use user_preset_bake::*;

/// Model types plus the time crate types they are built from.
pub mod prelude {
    pub use crate::*;
    pub use sq_core_time::{
        EaseHandle, Id, IdSource, Interpolation, Keyframe, KeyframeTrack, KeyframeValue, Time, TimeRange, Timestamp,
        Vec2,
    };
}
