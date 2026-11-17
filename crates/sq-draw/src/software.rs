//! The reference rasterizer of a [`DrawList`] (Swift `SoftwareRenderer`): the same per-pixel math as the `DrawQuads` shader.
//! Coverage at pixel centers from a rounded-rect distance, glyph texels read 1:1, pictures sampled bilinear, then
//! `src * a + dst * (1 - a)` in sRGB values on a float buffer. The oracle of [`crate::wgpu_renderer::WgpuRenderer`].

use crate::draw_list::{Color, DrawList, DrawQuad, QuadKind};
use crate::glyph_atlas::GlyphAtlas;

/// An 8-bit RGBA image, rows top to bottom (alpha is 255 for rendered frames).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RgbaImage {
    /// Width in pixels.
    pub width: usize,
    /// Height in pixels.
    pub height: usize,
    /// `width * height * 4` bytes.
    pub pixels: Vec<u8>,
}

impl RgbaImage {
    /// An image of one opaque color.
    pub fn filled(width: usize, height: usize, c: Color) -> RgbaImage {
        let px = [c.r, c.g, c.b].map(|v| (v * 255.0 + 0.5) as u8);
        let pixels = (0..width * height).flat_map(|_| [px[0], px[1], px[2], 255]).collect();
        RgbaImage { width, height, pixels }
    }
}

/// Software rendering of a draw list.
pub struct SoftwareRenderer;

/// The images a list refers to: `video` for the video quad, `images[slot]` for image quads.
#[derive(Clone, Copy, Default)]
pub struct Sources<'a> {
    /// The glyph page.
    pub atlas: Option<&'a GlyphAtlas>,
    /// The picture of the video quad (black when absent).
    pub video: Option<&'a RgbaImage>,
    /// Image slots 0...5.
    pub images: &'a [Option<RgbaImage>],
}

type Rgba = [f32; 4];

fn round_box(cx: f32, cy: f32, hx: f32, hy: f32, r: f32) -> f32 {
    let (qx, qy) = (cx.abs() - hx + r, cy.abs() - hy + r);
    let (mx, my) = (qx.max(0.0), qy.max(0.0));
    let d = (mx * mx + my * my).sqrt() + qx.max(qy).min(0.0) - r;
    (0.5 - d).clamp(0.0, 1.0)
}

/// Bilinear sample at normalized (u, v) with texel centers at (i + 0.5) / size, edges clamped.
fn bilinear(img: &RgbaImage, u: f32, v: f32) -> Rgba {
    let (fx, fy) = (u * img.width as f32 - 0.5, v * img.height as f32 - 0.5);
    let (x0, y0) = (fx.floor() as i32, fy.floor() as i32);
    let (ax, ay) = (fx - x0 as f32, fy - y0 as f32);
    let px = |x: i32, y: i32, c: usize| {
        let cx = x.clamp(0, img.width as i32 - 1) as usize;
        let cy = y.clamp(0, img.height as i32 - 1) as usize;
        img.pixels[(cy * img.width + cx) * 4 + c] as f32 / 255.0
    };
    let mut o = [0.0; 4];
    for (c, out) in o.iter_mut().enumerate() {
        let top = px(x0, y0, c) * (1.0 - ax) + px(x0 + 1, y0, c) * ax;
        let bottom = px(x0, y0 + 1, c) * (1.0 - ax) + px(x0 + 1, y0 + 1, c) * ax;
        *out = top * (1.0 - ay) + bottom * ay;
    }
    o
}

/// Coverage of a round-capped line (end points in pixels, `width` thick) at pixel center (px, py).
fn segment_coverage(px: f32, py: f32, x0: f32, y0: f32, x1: f32, y1: f32, width: f32) -> f32 {
    let (dx, dy) = (x1 - x0, y1 - y0);
    let len2 = dx * dx + dy * dy;
    let t = if len2 > 0.0 { (((px - x0) * dx + (py - y0) * dy) / len2).clamp(0.0, 1.0) } else { 0.0 };
    let (ex, ey) = (px - (x0 + dx * t), py - (y0 + dy * t));
    (width / 2.0 + 0.5 - (ex * ex + ey * ey).sqrt()).clamp(0.0, 1.0)
}

/// The shader's per-quad color at pixel center (px, py); `None` = untouched.
fn shade(q: &DrawQuad, px: f32, py: f32, atlas: Option<(&[u8], usize)>, s: &Sources) -> Option<Rgba> {
    let (lx, ly) = (px - q.rect.x, py - q.rect.y);
    let (w, h) = (q.rect.w, q.rect.h);
    let c = [q.color.r, q.color.g, q.color.b, q.color.a];
    match q.kind {
        QuadKind::Shape => {
            let (hx, hy) = (w / 2.0, h / 2.0);
            let r = q.radius.min(hx.min(hy));
            let mut cov = round_box(lx - hx, ly - hy, hx, hy, r);
            if q.stroke > 0.0 {
                let (ix, iy) = (hx - q.stroke, hy - q.stroke);
                if ix > 0.0 && iy > 0.0 {
                    cov -= round_box(lx - hx, ly - hy, ix, iy, (r - q.stroke).max(0.0));
                }
            }
            Some([c[0], c[1], c[2], c[3] * cov.max(0.0)])
        }
        QuadKind::Glyph => {
            let (pixels, size) = atlas?;
            if lx < 0.0 || ly < 0.0 || lx >= w || ly >= h {
                return None;
            }
            let (tx, ty) = (q.uv[0] as usize + lx as usize, q.uv[1] as usize + ly as usize);
            Some([c[0], c[1], c[2], c[3] * *pixels.get(ty * size + tx)? as f32 / 255.0])
        }
        QuadKind::Video => match s.video {
            None => Some([0.0, 0.0, 0.0, 1.0]),
            Some(v) => {
                let (u, vv) = (q.uv[0] + (q.uv[2] - q.uv[0]) * lx / w, q.uv[1] + (q.uv[3] - q.uv[1]) * ly / h);
                let t = bilinear(v, u, vv);
                Some([t[0], t[1], t[2], 1.0])
            }
        },
        QuadKind::Triangle => {
            // Pointing right: left edge, then the two slanted edges toward (w, h/2). Left-pointing mirrors x.
            let lx = if q.uv[0] > 0.5 { w - lx } else { lx };
            let n = (w * w + h * h / 4.0).sqrt();
            let d_top = (ly * w - lx * h / 2.0) / n;
            let d_bottom = ((h - ly) * w - lx * h / 2.0) / n;
            Some([c[0], c[1], c[2], c[3] * (lx.min(d_top.min(d_bottom)) + 0.5).clamp(0.0, 1.0)])
        }
        QuadKind::Image => {
            let img = s.images.get(q.slot as usize)?.as_ref()?;
            let (u, v) = (q.uv[0] + (q.uv[2] - q.uv[0]) * lx / w, q.uv[1] + (q.uv[3] - q.uv[1]) * ly / h);
            let t = bilinear(img, u, v);
            Some([c[0] * t[0], c[1] * t[1], c[2] * t[2], c[3] * t[3]])
        }
        QuadKind::Segment => {
            Some([c[0], c[1], c[2], c[3] * segment_coverage(px, py, q.uv[0], q.uv[1], q.uv[2], q.uv[3], q.stroke)])
        }
    }
}

impl SoftwareRenderer {
    /// Draws `list` onto a `width x height` image cleared to `clear`.
    pub fn render(list: &DrawList, width: usize, height: usize, clear: Color, src: &Sources) -> RgbaImage {
        Self::render_with(list, width, height, clear, src, false)
    }

    /// [`SoftwareRenderer::render`] with every quad's result rounded to 8 bits, as the GPU blends into an RGBA8 target
    /// (Metal and wgpu): a layer whose change is under half a count disappears. The many faint layers of a shadow
    /// (`Canvas::shadow`: 64 layers at alpha 0.013) then barely darken a dark ground, as on screen; the float render
    /// shows them. Measured 2026-11-09: the Swift Metal shot keeps 23 under a dialog shadow where the float render falls to 12.
    pub fn render_8bit(list: &DrawList, width: usize, height: usize, clear: Color, src: &Sources) -> RgbaImage {
        Self::render_with(list, width, height, clear, src, true)
    }

    fn render_with(list: &DrawList, width: usize, height: usize, clear: Color, src: &Sources, q8: bool) -> RgbaImage {
        let mut buf: Vec<f32> = (0..width * height).flat_map(|_| [clear.r, clear.g, clear.b]).collect();
        let draw = |pixels: Option<&[u8]>, buf: &mut Vec<f32>| {
            let atlas = pixels.zip(src.atlas).map(|(p, a)| (p, a.size() as usize));
            for q in list.quads() {
                draw_quad(q, buf, width, height, atlas, src, q8);
            }
        };
        match src.atlas {
            Some(a) => a.with_pixels(|p| draw(Some(p), &mut buf)),
            None => draw(None, &mut buf),
        }
        let mut pixels = vec![255u8; width * height * 4];
        for i in 0..width * height {
            for k in 0..3 {
                pixels[i * 4 + k] = (buf[i * 3 + k].clamp(0.0, 1.0) * 255.0 + 0.5) as u8;
            }
        }
        RgbaImage { width, height, pixels }
    }
}

fn draw_quad(
    q: &DrawQuad,
    buf: &mut [f32],
    width: usize,
    height: usize,
    atlas: Option<(&[u8], usize)>,
    s: &Sources,
    q8: bool,
) {
    let r = &q.rect;
    let x0 = r.x.max(q.clip[0]).floor().max(0.0) as usize;
    let y0 = r.y.max(q.clip[1]).floor().max(0.0) as usize;
    let x1 = (r.max_x().min(q.clip[2]).ceil().min(width as f32)).max(0.0) as usize;
    let y1 = (r.max_y().min(q.clip[3]).ceil().min(height as f32)).max(0.0) as usize;
    for y in y0..y1 {
        let py = y as f32 + 0.5;
        if py < q.clip[1] || py >= q.clip[3] || py < r.y || py >= r.max_y() {
            continue;
        }
        for x in x0..x1 {
            let px = x as f32 + 0.5;
            if px < q.clip[0] || px >= q.clip[2] || px < r.x || px >= r.max_x() {
                continue;
            }
            let Some(c) = shade(q, px, py, atlas, s) else { continue };
            let a = c[3];
            if a <= 0.0 {
                continue;
            }
            let i = (y * width + x) * 3;
            for k in 0..3 {
                let v = c[k] * a + buf[i + k] * (1.0 - a);
                buf[i + k] = if q8 { (v.clamp(0.0, 1.0) * 255.0 + 0.5).floor() / 255.0 } else { v };
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::canvas::Canvas;
    use crate::draw_list::Rect;
    use crate::glyph_atlas::tests::atlas;
    use sq_uikit::controls_grid::CGRect;

    fn render(l: &DrawList, w: usize, h: usize, clear: Color) -> RgbaImage {
        SoftwareRenderer::render(l, w, h, clear, &Sources::default())
    }

    // Swift SQDrawKitTests
    #[test]
    fn integer_rects_fill_exactly() {
        let mut l = DrawList::new(4.0, 4.0);
        l.fill(Rect::new(1.0, 1.0, 2.0, 2.0), Color::rgb(1.0, 0.0, 0.0), 0.0);
        let img = render(&l, 4, 4, Color::BLACK);
        let px = |x: usize, y: usize| img.pixels[(y * 4 + x) * 4..(y * 4 + x) * 4 + 4].to_vec();
        assert_eq!(px(1, 1), [255, 0, 0, 255]);
        assert_eq!(px(2, 2), [255, 0, 0, 255]);
        assert_eq!(px(0, 0), [0, 0, 0, 255]);
        assert_eq!(px(3, 1), [0, 0, 0, 255]);
    }

    #[test]
    fn rounded_corners_and_strokes_antialias() {
        let mut l = DrawList::new(20.0, 20.0);
        l.fill(Rect::new(0.0, 0.0, 20.0, 20.0), Color::WHITE, 8.0);
        let img = render(&l, 20, 20, Color::BLACK);
        assert_eq!(img.pixels[0], 0, "corner outside the arc");
        assert_eq!(img.pixels[(10 * 20 + 10) * 4], 255, "center");
        let edge = img.pixels[(20 + 3) * 4];
        assert!(edge > 0 && edge < 255, "on the arc: partial coverage");
        let mut s = DrawList::new(10.0, 10.0);
        s.stroke(Rect::new(0.0, 0.0, 10.0, 10.0), Color::WHITE, 2.0, 0.0);
        let st = render(&s, 10, 10, Color::BLACK);
        assert_eq!(st.pixels[(5 * 10 + 1) * 4], 255);
        assert_eq!(st.pixels[(5 * 10 + 5) * 4], 0);
    }

    #[test]
    fn clip_rect_limits_drawing() {
        let mut l = DrawList::new(8.0, 2.0);
        l.push_clip(Rect::new(0.0, 0.0, 3.0, 2.0));
        l.fill(Rect::new(0.0, 0.0, 8.0, 2.0), Color::WHITE, 0.0);
        l.pop_clip();
        let img = render(&l, 8, 2, Color::BLACK);
        assert_eq!((img.pixels[2 * 4], img.pixels[3 * 4]), (255, 0));
    }

    #[test]
    fn text_draws_glyphs_from_the_atlas() {
        let a = atlas();
        let mut l = DrawList::new(80.0, 20.0);
        let w = l.text("Hello", 2.0, 15.0, 13.0, Color::WHITE, &a, crate::TextAlign::Left, f32::INFINITY, 0);
        assert!(w > 20.0 && w < 45.0);
        assert_eq!(l.quads().len(), 5);
        assert!(a.generation() > 0);
        let img =
            SoftwareRenderer::render(&l, 80, 20, Color::BLACK, &Sources { atlas: Some(&a), ..Default::default() });
        assert!(img.pixels.iter().step_by(4).any(|&v| v > 200));
        assert!(a.fitted("A long clip name", 11.0, 40.0, 0).is_some_and(|t| t.ends_with('…')));
    }

    // Swift CanvasShadowTests
    fn shadow_picture(opaque_above: bool) -> (DrawList, RgbaImage) {
        let mut c = Canvas::with_size(300.0, 220.0, None, 1.0);
        let card = CGRect::new(60.0, 40.0, 180.0, 120.0);
        c.shadow(card, 10.0, 24.0, 8.0, Color::new(0.0, 0.0, 0.0, 0.35), opaque_above);
        c.fill_rounded(card, 10.0, Color::hex(0x2A2A2E, 1.0));
        let img = render(&c.list, 300, 220, Color::hex(0x505050, 1.0));
        (c.list, img)
    }

    #[test]
    fn ring_shadow_under_an_opaque_card_looks_the_same() {
        let (full, a) = shadow_picture(false);
        let (rings, b) = shadow_picture(true);
        assert!(rings.quads().iter().any(|q| q.stroke > 0.0) && full.quads().iter().all(|q| q.stroke == 0.0));
        let worst = a.pixels.iter().zip(&b.pixels).map(|(x, y)| (*x as i32 - *y as i32).abs()).max().unwrap_or(0);
        assert!(worst <= 2, "worst difference {worst}");
    }

    /// Darkness (0..1 of the ground) of the device pixel row nearest `y_pt` points, centered in x, on a mid-gray ground at
    /// `scale`, with the y (points) of that row's center: at 1.5 the row center is up to a third of a point off `y_pt`.
    fn shadow_darkness(
        card: CGRect,
        radius: f64,
        blur: f64,
        dy: f64,
        alpha: f32,
        scale: f32,
        y_pts: &[f64],
    ) -> Vec<(f64, f32)> {
        let mut c = Canvas::with_size(300.0 * scale, 220.0 * scale, None, scale);
        c.shadow(card, radius, blur, dy, Color::new(0.0, 0.0, 0.0, alpha), true);
        c.fill_rounded(card, radius, Color::hex(0x2A2A2E, 1.0));
        let (w, h) = ((300.0 * scale) as usize, (220.0 * scale) as usize);
        let img = render(&c.list, w, h, Color::hex(0x808080, 1.0));
        let x = ((card.x + card.width / 2.0) * scale as f64) as usize;
        y_pts
            .iter()
            .map(|y| {
                let py = (y * scale as f64 - 0.5).round() as usize;
                ((py as f64 + 0.5) / scale as f64, 1.0 - img.pixels[(py * w + x) * 4] as f32 / 128.0)
            })
            .collect()
    }

    /// Normal CDF for the expected values (same as the shadow code, kept independent here).
    fn phi(x: f64) -> f64 {
        0.5 * (1.0 + libm_erf(x / std::f64::consts::SQRT_2))
    }
    fn libm_erf(x: f64) -> f64 {
        // Series: erf(x) = 2/sqrt(pi) * sum (-1)^n x^(2n+1) / (n! (2n+1)), accurate for |x| < 3.
        let mut sum = 0.0;
        let mut term = x;
        for n in 0..60 {
            sum += term / (2 * n + 1) as f64;
            term *= -x * x / (n + 1) as f64;
        }
        sum * 2.0 / std::f64::consts::PI.sqrt()
    }

    #[test]
    fn raised_button_shadow_matches_the_spec_at_every_scale() {
        // Spec: `0 1px 1.5px #00000080` (blur 1.5 = sigma 0.75, peak alpha 0.5). 1.5 is the Linux and Windows desktop scale.
        let card = CGRect::new(100.0, 100.0, 60.0, 24.0);
        let bottom = 124.0;
        for scale in [1.0f32, 1.5, 2.0] {
            let ys = [bottom + 0.25, bottom + 0.75, bottom + 1.25, bottom + 2.25, bottom + 4.0];
            let got = shadow_darkness(card, 6.0, 1.5, 1.0, 0.5, scale, &ys);
            for (y, g) in &got {
                let want = 0.5 * phi((bottom + 1.0 - y) / 0.75) as f32;
                // The row center is where the pixel is sampled; a whole pixel still averages the edge over its height.
                let tol = if scale == 1.0 { 0.09 } else { 0.05 };
                assert!((g - want).abs() < tol, "scale {scale} y {y}: got {g}, want {want}");
            }
            assert!(got[4].1 < 0.01, "extent at scale {scale}: {}", got[4].1);
        }
    }

    #[test]
    fn dialog_card_shadow_matches_the_spec_at_every_scale() {
        // Spec: `0 12px 32px rgba(0,0,0,.6)` (sigma 16).
        let card = CGRect::new(60.0, 30.0, 180.0, 100.0);
        let bottom = 130.0;
        for scale in [1.0f32, 1.5, 2.0] {
            let ys = [bottom + 2.0, bottom + 12.0, bottom + 28.0, bottom + 45.0, bottom + 60.0];
            let got = shadow_darkness(card, 10.0, 32.0, 12.0, 0.6, scale, &ys);
            for (y, g) in &got {
                let want = 0.6 * phi((bottom + 12.0 - y) / 16.0) as f32;
                assert!((g - want).abs() < 0.04, "scale {scale} y {y}: got {g}, want {want}");
            }
        }
    }

    #[test]
    fn video_quad_is_black_without_a_picture_and_images_tint() {
        let mut l = DrawList::new(8.0, 4.0);
        l.video(Rect::new(0.0, 0.0, 4.0, 4.0), [0.0, 0.0, 1.0, 1.0]);
        l.image(Rect::new(4.0, 0.0, 4.0, 4.0), 1, [0.0, 0.0, 1.0, 1.0], Color::rgb(1.0, 0.5, 1.0));
        let imgs = [None, Some(RgbaImage::filled(2, 2, Color::rgb(1.0, 1.0, 0.0)))];
        let out = SoftwareRenderer::render(&l, 8, 4, Color::WHITE, &Sources { images: &imgs, ..Default::default() });
        let px = |x: usize| out.pixels[x * 4..x * 4 + 3].to_vec();
        assert_eq!(px(1), [0, 0, 0]);
        assert_eq!(px(5), [255, 128, 0]);
    }

    #[test]
    fn segments_and_triangles_cover_their_shapes() {
        let mut l = DrawList::new(20.0, 10.0);
        l.segment(2.0, 5.0, 8.0, 5.0, 2.0, Color::WHITE);
        l.triangle(Rect::new(10.0, 0.0, 8.0, 10.0), Color::WHITE, false);
        let out = render(&l, 20, 10, Color::BLACK);
        let v = |x: usize, y: usize| out.pixels[(y * 20 + x) * 4];
        assert_eq!(v(5, 4), 255);
        assert_eq!(v(5, 0), 0);
        assert!(v(11, 5) > 200 && v(17, 1) < 60, "the triangle narrows toward its tip");
    }
}
