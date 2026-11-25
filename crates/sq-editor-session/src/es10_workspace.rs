// Swift: Workspace.swift, WorkspaceStore.swift, WorkspaceDocking.swift, FloatingPanelState.swift, AppSettings.swift,
// PreferenceChoices.swift, StorageLocations.swift, KeyboardLayout.swift and the other ES10 files of TASKS.md.
//! ES10: workspaces (layout tree, docking, store, floating panels), app settings and preferences.
//!
//! Settings are read and written through [`sq_uikit::appearance_palette::UiDefaults`]; the JSON-file implementation
//! lives in the app crate. Flags are stored as the integer 0 / 1 and fractional numbers as text (see [`DefaultsExt`]).

mod defaults;
mod docking;
mod keyboard;
mod layout;
mod my_curves;
mod settings;
mod storage;
mod store;
mod update;
mod update_flow;

#[cfg(test)]
mod tests;

pub use defaults::DefaultsExt;
pub use docking::*;
pub use keyboard::*;
pub use layout::*;
pub use my_curves::MyCurves;
pub use settings::*;
pub use storage::*;
pub use store::*;
pub use update::*;
pub use update_flow::*;

/// Pretty JSON with sorted keys at every level (Swift `.prettyPrinted, .sortedKeys`).
pub(crate) fn encode_sorted_pretty<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_vec_pretty(&sq_core_time::json_sorted::to_value(value)?)
}
