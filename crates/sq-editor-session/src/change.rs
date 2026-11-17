// Swift: EditorSession.swift (`EditorSession.Change`)
//! What changed in the session, as bit flags. Replaces the Swift `onChange` hook and `@Observable` tracking: `notify`
//! bumps one version counter per flag and collects the flags until the app drains them.

use std::ops::{BitOr, BitOrAssign};

/// What changed (Swift `EditorSession.Change`, an `OptionSet` over `Int`; same raw values).
// Swift: EditorSession.swift:28
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Change(u32);

impl Change {
    /// Number of flags; the length of the session's version array.
    pub const COUNT: usize = 9;
    /// History, timeline, file state.
    // Swift: EditorSession.swift:31
    pub const PROJECT: Change = Change(1);
    // Swift: EditorSession.swift:32
    pub const SELECTION: Change = Change(2);
    // Swift: EditorSession.swift:33
    pub const PLAYHEAD: Change = Change(4);
    // Swift: EditorSession.swift:34
    pub const TRANSPORT: Change = Change(8);
    /// A background prepare finished.
    // Swift: EditorSession.swift:35
    pub const MEDIA: Change = Change(16);
    /// `last_error` changed.
    // Swift: EditorSession.swift:36
    pub const STATUS: Change = Change(32);
    /// Undo/redo: scroll `reveal_range` into view.
    // Swift: EditorSession.swift:37
    pub const REVEAL: Change = Change(64);
    /// The active sequence's source patch changed.
    // Swift: EditorSession.swift:38
    pub const SOURCE_PATCH: Change = Change(128);
    /// The Program monitor shows another picture (Color solo on/off/switched): the scopes re-measure.
    // Swift: EditorSession.swift:39
    pub const MONITOR_PICTURE: Change = Change(256);

    /// No flag.
    pub const fn empty() -> Change {
        Change(0)
    }
    /// The raw value (Swift `rawValue`).
    // Swift: EditorSession.swift:29
    pub const fn raw_value(self) -> u32 {
        self.0
    }
    /// The flags of `raw`, unknown bits dropped.
    // Swift: EditorSession.swift:30
    pub const fn from_raw(raw: u32) -> Change {
        Change(raw & ((1 << Change::COUNT) - 1))
    }
    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }
    /// Whether every flag of `other` is set.
    pub const fn contains(self, other: Change) -> bool {
        self.0 & other.0 == other.0
    }
    /// Whether any flag of `other` is set.
    pub const fn intersects(self, other: Change) -> bool {
        self.0 & other.0 != 0
    }
    /// Index into the version array of a single flag (`PLAYHEAD` -> 2); `None` for zero or several flags.
    pub const fn index(self) -> Option<usize> {
        if self.0.count_ones() == 1 { Some(self.0.trailing_zeros() as usize) } else { None }
    }
    /// The version indices of the set flags, lowest first.
    pub fn indices(self) -> impl Iterator<Item = usize> {
        (0..Change::COUNT).filter(move |i| self.0 & (1 << i) != 0)
    }
}

impl BitOr for Change {
    type Output = Change;
    fn bitor(self, rhs: Change) -> Change {
        Change(self.0 | rhs.0)
    }
}

impl BitOrAssign for Change {
    fn bitor_assign(&mut self, rhs: Change) {
        self.0 |= rhs.0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_values_match_swift() {
        assert_eq!(Change::PROJECT.raw_value(), 1);
        assert_eq!(Change::MONITOR_PICTURE.raw_value(), 256);
        assert_eq!(Change::from_raw(0xffff).raw_value(), 511);
    }

    #[test]
    fn flags_combine_and_index() {
        let c = Change::PLAYHEAD | Change::TRANSPORT;
        assert!(c.contains(Change::PLAYHEAD) && !c.contains(Change::PROJECT) && c.intersects(Change::TRANSPORT));
        assert_eq!(c.indices().collect::<Vec<_>>(), vec![2, 3]);
        assert_eq!(Change::REVEAL.index(), Some(6));
        assert_eq!(c.index(), None);
        assert!(Change::empty().is_empty());
    }
}
