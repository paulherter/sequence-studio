// Swift: EditorSession+TimelineOps.swift, EdgeEdits.swift, EditorSession+SourceEdit.swift, EditorSession+SplitEdit.swift,
// EditorSession+MultiEdit.swift, EditorSession+Replace*.swift, EditorSession+Angles.swift, TrimModeModel.swift,
// SnapGuides.swift, BuiltInClipboard.swift, MarkersPanelModel.swift and the other ES2 files of TASKS.md.
//! ES2: timeline edits from the session: ops, edge edits, source/split/multi edits, replace, angles, trim mode, snap
//! guides, clipboards, line keys, markers panel.

mod angles;
mod edge_edits;
mod line_keys;
mod markers_panel;
mod paste;
mod prelude;
mod session_edits;
mod snap_guides;
mod source_edit;
#[cfg(test)]
mod tests;
mod timeline_ops;
mod track_toggles;
mod trim_mode;

#[cfg(test)]
use crate::{EdgeRef, EdgeSelection, TimelineEdit};
pub use angles::*;
pub use edge_edits::EdgeEdits;
pub use line_keys::*;
pub use markers_panel::*;
pub use paste::*;
pub use session_edits::*;
pub use snap_guides::*;
pub use timeline_ops::*;
pub use track_toggles::*;
pub use trim_mode::*;
