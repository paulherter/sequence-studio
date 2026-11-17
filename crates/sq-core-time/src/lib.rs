// SPDX-License-Identifier: GPL-3.0-or-later
//! Bottom layer of the Sequence Studio core, ported from SQCore: rational time, frame rates, keyframe tracks and
//! easing, ids, timestamps, the encoder side channel, base64 for `Data` and text helpers.
//! The only other `sq-*` dependency is `sq-prproj-reader` (raw inflate).

pub mod base64;
pub mod caught_panic;
pub mod cmx_timecode;
pub mod codec;
pub mod ease_names;
pub mod easing_spring;
pub mod frame_rate;
pub mod ids;
pub mod json_sorted;
pub mod keyframes_easing;
pub mod keyframes_model;
pub mod keyframes_spatial;
pub mod local_time;
pub mod milestones;
pub mod portable_png;
pub mod raw_inflate;
pub mod sha256_digest;
pub mod step_status;
pub mod text;
pub mod text_search;
pub mod time;
pub mod timestamp;
pub mod word_segmentation;

pub use cmx_timecode::CmxTimecode;
pub use codec::{EncodeContext, Seen, SeenFlags};
pub use easing_spring::{SpringEasing, SpringPreset};
pub use frame_rate::FrameRate;
pub use ids::{Id, IdSource, RandomIds, SequentialIds};
pub use keyframes_easing::{EaseSide, EasingCurve, EasingLibrary};
pub use keyframes_model::{EaseHandle, Interpolation, Keyframe, KeyframeTrack, KeyframeValue, Vec2};
pub use keyframes_spatial::{MotionPathSegment, SpatialPath};
pub use time::{Time, TimeRange};
pub use timestamp::Timestamp;
