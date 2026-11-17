// Swift: EditorSession+Effects.swift, EditorSession+Color*.swift, ColorMattePreview.swift, EditorSession+Looks.swift,
// LookStore.swift, EditorSession+Transition*.swift, TransitionTargets.swift, EditorSession+Presets.swift,
// EditorSession+Variants.swift, QuickApplyModel.swift and the other ES4 files of TASKS.md.
//! ES4: effects, color, looks and the Look store, transitions, presets, format variants, quick apply.
//!
//! One submodule per Swift topic; the public items are re-exported here (lib.rs globs this module).

mod color;
mod color_match;
mod effect_support;
mod effects;
mod helpers;
mod look_commands;
mod look_store;
mod looks;
mod presets;
mod quick_apply;
mod split_blurred;
mod transition_layer;
mod transition_targets;
mod transitions;
mod variants;

#[cfg(test)]
mod tests;

pub(crate) use color::showing_matte;
pub use color::*;
pub use color_match::*;
pub use effect_support::*;
pub use look_commands::*;
pub use look_store::*;
pub use looks::*;
pub use presets::*;
pub use quick_apply::*;
pub use split_blurred::*;
pub use transition_layer::*;
pub use transition_targets::*;
pub use transitions::*;

#[cfg(test)]
mod transition_ui_tests;
