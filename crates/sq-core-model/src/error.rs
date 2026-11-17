// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Model.swift (EditError)

use std::fmt;

/// Why an edit was refused. Edits return `Result<_, EditError>` and leave the model unchanged on error.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditError {
    /// The clip does not fit the track kind.
    WrongTrackKind,
    /// The clip would have no length.
    EmptyClip,
    /// The track is locked.
    TrackLocked,
    /// No clip with that id.
    ClipNotFound,
    /// The edit would overlap another clip.
    Collision,
    /// A sequence would contain itself, directly or through other nested sequences.
    NestingCycle,
    /// No timeline with that id.
    TimelineNotFound,
    /// The format is not valid.
    InvalidFormat,
    /// Speed/Duration on a clip that has no constant speed (nested sequence, generator, still).
    SpeedUnsupported,
    /// Apply Transition at a place that is not a cut.
    NotACut,
    /// Not one frame of media beyond the cut(s) is available for the transition.
    InsufficientMedia,
    /// Ungroup on a nested clip that is not a Group.
    NotAGroup,
    /// Unnest on a clip that plays no ordinary nested sequence.
    NotNested,
    /// Ungroup would change the picture or sound.
    UngroupLosesLook,
    /// Make Graphic would change the picture or break keys or variants.
    NotConvertible,
    /// Delete Track with no deletable targeted track.
    NoTrackToDelete,
}

impl fmt::Display for EditError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

impl std::error::Error for EditError {}
