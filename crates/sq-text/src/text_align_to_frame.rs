// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextAlignToFrame.swift

use crate::text_layout::TextLayoutResult;
use sq_core_time::Vec2;

/// Premiere's six align buttons: the text block is moved so its edge (or center) meets the frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FrameAlignment {
    /// Left edge.
    Left,
    /// Center horizontally.
    CenterHorizontally,
    /// Right edge.
    Right,
    /// Top edge.
    Top,
    /// Center vertically.
    CenterVertically,
    /// Bottom edge.
    Bottom,
}

/// Aligning a text block to the frame.
pub enum TextAlignToFrame {}

impl TextAlignToFrame {
    /// The clip position (sequence px from the canvas center) that puts the layout's text block (`layout.bounds`: the
    /// text, or the box of area text; not the shadow or stroke) against the frame. Only the aligned axis changes.
    /// The block is scaled about the raster's center, which differs from the block's center when a shadow or stroke
    /// makes the ink lopsided; that offset is accounted for. Rotation is taken into account through the extents of the
    /// rotated block (degrees).
    pub fn position(
        a: FrameAlignment,
        layout: &TextLayoutResult,
        cur: Vec2,
        scale: Vec2,
        rotation: f64,
        canvas_width: f64,
        canvas_height: f64,
    ) -> Vec2 {
        let b = layout.bounds;
        let ink = layout.ink_bounds;
        let sx = scale.x.abs();
        let sy = scale.y.abs();
        let rad = rotation * std::f64::consts::PI / 180.0;
        let c = rad.cos().abs();
        let s = rad.sin().abs();
        let hx = (c * b.width * sx + s * b.height * sy) / 2.0;
        let hy = (s * b.width * sx + c * b.height * sy) / 2.0;
        // Offset of the block's center from the raster's center once scaled (zero for symmetric ink or no scaling).
        let mut off_x = 0.0;
        let mut off_y = 0.0;
        if rotation == 0.0 {
            let dx = (ink.x + ink.width / 2.0) - (b.x + b.width / 2.0);
            let dy = (ink.y + ink.height / 2.0) - (b.y + b.height / 2.0);
            off_x = dx * (1.0 - scale.x);
            off_y = dy * (1.0 - scale.y);
        }
        let mut p = cur;
        match a {
            FrameAlignment::Left => p.x = hx - canvas_width / 2.0 - off_x,
            FrameAlignment::Right => p.x = canvas_width / 2.0 - hx - off_x,
            FrameAlignment::CenterHorizontally => p.x = -off_x,
            FrameAlignment::Top => p.y = hy - canvas_height / 2.0 - off_y,
            FrameAlignment::Bottom => p.y = canvas_height / 2.0 - hy - off_y,
            FrameAlignment::CenterVertically => p.y = -off_y,
        }
        p
    }
}
