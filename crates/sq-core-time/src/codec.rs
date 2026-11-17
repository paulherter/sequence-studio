// SPDX-License-Identifier: GPL-3.0-or-later
//! Encoder side channel. Swift passes flags through `JSONEncoder.userInfo`: project files write keyframes compactly
//! (v36) and record whether content that needs a newer file version was written (Hold Ahead v77, tilt v84, follow
//! edge padding v85). Here the same state lives in a thread-local scope that the project file writer opens.

use std::cell::Cell;
use std::marker::PhantomData;

/// Content that raises the project file version when it is written.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Seen {
    /// A key with `Interpolation::HoldAhead` (v77).
    HoldAhead,
    /// Perspective tilt on a clip or variant (v84).
    Tilt,
    /// Follow edge padding on a graphics item (v85).
    FollowEdgePadding,
}

/// What an encode scope saw.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SeenFlags {
    /// See `Seen::HoldAhead`.
    pub hold_ahead: bool,
    /// See `Seen::Tilt`.
    pub tilt: bool,
    /// See `Seen::FollowEdgePadding`.
    pub follow_edge_padding: bool,
}

thread_local! {
    static CURRENT: Cell<Option<SeenFlags>> = const { Cell::new(None) };
}

/// Scope guard for one project file encode: while it lives, serialization on this thread writes compact keyframes
/// and records `Seen` flags. Dropping it restores the enclosing scope. Not `Send`: the scope belongs to the thread.
pub struct EncodeContext {
    outer: Option<SeenFlags>,
    _not_send: PhantomData<*const ()>,
}

impl EncodeContext {
    /// Opens a project file scope (Swift: the encoder `ProjectFile.encode` configures).
    pub fn project_file() -> EncodeContext {
        Self::install(Some(SeenFlags::default()))
    }

    /// Opens a plain scope (Swift: any other `JSONEncoder`, e.g. a payload encoded inside a project file encode):
    /// full keyframes, nothing recorded.
    pub fn plain() -> EncodeContext {
        Self::install(None)
    }

    fn install(state: Option<SeenFlags>) -> EncodeContext {
        EncodeContext { outer: CURRENT.replace(state), _not_send: PhantomData }
    }

    /// What this scope saw so far.
    pub fn seen(&self) -> SeenFlags {
        CURRENT.get().unwrap_or_default()
    }

    /// True inside a project file scope: keyframe fields at their defaults are left out.
    pub fn compact_keyframes() -> bool {
        CURRENT.get().is_some()
    }

    /// Records `s` in the current project file scope; no-op elsewhere.
    pub fn mark(s: Seen) {
        if let Some(mut f) = CURRENT.get() {
            match s {
                Seen::HoldAhead => f.hold_ahead = true,
                Seen::Tilt => f.tilt = true,
                Seen::FollowEdgePadding => f.follow_edge_padding = true,
            }
            CURRENT.set(Some(f));
        }
    }
}

impl Drop for EncodeContext {
    fn drop(&mut self) {
        CURRENT.set(self.outer);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scopes_record_and_restore() {
        assert!(!EncodeContext::compact_keyframes());
        EncodeContext::mark(Seen::Tilt); // outside any scope: ignored
        let outer = EncodeContext::project_file();
        assert!(EncodeContext::compact_keyframes());
        {
            let _inner = EncodeContext::plain();
            assert!(!EncodeContext::compact_keyframes());
            EncodeContext::mark(Seen::HoldAhead);
        }
        EncodeContext::mark(Seen::Tilt);
        assert_eq!(outer.seen(), SeenFlags { tilt: true, ..SeenFlags::default() });
        drop(outer);
        assert!(!EncodeContext::compact_keyframes());
    }
}
