// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PortableRaster/PortableShapeRenderer.swift

use crate::linear_canvas::{LinearCanvas, PolygonMask, Rgba};
use crate::portable_text_renderer::Picture;
use sq_core_model::{EffectColor, ShapeKind, ShapeStyle};
use sq_core_time::Vec2;
use std::f64::consts::PI;

/// Shape clips on the portable raster (Windows): the drawing of the Mac `ShapeRenderer` (SQRender, Core Graphics) on the
/// text raster's coverage masks, so both platforms share one polygon rasterizer. Same picture size (one px per sequence
/// px, at most `MAX_SIDE`), same centered box, colors display-encoded BT.709 linearized with the inverse BT.709 OETF,
/// premultiplied linear light, top row first.
pub enum PortableShapeRenderer {}

/// A drawn shape: the picture and the size in sequence px it covers (larger than the picture when a huge shape was
/// drawn scaled down).
#[derive(Clone, Debug)]
pub struct Shape {
    /// The pixels.
    pub picture: Picture,
    /// Width in sequence px.
    pub width: f64,
    /// Height in sequence px.
    pub height: f64,
}

/// What `render` shares between its fill and stroke passes.
struct Pass<'a> {
    s: &'a ShapeStyle,
    k: f64,
    box_h: f64,
    w: usize,
    h: usize,
}

impl Pass<'_> {
    /// Fills `poly` (pixels) with `color`, or the gradient to `gradient_end`.
    fn fill(&self, canvas: &mut LinearCanvas, poly: &[Vec2], color: &EffectColor) {
        let mut m = PolygonMask::new(self.w, self.h);
        m.add(poly);
        let mask = m.mask();
        let Some(end) = &self.s.gradient_end else {
            canvas.fill(&mask, PortableShapeRenderer::premultiplied(color));
            return;
        };
        // Core Graphics' linear gradient across the path's bounds (y up), extended past both ends.
        let k = self.k;
        let box_h = self.box_h;
        let min_px = poly.iter().map(|p| p.x).fold(f64::INFINITY, f64::min);
        let max_px = poly.iter().map(|p| p.x).fold(f64::NEG_INFINITY, f64::max);
        let min_py = poly.iter().map(|p| p.y).fold(f64::INFINITY, f64::min);
        let max_py = poly.iter().map(|p| p.y).fold(f64::NEG_INFINITY, f64::max);
        let (min_x, max_x) = (min_px / k, max_px / k);
        let (min_y, max_y) = (box_h - max_py / k, box_h - min_py / k);
        let a = self.s.gradient_angle * PI / 180.0;
        let dx = a.cos();
        let dy = -a.sin();
        let half = (((max_x - min_x) * dx).abs() + ((max_y - min_y) * dy).abs()) / 2.0;
        let mx = (min_x + max_x) / 2.0;
        let my = (min_y + max_y) / 2.0;
        let c0 = PortableShapeRenderer::straight(color);
        let c1 = PortableShapeRenderer::straight(end);
        canvas.fill_with(&mask, |x, y| {
            let xx = (x as f64 + 0.5) / k;
            let yy = box_h - (y as f64 + 0.5) / k;
            let t = if half > 0.0 {
                1.0_f64.min(0.0_f64.max(((xx - mx) * dx + (yy - my) * dy) / (2.0 * half) + 0.5))
            } else {
                0.0
            };
            let t = t as f32;
            let c: Rgba = [
                c0[0] + (c1[0] - c0[0]) * t,
                c0[1] + (c1[1] - c0[1]) * t,
                c0[2] + (c1[2] - c0[2]) * t,
                c0[3] + (c1[3] - c0[3]) * t,
            ];
            [c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3]]
        });
    }

    fn stroke(&self, canvas: &mut LinearCanvas, line: &[Vec2], closed: bool, color: &EffectColor) {
        if self.s.stroke_width <= 0.0 || line.len() <= 1 {
            return;
        }
        let r = self.s.stroke_width / 2.0 * self.k;
        let mut m = PolygonMask::new(self.w, self.h);
        if closed {
            m.stroke(&[line.to_vec()], r);
        } else {
            // Round caps and joins along an open path: a disc per point, a rectangle per segment.
            for i in 0..line.len() {
                m.add_positive(&PolygonMask::disc(line[i], r));
                if i + 1 >= line.len() {
                    continue;
                }
                let a = line[i];
                let b = line[i + 1];
                let d = b - a;
                let len = (d.x * d.x + d.y * d.y).sqrt();
                if len <= 1e-9 {
                    continue;
                }
                let n = Vec2::new(-d.y, d.x) * (1.0 / len) * r;
                m.add_positive(&[a + n, b + n, b - n, a - n]);
            }
        }
        canvas.fill(&m.mask(), PortableShapeRenderer::premultiplied(color));
    }
}

impl PortableShapeRenderer {
    /// Largest side of the picture in pixels.
    pub const MAX_SIDE: i64 = 4096;

    /// `None` when nothing is visible (no fill and no stroke, zero size, a path with fewer than two points).
    pub fn render(s: &ShapeStyle) -> Option<Shape> {
        if s.is_empty() {
            return None;
        }
        let size = s.raster_size();
        if size.0 <= 0.0 || size.1 <= 0.0 {
            return None;
        }
        let max_side = Self::MAX_SIDE;
        let k = 1.0_f64.min(max_side as f64 / size.0.max(size.1));
        let w = (((size.0 * k).ceil() as i64).max(1)).min(max_side);
        let h = (((size.1 * k).ceil() as i64).max(1)).min(max_side);
        let box_w = w as f64 / k;
        let box_h = h as f64 / k;
        let ox = (box_w - size.0) / 2.0;
        let oy = (box_h - size.1) / 2.0;
        let mut canvas = LinearCanvas::new(w as usize, h as usize);
        // The Mac draws y up (Core Graphics); points here are given the same way and flipped into pixels (y down).
        let px = |x: f64, y: f64| Vec2::new(x * k, (box_h - y) * k);
        let pass = Pass { s, k, box_h, w: w as usize, h: h as usize };

        if let Some(pts) = &s.path {
            if pts.len() < 2 {
                return None;
            }
            let half = if s.stroke.is_none() { 0.0 } else { s.stroke_width / 2.0 };
            let line: Vec<Vec2> =
                pts.iter().map(|p| px(ox + half + p.x * s.width, box_h - (oy + half + p.y * s.height))).collect();
            if let (Some(f), true) = (&s.fill, s.path_closed) {
                pass.fill(&mut canvas, &line, f);
            }
            if let Some(st) = &s.stroke {
                pass.stroke(&mut canvas, &line, s.path_closed, st);
            }
        } else if s.kind == ShapeKind::Line {
            let st = s.stroke.as_ref()?;
            // A plain rectangle in the stroke color (no gradient).
            let mut m = PolygonMask::new(w as usize, h as usize);
            m.add(&[
                px(ox, oy),
                px(ox + s.width, oy),
                px(ox + s.width, oy + s.stroke_width),
                px(ox, oy + s.stroke_width),
            ]);
            canvas.fill(&m.mask(), Self::premultiplied(st));
        } else {
            let half = if s.stroke.is_none() { 0.0 } else { s.stroke_width / 2.0 };
            let rx = ox + half;
            let ry = oy + half;
            let outline: Vec<Vec2> = match s.kind {
                ShapeKind::Ellipse => {
                    Self::ellipse(rx, ry, s.width, s.height, k).iter().map(|p| px(p.x, p.y)).collect()
                }
                ShapeKind::Arrow => s.arrow_points().iter().map(|p| px(rx + p.x, ry + p.y)).collect(),
                _ => PolygonMask::rounded_rect(rx, ry, s.width, s.height, s.corner_radius)
                    .iter()
                    .map(|p| px(p.x, p.y))
                    .collect(),
            };
            if let Some(f) = &s.fill {
                pass.fill(&mut canvas, &outline, f);
            }
            if let Some(st) = &s.stroke {
                pass.stroke(&mut canvas, &outline, true, st);
            }
        }
        Some(Shape {
            picture: Picture { width: w as usize, height: h as usize, pixels: canvas.pixels },
            width: box_w,
            height: box_h,
        })
    }

    /// An ellipse in the rect as a polygon fine enough at `k` pixels per unit.
    pub fn ellipse(x: f64, y: f64, width: f64, height: f64, k: f64) -> Vec<Vec2> {
        let rx = width / 2.0;
        let ry = height / 2.0;
        let n = 16.max(1024.min((PI * (rx + ry) * k / 2.0).ceil() as i64));
        (0..n)
            .map(|i| {
                let t = i as f64 / n as f64 * 2.0 * PI;
                Vec2::new(x + rx + t.cos() * rx, y + ry + t.sin() * ry)
            })
            .collect()
    }

    /// The Mac `ShapeRenderer.linear`: BT.709 inverse OETF.
    pub fn linear(e: f64) -> f64 {
        if e < 0.081242858 { e / 4.5 } else { ((e + 0.09929682680944) / 1.09929682680944).powf(1.0 / 0.45) }
    }

    /// Straight linear RGBA (Core Graphics interpolates gradient colors unpremultiplied).
    pub fn straight(c: &EffectColor) -> Rgba {
        let k = c.clamped();
        [Self::linear(k.red) as f32, Self::linear(k.green) as f32, Self::linear(k.blue) as f32, k.alpha as f32]
    }

    /// Premultiplied linear RGBA.
    pub fn premultiplied(c: &EffectColor) -> Rgba {
        let s = Self::straight(c);
        [s[0] * s[3], s[1] * s[3], s[2] * s[3], s[3]]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filled_rectangle_is_a_centered_premultiplied_linear_picture() {
        let mut s = ShapeStyle::new(ShapeKind::Rectangle, 10.0, 6.0);
        s.fill = Some(EffectColor { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 });
        let shape = PortableShapeRenderer::render(&s);
        let Some(shape) = shape else { panic!("shape") };
        assert_eq!((shape.picture.width, shape.picture.height), (10, 6));
        assert_eq!((shape.width, shape.height), (10.0, 6.0));
        let i = (3 * 10 + 5) * 4;
        assert_eq!(&shape.picture.pixels[i..i + 4], &[1.0, 0.0, 0.0, 1.0]);
    }

    #[test]
    fn invisible_shapes_draw_nothing() {
        assert!(PortableShapeRenderer::render(&ShapeStyle::new(ShapeKind::Ellipse, 10.0, 6.0)).is_none());
        let mut s = ShapeStyle::new(ShapeKind::Line, 10.0, 6.0);
        s.stroke = Some(EffectColor::WHITE);
        assert!(PortableShapeRenderer::render(&s).is_none()); // zero stroke width: no height
    }

    #[test]
    fn linear_follows_the_inverse_oetf() {
        assert_eq!(PortableShapeRenderer::linear(0.0), 0.0);
        assert!((PortableShapeRenderer::linear(1.0) - 1.0).abs() < 1e-9);
        assert!((PortableShapeRenderer::linear(0.045) - 0.01).abs() < 1e-9);
    }
}
