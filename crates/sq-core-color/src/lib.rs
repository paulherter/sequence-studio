// SPDX-License-Identifier: GPL-3.0-or-later
//! Color logic of the Sequence Studio project model (port of the color files of Swift `SQCore`): tone curves, Auto
//! Tone, the Zone Board, film looks, the Pro grade graph and its wiring, camera input color spaces.
//!
//! The saved color types live in `sq-core-model`. Swift extensions on them are extension traits here (`ClipColorExt`,
//! `ColorGraphExt`, ...), re-exported flat; import what you call.

pub mod auto_tone_solver;
pub mod basic_tone_curves;
mod clip_grade;
mod color_bypass;
pub mod color_decision_import;
mod color_effect;
mod color_grade_effect;
mod color_grade_links;
mod color_graph;
mod color_graph_wiring;
mod color_match;
mod color_match_oklab;
mod color_match_to_clip;
mod color_matte;
mod color_range_key;
mod film_look;
mod input_color_space;
pub mod key_color_pick;
mod vec3;
mod zone_board;

pub use clip_grade::*;
pub use color_bypass::*;
pub use color_effect::*;
pub use color_grade_effect::*;
pub use color_grade_links::*;
pub use color_graph::*;
pub use color_graph_wiring::*;
pub use color_match::*;
pub use color_match_oklab::Oklab;
pub use color_match_to_clip::*;
pub use color_matte::*;
pub use color_range_key::ColorRangeKeyExt;
pub use film_look::*;
pub use input_color_space::*;
pub use zone_board::*;
