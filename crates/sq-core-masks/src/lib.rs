// SPDX-License-Identifier: GPL-3.0-or-later
//! Mask, Magic mask, Subject mask, Picture mask, stabilizer, rolling shutter, anonymize and perspective tilt logic
//! (port of the matching files of Swift `SQCore`). The saved types live in `sq-core-model`; Swift extensions on them
//! are extension traits here.

pub mod anonymize;
pub mod anonymize_order;
pub mod magic_correction;
pub mod magic_follow;
pub mod magic_mask;
pub mod magic_matte_needs;
pub mod magic_track_health;
pub mod mask_inputs;
pub mod mask_motion;
pub mod mask_path_editing;
pub mod masks;
pub mod matte_refine;
pub mod perspective_tilt;
pub mod picture_mask;
pub mod rolling_shutter;
pub mod stabilization_cuts;
pub mod stabilize_effect;
pub mod stabilizer;
pub mod stabilizer_l1;
pub mod stabilizer_perspective;
pub mod stabilizer_quadratic;
pub mod stabilizer_solve;
#[cfg(test)]
mod stabilizer_tests;
pub mod subject_crop_pass;
pub mod subject_mask;
pub mod subject_mask_editing;
pub mod subject_track_rules;
#[cfg(test)]
mod test_util;

pub use anonymize::*;
pub use anonymize_order::*;
pub use magic_follow::*;
pub use magic_mask::*;
pub use magic_matte_needs::*;
pub use magic_track_health::*;
pub use mask_inputs::*;
pub use mask_motion::*;
pub use mask_path_editing::*;
pub use masks::*;
pub use picture_mask::*;
pub use rolling_shutter::*;
pub use sq_core_model::StageTransform;
pub use stabilization_cuts::*;
pub use stabilize_effect::*;
pub use stabilizer::*;
pub use stabilizer_perspective::*;
pub use subject_crop_pass::*;
pub use subject_mask::*;
pub use subject_mask_editing::*;
pub use subject_track_rules::*;
