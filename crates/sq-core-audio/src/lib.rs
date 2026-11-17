// SPDX-License-Identifier: GPL-3.0-or-later
//! Audio, ducking and caption logic on top of `sq-core-model` (port of the audio part of Swift `SQCore`).
//!
//! Swift extensions on model types are extension traits, re-exported flat. Ids come in as `&mut dyn IdSource`, user
//! defaults as `DefaultsStore`. What cannot be ported yet is listed in `NOTES.md`.

pub mod angles_audio_sync;
pub mod audio_channel_map;
pub mod audio_drift_fit;
pub mod audio_effects;
pub mod audio_gain;
pub mod audio_gain_plan;
pub mod audio_role;
pub mod caption_handover;
pub mod caption_item;
pub mod caption_items;
pub mod caption_tidy;
pub mod caption_words;
pub mod ducking;
pub mod filler_words;
pub mod live_ducking;
pub mod live_ducking_index;
pub mod silence_removal;
pub mod timeline_caption_edits;
pub mod tone_generator;
pub mod voiceover;

pub use angles_audio_sync::*;
pub use audio_channel_map::*;
pub use audio_drift_fit::*;
pub use audio_effects::*;
pub use audio_gain::*;
pub use audio_gain_plan::*;
pub use audio_role::*;
pub use caption_handover::*;
pub use caption_item::*;
pub use caption_items::*;
pub use caption_tidy::*;
pub use caption_words::*;
pub use ducking::*;
pub use filler_words::*;
pub use live_ducking::*;
pub use live_ducking_index::*;
pub use silence_removal::*;
pub use timeline_caption_edits::*;
pub use tone_generator::*;
pub use voiceover::*;
