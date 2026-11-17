// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SequencePixelShape.swift
//
// v82: the pixel shape of a sequence (Sequence Settings > Pixel Shape). Stored only when not square, so square sequences
// encode, render and export exactly as before.
//
// Contract: `width` x `height` stay the stored pixel size (render targets, scopes, export). Everything a user can place
// (Scale, Position, graphics, text, masks, handles) lives in DISPLAY space: `display_width` x `height`, the picture as it is
// shown. The compositor draws display space into the stored pixels, which squeezes it horizontally by width / display_width.

use crate::{PixelAspect, SequenceFormat};

impl SequenceFormat {
    /// The shape of one stored pixel (default square).
    pub fn pixel_aspect(&self) -> PixelAspect {
        self.pixel_aspect_store.unwrap_or_else(PixelAspect::square)
    }

    /// Sets the pixel shape; square is stored as absent.
    pub fn set_pixel_aspect(&mut self, aspect: PixelAspect) {
        self.pixel_aspect_store = (!aspect.is_square()).then_some(aspect);
    }

    /// Width in pixels of the picture as shown (even, see `PixelAspect::display_width`); `width` for square pixels.
    pub fn display_width(&self) -> i64 {
        self.pixel_aspect_store.map_or(self.width, |a| a.display_width(self.width))
    }

    /// Display size as a float pair, the frame user-facing geometry is computed in.
    pub fn display_size(&self) -> (f64, f64) {
        (self.display_width() as f64, self.height as f64)
    }

    /// A square-pixel format of the display size: what layout code (text, captions, graphics, date stamp) reads as "the
    /// canvas". A copy of `self` for square pixels.
    pub fn layout_format(&self) -> SequenceFormat {
        let mut f = self.clone();
        if self.pixel_aspect_store.is_some() {
            f.width = self.display_width();
            f.pixel_aspect_store = None;
        }
        f
    }

    /// The same stored size with square pixels: for passes that work on the target's own pixels (transition canvases).
    pub fn stored_pixels(&self) -> SequenceFormat {
        let mut f = self.clone();
        f.pixel_aspect_store = None;
        f
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;

    fn format(w: i64, h: i64, par: (i64, i64)) -> SequenceFormat {
        let mut f = SequenceFormat {
            width: w,
            height: h,
            frame_duration: Time::new(1, 30),
            audio_sample_rate: 48000,
            pixel_aspect_store: None,
            unknown: crate::UnknownKeys::default(),
        };
        f.set_pixel_aspect(PixelAspect::new(par.0, par.1).unwrap_or_else(PixelAspect::square));
        f
    }

    #[test]
    fn display_size_follows_the_shape() {
        assert_eq!(format(1920, 1080, (1, 1)).display_width(), 1920);
        assert_eq!(format(1080, 1080, (2, 1)).display_width(), 2160);
        assert_eq!(format(1440, 1080, (4, 3)).display_width(), 1920);
        assert_eq!(format(1440, 1080, (4, 3)).display_size(), (1920.0, 1080.0));
        assert_eq!(format(1920, 1080, (1, 1)).layout_format(), format(1920, 1080, (1, 1)));
        let l = format(1080, 1080, (2, 1)).layout_format();
        assert_eq!((l.width, l.height, l.pixel_aspect()), (2160, 1080, PixelAspect::square()));
        assert_eq!(format(1080, 1080, (2, 1)).stored_pixels().width, 1080);
    }

    #[test]
    fn square_is_stored_as_absent() {
        let mut f = format(1080, 1080, (2, 1));
        assert!(f.pixel_aspect_store.is_some());
        f.set_pixel_aspect(PixelAspect::square());
        assert_eq!((f.pixel_aspect_store, f.pixel_aspect()), (None, PixelAspect::square()));
    }
}
