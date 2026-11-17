// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MediaManagement.swift (the ImportMode type, moved down; media management itself lives in sq-core-project)

use serde::{Deserialize, Serialize};

/// What import does with the media file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ImportMode {
    /// Copy into the project folder.
    Copy,
    /// Move into the project folder.
    Move,
    /// Leave it where it is.
    Leave,
}
