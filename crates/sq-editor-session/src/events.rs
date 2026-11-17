// Swift: EditorSession.swift (the `on*` hooks of `EditorSession`)
//! Hooks of the Swift session as events. The session pushes them in the order Swift called the hooks; the app drains
//! them after the call that caused them (`EditorSession::take_events`) and runs what the Swift host assigned to the
//! hook, as a match arm in `App::dispatch`. `onChange` is not an event: it is [`crate::Change`] plus the versions.

use std::collections::BTreeSet;

use sq_core_model::Project;
use sq_core_model::effect_defaults::EffectDefaults;
use sq_core_time::Id;

/// One call of a Swift `EditorSession.on*` hook.
#[derive(Clone, Debug, PartialEq)]
pub enum SessionEvent {
    /// `onEffectDefaultsChange`: the user's effect and transition defaults changed (the app stores them).
    // Swift: EditorSession.swift:140
    EffectDefaultsChange(EffectDefaults),
    /// `onMediaFilesChanged`: media files changed on disk (re-exported, gone, back); UI caches of these items drop.
    // Swift: EditorSession.swift:246
    MediaFilesChanged(BTreeSet<Id>),
    /// `onStabilizerNeedsAnalysis`: Stabilize dropped from the Effects panel; the app analyzes these clips of the sequence.
    // Swift: EditorSession.swift:256
    StabilizerNeedsAnalysis { timeline: Id, clips: BTreeSet<Id> },
    /// `onReleaseProject`: the session lets go of a project (close, open another, new) and whether it had unsaved edits.
    // Swift: EditorSession.swift:260
    ReleaseProject { project: Box<Project>, was_dirty: bool },
    /// `onSaved`: the project was written to its file.
    // Swift: EditorSession.swift:824
    Saved(Box<Project>),
    /// `onProjectReplaced`: another project replaced the open one (open, new, close).
    // Swift: EditorSession.swift:827
    ProjectReplaced,
}
