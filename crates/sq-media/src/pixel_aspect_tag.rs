// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PixelAspectTag.swift
//! The pixel aspect ratio a file tags its picture with (`pasp` in MP4/MOV, the SPS VUI sample aspect ratio, DisplayWidth
//! in Matroska): FFmpeg reports it as the stream's sample aspect ratio.

use sq_core_model::PixelAspect;

/// Square for an untagged track (0:0 or 0:1) and for a tag no lens or broadcast format produces (zero, negative,
/// beyond 4:1).
pub fn pixel_aspect(horizontal: i64, vertical: i64) -> PixelAspect {
    PixelAspect::new(horizontal, vertical).unwrap_or_else(PixelAspect::square)
}

/// Width of an upright picture `width` px wide, drawn with pixel aspect `from`, as it looks with `to` at the same height.
/// `quarter_turned` = the source is shown turned by 90 or 270 degrees: its stored width is the upright height, so a
/// wider pixel makes the picture taller, which at the same height is a narrower image. Never below 1.
pub fn redrawn_width(width: i64, from: PixelAspect, to: PixelAspect, quarter_turned: bool) -> i64 {
    if from == to {
        return width;
    }
    let (up, down) = if quarter_turned {
        (to.den() * from.num(), to.num() * from.den())
    } else {
        (to.num() * from.den(), to.den() * from.num())
    };
    ((width * up + down / 2) / down).max(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pa(n: i64, d: i64) -> PixelAspect {
        PixelAspect::new(n, d).expect("valid")
    }

    #[test]
    fn pixel_aspect_tag_is_read_and_reduced() {
        assert_eq!(pixel_aspect(4, 3), pa(4, 3));
        assert_eq!(pixel_aspect(40, 33), pa(40, 33));
        assert_eq!(pixel_aspect(2, 2), PixelAspect::square());
    }

    #[test]
    fn missing_or_broken_tag_is_square() {
        for (h, v) in [(0, 0), (0, 1), (1, 0), (100, 1), (-4, 3)] {
            assert_eq!(pixel_aspect(h, v), PixelAspect::square(), "{h}:{v}");
        }
    }

    #[test]
    fn a_wider_pixel_widens_the_picture_and_narrows_a_turned_one() {
        // 320x180 untagged at height 90 is 160 wide; a 2:1 pixel makes it 320 (Swift thumbnailTakesTheChosenPixelAspect).
        assert_eq!(redrawn_width(160, PixelAspect::square(), pa(2, 1), false), 320);
        assert_eq!(redrawn_width(90, PixelAspect::square(), pa(2, 1), true), 45);
        assert_eq!(redrawn_width(160, pa(2, 1), pa(2, 1), false), 160);
    }
}
