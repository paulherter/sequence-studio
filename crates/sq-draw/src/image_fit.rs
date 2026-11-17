//! Placing a picture into a rect without stretching it: [`fit_rect`] shows the whole picture with bars around it
//! (letterbox or pillarbox), [`fill_source`] crops the picture to the rect's aspect, and the canvas methods draw with
//! either result. Every panel that draws a poster, frame or still into a rect of its own shape goes through here.

use crate::canvas::Canvas;
use crate::draw_list::Color;
use sq_uikit::controls_grid::{CGRect, CGSize};

/// The largest rect with the aspect of `content` that fits `bounds`, centered: the picture shows whole and the rest of
/// `bounds` stays for the bars. Content or bounds without area give `bounds` back.
pub fn fit_rect(content: CGSize, bounds: CGRect) -> CGRect {
    if !(content.width > 0.0 && content.height > 0.0 && bounds.width > 0.0 && bounds.height > 0.0) {
        return bounds;
    }
    let k = (bounds.width / content.width).min(bounds.height / content.height);
    let (w, h) = (content.width * k, content.height * k);
    CGRect::new(bounds.mid_x() - w / 2.0, bounds.mid_y() - h / 2.0, w, h)
}

/// The part of `source` (a normalized cell `[u0, v0, u1, v1]` holding a picture of `pixels`) that fills `bounds` when the
/// picture is cropped to the aspect of `bounds`, centered. Without sizes the whole cell comes back.
pub fn fill_source(source: [f32; 4], pixels: CGSize, bounds: CGRect) -> [f32; 4] {
    if !(pixels.width > 0.0 && pixels.height > 0.0 && bounds.width > 0.0 && bounds.height > 0.0) {
        return source;
    }
    let k = (bounds.width / pixels.width).max(bounds.height / pixels.height);
    let fx = (bounds.width / (pixels.width * k)).min(1.0) as f32;
    let fy = (bounds.height / (pixels.height * k)).min(1.0) as f32;
    if fx == 1.0 && fy == 1.0 {
        return source;
    }
    let [u0, v0, u1, v1] = source;
    let (w, h) = (u1 - u0, v1 - v0);
    let (cu, cv) = (u0 + w / 2.0, v0 + h / 2.0);
    [cu - w * fx / 2.0, cv - h * fy / 2.0, cu + w * fx / 2.0, cv + h * fy / 2.0]
}

impl Canvas<'_> {
    /// Draws the part `source` of image `slot` (a picture of `pixels`) into `bounds` without stretching it: whole,
    /// centered, with `bars` painted in the rest of `bounds` (`None` leaves what is there). Returns the rect the
    /// picture got, so a caller can attach overlays to its edges.
    pub fn draw_image_fit(
        &mut self,
        slot: usize,
        bounds: CGRect,
        source: [f32; 4],
        pixels: CGSize,
        tint: Color,
        bars: Option<Color>,
    ) -> CGRect {
        let pic = fit_rect(pixels, bounds);
        if let Some(bars) = bars {
            self.fill(bounds, bars);
        }
        self.draw_image_slot(slot, pic, source, tint);
        pic
    }

    /// Rounds the corners of a square picture just drawn into `r`: the four wedges outside the rounded rect (`radius`)
    /// are painted over with `ground`, the color behind the picture. The renderer's image quads have no corner
    /// radius, so a rounded frame would otherwise show the picture's square corners under its border.
    pub fn round_picture_corners(&mut self, r: CGRect, radius: f64, ground: Color) {
        if radius <= 0.0 || r.width <= 0.0 || r.height <= 0.0 {
            return;
        }
        // An inside stroke of width `radius` on `r` grown by `radius` (corner radius doubled) is a ring whose inner edge
        // is exactly `r` rounded by `radius`; clipped to `r`, only the corner wedges stay.
        let grown = r.inset_by(-radius, -radius);
        let p = self.px(grown);
        self.save_gstate();
        self.clip_to(r);
        self.list.stroke(p, ground, radius as f32 * self.scale, 2.0 * radius as f32 * self.scale);
        self.restore_gstate();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::software::{RgbaImage, SoftwareRenderer, Sources};

    /// Picture aspects (width, height) and box shapes the app meets: 16:9, 9:16, 1:1 and 4:3 in 16:9, 9:16 and 1:1.
    const PICTURES: [(f64, f64); 4] = [(1920.0, 1080.0), (1080.0, 1920.0), (1000.0, 1000.0), (1440.0, 1080.0)];
    const BOXES: [(f64, f64); 3] = [(160.0, 90.0), (90.0, 160.0), (100.0, 100.0)];

    #[test]
    fn fit_never_stretches_stays_inside_and_is_centered() {
        for (pw, ph) in PICTURES {
            for (bw, bh) in BOXES {
                let bounds = CGRect::new(10.0, 20.0, bw, bh);
                let r = fit_rect(CGSize::new(pw, ph), bounds);
                assert!((r.width / r.height - pw / ph).abs() < 1e-9, "{pw}x{ph} in {bw}x{bh}: {r:?} is stretched");
                assert!(
                    r.min_x() >= bounds.min_x() - 1e-9 && r.max_x() <= bounds.max_x() + 1e-9,
                    "{r:?} leaves {bw}x{bh}"
                );
                assert!(
                    r.min_y() >= bounds.min_y() - 1e-9 && r.max_y() <= bounds.max_y() + 1e-9,
                    "{r:?} leaves {bw}x{bh}"
                );
                assert!(
                    (r.mid_x() - bounds.mid_x()).abs() < 1e-9 && (r.mid_y() - bounds.mid_y()).abs() < 1e-9,
                    "centered"
                );
                let touches = (r.width - bw).abs() < 1e-9 || (r.height - bh).abs() < 1e-9;
                assert!(touches, "{pw}x{ph} in {bw}x{bh}: the picture is not as large as it can be");
            }
        }
    }

    #[test]
    fn a_vertical_picture_in_a_wide_box_gets_bars_left_and_right() {
        let r = fit_rect(CGSize::new(1080.0, 1920.0), CGRect::new(0.0, 0.0, 160.0, 90.0));
        assert_eq!((r.height, r.min_y()), (90.0, 0.0));
        assert!((r.width - 50.625).abs() < 1e-9 && (r.min_x() - 54.6875).abs() < 1e-9, "{r:?}");
    }

    #[test]
    fn empty_sizes_fall_back_to_the_bounds() {
        let b = CGRect::new(1.0, 2.0, 30.0, 20.0);
        assert_eq!(fit_rect(CGSize::new(0.0, 10.0), b), b);
        assert_eq!(fit_rect(CGSize::new(10.0, 10.0), CGRect::new(0.0, 0.0, 0.0, 5.0)), CGRect::new(0.0, 0.0, 0.0, 5.0));
        assert_eq!(fill_source([0.1, 0.2, 0.3, 0.4], CGSize::new(0.0, 0.0), b), [0.1, 0.2, 0.3, 0.4]);
    }

    #[test]
    fn fill_crops_to_the_box_aspect_around_the_center() {
        for (pw, ph) in PICTURES {
            for (bw, bh) in BOXES {
                let src = fill_source([0.0, 0.0, 1.0, 1.0], CGSize::new(pw, ph), CGRect::new(0.0, 0.0, bw, bh));
                let (w, h) = (f64::from(src[2] - src[0]) * pw, f64::from(src[3] - src[1]) * ph);
                assert!((w / h - bw / bh).abs() < 1e-4, "{pw}x{ph} for {bw}x{bh}: cropped to {w}x{h}");
                assert!(
                    (f64::from(src[0] + src[2]) - 1.0).abs() < 1e-6 && (f64::from(src[1] + src[3]) - 1.0).abs() < 1e-6
                );
                assert!(src.iter().all(|v| (0.0..=1.0).contains(v)), "{src:?} leaves the cell");
            }
        }
    }

    #[test]
    fn fill_keeps_a_cell_inside_an_atlas() {
        // A 2:1 picture in the cell (0.5, 0.25)-(1.0, 0.5) of an atlas, shown in a square: its middle half.
        let src = fill_source([0.5, 0.25, 1.0, 0.5], CGSize::new(200.0, 100.0), CGRect::new(0.0, 0.0, 40.0, 40.0));
        assert_eq!(src, [0.625, 0.25, 0.875, 0.5]);
    }

    fn render(c: &Canvas, w: usize, h: usize, images: &[Option<RgbaImage>]) -> RgbaImage {
        SoftwareRenderer::render(&c.list, w, h, Color::rgb(0.0, 0.0, 1.0), &Sources { images, ..Default::default() })
    }

    fn px(img: &RgbaImage, x: usize, y: usize) -> [u8; 3] {
        let i = (y * img.width + x) * 4;
        [img.pixels[i], img.pixels[i + 1], img.pixels[i + 2]]
    }

    #[test]
    fn a_vertical_picture_is_drawn_pillarboxed_with_bars() {
        let imgs = [None, Some(RgbaImage::filled(9, 16, Color::rgb(1.0, 0.0, 0.0)))];
        let mut c = Canvas::with_size(32.0, 18.0, None, 1.0);
        let pic = c.draw_image_fit(
            1,
            CGRect::new(0.0, 0.0, 32.0, 18.0),
            [0.0, 0.0, 1.0, 1.0],
            CGSize::new(9.0, 16.0),
            Color::WHITE,
            Some(Color::BLACK),
        );
        assert_eq!((pic.width, pic.height), (10.125, 18.0));
        let out = render(&c, 32, 18, &imgs);
        assert_eq!(px(&out, 2, 9), [0, 0, 0], "bar on the left");
        assert_eq!(px(&out, 16, 9), [255, 0, 0], "the picture in the middle");
        assert_eq!(px(&out, 30, 9), [0, 0, 0], "bar on the right");
    }

    #[test]
    fn rounding_a_square_picture_paints_the_corners_back_and_keeps_the_rest() {
        let imgs = [None, Some(RgbaImage::filled(2, 2, Color::rgb(1.0, 0.0, 0.0)))];
        for scale in [1.0f32, 2.0] {
            let n = (40.0 * scale) as usize;
            let mut c = Canvas::with_size(n as f32, n as f32, None, scale);
            let r = CGRect::new(4.0, 4.0, 32.0, 32.0);
            c.draw_image_slot(1, r, [0.0, 0.0, 1.0, 1.0], Color::WHITE);
            c.round_picture_corners(r, 8.0, Color::rgb(0.0, 1.0, 0.0));
            let out = render(&c, n, n, &imgs);
            let at = |x: f32, y: f32| px(&out, (x * scale) as usize, (y * scale) as usize);
            for (x, y) in [(4.5, 4.5), (35.5, 4.5), (4.5, 35.5), (35.5, 35.5)] {
                assert_eq!(at(x, y), [0, 255, 0], "corner ({x}, {y}) shows the ground at {scale}x");
            }
            for (x, y) in [(20.5, 20.5), (20.5, 4.5), (4.5, 20.5), (11.5, 5.5), (5.5, 11.5)] {
                assert_eq!(at(x, y), [255, 0, 0], "({x}, {y}) stays the picture at {scale}x");
            }
            assert_eq!(at(2.0, 2.0), [0, 0, 255], "nothing outside the frame is painted");
        }
    }
}
