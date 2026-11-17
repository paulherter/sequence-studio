// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ProjectFile.swift (ProjectFileError)

use std::fmt;

/// Why a project file could not be read or written.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProjectFileError {
    /// No file at the path.
    Missing,
    /// Not a project file, or damaged beyond the migration path.
    Corrupt,
    /// Written by a newer build.
    NewerVersion {
        /// The file's `formatVersion`.
        found: i64,
        /// The newest version this build reads.
        supported: i64,
    },
    /// The project could not be turned into JSON (Swift: the encoder's error).
    Encode(String),
    /// A file system call failed (Swift: the Foundation error).
    Io(String),
}

impl fmt::Display for ProjectFileError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ProjectFileError::Missing => f.write_str("the project file is missing"),
            ProjectFileError::Corrupt => f.write_str("the project file is damaged"),
            ProjectFileError::NewerVersion { found, supported } => {
                write!(f, "made with a newer version (file v{found}, this build reads up to v{supported})")
            }
            ProjectFileError::Encode(m) => write!(f, "the project could not be encoded: {m}"),
            ProjectFileError::Io(m) => write!(f, "file error: {m}"),
        }
    }
}

impl std::error::Error for ProjectFileError {}

impl From<std::io::Error> for ProjectFileError {
    fn from(e: std::io::Error) -> Self {
        ProjectFileError::Io(e.to_string())
    }
}
