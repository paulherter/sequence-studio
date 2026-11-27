// Swift: ShellAppIcon.swift, ShellAppIconPixels.swift
//! The app icon on the draw canvas (portable redraw of `App/AppIcon.icon`: the gradient field, Pip's head, his face).
//! The Mac host puts the real icon over the About card instead; the Windows host has no image to place, so the card draws
//! this. Art space is the 512 px icon picture.
//!
//! `ShellAppIconPixels` (128 px RGBA from Windows/Resources/SequenceStudio.ico, base64 in Swift) is `app_icon_pixels.rgba`,
//! the same bytes decoded once.
//!
//! Mapping: Swift's static `hasImage` is the `has_image` argument of [`ShellAppIcon::draw`] (the host knows whether it holds
//! the real picture, `ShellHost.appIconImage`).

use crate::shell_mascot::{Aff, Gfx, Path, head_path};
use sq_draw::{Canvas, Color};
use sq_uikit::controls_grid::CGRect;
use std::sync::{Arc, Mutex};

const SIZE: usize = 128;
const PIXELS: &[u8] = include_bytes!("app_icon_pixels.rgba");
/// The 256 px picture the card scales from.
const SOURCE: &[u8] = include_bytes!("app_icon_256.rgba");
const SOURCE_SIDE: usize = 256;
/// The Nightly channel's icon (Pip on the blue plate, `packaging/linux/sequence-studio-nightly.png`), same sizes.
const NIGHTLY_PIXELS: &[u8] = include_bytes!("app_icon_nightly_pixels.rgba");
const NIGHTLY_SOURCE: &[u8] = include_bytes!("app_icon_nightly_256.rgba");

/// The (128 px, 256 px) pictures of a channel: the card, the title bar and the window icon follow the build's channel.
fn pictures(channel: sq_editor_session::ReleaseChannel) -> (&'static [u8], &'static [u8]) {
    match channel {
        sq_editor_session::ReleaseChannel::Nightly => (NIGHTLY_PIXELS, NIGHTLY_SOURCE),
        sq_editor_session::ReleaseChannel::Stable => (PIXELS, SOURCE),
    }
}

/// A run of equal pixels in one row.
struct Run {
    x: usize,
    y: usize,
    length: usize,
    color: Color,
}

/// The app icon on the canvas.
pub struct ShellAppIcon;

impl ShellAppIcon {
    /// Image slot of the real icon picture while the About card shows (borrows the Slip two-up slot like the Export preview:
    /// no Slip drag runs under a modal card). shortcut: one borrowed slot; upgrade when the renderers keep a seventh.
    pub const SLOT: usize = 1;

    fn field_top() -> Color {
        Color::hex(0xFFA94D, 1.0)
    }
    fn field_bottom() -> Color {
        Color::hex(0x5A1590, 1.0)
    }
    fn face() -> Color {
        Color::hex(0x1A1A1F, 1.0)
    }

    /// The real icon as 128 x 128 RGBA (from `Windows/Resources/SequenceStudio.ico`): the window icon of the hosts.
    pub fn rgba() -> (&'static [u8], u32) {
        (pictures(sq_editor_session::ReleaseChannel::build()).0, SIZE as u32)
    }

    /// The real icon (128 px) as one quad per run of equal pixels: the draw list has no spare image slot for a picture.
    /// With `has_image` the host holds the real picture and the card places it from [`ShellAppIcon::SLOT`].
    /// Nearest-neighbor at 128 px, as in Swift `ShellAppIcon` (one borrowed image slot).
    pub fn draw(rect: CGRect, c: &mut Canvas, has_image: bool) {
        if has_image && rect.width > 0.0 && rect.height > 0.0 {
            let side = rect.width.min(rect.height);
            c.draw_image_slot(
                Self::SLOT,
                CGRect::new(rect.mid_x() - side / 2.0, rect.mid_y() - side / 2.0, side, side),
                [0.0, 0.0, 1.0, 1.0],
                Color::WHITE,
            );
            return;
        }
        let side_px = (rect.width.min(rect.height) * c.scale as f64).round().max(1.0) as usize;
        let runs = runs(side_px);
        if rect.width <= 0.0 || rect.height <= 0.0 || runs.is_empty() {
            return Self::draw_vector(rect, c);
        }
        // Whole device pixels only: every run starts and ends on the pixel grid, so no edge is smoothed into a seam.
        let px = 1.0 / c.scale as f64;
        let ox = ((rect.mid_x() - side_px as f64 * px / 2.0) / px).round() * px;
        let oy = ((rect.mid_y() - side_px as f64 * px / 2.0) / px).round() * px;
        for r in runs.iter() {
            c.fill(CGRect::new(ox + r.x as f64 * px, oy + r.y as f64 * px, r.length as f64 * px, px), r.color);
        }
    }

    /// Draws the icon so its first INK column (not its transparent margin) starts at `rect.min_x()`: the title bar's left inset
    /// must look as wide as the right one (the artwork has about 1.5 pt of empty margin inside its square).
    /// The margin is measured from the real picture at the device size, never guessed.
    pub fn draw_ink_flush(rect: CGRect, c: &mut Canvas) {
        let px = 1.0 / c.scale as f64;
        let side_px = (rect.width.min(rect.height) * c.scale as f64).round().max(1.0) as usize;
        let margin = Self::ink_margin_px(side_px) as f64 * px;
        Self::draw(CGRect::new(rect.min_x() - margin, rect.min_y(), rect.width, rect.height), c, false);
    }

    /// Transparent device pixels left of the first ink at `side_px` (first pixel at half opacity or more: a faint anti-aliased fringe is not ink).
    pub fn ink_margin_px(side_px: usize) -> usize {
        runs(side_px).iter().filter(|r| r.color.a >= 0.5).map(|r| r.x).min().unwrap_or(0)
    }

    /// The portable redraw of `App/AppIcon.icon` (the gradient field, Pip's head, his face): the fallback.
    pub(crate) fn draw_vector(rect: CGRect, c: &mut Canvas) {
        let s = rect.width.min(rect.height) / 512.0;
        let base = Aff::move_by(rect.min_x(), rect.min_y()).concat(Aff::scale(s, s));
        // Field: the rounded square as horizontal slabs, orange at the top to violet at the bottom.
        let field = Gfx { m: base };
        let square = Path::rounded_rect(CGRect::new(0.0, 0.0, 512.0, 512.0), 115.0);
        let pts = field.map(&square);
        let lo = pts.iter().map(|p| p.y).reduce(f64::min);
        let hi = pts.iter().map(|p| p.y).reduce(f64::max);
        if let (Some(lo), Some(hi)) = (lo, hi) {
            let n = 2.max(32.min(((hi - lo) / 1.5) as i64)) as usize;
            let (a, b) = (Self::field_top(), Self::field_bottom());
            for i in 0..n {
                let y0 = lo + (hi - lo) * i as f64 / n as f64;
                let y1 = lo + (hi - lo) * (i + 1) as f64 / n as f64 + if i == n - 1 { 0.0 } else { 0.6 };
                let t = (i * 2 + 1) as f32 / (n * 2) as f32;
                let col = Color::rgb(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t);
                let slab = Gfx::clip(&pts, y0, y1);
                if slab.len() >= 3 {
                    c.fill_polygon(&slab, col);
                }
            }
        }
        Self::draw_head(rect, c);
    }

    /// Pip's head and face alone (no gradient field): the About card's mascot (art.html 43).
    pub(crate) fn draw_head(rect: CGRect, c: &mut Canvas) {
        Self::draw_head_face(rect, c);
    }

    fn draw_head_face(rect: CGRect, c: &mut Canvas) {
        let s = rect.width.min(rect.height) / 512.0;
        let base = Aff::move_by(rect.min_x(), rect.min_y()).concat(Aff::scale(s, s));
        // Head: the mascot's head outline (art 1024) placed as in the icon (scale 1.04 about the middle).
        let head_m =
            base.concat(Aff::move_by(256.0, 269.5)).concat(Aff::scale(0.52, 0.52)).concat(Aff::move_by(-512.0, -652.0));
        Gfx { m: head_m }.gradient(&head_path(), c);
        // Face: two bars and a smile.
        let g = Gfx { m: base };
        for x in [169.0, 305.0] {
            g.fill(&Path::rounded_rect(CGRect::new(x, 193.0, 36.0, 95.0), 18.0), Self::face(), c);
        }
        let mut smile = Path::new();
        smile.move_to(220.0, 326.0);
        smile.quad(255.0, 358.0, 290.0, 326.0);
        g.stroke(&smile, 20.0, Self::face(), false, c);
    }
}

/// The 256 px icon (`Windows/Resources/SequenceStudio.ico`, largest entry) scaled to `side` device pixels by area
/// averaging (premultiplied, so soft edges stay clean) and cut into runs of equal pixels, row by row; transparent pixels are
/// skipped. shortcut: above 256 px the picture is magnified without smoothing; upgrade with a larger source.
fn runs(side: usize) -> Arc<Vec<Run>> {
    static CACHE: Mutex<Vec<(usize, Arc<Vec<Run>>)>> = Mutex::new(Vec::new());
    let mut cache = CACHE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some((_, r)) = cache.iter().find(|(n, _)| *n == side) {
        return Arc::clone(r);
    }
    let made = Arc::new(scaled_runs(pictures(sq_editor_session::ReleaseChannel::build()).1, SOURCE_SIDE, side));
    cache.truncate(7);
    cache.push((side, Arc::clone(&made)));
    made
}

fn scaled_runs(src: &[u8], n: usize, side: usize) -> Vec<Run> {
    if src.len() != n * n * 4 || side == 0 {
        return Vec::new();
    }
    let span = |i: usize| {
        let start = (i * n / side).min(n - 1);
        (start, ((i + 1) * n / side).clamp(start + 1, n))
    };
    let mut out = Vec::new();
    for y in 0..side {
        let (y0, y1) = span(y);
        let row: Vec<[u8; 4]> = (0..side)
            .map(|x| {
                let (x0, x1) = span(x);
                let (mut sum, mut alpha, mut count) = ([0.0_f32; 3], 0.0_f32, 0.0_f32);
                for sy in y0..y1 {
                    for sx in x0..x1 {
                        let i = (sy * n + sx) * 4;
                        let a = f32::from(src[i + 3]);
                        for k in 0..3 {
                            sum[k] += f32::from(src[i + k]) * a;
                        }
                        alpha += a;
                        count += 1.0;
                    }
                }
                if alpha <= 0.0 {
                    return [0; 4];
                }
                let c = |v: f32| (v / alpha).round().clamp(0.0, 255.0) as u8;
                [c(sum[0]), c(sum[1]), c(sum[2]), (alpha / count).round().clamp(0.0, 255.0) as u8]
            })
            .collect();
        let mut x = 0;
        while x < side {
            let k = row[x];
            let mut e = x + 1;
            while e < side && row[e] == k {
                e += 1;
            }
            if k[3] > 0 {
                let f = |v: u8| f32::from(v) / 255.0;
                out.push(Run { x, y, length: e - x, color: Color::new(f(k[0]), f(k[1]), f(k[2]), f(k[3])) });
            }
            x = e;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_nightly_channel_has_its_own_icon_of_the_same_size() {
        use sq_editor_session::ReleaseChannel::{Nightly, Stable};
        assert_ne!(pictures(Nightly).0, pictures(Stable).0);
        assert_ne!(pictures(Nightly).1, pictures(Stable).1);
        assert_eq!(pictures(Nightly).0.len(), SIZE * SIZE * 4);
        assert_eq!(pictures(Nightly).1.len(), SOURCE_SIDE * SOURCE_SIDE * 4);
    }

    /// The ink of the icon starts left of the layout rect's edge by exactly its measured margin (about 1.5 pt at 18 pt, 2x).
    #[test]
    fn the_icon_has_a_measured_transparent_margin_that_draw_ink_flush_removes() {
        let m = ShellAppIcon::ink_margin_px(36);
        assert!((1..=6).contains(&m), "margin {m}");
        let mut c = Canvas::with_size(100.0, 40.0, None, 2.0);
        ShellAppIcon::draw_ink_flush(CGRect::new(12.0, 10.0, 18.0, 18.0), &mut c);
        // Ink is a pixel at half opacity or more, as `ink_margin_px` counts it: a fainter anti-aliased fringe left of it is not ink.
        let first =
            c.list.quads().iter().filter(|q| q.color.a >= 0.5).map(|q| f64::from(q.rect.x)).fold(f64::MAX, f64::min);
        assert!((first - 24.0).abs() < 0.01, "first ink at {first} device px (rect edge 12 pt at 2x)");
    }

    #[test]
    fn the_scaled_icon_is_clean_at_one_and_two_times() {
        for side in [72_usize, 144, 216] {
            let runs = scaled_runs(pictures(sq_editor_session::ReleaseChannel::build()).1, SOURCE_SIDE, side);
            assert!(!runs.is_empty());
            // Every row's runs tile without overlap, so nothing is painted twice (no stripes), and stay inside the square.
            for y in 0..side {
                let mut end = 0;
                for r in runs.iter().filter(|r| r.y == y) {
                    assert!(r.x >= end && r.x + r.length <= side, "row {y} of {side}");
                    end = r.x + r.length;
                }
            }
            // The middle of the head is the same white on every row of a block: no horizontal bands in flat areas.
            let at = |y: usize| {
                runs.iter().find(|r| r.y == y && r.x <= side / 2 && side / 2 < r.x + r.length).map(|r| r.color)
            };
            let (a, b) = (at(side * 2 / 5), at(side * 2 / 5 + 1));
            assert!(a.is_some() && b.is_some());
            assert!((a.unwrap().r - b.unwrap().r).abs() < 0.03, "no stripes across rows at {side}");
        }
    }

    #[test]
    fn a_translucent_pixel_keeps_its_color_when_averaged() {
        // 2 x 2: one opaque red, three clear pixels: the average stays red at a quarter of the alpha.
        let mut src = vec![0_u8; 16];
        src[..4].copy_from_slice(&[255, 0, 0, 255]);
        let runs = scaled_runs(&src, 2, 1);
        assert_eq!(runs.len(), 1);
        assert!((runs[0].color.r - 1.0).abs() < 0.01 && runs[0].color.g < 0.01);
        assert!((runs[0].color.a - 0.25).abs() < 0.01);
    }
}
