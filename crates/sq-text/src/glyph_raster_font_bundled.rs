// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: GlyphRasterFont+Bundled.swift

use crate::glyph_raster::GlyphRasterFont;
use crate::inter_font;
use crate::portable_font_match::PortableFontMatch;
use crate::text_style::FontWeight;
use std::sync::Arc;

impl GlyphRasterFont {
    /// The bundled file a family name resolves to (`PortableFontMatch`: the face nearest `weight`, the italic file for
    /// italic): the face drawn-list previews (look and template tiles) bake into the glyph atlas. nil for Inter and for
    /// a name that is not bundled (the preview keeps the UI face). Same on the Mac and Windows, so both preview identical glyphs.
    /// known limit: the file's default instance (no variation coordinates, no shear): previews of a variable font's other
    /// weights draw at its default weight; pass coords to the atlas when previews need them.
    pub fn bundled(name: &str, weight: FontWeight, italic: bool) -> Option<Arc<GlyphRasterFont>> {
        if name.to_lowercase() == inter_font::FAMILY_NAME.to_lowercase()
            || PortableFontMatch::candidates(name).is_empty()
        {
            return None;
        }
        PortableFontMatch::choose(name, weight, italic, 24.0, None).map(|c| c.font)
    }
}
