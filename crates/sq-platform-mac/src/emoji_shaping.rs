//! Apple Color Emoji sequences (ZWJ family, skin tone, flag, keycap) through CoreText: the font keeps its ligatures in
//! `morx`, which only CoreText reads. Installed into sq-text at startup ([`install`]).

use objc2_core_foundation::{CFAttributedString, CFDictionary, CFRange, CFString};
use objc2_core_text::{CTFont, CTLine, CTRun, kCTFontAttributeName};
use std::ptr::NonNull;

/// Hands the CoreText shaper to the text engine.
pub fn install_emoji_sequence_shaper() {
    sq_text::emoji_font::install_emoji_sequence_shaper(shape);
}

/// The glyph CoreText draws for the whole of `text` (one glyph in one run); `None` for several glyphs.
fn shape(text: &str) -> Option<u16> {
    // SAFETY: plain CoreText calls on objects created here and owned for the call; the run index is checked.
    unsafe {
        let font = CTFont::with_name(&CFString::from_str("Apple Color Emoji"), 20.0, std::ptr::null());
        let attrs = CFDictionary::from_slices(&[kCTFontAttributeName], &[&*font]);
        let string = CFAttributedString::new(None, Some(&CFString::from_str(text)), Some(attrs.as_opaque()))?;
        let runs = CTLine::with_attributed_string(&string).glyph_runs();
        if runs.len() != 1 {
            return None;
        }
        let run = runs.cast_unchecked::<CTRun>().get_unchecked(0);
        if run.glyph_count() != 1 {
            return None;
        }
        let mut glyph = 0u16;
        run.glyphs(CFRange { location: 0, length: 1 }, NonNull::from(&mut glyph));
        (glyph != 0).then_some(glyph)
    }
}
