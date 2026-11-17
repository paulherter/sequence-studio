// Swift: ColorLoupe.swift
//! The loupe next to the pointer while the eyedropper samples.

use sq_draw::Color;
use sq_draw::TextAlign;
use sq_draw::canvas::Canvas;
use sq_draw::theme::{DrawTheme, radius, spacing, type_size};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};

/// The loupe next to the pointer while the eyedropper samples (the Mac `MagnifierView` / `MagnifierGrid` on the draw
/// list): the pixels around the pointer enlarged, the center cell outlined and its 8-bit RGB under it. The host fills
/// `pixels` (display 8-bit RGB, row by row, y down) from its screen or picture readback.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ColorLoupe {
    /// Grid width.
    pub width: usize,
    /// Grid height.
    pub height: usize,
    /// `width * height` RGB triples.
    pub pixels: Vec<[u8; 3]>,
    /// Column of the cell under the pointer.
    pub center_x: usize,
    /// Row of the cell under the pointer.
    pub center_y: usize,
}

impl ColorLoupe {
    /// Edge of one enlarged pixel in points.
    pub const CELL: f64 = 10.0;
    /// Padding around the grid.
    pub const PADDING: f64 = spacing::SM as f64;
    /// Height of the readout line.
    pub const READOUT_HEIGHT: f64 = 16.0;
    /// Offset of the loupe from the pointer, so it never covers the pixel being picked.
    pub const POINTER_GAP: f64 = 18.0;
    /// Pixels per side of the grid the host reads (odd, so one pixel sits in the middle).
    pub const SIDE: usize = 11;

    /// A loupe centered in its grid.
    pub fn new(width: usize, height: usize, pixels: Vec<[u8; 3]>) -> ColorLoupe {
        ColorLoupe { width, height, pixels, center_x: width / 2, center_y: height / 2 }
    }

    /// The cell under the pointer.
    pub fn center(&self) -> [u8; 3] {
        self.pixels.get(self.center_y * self.width + self.center_x).copied().unwrap_or([0, 0, 0])
    }

    /// "#0CC807": the center cell in hex (the 8-bit values are on the second call, [`rgb_readout`](Self::rgb_readout)).
    pub fn readout(&self) -> String {
        let c = self.center();
        format!("#{:02X}{:02X}{:02X}", c[0], c[1], c[2])
    }

    /// "R 12  G 200  B 7".
    pub fn rgb_readout(&self) -> String {
        let c = self.center();
        format!("R {}  G {}  B {}", c[0], c[1], c[2])
    }

    /// The loupe's size in points.
    pub fn size(&self) -> CGSize {
        CGSize::new(
            self.width as f64 * Self::CELL + 2.0 * Self::PADDING,
            self.height as f64 * Self::CELL + 2.0 * Self::PADDING + Self::READOUT_HEIGHT,
        )
    }

    /// Below and right of the pointer, flipped to the other side near an edge of `bounds`.
    pub fn frame(size: CGSize, pointer: CGPoint, bounds: CGRect) -> CGRect {
        let mut x = pointer.x + Self::POINTER_GAP;
        let mut y = pointer.y + Self::POINTER_GAP;
        if x + size.width > bounds.max_x() {
            x = pointer.x - Self::POINTER_GAP - size.width;
        }
        if y + size.height > bounds.max_y() {
            y = pointer.y - Self::POINTER_GAP - size.height;
        }
        x = x.max(bounds.min_x()).min((bounds.max_x() - size.width).max(bounds.min_x()));
        y = y.max(bounds.min_y()).min((bounds.max_y() - size.height).max(bounds.min_y()));
        CGRect::new(x, y, size.width, size.height)
    }

    /// Draws the loupe beside `pointer` (window points), kept inside `bounds`.
    pub fn draw(&self, c: &mut Canvas, pointer: CGPoint, bounds: CGRect, t: &DrawTheme) {
        if self.width == 0 || self.height == 0 || self.pixels.len() < self.width * self.height {
            return;
        }
        let f = Self::frame(self.size(), pointer, bounds);
        let rad = radius::SMALL as f64;
        c.fill_rounded(f, rad, t.panel());
        c.stroke_rounded(f.inset_by(0.5, 0.5), rad, 1.0, t.ink_fill(0.10));
        let o = CGPoint::new(f.min_x() + Self::PADDING, f.min_y() + Self::PADDING);
        for y in 0..self.height {
            for x in 0..self.width {
                let p = self.pixels[y * self.width + x];
                // Picture data, not a UI color.
                c.fill(
                    CGRect::new(o.x + x as f64 * Self::CELL, o.y + y as f64 * Self::CELL, Self::CELL, Self::CELL),
                    Color::rgb(p[0] as f32 / 255.0, p[1] as f32 / 255.0, p[2] as f32 / 255.0),
                );
            }
        }
        let mid = CGRect::new(
            o.x + self.center_x as f64 * Self::CELL,
            o.y + self.center_y as f64 * Self::CELL,
            Self::CELL,
            Self::CELL,
        );
        c.stroke_rounded(mid.inset_by(-0.5, -0.5), 0.0, 1.0, t.ink_fill(0.10));
        c.stroke_rounded(mid.inset_by(0.5, 0.5), 0.0, 1.0, t.label());
        c.draw_text_in(
            &self.readout(),
            CGRect::new(f.min_x(), o.y + self.height as f64 * Self::CELL, f.width, Self::READOUT_HEIGHT),
            type_size::CAPTION as f64,
            t.label(),
            TextAlign::Center,
            0.0,
            0,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn readout_names_the_center_cell() {
        let mut px = vec![[0u8, 0, 0]; 9];
        px[4] = [12, 200, 7];
        let l = ColorLoupe::new(3, 3, px);
        assert_eq!(l.readout(), "#0CC807");
        assert_eq!(l.rgb_readout(), "R 12  G 200  B 7");
        assert_eq!(ColorLoupe::new(3, 3, vec![]).center(), [0, 0, 0]);
    }

    #[test]
    fn the_loupe_flips_near_an_edge_and_stays_inside() {
        let size = CGSize::new(100.0, 80.0);
        let bounds = CGRect::new(0.0, 0.0, 400.0, 300.0);
        let f = ColorLoupe::frame(size, CGPoint::new(10.0, 10.0), bounds);
        assert_eq!((f.x, f.y), (28.0, 28.0));
        let f = ColorLoupe::frame(size, CGPoint::new(395.0, 295.0), bounds);
        assert_eq!((f.x, f.y), (395.0 - 18.0 - 100.0, 295.0 - 18.0 - 80.0));
        let tiny = ColorLoupe::frame(size, CGPoint::new(0.0, 0.0), CGRect::new(0.0, 0.0, 50.0, 50.0));
        assert_eq!((tiny.x, tiny.y), (0.0, 0.0));
    }
}
