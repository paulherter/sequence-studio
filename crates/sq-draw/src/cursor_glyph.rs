// Swift: SQDrawKit/Hover/DrawCursor.swift (DrawCursorGlyph, DrawCursorImage)
//! The drawn pointer shapes (timeline tool cursors, drag copy, zoom in; the monitor overlay cursors are icons, see `render_overlay`) as strokes in a 24 x 24 box
//! (y down, hot spot in the middle) and a small rasterizer for them: black lines over a white halo so they read on any
//! clip color. The window turns the pixels into a winit custom cursor.

use crate::canvas_shapes::IconOutline;
use crate::ui_cx::DrawCursor;
use sq_uikit::controls_grid::CGPoint;
use sq_uikit::sqicon::SQIcon;

/// Box side in points.
pub const SIZE: f32 = 24.0;
/// Hot spot in points (both axes).
pub const HOT_SPOT: f32 = 12.0;
/// Line width; the halo is `WIDTH + HALO`.
pub const WIDTH: f32 = 1.6;
/// Extra width of the white halo.
pub const HALO: f32 = 2.4;

type Pt = (f32, f32);

/// The polylines of `cursor` (empty for the system shapes).
pub fn strokes(cursor: DrawCursor) -> Vec<Vec<Pt>> {
    use DrawCursor::*;
    let c = HOT_SPOT;
    let p = |x: f32, y: f32| (c + x, c + y);
    let arrow = |x: f32, dir: f32| vec![p(x - dir * 4.0, -3.5), p(x, 0.0), p(x - dir * 4.0, 3.5)];
    let circle = |cx: f32, cy: f32, r: f32, n: usize| -> Vec<Pt> {
        (0..=n)
            .map(|i| {
                let a = i as f32 / n as f32 * std::f32::consts::TAU;
                p(cx + r * a.cos(), cy + r * a.sin())
            })
            .collect()
    };
    match cursor {
        TrimIn | TrimOut | RippleIn | RippleOut | RateIn | RateOut => {
            let s = if matches!(cursor, TrimIn | RippleIn | RateIn) { 1.0 } else { -1.0 };
            let mut out = vec![
                vec![p(s * 4.0, -7.0), p(0.0, -7.0), p(0.0, 7.0), p(s * 4.0, 7.0)],
                vec![p(-9.0, 0.0), p(9.0, 0.0)],
                arrow(-9.0, -1.0),
                arrow(9.0, 1.0),
            ];
            if matches!(cursor, RippleIn | RippleOut) {
                out.push(vec![p(s * 7.0, -4.0), p(s * 7.0, 4.0)]);
            }
            if matches!(cursor, RateIn | RateOut) {
                for dy in [-3.5, 3.5] {
                    out.push(vec![p(s * 6.0, dy), p(s * 11.0, dy)]);
                }
            }
            out
        }
        TrackSelect => vec![vec![p(-8.0, 0.0), p(6.0, 0.0)], arrow(6.0, 1.0), vec![p(9.0, -7.0), p(9.0, 7.0)]],
        Roll => vec![
            vec![p(-2.0, -7.0), p(-2.0, 7.0)],
            vec![p(2.0, -7.0), p(2.0, 7.0)],
            vec![p(-10.0, 0.0), p(10.0, 0.0)],
            arrow(-10.0, -1.0),
            arrow(10.0, 1.0),
        ],
        Slip | Slide => {
            let mut out = vec![
                vec![p(-4.0, -5.0), p(4.0, -5.0), p(4.0, 5.0), p(-4.0, 5.0), p(-4.0, -5.0)],
                vec![p(-10.0, 0.0), p(10.0, 0.0)],
                arrow(-10.0, -1.0),
                arrow(10.0, 1.0),
            ];
            if cursor == Slip {
                out.push(vec![p(0.0, -5.0), p(0.0, 5.0)]);
            } else {
                out.push(vec![p(-7.0, -6.0), p(-7.0, 6.0)]);
                out.push(vec![p(7.0, -6.0), p(7.0, 6.0)]);
            }
            out
        }
        Razor => vec![
            circle(-5.0, -5.0, 2.5, 12),
            circle(-5.0, 5.0, 2.5, 12),
            vec![p(-3.2, -3.2), p(8.0, 7.0)],
            vec![p(-3.2, 3.2), p(8.0, -7.0)],
        ],
        DragCopy => vec![
            vec![
                p(0.0, 0.0),
                p(0.0, 13.0),
                p(3.2, 10.0),
                p(5.6, 15.0),
                p(7.6, 14.0),
                p(5.2, 9.2),
                p(9.4, 9.2),
                p(0.0, 0.0),
            ],
            vec![p(10.0, 1.0), p(10.0, 9.0)],
            vec![p(6.0, 5.0), p(14.0, 5.0)],
        ],
        ZoomIn => vec![
            circle(0.0, 0.0, 6.0, 16),
            vec![p(4.3, 4.3), p(9.5, 9.5)],
            vec![p(-3.0, 0.0), p(3.0, 0.0)],
            vec![p(0.0, -3.0), p(0.0, 3.0)],
        ],
        _ => Vec::new(),
    }
}

/// A rendered cursor: straight-alpha RGBA rows top to bottom and the hot spot in pixels.
#[derive(Debug, Clone, PartialEq)]
pub struct CursorImage {
    /// Side in pixels.
    pub side: u32,
    /// RGBA, `side * side * 4` bytes.
    pub rgba: Vec<u8>,
    /// Hot spot in pixels.
    pub hot: u32,
}

fn seg_dist2(p: Pt, a: Pt, b: Pt) -> f32 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let len2 = dx * dx + dy * dy;
    let t = if len2 > 0.0 { (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len2).clamp(0.0, 1.0) } else { 0.0 };
    let (qx, qy) = (a.0 + t * dx - p.0, a.1 + t * dy - p.1);
    qx * qx + qy * qy
}

/// The cursor at `scale` pixels per point (`None` for the system shapes).
pub fn render(cursor: DrawCursor, scale: f32) -> Option<CursorImage> {
    if let Some(img) = render_overlay(cursor, scale) {
        return Some(img);
    }
    let lines = strokes(cursor);
    if lines.is_empty() {
        return None;
    }
    let side = (SIZE * scale).ceil() as u32;
    let mut rgba = vec![0u8; (side * side * 4) as usize];
    const N: u32 = 4; // samples per axis
    let (r_halo, r_line) = ((WIDTH + HALO) / 2.0, WIDTH / 2.0);
    for y in 0..side {
        for x in 0..side {
            let (mut halo, mut line) = (0u32, 0u32);
            for sy in 0..N {
                for sx in 0..N {
                    let p = (
                        (x as f32 + (sx as f32 + 0.5) / N as f32) / scale,
                        (y as f32 + (sy as f32 + 0.5) / N as f32) / scale,
                    );
                    let d2 = lines
                        .iter()
                        .flat_map(|l| l.windows(2))
                        .map(|w| seg_dist2(p, w[0], w[1]))
                        .fold(f32::MAX, f32::min);
                    if d2 <= r_halo * r_halo {
                        halo += 1;
                    }
                    if d2 <= r_line * r_line {
                        line += 1;
                    }
                }
            }
            if halo == 0 {
                continue;
            }
            let total = (N * N) as f32;
            let v = ((halo - line) as f32 / halo as f32 * 255.0 + 0.5) as u8;
            let i = ((y * side + x) * 4) as usize;
            rgba[i..i + 4].copy_from_slice(&[v, v, v, (halo as f32 / total * 255.0 + 0.5) as u8]);
        }
    }
    Some(CursorImage { side, rgba, hot: (HOT_SPOT * scale).round() as u32 })
}

/// Box side of the overlay cursors in points (the Mac `OverlayCursors.image` size).
pub const OVERLAY_SIZE: f32 = 26.0;
/// Icon side inside the overlay box.
const OVERLAY_ICON: f32 = 18.0;
/// Reach of the dark halo around the white glyph (the Mac draws the dark copy at eight offsets of 1.2 / 0.9).
const OVERLAY_HALO: f32 = 1.2;

/// The icon and turn (degrees clockwise on screen) of an overlay cursor, `None` for the others. Like the Mac: the rotate
/// cursor is `rotateCW` turned by angle + 45, the resize cursor `moveHorizontal` turned by angle, move is `move`.
fn overlay_spec(cursor: DrawCursor) -> Option<(SQIcon, f64)> {
    match cursor {
        DrawCursor::OverlayRotate(a) => Some((SQIcon::RotateCW, f64::from(a) + 45.0)),
        DrawCursor::OverlayResize(a) => Some((SQIcon::MoveHorizontal, f64::from(a))),
        DrawCursor::Move => Some((SQIcon::Move, 0.0)),
        _ => None,
    }
}

/// Nonzero winding of `p` in the closed `contours`, and the distance to the nearest contour edge.
fn winding_and_distance(contours: &[Vec<CGPoint>], p: Pt) -> (bool, f32) {
    let mut winding = 0i32;
    let mut d2 = f32::MAX;
    for c in contours {
        let n = c.len();
        for i in 0..n {
            let (a, b) = (c[i], c[(i + 1) % n]);
            let (a, b) = ((a.x as f32, a.y as f32), (b.x as f32, b.y as f32));
            d2 = d2.min(seg_dist2(p, a, b));
            if (a.1 <= p.1) != (b.1 <= p.1) {
                let t = (p.1 - a.1) / (b.1 - a.1);
                if a.0 + t * (b.0 - a.0) > p.0 {
                    winding += if b.1 > a.1 { 1 } else { -1 };
                }
            }
        }
    }
    (winding != 0, d2.sqrt())
}

/// The overlay cursor (white glyph with a dark halo) from the icon outline, the same pixels on every system.
pub fn render_overlay(cursor: DrawCursor, scale: f32) -> Option<CursorImage> {
    let (icon, degrees) = overlay_spec(cursor)?;
    let glyph = IconOutline::glyph(icon);
    let k = OVERLAY_ICON / glyph.grid as f32; // grid unit -> point
    let origin = (OVERLAY_SIZE - OVERLAY_ICON) / 2.0;
    let contours: Vec<Vec<CGPoint>> = glyph.fills.iter().filter(|c| c.len() > 2).cloned().collect();
    let side = (OVERLAY_SIZE * scale).ceil() as u32;
    let mut rgba = vec![0u8; (side * side * 4) as usize];
    let (sin, cos) = (-degrees.to_radians()).sin_cos();
    let (sin, cos) = (sin as f32, cos as f32);
    let mid = OVERLAY_SIZE / 2.0;
    const N: u32 = 3;
    for y in 0..side {
        for x in 0..side {
            let (mut white, mut dark) = (0u32, 0u32);
            for sy in 0..N {
                for sx in 0..N {
                    let px = (x as f32 + (sx as f32 + 0.5) / N as f32) / scale - mid;
                    let py = (y as f32 + (sy as f32 + 0.5) / N as f32) / scale - mid;
                    // Back through the turn into the icon box, then onto the icon grid.
                    let (qx, qy) = (px * cos - py * sin + mid, px * sin + py * cos + mid);
                    let g = ((qx - origin) / k, (qy - origin) / k);
                    let (inside, d) = winding_and_distance(&contours, g);
                    if inside {
                        white += 1;
                    } else if d * k <= OVERLAY_HALO {
                        dark += 1;
                    }
                }
            }
            if white + dark == 0 {
                continue;
            }
            let (w, d) = (white as f32, dark as f32 * 0.85);
            let i = ((y * side + x) * 4) as usize;
            let c = (255.0 * w / (w + d) + 0.5) as u8;
            rgba[i..i + 4].copy_from_slice(&[c, c, c, ((w + d) / (N * N) as f32 * 255.0 + 0.5) as u8]);
        }
    }
    Some(CursorImage { side, rgba, hot: (OVERLAY_SIZE / 2.0 * scale).round() as u32 })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(img: &CursorImage, x: u32, y: u32) -> [u8; 4] {
        let i = ((y * img.side + x) * 4) as usize;
        [img.rgba[i], img.rgba[i + 1], img.rgba[i + 2], img.rgba[i + 3]]
    }

    #[test]
    fn system_shapes_have_no_strokes() {
        assert!(render(DrawCursor::Arrow, 1.0).is_none());
        assert!(!DrawCursor::ResizeLeftRight.has_drawn_glyph());
    }

    #[test]
    fn every_drawn_shape_renders() {
        use DrawCursor::*;
        for c in [
            TrimIn,
            TrimOut,
            RippleIn,
            RippleOut,
            RateIn,
            RateOut,
            Roll,
            Slip,
            Slide,
            Razor,
            TrackSelect,
            DragCopy,
            ZoomIn,
        ] {
            assert!(c.has_drawn_glyph());
            let img = render(c, 2.0).unwrap();
            assert_eq!((img.side, img.hot), (48, 24));
            assert!(img.rgba.chunks(4).any(|p| p[3] == 255));
        }
    }

    #[test]
    fn trim_in_is_black_line_over_white_halo() {
        let img = render(DrawCursor::TrimIn, 1.0).unwrap();
        // the bar at x = 12 is black and opaque; a pixel beside it only the white halo
        assert_eq!(at(&img, 11, 9)[3], 255);
        assert!(at(&img, 11, 9)[0] < 90);
        assert!(at(&img, 13, 9)[3] > 200 && at(&img, 13, 9)[0] > 200);
        assert_eq!(at(&img, 0, 0)[3], 0);
    }

    #[test]
    fn trim_out_mirrors_trim_in_serifs() {
        let a = render(DrawCursor::TrimIn, 1.0).unwrap();
        let b = render(DrawCursor::TrimOut, 1.0).unwrap();
        assert!(at(&a, 15, 5)[3] > 0 && at(&b, 15, 5)[3] == 0);
        assert!(at(&b, 8, 5)[3] > 0 && at(&a, 8, 5)[3] == 0);
    }

    #[test]
    fn overlay_cursors_are_white_glyphs_with_a_dark_halo() {
        for c in [
            DrawCursor::Move,
            DrawCursor::OverlayRotate(45),
            DrawCursor::OverlayResize(0),
            DrawCursor::OverlayResize(90),
        ] {
            assert!(c.has_drawn_glyph() && c.is_overlay_glyph());
            let img = render(c, 2.0).unwrap();
            assert_eq!((img.side, img.hot), (52, 26));
            assert!(img.rgba.chunks(4).any(|p| p[3] == 255 && p[0] > 240), "{c:?} has white pixels");
            assert!(img.rgba.chunks(4).any(|p| p[3] > 100 && p[0] < 40), "{c:?} has dark halo pixels");
            assert_eq!(at(&img, 0, 0)[3], 0);
        }
    }

    #[test]
    fn horizontal_resize_arrow_fills_the_row_and_turns_with_the_angle() {
        let h = render(DrawCursor::OverlayResize(0), 1.0).unwrap();
        let v = render(DrawCursor::OverlayResize(90), 1.0).unwrap();
        // The double arrow reaches the left edge of the icon box along the middle row, and the top edge when turned.
        assert!(at(&h, 6, 13)[3] > 0 && at(&h, 13, 6)[3] == 0);
        assert!(at(&v, 13, 6)[3] > 0 && at(&v, 6, 13)[3] == 0);
    }
}
