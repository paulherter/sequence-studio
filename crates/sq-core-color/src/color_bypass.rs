// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorBypass.swift
//! Color page compare (Before | After | Split): the monitor shows the target clips without their grade, either whole
//! (`Before`) or on the left half of the picture (`Split`, graded on the right). A viewing aid only: never stored in
//! the project and never applied by the export.

use crate::color_effect::ClipColorExt;
use sq_core_model::ClipColor;
use sq_core_time::Id;
use std::collections::BTreeSet;

/// Which compare view shows the ungraded picture.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ColorBypassMode {
    /// The whole picture ungraded.
    Before,
    /// The left half ungraded, the right half graded.
    Split,
}

/// The clips shown ungraded and how.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ColorBypass {
    /// Clips (or adjustment layers / the sequence grade layer) shown ungraded.
    pub clips: BTreeSet<Id>,
    /// Whole picture or split.
    pub mode: ColorBypassMode,
}

impl ColorBypass {
    /// No clip is bypassed.
    pub fn is_empty(&self) -> bool {
        self.clips.is_empty()
    }

    /// The compare view is the split view.
    pub fn is_split(&self) -> bool {
        self.mode == ColorBypassMode::Split
    }

    /// The clip is shown ungraded.
    pub fn bypasses(&self, clip: Id) -> bool {
        self.clips.contains(&clip)
    }

    /// Width in pixels of the ungraded (left) part of a split picture `width` pixels wide.
    pub fn split_width(width: i64) -> i64 {
        width.max(0) / 2
    }

    /// Resolver slot of a clip's ungraded pipeline (distinct from the clip's own slot, so both stay cached side by
    /// side): the first and last byte of the id flipped.
    pub fn ungraded_owner(clip: Id) -> Id {
        Id::from_u128(clip.as_u128() ^ ((0x5A_u128 << 120) | 0xA5))
    }

    /// The color a bypassed layer is drawn with and the resolver slot to resolve it under; `None` when the layer
    /// (`clip`, graded with `color`) keeps its grade.
    pub fn ungraded(&self, clip: Id, color: &ClipColor) -> Option<(ClipColor, Id)> {
        if !self.bypasses(clip) {
            return None;
        }
        Some((color.ungraded(), Self::ungraded_owner(clip)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color_effect::ColorEffectExt;
    use sq_core_model::{ColorSpaceID, LUTRef};

    fn id(n: u128) -> Id {
        Id::from_u128(n * 0x1234_5678_9ABC_DEF0_1111_2222_3333_4444 + 7)
    }

    #[test]
    fn ungraded_keeps_the_footage_interpretation_and_drops_the_grade() {
        let mut c = ClipColor::new(Some(ColorSpaceID::SLog3SGamut3Cine), false, Vec::new());
        c.edit_effects(|fx| {
            fx[0].basic.exposure = 2.0;
            fx[0].input_lut = Some(LUTRef::File { path: "/luts/convert.cube".into() });
        });
        c.add_effect();
        c.edit_effects(|fx| fx[1].basic.contrast = 40.0);
        let u = c.ungraded();
        assert!(u.source == Some(ColorSpaceID::SLog3SGamut3Cine) && !u.use_embedded_lut);
        assert_eq!(u.effects(), ClipColor::default_effects().as_slice());
        assert!(ClipColor::default().ungraded().is_default());
        assert!(u.primary().input_lut_is_neutral());
    }

    #[test]
    fn modes_and_targets() {
        let (a, b) = (id(1), id(2));
        let none = ColorBypass { clips: BTreeSet::new(), mode: ColorBypassMode::Before };
        assert!(none.is_empty());
        let before = ColorBypass { clips: BTreeSet::from([a]), mode: ColorBypassMode::Before };
        assert!(!before.is_empty() && before.bypasses(a) && !before.bypasses(b) && !before.is_split());
        assert!(ColorBypass { clips: BTreeSet::from([a]), mode: ColorBypassMode::Split }.is_split());
    }

    #[test]
    fn split_shows_the_ungraded_picture_on_the_left_half() {
        assert_eq!(ColorBypass::split_width(1920), 960);
        assert_eq!(ColorBypass::split_width(1921), 960);
        assert_eq!(ColorBypass::split_width(1), 0);
        assert_eq!(ColorBypass::split_width(0), 0);
        assert_eq!(ColorBypass::split_width(-5), 0);
    }

    #[test]
    fn ungraded_slot_is_its_own_and_stable() {
        let (a, b) = (id(1), id(2));
        assert_ne!(ColorBypass::ungraded_owner(a), a);
        assert_eq!(ColorBypass::ungraded_owner(a), ColorBypass::ungraded_owner(a));
        assert_ne!(ColorBypass::ungraded_owner(a), ColorBypass::ungraded_owner(b));
        assert_eq!(ColorBypass::ungraded_owner(ColorBypass::ungraded_owner(a)), a, "the slot flip is its own inverse");
    }

    #[test]
    fn ungraded_color_only_for_bypassed_layers() {
        let (a, b) = (id(1), id(2));
        let mut c = ClipColor::default();
        c.edit_effects(|fx| fx[0].basic.exposure = 1.5);
        let bypass = ColorBypass { clips: BTreeSet::from([a]), mode: ColorBypassMode::Before };
        assert_eq!(bypass.ungraded(a, &c), Some((c.ungraded(), ColorBypass::ungraded_owner(a))));
        assert_eq!(bypass.ungraded(b, &c), None);
    }
}
