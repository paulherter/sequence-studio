//! Lottie shape geometry: bezier paths, rectangles, ellipses, stars and trim paths, as tiny-skia paths.

use tiny_skia::{Path, PathBuilder, PathSegment, Point};

const KAPPA: f32 = 0.552_284_8;

/// A path from the flat form of `lottie_props::flat` (`[closed, n, v.., in.., out..]`).
pub fn path_from_flat(f: &[f64]) -> Option<Path> {
    let n = *f.get(1)? as usize;
    if n == 0 || f.len() < 2 + 6 * n {
        return None;
    }
    let v = |k: usize, c: usize| f[2 + k * 2 + c] as f32;
    let i = |k: usize, c: usize| f[2 + 2 * n + k * 2 + c] as f32;
    let o = |k: usize, c: usize| f[2 + 4 * n + k * 2 + c] as f32;
    let mut pb = PathBuilder::new();
    pb.move_to(v(0, 0), v(0, 1));
    let closed = f[0] >= 0.5;
    let segs = if closed { n } else { n - 1 };
    for k in 0..segs {
        let j = (k + 1) % n;
        pb.cubic_to(v(k, 0) + o(k, 0), v(k, 1) + o(k, 1), v(j, 0) + i(j, 0), v(j, 1) + i(j, 1), v(j, 0), v(j, 1));
    }
    if closed {
        pb.close();
    }
    pb.finish()
}

/// A rectangle with centre `p`, size `s` and corner radius `r`.
pub fn rect(p: (f32, f32), s: (f32, f32), r: f32) -> Option<Path> {
    let (hw, hh) = (s.0 / 2.0, s.1 / 2.0);
    let (l, t, rt, b) = (p.0 - hw, p.1 - hh, p.0 + hw, p.1 + hh);
    let r = r.min(hw).min(hh).max(0.0);
    let mut pb = PathBuilder::new();
    if r <= 0.0 {
        pb.move_to(l, t);
        pb.line_to(rt, t);
        pb.line_to(rt, b);
        pb.line_to(l, b);
        pb.close();
        return pb.finish();
    }
    let k = r * (1.0 - KAPPA);
    pb.move_to(l + r, t);
    pb.line_to(rt - r, t);
    pb.cubic_to(rt - k, t, rt, t + k, rt, t + r);
    pb.line_to(rt, b - r);
    pb.cubic_to(rt, b - k, rt - k, b, rt - r, b);
    pb.line_to(l + r, b);
    pb.cubic_to(l + k, b, l, b - k, l, b - r);
    pb.line_to(l, t + r);
    pb.cubic_to(l, t + k, l + k, t, l + r, t);
    pb.close();
    pb.finish()
}

/// An ellipse with centre `p` and size `s`.
pub fn ellipse(p: (f32, f32), s: (f32, f32)) -> Option<Path> {
    let (rx, ry) = (s.0 / 2.0, s.1 / 2.0);
    let (kx, ky) = (rx * KAPPA, ry * KAPPA);
    let mut pb = PathBuilder::new();
    pb.move_to(p.0, p.1 - ry);
    pb.cubic_to(p.0 + kx, p.1 - ry, p.0 + rx, p.1 - ky, p.0 + rx, p.1);
    pb.cubic_to(p.0 + rx, p.1 + ky, p.0 + kx, p.1 + ry, p.0, p.1 + ry);
    pb.cubic_to(p.0 - kx, p.1 + ry, p.0 - rx, p.1 + ky, p.0 - rx, p.1);
    pb.cubic_to(p.0 - rx, p.1 - ky, p.0 - kx, p.1 - ry, p.0, p.1 - ry);
    pb.close();
    pb.finish()
}

/// A star (`inner` is `Some`) or polygon with `points` corners, outer radius `outer`, rotated `rot_deg`. `outer_round` and
/// `inner_round` (0..1, Lottie `os` / `is` divided by 100) bend the corners the way lottie-web does: each vertex gets tangents
/// perpendicular to its radius, `roundness * 2 * pi * radius / vertices` long (a polygon uses 4 * points as the divisor).
pub fn star(
    c: (f32, f32),
    points: usize,
    outer: f32,
    inner: Option<f32>,
    rot_deg: f32,
    outer_round: f32,
    inner_round: f32,
) -> Option<Path> {
    let n = points.max(3);
    let steps = if inner.is_some() { n * 2 } else { n };
    let (mut v, mut tin, mut tout) = (Vec::new(), Vec::new(), Vec::new());
    for k in 0..steps {
        let (r, round) = match inner {
            Some(ir) if k % 2 == 1 => (ir, inner_round),
            _ => (outer, outer_round),
        };
        let a = (rot_deg - 90.0).to_radians() + std::f32::consts::TAU * k as f32 / steps as f32;
        let (cs, sn) = (a.cos(), a.sin());
        let seg = std::f32::consts::TAU * r / (if inner.is_some() { n * 2 } else { n * 4 }) as f32;
        let len = round * seg;
        // Forward direction for increasing angle is (-sin, cos).
        v.extend([f64::from(c.0 + r * cs), f64::from(c.1 + r * sn)]);
        tin.extend([f64::from(sn * len), f64::from(-cs * len)]);
        tout.extend([f64::from(-sn * len), f64::from(cs * len)]);
    }
    let mut flat = vec![1.0, steps as f64];
    flat.extend(v);
    flat.extend(tin);
    flat.extend(tout);
    path_from_flat(&flat)
}

/// A contour as a polyline.
struct Contour {
    pts: Vec<Point>,
    closed: bool,
}

fn lerp(a: Point, b: Point, t: f32) -> Point {
    Point::from_xy(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
}

fn contours(path: &Path) -> Vec<Contour> {
    const STEPS: usize = 24;
    let mut out: Vec<Contour> = Vec::new();
    let mut cur: Vec<Point> = Vec::new();
    let mut last = Point::from_xy(0.0, 0.0);
    let flush = |cur: &mut Vec<Point>, closed: bool, out: &mut Vec<Contour>| {
        if cur.len() > 1 {
            out.push(Contour { pts: std::mem::take(cur), closed });
        } else {
            cur.clear();
        }
    };
    for seg in path.segments() {
        match seg {
            PathSegment::MoveTo(p) => {
                flush(&mut cur, false, &mut out);
                cur.push(p);
                last = p;
            }
            PathSegment::LineTo(p) => {
                cur.push(p);
                last = p;
            }
            PathSegment::QuadTo(c, p) => {
                for s in 1..=STEPS {
                    let t = s as f32 / STEPS as f32;
                    cur.push(lerp(lerp(last, c, t), lerp(c, p, t), t));
                }
                last = p;
            }
            PathSegment::CubicTo(c1, c2, p) => {
                for s in 1..=STEPS {
                    let t = s as f32 / STEPS as f32;
                    let (a, b, c) = (lerp(last, c1, t), lerp(c1, c2, t), lerp(c2, p, t));
                    cur.push(lerp(lerp(a, b, t), lerp(b, c, t), t));
                }
                last = p;
            }
            PathSegment::Close => {
                if let Some(first) = cur.first().copied() {
                    cur.push(first);
                }
                flush(&mut cur, true, &mut out);
            }
        }
    }
    flush(&mut cur, false, &mut out);
    out
}

fn dist(a: Point, b: Point) -> f32 {
    ((b.x - a.x).powi(2) + (b.y - a.y).powi(2)).sqrt()
}

/// The part of `pts` between arc lengths `from` and `to`.
fn slice(pts: &[Point], from: f32, to: f32, pb: &mut PathBuilder) {
    let mut acc = 0.0;
    let mut started = false;
    for w in pts.windows(2) {
        let len = dist(w[0], w[1]);
        let (s, e) = (acc, acc + len);
        acc = e;
        if len <= 0.0 || e < from || s > to {
            continue;
        }
        let a = lerp(w[0], w[1], ((from - s) / len).clamp(0.0, 1.0));
        let b = lerp(w[0], w[1], ((to - s) / len).clamp(0.0, 1.0));
        if !started {
            pb.move_to(a.x, a.y);
            started = true;
        }
        pb.line_to(b.x, b.y);
    }
}

/// Trim paths: the part of every contour between `start` and `end` (0..1 of its length), moved by `offset` (turns).
/// A range that wraps past the end continues at the start of a closed contour.
pub fn trim(path: &Path, start: f32, end: f32, offset: f32) -> Option<Path> {
    let (mut a, mut b) = (start + offset, end + offset);
    if a > b {
        std::mem::swap(&mut a, &mut b);
    }
    let mut pb = PathBuilder::new();
    for c in contours(path) {
        let total: f32 = c.pts.windows(2).map(|w| dist(w[0], w[1])).sum();
        if total <= 0.0 {
            continue;
        }
        if b - a >= 1.0 {
            slice(&c.pts, 0.0, total, &mut pb);
            continue;
        }
        let a0 = a - a.floor();
        let b0 = a0 + (b - a);
        if b0 <= 1.0 || !c.closed {
            slice(&c.pts, a0 * total, b0.min(1.0) * total, &mut pb);
        } else {
            slice(&c.pts, a0 * total, total, &mut pb);
            slice(&c.pts, 0.0, (b0 - 1.0) * total, &mut pb);
        }
    }
    pb.finish()
}

/// Trim paths in "individually" mode: all contours of all `paths` count as one continuous line, and the range
/// `start..end` (+ `offset`, in turns) of that total length is kept.
pub fn trim_individually(paths: &[Path], start: f32, end: f32, offset: f32) -> Option<Path> {
    let (mut a, mut b) = (start + offset, end + offset);
    if a > b {
        std::mem::swap(&mut a, &mut b);
    }
    let all: Vec<Contour> = paths.iter().flat_map(contours).collect();
    let lens: Vec<f32> = all.iter().map(|c| c.pts.windows(2).map(|w| dist(w[0], w[1])).sum()).collect();
    let total: f32 = lens.iter().sum();
    if total <= 0.0 {
        return None;
    }
    let mut ranges: Vec<(f32, f32)> = Vec::new();
    if b - a >= 1.0 {
        ranges.push((0.0, 1.0));
    } else {
        let a0 = a - a.floor();
        let b0 = a0 + (b - a);
        ranges.push((a0, b0.min(1.0)));
        if b0 > 1.0 {
            ranges.push((0.0, b0 - 1.0));
        }
    }
    let mut pb = PathBuilder::new();
    let mut at = 0.0;
    for (c, len) in all.iter().zip(&lens) {
        for (r0, r1) in &ranges {
            let (from, to) = ((r0 * total - at).max(0.0), (r1 * total - at).min(*len));
            if to > from {
                slice(&c.pts, from, to, &mut pb);
            }
        }
        at += len;
    }
    pb.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trim_half_of_a_square_outline() {
        let sq = rect((50.0, 50.0), (100.0, 100.0), 0.0).unwrap_or_else(unreachable_path);
        let t = trim(&sq, 0.0, 0.5, 0.0).unwrap_or_else(unreachable_path);
        let b = t.bounds();
        // Half the perimeter of a 100 square from the top left: the top and the right side.
        assert!((b.width() - 100.0).abs() < 0.5 && (b.height() - 100.0).abs() < 0.5);
        let t = trim(&sq, 0.0, 0.25, 0.0).unwrap_or_else(unreachable_path);
        assert!(t.bounds().height() < 0.5);
    }

    #[test]
    fn individually_trims_across_two_lines() {
        let line = |y: f32| {
            let mut pb = PathBuilder::new();
            pb.move_to(0.0, y);
            pb.line_to(100.0, y);
            pb.finish().unwrap_or_else(unreachable_path)
        };
        // 0..50 % of 200 px of total length: the whole first line, nothing of the second.
        let t = trim_individually(&[line(0.0), line(50.0)], 0.0, 0.5, 0.0).unwrap_or_else(unreachable_path);
        assert!((t.bounds().width() - 100.0).abs() < 0.5 && t.bounds().height() < 0.5);
        let t = trim_individually(&[line(0.0), line(50.0)], 0.25, 0.75, 0.0).unwrap_or_else(unreachable_path);
        assert!((t.bounds().height() - 50.0).abs() < 0.5 && (t.bounds().width() - 100.0).abs() < 0.5);
    }

    fn unreachable_path() -> Path {
        PathBuilder::from_rect(
            tiny_skia::Rect::from_xywh(0.0, 0.0, 1.0, 1.0)
                .unwrap_or(tiny_skia::Rect::from_ltrb(0.0, 0.0, 1.0, 1.0).unwrap_or_else(|| panic!("rect"))),
        )
    }
}
