// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AnonymizeOrder.swift (`Clip.movesPixels` waits on the effects crate, see NOTES.md)
//! Anonymize: where a cover sits among the clip's effects. A mask that must cover is tracked on the source frame and the
//! renderer reads its matte in the clip's frame, never moved along by an earlier effect. So the effects that take such a
//! mask (the covers) are pinned in front of every other picture effect, behind the Color effects.

use crate::anonymize::MagicSelectionAnonymizeExt;
use crate::mask_inputs::is_color;
use crate::masks::ClipMasksExt;
use sq_core_model::{Clip, ClipEffect, MaskSource, Timeline};
use std::collections::BTreeSet;

/// Picture kinds that leave every part of the picture where it was (color, grain, light, edges, blocks): one in front of
/// a cover does not move the person out from under the matte. Every other picture kind counts as moving pixels, a new
/// kind too until it is listed here.
// shortcut: the kind strings are copied because the effects catalog constants live in the effects crate; switch to its
// constants when that crate exists.
#[doc(hidden)]
pub const IN_PLACE_KINDS: [&str; 30] = [
    "color",
    "invert",
    "posterize",
    "tint",
    "blackAndWhite",
    "brightnessContrast",
    "vignette",
    "filmGrain",
    "noise",
    "sharpen",
    "unsharpMask",
    "strobeLight",
    "alphaAdjust",
    "lightLeak",
    "gradient",
    "edgeFeather",
    "scanlines",
    "agedFilm",
    "glow",
    "alphaOutline",
    "longShadow",
    "mosaic",
    "halftone",
    "gaussianBlur",
    "roundedCorners",
    "crop",
    "dropShadow",
    "ultraKey",
    "lumaKey",
    "trackMask",
];

/// Logic Swift keeps on `Clip` in `AnonymizeOrder.swift`.
pub trait AnonymizeOrderExt {
    /// A mask made by Anonymize: what it limits has to cover the person on every frame.
    #[doc(hidden)]
    fn has_cover_mask(&self) -> bool;
    /// `e` takes a mask that must cover as input (on or off): it is a cover.
    fn is_cover(&self, e: &ClipEffect) -> bool;
    /// A mask that must cover is among `e`'s inputs but switched off: its person would be left open.
    #[doc(hidden)]
    fn cover_input_is_off(&self, e: &ClipEffect) -> bool;
    /// Where a new cover goes: behind the Color effects (they stay first), in front of everything else.
    #[doc(hidden)]
    fn cover_insertion_index(&self) -> usize;
    /// Moves every cover in front of the other picture effects (behind the leading Color effects), keeping the order
    /// within both groups. True when the list changed.
    fn pin_covers(&mut self) -> bool;
}

impl AnonymizeOrderExt for Clip {
    fn has_cover_mask(&self) -> bool {
        self.masks().iter().any(|m| m.source() == MaskSource::Magic && m.magic.as_ref().is_some_and(|s| s.must_cover()))
    }

    fn is_cover(&self, e: &ClipEffect) -> bool {
        if e.mask_input.is_empty() {
            return false;
        }
        self.masks().iter().any(|m| {
            m.source() == MaskSource::Magic
                && m.magic.as_ref().is_some_and(|s| s.must_cover())
                && e.mask_input.contains(&m.id)
        })
    }

    fn cover_input_is_off(&self, e: &ClipEffect) -> bool {
        self.masks().iter().any(|m| {
            !m.enabled
                && m.source() == MaskSource::Magic
                && m.magic.as_ref().is_some_and(|s| s.must_cover())
                && e.mask_input.contains(&m.id)
        })
    }

    fn cover_insertion_index(&self) -> usize {
        self.effects.iter().take_while(|e| is_color(e)).count()
    }

    fn pin_covers(&mut self) -> bool {
        if !self.has_cover_mask() {
            return false;
        }
        let lead = self.cover_insertion_index();
        let rest = &self.effects[lead..];
        let covers: Vec<ClipEffect> = rest.iter().filter(|e| !is_color(e) && self.is_cover(e)).cloned().collect();
        if covers.is_empty() {
            return false;
        }
        let mut sorted: Vec<ClipEffect> = self.effects[..lead].to_vec();
        sorted.extend(covers);
        sorted.extend(rest.iter().filter(|e| is_color(e) || !self.is_cover(e)).cloned());
        if sorted.iter().map(|e| e.id).eq(self.effects.iter().map(|e| e.id)) {
            return false;
        }
        self.effects = sorted;
        true
    }
}

/// Logic Swift keeps on `Timeline` in `AnonymizeOrder.swift`.
pub trait AnonymizeTimelineExt {
    /// Matte keys of every mask that must cover on this timeline's clips (nested sequences: ask each): playback reads
    /// their files ahead, so a cover never waits on the disk.
    fn cover_matte_keys(&self) -> BTreeSet<String>;
}

impl AnonymizeTimelineExt for Timeline {
    fn cover_matte_keys(&self) -> BTreeSet<String> {
        let mut out = BTreeSet::new();
        for t in &self.tracks {
            for c in t.clips() {
                for m in c.masks().iter().filter(|m| m.source() == MaskSource::Magic) {
                    if let Some(sel) = &m.magic
                        && sel.must_cover()
                    {
                        out.extend(sel.matte_keys(c.media));
                    }
                }
            }
        }
        out
    }
}
