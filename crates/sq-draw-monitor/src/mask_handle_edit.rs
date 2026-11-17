// Swift: MaskHandleEdit.swift
//! One pen-handle edit of a mask from the Program monitor overlay.

use sq_core_time::{Id, Vec2};

/// One pen-handle edit of a mask from the Program monitor overlay (frame fractions). The host applies it through Effect
/// Controls (`moveMaskTangent`, `moveMask`, `insertMaskVertex`, `placeMaskVertex`, `removeMaskVertex`,
/// `toggleMaskVertexSmooth`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum MaskHandleEdit {
    /// A Bezier handle of `vertex` dragged to `offset` from its vertex (`independent`: Option / Alt breaks the pair).
    Tangent { mask: Id, vertex: usize, out: bool, offset: Vec2, independent: bool },
    /// The whole mask moved by `delta` since the drag began.
    Move { mask: Id, delta: Vec2 },
    /// A click on the outline: a vertex at `t` along `segment`, the curve kept.
    Insert { mask: Id, segment: usize, t: f64 },
    /// A press on the outline then a drag: the new vertex with its handle pulled out to `handle` (relative to the vertex).
    Pen { mask: Id, segment: usize, t: f64, handle: Vec2, independent: bool },
    /// Cmd / Ctrl-click on a vertex: removed.
    Remove { mask: Id, vertex: usize },
    /// Option / Alt-click on a vertex: corner <-> smooth.
    ToggleSmooth { mask: Id, vertex: usize },
}

impl MaskHandleEdit {
    /// The mask the edit is about.
    pub fn mask_id(&self) -> Id {
        match *self {
            Self::Tangent { mask, .. }
            | Self::Move { mask, .. }
            | Self::Insert { mask, .. }
            | Self::Pen { mask, .. }
            | Self::Remove { mask, .. }
            | Self::ToggleSmooth { mask, .. } => mask,
        }
    }

    /// Edits the path shown at the playhead (adding or deleting a vertex changes every key, wherever the playhead is).
    pub fn edits_at_playhead(&self) -> bool {
        !matches!(self, Self::Insert { .. } | Self::Remove { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_and_remove_edit_every_key() {
        let id = Id::from_u128(7);
        assert!(!MaskHandleEdit::Insert { mask: id, segment: 0, t: 0.5 }.edits_at_playhead());
        assert!(!MaskHandleEdit::Remove { mask: id, vertex: 1 }.edits_at_playhead());
        assert!(MaskHandleEdit::Move { mask: id, delta: Vec2::ZERO }.edits_at_playhead());
        assert_eq!(MaskHandleEdit::ToggleSmooth { mask: id, vertex: 0 }.mask_id(), id);
    }
}
