// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextUnits+Layout.swift

use crate::text_layout::{TextLayoutResult, utf16_len};
use sq_core_graphics::text_animator_model::{TextUnits, Utf16Range};

/// `extension TextUnits` of TextUnits+Layout.swift.
pub trait TextUnitsLayoutExt {
    /// The animatable units of a laid-out text (lines as the layout broke them).
    fn segment_layout(layout: &TextLayoutResult) -> Self;
}

impl TextUnitsLayoutExt for TextUnits {
    fn segment_layout(layout: &TextLayoutResult) -> TextUnits {
        let lines: Vec<Utf16Range> = layout
            .lines
            .iter()
            .map(|l| Utf16Range { location: l.location.max(0) as usize, length: utf16_len(&l.content()) as usize })
            .collect();
        TextUnits::segment(&layout.display_text, &lines)
    }
}
