// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PortableRaster/TextPresetStill.swift

use crate::portable_text_renderer::{Picture, PortableTextRenderer};
use crate::text_presets::{TextMotion, TextPresetCatalog};
use crate::text_style::{FontWeight, RGBAColor, StrokePosition, TextShadow, TextStroke, TextStyle};
use sq_core_model::anchored_animation::{AnimationSample, AnimationSet};
use sq_core_time::Time;
use std::sync::OnceLock;

/// Thumbnails and hover loops of the text Looks, Animations and text templates without Core Graphics: the Mac
/// `TextPresetPreview` (SQMonitorUI) on `PortableTextRenderer`, so Windows and the shared UI show the same pictures. The
/// text is drawn by the real renderer (same fonts, stroke, shadow, box as on the timeline) over a background, the motion
/// by the real `AnimationSet::sample`. Buffers are RGBA8 sRGB, top row first, `width * height * 4` bytes.
pub enum TextPresetStill {}

impl TextPresetStill {
    /// The text of a thumbnail.
    pub const SAMPLE_TEXT: &'static str = "Text";
    /// In-animation, a hold, then the out-animation (when the motion has one), then a short rest.
    const HOLD: f64 = 0.45;
    const TAIL: f64 = 0.3;

    /// Neutral look used to show a motion.
    pub fn motion_style() -> TextStyle {
        TextStyle {
            stroke: Some(TextStroke::new(RGBAColor::BLACK, 8.0, StrokePosition::Outside)),
            shadow: Some(TextShadow::from_angle(RGBAColor::new(0.0, 0.0, 0.0, 0.5), 135.0, 3.0, 6.0)),
            ..TextStyle::new("Montserrat", 80.0, FontWeight::Black, RGBAColor::WHITE)
        }
    }

    fn ms(s: f64) -> Time {
        Time::new((s * 1000.0).round() as i64, 1000)
    }

    fn secs(t: Option<Time>) -> f64 {
        t.map(|t| t.value() as f64 / t.timescale() as f64).unwrap_or(0.0)
    }

    /// Seconds of one hover loop of a motion.
    pub fn loop_duration(m: &TextMotion) -> f64 {
        Self::secs(m.animation_in.as_ref().map(|a| a.duration))
            + Self::HOLD
            + Self::secs(m.animation_out.as_ref().map(|a| a.duration))
            + Self::TAIL
    }

    /// The layer's pose at second `s` of the loop.
    pub fn pose(m: &TextMotion, s: f64) -> AnimationSample {
        let total = Self::loop_duration(m);
        // The clip is exactly the loop, so the out-animation (end-anchored) finishes before the tail.
        let set = AnimationSet::new(m.animation_in.clone(), m.animation_out.clone());
        set.sample(Self::ms(s.min(total - Self::TAIL)), Self::ms(total - Self::TAIL))
    }

    /// The still of a Look (at rest on the background) or of an Animation (after its in-animation); `None` for other ids.
    pub fn still(id: &str, background: &[u8], w: usize, h: usize) -> Option<Vec<u8>> {
        if let Some(look) = TextPresetCatalog::look(id) {
            return Some(Self::still_style(&look.style, Self::SAMPLE_TEXT, background, w, h));
        }
        if let Some(m) = TextPresetCatalog::motion(id) {
            let Some(pic) = Self::raster(&Self::motion_style(), w, h, Self::SAMPLE_TEXT) else {
                return Some(background.to_vec());
            };
            let at = Self::secs(m.animation_in.as_ref().map(|a| a.duration));
            return Some(Self::compose(&pic, &Self::pose(&m, at), background, w, h));
        }
        None
    }

    /// Frames of the hover loop (motions, and generated looks with their suggested motion; other looks are static: `None`).
    pub fn loop_frames(id: &str, fps: f64, background: &[u8], w: usize, h: usize) -> Option<Vec<Vec<u8>>> {
        let (style, motion) = match TextPresetCatalog::look(id) {
            // a generated look hovers in its own style with the motion it suggests
            Some(look) if look.suggested_motion_id.is_some() => {
                let mid = look.suggested_motion_id.clone().unwrap_or_default();
                match TextPresetCatalog::motions().iter().find(|m| m.id == mid) {
                    Some(m) => (look.style, m.clone()),
                    None => Self::motion_pair(id)?,
                }
            }
            _ => Self::motion_pair(id)?,
        };
        let pic = Self::raster(&style, w, h, Self::SAMPLE_TEXT)?;
        let n = 1.max((Self::loop_duration(&motion) * fps).round() as i64);
        Some((0..n).map(|i| Self::compose(&pic, &Self::pose(&motion, i as f64 / fps), background, w, h)).collect())
    }

    fn motion_pair(id: &str) -> Option<(TextStyle, TextMotion)> {
        TextPresetCatalog::motion(id).map(|m| (Self::motion_style(), m))
    }

    /// The thumbnail of any text style (a template, a saved text preset, a Look) at rest over `background`.
    pub fn still_style(style: &TextStyle, text: &str, background: &[u8], w: usize, h: usize) -> Vec<u8> {
        match Self::raster(style, w, h, text) {
            Some(pic) => Self::compose(&pic, &AnimationSample::REST, background, w, h),
            None => background.to_vec(),
        }
    }

    /// An opaque background buffer of one sRGB color (0...255 channels).
    pub fn background(red: u8, green: u8, blue: u8, w: usize, h: usize) -> Vec<u8> {
        let mut out = vec![255u8; w * h * 4];
        for i in (0..out.len()).step_by(4) {
            out[i] = red;
            out[i + 1] = green;
            out[i + 2] = blue;
        }
        out
    }

    /// Sized so the text fills about 42 % of the thumbnail height at its own proportions; a long one shrinks to 92 % of
    /// the width (the Mac `raster`).
    pub fn raster(style: &TextStyle, w: usize, h: usize, text: &str) -> Option<Picture> {
        if !(style.size > 0.0 && w > 0 && h > 0) {
            return None;
        }
        let mut scale = 1.0_f64.min(h as f64 * 0.42 / style.size);
        let first = PortableTextRenderer::render(text, style, None, None, scale, None);
        if let Some(f) = &first
            && f.picture.width as f64 > w as f64 * 0.92
        {
            scale *= w as f64 * 0.92 / f.picture.width as f64;
            return PortableTextRenderer::render(text, style, None, None, scale, None).map(|r| r.picture);
        }
        first.map(|r| r.picture)
    }

    /// `pic` (premultiplied linear light) centered on the background, moved, turned and scaled by `pose` (offsets are
    /// sequence pixels of a 1080p canvas, y down; rotation in degrees clockwise), faded by its opacity. Bilinear.
    pub fn compose(pic: &Picture, pose: &AnimationSample, bg: &[u8], w: usize, h: usize) -> Vec<u8> {
        if bg.len() != w * h * 4 || pic.width == 0 || pic.height == 0 || pose.scale <= 0.0 {
            return bg.to_vec();
        }
        let op = 1.0_f64.min(0.0_f64.max(pose.opacity)) as f32;
        if op <= 0.0 {
            return bg.to_vec();
        }
        let mut out = bg.to_vec();
        let k = h as f64 / 1080.0;
        let cx = w as f64 / 2.0 + pose.offset.x * k;
        let cy = h as f64 / 2.0 + pose.offset.y * k;
        let a = pose.rotation * std::f64::consts::PI / 180.0;
        let (cos_a, sin_a, inv) = (a.cos(), a.sin(), 1.0 / pose.scale);
        let (pw, ph) = (pic.width as i64, pic.height as i64);
        let (hw, hh) = (pw as f64 / 2.0, ph as f64 / 2.0);
        // The destination box the turned, scaled picture covers.
        let ex = (cos_a.abs() * hw + sin_a.abs() * hh) * pose.scale;
        let ey = (sin_a.abs() * hw + cos_a.abs() * hh) * pose.scale;
        let (wi, hi) = (w as i64, h as i64);
        let x0 = 0.max((cx - ex).floor() as i64 - 1);
        let x1 = (wi - 1).min((cx + ex).ceil() as i64 + 1);
        let y0 = 0.max((cy - ey).floor() as i64 - 1);
        let y1 = (hi - 1).min((cy + ey).ceil() as i64 + 1);
        if x0 > x1 || y0 > y1 {
            return bg.to_vec();
        }
        let px = &pic.pixels;
        let texel = |x: i64, y: i64, ch: usize| -> f32 {
            if x < 0 || y < 0 || x >= pw || y >= ph {
                return 0.0;
            }
            px[((y * pw + x) * 4) as usize + ch]
        };
        let decode = Self::decode_table();
        for y in y0..=y1 {
            for x in x0..=x1 {
                // Inverse pose: destination pixel center into picture pixels.
                let dx = x as f64 + 0.5 - cx;
                let dy = y as f64 + 0.5 - cy;
                let sx = (dx * cos_a + dy * sin_a) * inv + hw - 0.5;
                let sy = (-dx * sin_a + dy * cos_a) * inv + hh - 0.5;
                if !(sx > -1.0 && sy > -1.0 && sx < pw as f64 && sy < ph as f64) {
                    continue;
                }
                let ix = sx.floor() as i64;
                let iy = sy.floor() as i64;
                let fx = (sx - ix as f64) as f32;
                let fy = (sy - iy as f64) as f32;
                let mut s = [0.0f32; 4];
                for (ch, slot) in s.iter_mut().enumerate() {
                    let top = texel(ix, iy, ch) * (1.0 - fx) + texel(ix + 1, iy, ch) * fx;
                    let bottom = texel(ix, iy + 1, ch) * (1.0 - fx) + texel(ix + 1, iy + 1, ch) * fx;
                    *slot = (top * (1.0 - fy) + bottom * fy) * op;
                }
                if s[3] <= 0.0005 {
                    continue;
                }
                let i = ((y * wi + x) * 4) as usize;
                let ba = bg[i + 3] as f32 / 255.0;
                let sa = 1.0_f32.min(s[3]);
                let oa = sa + ba * (1.0 - sa);
                if oa <= 0.0 {
                    continue;
                }
                for ch in 0..3 {
                    let lin = (s[ch] + decode[bg[i + ch] as usize] * ba * (1.0 - sa)) / oa;
                    out[i + ch] = Self::encode(lin);
                }
                out[i + 3] = 0.0_f32.max(255.0_f32.min((oa * 255.0).round())) as u8;
            }
        }
        out
    }

    /// sRGB byte to linear light.
    fn decode_table() -> &'static [f32; 256] {
        static TABLE: OnceLock<[f32; 256]> = OnceLock::new();
        TABLE.get_or_init(|| {
            let mut t = [0.0f32; 256];
            for (i, v) in t.iter_mut().enumerate() {
                let c = i as f32 / 255.0;
                *v = if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) };
            }
            t
        })
    }

    /// Linear light to an sRGB byte.
    pub fn encode(l: f32) -> u8 {
        let c = 1.0_f32.min(0.0_f32.max(l));
        let s = if c <= 0.0031308 { c * 12.92 } else { 1.055 * c.powf(1.0 / 2.4) - 0.055 };
        (s * 255.0).round() as u8
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundled_fonts::test_fonts_root;
    use crate::portable_font_match::set_fonts_root;

    const W: usize = 128;
    const H: usize = 80;

    fn gray() -> Vec<u8> {
        set_fonts_root(&test_fonts_root());
        TextPresetStill::background(34, 34, 34, W, H)
    }

    /// Bounding box (min x, max x, min y, max y) of the pixels that differ from the background.
    fn ink(px: &[u8]) -> Option<(usize, usize, usize, usize)> {
        let mut bx: Option<(usize, usize, usize, usize)> = None;
        for y in 0..H {
            for x in 0..W {
                if px[(y * W + x) * 4] != 34 {
                    bx = Some(match bx {
                        Some(b) => (b.0.min(x), b.1.max(x), b.2.min(y), b.3.max(y)),
                        None => (x, x, y, y),
                    });
                }
            }
        }
        bx
    }

    fn inter_bold() -> TextStyle {
        TextStyle::new("Inter", 96.0, FontWeight::Bold, RGBAColor::WHITE)
    }

    #[test]
    fn a_style_draws_its_sample_text_centered_over_the_background() {
        let px = TextPresetStill::still_style(&inter_bold(), TextPresetStill::SAMPLE_TEXT, &gray(), W, H);
        assert_eq!(px.len(), W * H * 4);
        let Some(b) = ink(&px) else { panic!("ink") };
        assert!(((b.0 + b.1) as i64 / 2 - W as i64 / 2).abs() <= 3);
        assert!(((b.2 + b.3) as i64 / 2 - H as i64 / 2).abs() <= 4);
        assert!(b.1 - b.0 < W);
        // White text at full cover reaches near white.
        assert!((0..px.len()).step_by(4).any(|i| px[i] > 240));
        assert!((3..px.len()).step_by(4).all(|i| px[i] == 255));
    }

    #[test]
    fn a_long_text_shrinks_to_the_tile_width() {
        let px = TextPresetStill::still_style(&inter_bold(), "A rather long template title", &gray(), W, H);
        let Some(b) = ink(&px) else { panic!("ink") };
        assert!(b.0 >= 2 && b.1 <= W - 3);
    }

    #[test]
    fn looks_and_animations_have_stills_and_animations_loop() {
        let g = gray();
        let look = TextPresetCatalog::looks().first().cloned();
        let Some(look) = look else { panic!("a look") };
        assert!(TextPresetStill::still(&TextPresetCatalog::look_id(&look), &g, W, H).is_some());
        let motion = TextPresetCatalog::motions().first().cloned();
        let Some(motion) = motion else { panic!("a motion") };
        let id = TextPresetCatalog::motion_id(&motion);
        assert!(TextPresetStill::still(&id, &g, W, H).map(|p| ink(&p)).is_some());
        let frames = TextPresetStill::loop_frames(&id, 10.0, &g, W, H);
        let Some(frames) = frames else { panic!("frames") };
        assert_eq!(frames.len() as i64, 1.max((TextPresetStill::loop_duration(&motion) * 10.0).round() as i64));
        assert!(TextPresetStill::still("not.a.preset", &g, W, H).is_none());
    }

    #[test]
    fn the_pose_moves_turns_and_fades_the_picture() {
        let g = gray();
        // A 10 x 2 white bar.
        let bar = Picture { width: 10, height: 2, pixels: vec![1.0; 10 * 2 * 4] };
        let bx = |pose: &AnimationSample| ink(&TextPresetStill::compose(&bar, pose, &g, W, H));
        let Some(rest) = bx(&AnimationSample::REST) else { panic!("rest") };
        assert!(rest.1 - rest.0 >= 9 && rest.3 - rest.2 <= 2);
        let turned = AnimationSample { rotation: 90.0, ..AnimationSample::REST };
        let Some(t) = bx(&turned) else { panic!("turned") };
        assert!(t.3 - t.2 >= 9 && t.1 - t.0 <= 2);
        // a quarter of 1080 = 20 of 80 px, down
        let moved = AnimationSample { offset: sq_core_time::Vec2::new(0.0, 270.0), ..AnimationSample::REST };
        let Some(m) = bx(&moved) else { panic!("moved") };
        assert_eq!(m.2 - rest.2, 20);
        let faded = AnimationSample { opacity: 0.0, ..AnimationSample::REST };
        assert!(bx(&faded).is_none());
    }
}
