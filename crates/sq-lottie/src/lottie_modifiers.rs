//! Path modifiers on cubic contours: round corners (Lottie `rd`) and the path conversion it needs.

use tiny_skia::{Path, PathBuilder, PathSegment, Point};

const KAPPA: f32 = 0.552_284_8;

/// One cubic bezier (a line is a cubic with its controls on the line).
#[derive(Clone, Copy)]
struct Cubic([Point; 4]);

struct Cont {
    segs: Vec<Cubic>,
    closed: bool,
}

fn pt(x: f32, y: f32) -> Point {
    Point::from_xy(x, y)
}

fn lerp(a: Point, b: Point, t: f32) -> Point {
    pt(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
}

fn dist(a: Point, b: Point) -> f32 {
    ((b.x - a.x).powi(2) + (b.y - a.y).powi(2)).sqrt()
}

fn line(a: Point, b: Point) -> Cubic {
    Cubic([a, lerp(a, b, 1.0 / 3.0), lerp(a, b, 2.0 / 3.0), b])
}

fn split(c: Cubic, t: f32) -> (Cubic, Cubic) {
    let [p0, p1, p2, p3] = c.0;
    let (a, b, d) = (lerp(p0, p1, t), lerp(p1, p2, t), lerp(p2, p3, t));
    let (e, f) = (lerp(a, b, t), lerp(b, d, t));
    let m = lerp(e, f, t);
    (Cubic([p0, a, e, m]), Cubic([m, f, d, p3]))
}

fn sub(c: Cubic, t0: f32, t1: f32) -> Cubic {
    let (_, right) = split(c, t0);
    if t0 >= 1.0 {
        return right;
    }
    split(right, ((t1 - t0) / (1.0 - t0)).clamp(0.0, 1.0)).0
}

/// Approximate length: the control polygon and the chord averaged.
fn length(c: Cubic) -> f32 {
    let [p0, p1, p2, p3] = c.0;
    (dist(p0, p1) + dist(p1, p2) + dist(p2, p3) + dist(p0, p3)) / 2.0
}

fn dir(from: Point, to: Point) -> Option<(f32, f32)> {
    let d = dist(from, to);
    (d > 1e-6).then(|| ((to.x - from.x) / d, (to.y - from.y) / d))
}

fn end_dir(c: Cubic) -> Option<(f32, f32)> {
    dir(c.0[2], c.0[3]).or_else(|| dir(c.0[1], c.0[3])).or_else(|| dir(c.0[0], c.0[3]))
}

fn start_dir(c: Cubic) -> Option<(f32, f32)> {
    dir(c.0[0], c.0[1]).or_else(|| dir(c.0[0], c.0[2])).or_else(|| dir(c.0[0], c.0[3]))
}

fn conts(path: &Path) -> Vec<Cont> {
    let mut out: Vec<Cont> = Vec::new();
    let mut cur: Vec<Cubic> = Vec::new();
    let (mut start, mut last) = (pt(0.0, 0.0), pt(0.0, 0.0));
    let flush = |cur: &mut Vec<Cubic>, closed: bool, out: &mut Vec<Cont>| {
        if !cur.is_empty() {
            out.push(Cont { segs: std::mem::take(cur), closed });
        }
    };
    for seg in path.segments() {
        match seg {
            PathSegment::MoveTo(p) => {
                flush(&mut cur, false, &mut out);
                start = p;
                last = p;
            }
            PathSegment::LineTo(p) => {
                cur.push(line(last, p));
                last = p;
            }
            PathSegment::QuadTo(c, p) => {
                cur.push(Cubic([last, lerp(last, c, 2.0 / 3.0), lerp(p, c, 2.0 / 3.0), p]));
                last = p;
            }
            PathSegment::CubicTo(c1, c2, p) => {
                cur.push(Cubic([last, c1, c2, p]));
                last = p;
            }
            PathSegment::Close => {
                if dist(last, start) > 1e-4 {
                    cur.push(line(last, start));
                }
                flush(&mut cur, true, &mut out);
                last = start;
            }
        }
    }
    flush(&mut cur, false, &mut out);
    out
}

fn build(conts: &[Cont]) -> Option<Path> {
    let mut pb = PathBuilder::new();
    for c in conts {
        let Some(first) = c.segs.first() else { continue };
        pb.move_to(first.0[0].x, first.0[0].y);
        for s in &c.segs {
            pb.cubic_to(s.0[1].x, s.0[1].y, s.0[2].x, s.0[2].y, s.0[3].x, s.0[3].y);
        }
        if c.closed {
            pb.close();
        }
    }
    pb.finish()
}

/// Rounds every corner (a join of two segments that are not tangent-continuous) with `radius`; the cut is at most half of
/// each neighboring segment. A radius of 0 returns the path unchanged.
pub fn round_corners(path: &Path, radius: f32) -> Option<Path> {
    if radius <= 0.0 {
        return Some(path.clone());
    }
    let mut out: Vec<Cont> = Vec::new();
    for c in conts(path) {
        let n = c.segs.len();
        let lens: Vec<f32> = c.segs.iter().map(|s| length(*s)).collect();
        // cut[k] = (distance cut from the start of segment k, distance cut from its end)
        let mut cut = vec![(0.0f32, 0.0f32); n];
        let corners: Vec<usize> = if c.closed { (0..n).collect() } else { (0..n.saturating_sub(1)).collect() };
        for &i in &corners {
            let j = (i + 1) % n;
            let (Some(a), Some(b)) = (end_dir(c.segs[i]), start_dir(c.segs[j])) else { continue };
            if (a.0 * b.0 + a.1 * b.1) > 0.9999 {
                continue;
            }
            let d = radius.min(lens[i] / 2.0).min(lens[j] / 2.0);
            cut[i].1 = d;
            cut[j].0 = d;
        }
        let mut segs: Vec<Cubic> = Vec::new();
        let mut trimmed: Vec<Cubic> = Vec::new();
        for k in 0..n {
            let l = lens[k].max(1e-6);
            trimmed.push(sub(c.segs[k], cut[k].0 / l, 1.0 - cut[k].1 / l));
        }
        for k in 0..n {
            segs.push(trimmed[k]);
            let j = (k + 1) % n;
            if (k + 1 < n || c.closed) && cut[k].1 > 0.0 {
                let (from, corner, to) = (trimmed[k].0[3], c.segs[k].0[3], trimmed[j].0[0]);
                segs.push(Cubic([from, lerp(from, corner, KAPPA), lerp(to, corner, KAPPA), to]));
            }
        }
        out.push(Cont { segs, closed: c.closed });
    }
    build(&out)
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use crate::lottie_geometry::rect;

    #[test]
    fn rounding_a_square_cuts_its_corner() {
        let sq = rect((50.0, 50.0), (100.0, 100.0), 0.0).unwrap();
        let r = round_corners(&sq, 20.0).unwrap();
        // The corner point (0,0) is no longer on the path; the bounds stay.
        let b = r.bounds();
        assert!((b.width() - 100.0).abs() < 0.01);
        let near_corner = r.points().iter().any(|p| p.x < 0.01 && p.y < 0.01);
        assert!(!near_corner);
    }
}
