// Swift: ShellMascot.swift
//! Pip's still poses on the draw canvas (portable port of the Mac `SQMascotArt`, which is CoreGraphics). Curves are
//! flattened to polygons, the head gradient is drawn as horizontal slabs. Used by the export queue rows and the dialog
//! footer, and animated by [`crate::shell_mascot_stage::ShellMascotStage`] (lens, floating marks, squeezed eyes for blinks,
//! round caps).
//!
//! Mapping: Swift's static `markOverride` (the empty-state mascot's neutral sleep marks) is the `violet` argument of the
//! `*_with_marks` entry points.

use sq_draw::{Canvas, Color};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqmascot_model::{SQMascotAnim, SQMascotKey, SQMascotLibrary, SQMascotPose, SQMascotShape};
use std::f64::consts::PI;

/// An affine transform (CoreGraphics order).
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Aff {
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    tx: f64,
    ty: f64,
}

impl Aff {
    const IDENTITY: Aff = Aff { a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0 };

    /// `self` followed by `m` applied first to a point (CoreGraphics `concatenating` order of translate/rotate/scale calls).
    pub(crate) fn concat(self, m: Aff) -> Aff {
        Aff {
            a: self.a * m.a + self.c * m.b,
            b: self.b * m.a + self.d * m.b,
            c: self.a * m.c + self.c * m.d,
            d: self.b * m.c + self.d * m.d,
            tx: self.a * m.tx + self.c * m.ty + self.tx,
            ty: self.b * m.tx + self.d * m.ty + self.ty,
        }
    }

    pub(crate) fn move_by(x: f64, y: f64) -> Aff {
        Aff { tx: x, ty: y, ..Aff::IDENTITY }
    }

    pub(crate) fn scale(x: f64, y: f64) -> Aff {
        Aff { a: x, d: y, ..Aff::IDENTITY }
    }

    fn rotate(deg: f64) -> Aff {
        let r = deg * PI / 180.0;
        Aff { a: r.cos(), b: r.sin(), c: -r.sin(), d: r.cos(), tx: 0.0, ty: 0.0 }
    }

    fn apply(&self, p: CGPoint) -> CGPoint {
        CGPoint::new(self.a * p.x + self.c * p.y + self.tx, self.b * p.x + self.d * p.y + self.ty)
    }

    fn mean_scale(&self) -> f64 {
        (self.a * self.d - self.b * self.c).abs().sqrt()
    }
}

/// A path in art space, flattened while building.
#[derive(Clone, Debug, Default)]
pub(crate) struct Path {
    pts: Vec<CGPoint>,
    cur: CGPoint,
}

impl Path {
    const STEPS: usize = 10;

    pub(crate) fn new() -> Path {
        Path::default()
    }

    pub(crate) fn move_to(&mut self, x: f64, y: f64) {
        self.cur = CGPoint::new(x, y);
        self.pts = vec![self.cur];
    }

    pub(crate) fn line(&mut self, x: f64, y: f64) {
        self.cur = CGPoint::new(x, y);
        self.pts.push(self.cur);
    }

    pub(crate) fn quad(&mut self, cx: f64, cy: f64, x: f64, y: f64) {
        let p0 = self.cur;
        for i in 1..=Self::STEPS {
            let t = i as f64 / Self::STEPS as f64;
            let u = 1.0 - t;
            self.pts.push(CGPoint::new(
                u * u * p0.x + 2.0 * u * t * cx + t * t * x,
                u * u * p0.y + 2.0 * u * t * cy + t * t * y,
            ));
        }
        self.cur = CGPoint::new(x, y);
    }

    pub(crate) fn cubic(&mut self, c1x: f64, c1y: f64, c2x: f64, c2y: f64, x: f64, y: f64) {
        let p0 = self.cur;
        for i in 1..=Self::STEPS {
            let t = i as f64 / Self::STEPS as f64;
            let u = 1.0 - t;
            let (w0, w1, w2, w3) = (u * u * u, 3.0 * u * u * t, 3.0 * u * t * t, t * t * t);
            self.pts
                .push(CGPoint::new(w0 * p0.x + w1 * c1x + w2 * c2x + w3 * x, w0 * p0.y + w1 * c1y + w2 * c2y + w3 * y));
        }
        self.cur = CGPoint::new(x, y);
    }

    pub(crate) fn ellipse(cx: f64, cy: f64, rx: f64, ry: f64) -> Path {
        let mut p = Path::new();
        for i in 0..28 {
            let a = i as f64 / 28.0 * 2.0 * PI;
            p.pts.push(CGPoint::new(cx + rx * a.cos(), cy + ry * a.sin()));
        }
        p
    }

    pub(crate) fn rounded_rect(r: CGRect, radius: f64) -> Path {
        let mut p = Path::new();
        let rad = radius.min(r.width.min(r.height) / 2.0);
        let corners = [
            (r.max_x() - rad, r.min_y() + rad, -90.0),
            (r.max_x() - rad, r.max_y() - rad, 0.0),
            (r.min_x() + rad, r.max_y() - rad, 90.0),
            (r.min_x() + rad, r.min_y() + rad, 180.0),
        ];
        for (cx, cy, start) in corners {
            for i in 0..=6 {
                let a = (start + i as f64 / 6.0 * 90.0) * PI / 180.0;
                p.pts.push(CGPoint::new(cx + rad * a.cos(), cy + rad * a.sin()));
            }
        }
        p
    }

    fn heart(cx: f64, cy: f64, s: f64) -> Path {
        let mut p = Path::new();
        p.move_to(cx, cy + 52.0 * s);
        p.cubic(cx - 92.0 * s, cy - 8.0 * s, cx - 54.0 * s, cy - 82.0 * s, cx, cy - 34.0 * s);
        p.cubic(cx + 54.0 * s, cy - 82.0 * s, cx + 92.0 * s, cy - 8.0 * s, cx, cy + 52.0 * s);
        p
    }
}

fn head_top() -> Color {
    Color::hex(0xFFFFFF, 1.0)
}
fn head_bottom() -> Color {
    Color::hex(0xC3C9D9, 1.0)
}
fn ink() -> Color {
    Color::hex(0x17171B, 1.0)
}
fn head_edge() -> Color {
    Color::hex(0x8D93A8, 0.6)
}
fn arm_edge() -> Color {
    Color::hex(0x8D93A8, 0.75)
}
fn cheek() -> Color {
    Color::hex(0xFF8FA3, 1.0)
}
fn tongue() -> Color {
    Color::hex(0xFF7389, 1.0)
}
fn drop_color() -> Color {
    Color::hex(0x58AEF7, 1.0)
}
fn lens_fill() -> Color {
    Color::hex(0xDFE6FF, 1.0)
}
fn spark() -> Color {
    Color::hex(0xF7B23B, 1.0)
}
fn heart_color() -> Color {
    Color::hex(0xF2577F, 1.0)
}
fn ok() -> Color {
    Color::hex(0x30C463, 1.0)
}

/// The violet of the floating marks.
pub(crate) fn brand_violet() -> Color {
    Color::hex(0xA48CF0, 1.0)
}

/// The gray the empty-state mascot's sleep marks take instead of violet (the approved design has no violet).
pub fn neutral_mark() -> Color {
    Color::hex(0x8A8A8E, 1.0)
}

/// Pip's still poses on the canvas.
pub struct ShellMascot;

impl ShellMascot {
    /// Draws the still of `anim` aspect-fitted and centered in `rect` (window points).
    pub fn draw(anim: SQMascotAnim, rect: CGRect, c: &mut Canvas) {
        Self::draw_with_marks(anim, rect, c, brand_violet());
    }

    /// [`ShellMascot::draw`] with the marks (sleep Zs, dots) in `violet`.
    pub fn draw_with_marks(anim: SQMascotAnim, rect: CGRect, c: &mut Canvas, violet: Color) {
        let a = SQMascotLibrary::shared().animation(anim);
        let side = rect.width.min(rect.height);
        let (mut tight, mut vb) = (a.tight, a.view_box);
        if side <= 24.0 {
            tight = true;
            vb = CGRect::new(125.0, 268.0, 774.0, 774.0);
        }
        Self::draw_pose(&a.still, tight, vb, rect, c, violet);
    }

    pub(crate) fn draw_pose(p: &SQMascotPose, tight: bool, vb: CGRect, rect: CGRect, c: &mut Canvas, violet: Color) {
        use SQMascotKey as K;
        if p[K::Hide] >= 0.5 {
            return;
        }
        let s = rect.width.min(rect.height) / vb.width.max(vb.height);
        let ox = rect.mid_x() - vb.width * s / 2.0 - vb.min_x() * s;
        let oy = rect.mid_y() - vb.height * s / 2.0 - vb.min_y() * s;
        let base = Aff::move_by(ox, oy).concat(Aff::scale(s, s));
        let mut m = base;
        m = m
            .concat(Aff::move_by(p[K::Tx], p[K::Ty]))
            .concat(Aff::move_by(512.0, 653.0))
            .concat(Aff::rotate(p[K::Rot]))
            .concat(Aff::move_by(-512.0, -653.0));
        m = m
            .concat(Aff::move_by(512.0, 1026.0))
            .concat(Aff::scale(p[K::Sx], p[K::Sy]))
            .concat(Aff::move_by(-512.0, -1026.0));
        let g = Gfx { m };
        let edge = if tight { 10.0 } else { 8.0 };
        if !tight && p[K::HL] > 3.0 {
            let h = Gfx {
                m: m.concat(Aff::move_by(824.0, 742.0))
                    .concat(Aff::rotate(p[K::Hd]))
                    .concat(Aff::move_by(-824.0, -742.0)),
            };
            let arm = Path::rounded_rect(CGRect::new(777.0, 742.0 - p[K::HL] - 47.0, 94.0, p[K::HL] + 94.0), 47.0);
            h.gradient(&arm, c);
            h.stroke(&arm, 8.0, arm_edge(), true, c);
        }
        let head = head_path();
        g.gradient(&head, c);
        g.stroke(&head, edge, head_edge(), true, c);
        if p[K::Dps] > 0.03 {
            let mut d = Path::new();
            let k = 48.0 * 0.5523;
            d.move_to(0.0, 0.0);
            d.cubic(0.0, 0.0, -48.0, 66.0, -48.0, 100.0);
            d.cubic(-48.0, 100.0 + k, -k, 148.0, 0.0, 148.0);
            d.cubic(k, 148.0, 48.0, 100.0 + k, 48.0, 100.0);
            d.cubic(48.0, 66.0, 0.0, 0.0, 0.0, 0.0);
            Gfx { m: m.concat(Aff::move_by(p[K::Dpx], p[K::Dpy])).concat(Aff::scale(p[K::Dps], p[K::Dps])) }.fill(
                &d,
                drop_color(),
                c,
            );
        }
        face(p, &Gfx { m: m.concat(Aff::move_by(p[K::Fx], p[K::Fy])) }, c);
        if !tight && p[K::Mgs] > 0.03 {
            lens(p, &g, violet, c);
        }
        if !tight {
            marks(p, &Gfx { m: base }, violet, c);
        }
    }
}

fn lens(p: &SQMascotPose, g: &Gfx, violet: Color, c: &mut Canvas) {
    use SQMascotKey as K;
    let lg = Gfx { m: g.m.concat(Aff::move_by(p[K::Mgx], p[K::Mgy])).concat(Aff::scale(p[K::Mgs], p[K::Mgs])) };
    let circle = Path::ellipse(0.0, 0.0, 70.0, 70.0);
    lg.fill(&circle, lens_fill().with_alpha(p[K::Mgo].clamp(0.0, 1.0) as f32), c);
    lg.stroke(&circle, 30.0, violet, true, c);
    let mut h = Path::new();
    h.move_to(54.0, 54.0);
    h.line(114.0, 114.0);
    lg.stroke(&h, 36.0, violet, false, c);
}

/// Badge, dots, Zs, sparkles and hearts: drawn outside the head's transform.
fn marks(p: &SQMascotPose, g: &Gfx, violet: Color, c: &mut Canvas) {
    use SQMascotKey as K;
    let at = |x: f64, y: f64, k: f64| Gfx { m: g.m.concat(Aff::move_by(x, y)).concat(Aff::scale(k, k)) };
    let disc = |x: f64, y: f64, r: f64, col: Color, c: &mut Canvas| g.fill(&Path::ellipse(x, y, r, r), col, c);
    if p[K::Bs] > 0.03 {
        let b = at(868.0, 968.0, p[K::Bs]);
        b.fill(&Path::ellipse(0.0, 0.0, 86.0, 86.0), ok(), c);
        let mut t = Path::new();
        t.move_to(-40.0, 0.0);
        t.line(-12.0, 30.0);
        t.line(42.0, -32.0);
        b.stroke(&t, 26.0, head_top(), false, c);
    }
    let dots = [(742.0, 228.0, 21.0, K::D1), (812.0, 220.0, 26.0, K::D2), (890.0, 228.0, 21.0, K::D3)];
    for d in dots.iter().filter(|d| p[d.3] > 0.03) {
        disc(d.0, d.1, d.2 * p[d.3], violet, c);
    }
    let zs =
        [(716.0, 214.0, 40.0, K::Z1, K::Z1y), (800.0, 236.0, 56.0, K::Z2, K::Z2y), (898.0, 196.0, 36.0, K::Z3, K::Z3y)];
    for z in zs.iter().filter(|z| p[z.3] > 0.03) {
        let q = z.2;
        let mut zp = Path::new();
        zp.move_to(-q / 2.0, -q * 0.575);
        zp.line(q / 2.0, -q * 0.575);
        zp.line(-q / 2.0, q * 0.575);
        zp.line(q / 2.0, q * 0.575);
        at(z.0 + q / 2.0, z.1 + q * 0.575 + p[z.4], p[z.3]).stroke(&zp, (q * 0.26).max(12.0), violet, false, c);
    }
    if p[K::Sp] > 0.03 {
        let k = p[K::Sp];
        let star = |x: f64, y: f64, r: f64, c: &mut Canvas| {
            let mut sp = Path::new();
            sp.move_to(0.0, -r);
            sp.quad(0.0, 0.0, r, 0.0);
            sp.quad(0.0, 0.0, 0.0, r);
            sp.quad(0.0, 0.0, -r, 0.0);
            sp.quad(0.0, 0.0, 0.0, -r);
            at(x, y, k).fill(&sp, spark(), c);
        };
        star(150.0, 262.0, 58.0, c);
        star(900.0, 330.0, 40.0, c);
        star(96.0, 560.0, 30.0, c);
        disc(930.0, 560.0, 17.0 * k, heart_color(), c);
        disc(215.0, 1010.0, 15.0 * k, violet, c);
        disc(880.0, 930.0, 13.0 * k, spark(), c);
    }
    if p[K::H1] > 0.03 {
        g.fill(&Path::heart(884.0, 250.0, 0.62 * p[K::H1]), heart_color(), c);
    }
    if p[K::H2] > 0.03 {
        g.fill(&Path::heart(150.0, 330.0, 0.4 * p[K::H2]), heart_color(), c);
    }
}

/// The mascot's head outline in art space.
pub(crate) fn head_path() -> Path {
    let mut p = Path::new();
    p.move_to(261.0, 280.0);
    p.line(763.0, 280.0);
    p.cubic(842.4, 280.0, 887.0, 324.6, 887.0, 404.0);
    p.line(887.0, 730.0);
    p.cubic(887.0, 777.9, 851.6, 814.1, 812.0, 844.0);
    p.line(605.8, 1000.0);
    p.cubic(559.5, 1035.0, 464.5, 1035.0, 418.2, 1000.0);
    p.line(212.0, 844.0);
    p.cubic(172.4, 814.1, 137.0, 777.9, 137.0, 730.0);
    p.line(137.0, 404.0);
    p.cubic(137.0, 324.6, 181.6, 280.0, 261.0, 280.0);
    p
}

/// Drawing under a transform.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Gfx {
    pub(crate) m: Aff,
}

impl Gfx {
    pub(crate) fn map(&self, p: &Path) -> Vec<CGPoint> {
        p.pts.iter().map(|q| self.m.apply(*q)).collect()
    }

    /// `self` scaled about the art point (x, y).
    fn squeezed(&self, x: f64, y: f64, sx: f64, sy: f64) -> Gfx {
        Gfx { m: self.m.concat(Aff::move_by(x, y)).concat(Aff::scale(sx, sy)).concat(Aff::move_by(-x, -y)) }
    }

    pub(crate) fn fill(&self, p: &Path, col: Color, c: &mut Canvas) {
        c.fill_polygon(&self.map(p), col);
    }

    pub(crate) fn stroke(&self, p: &Path, width: f64, col: Color, closed: bool, c: &mut Canvas) {
        let pts = self.map(p);
        let w = (width * self.m.mean_scale()).max(0.75);
        if closed {
            c.stroke_polygon(&pts, w, col);
        } else {
            c.stroke_polyline(&pts, w, col);
            for e in [pts.first(), pts.last()].into_iter().flatten() {
                c.fill_ellipse(CGRect::new(e.x - w / 2.0, e.y - w / 2.0, w, w), col);
            }
        }
    }

    /// The head gradient (art y 280...1046) as horizontal slabs of the polygon.
    pub(crate) fn gradient(&self, p: &Path, c: &mut Canvas) {
        let pts = self.map(p);
        let Some(lo) = pts.iter().map(|q| q.y).reduce(f64::min) else { return };
        let Some(hi) = pts.iter().map(|q| q.y).reduce(f64::max) else { return };
        let n = 2.max(24.min(((hi - lo) / 1.5) as i64)) as usize;
        let top = self.m.apply(CGPoint::new(0.0, 280.0)).y;
        let bottom = self.m.apply(CGPoint::new(0.0, 1046.0)).y;
        let (t0, t1) = (head_top(), head_bottom());
        for i in 0..n {
            let y0 = lo + (hi - lo) * i as f64 / n as f64;
            let y1 = lo + (hi - lo) * (i + 1) as f64 / n as f64 + if i == n - 1 { 0.0 } else { 0.6 };
            let mid = (y0 + y1) / 2.0;
            let t = ((mid - top) / (bottom - top).max(0.001)).clamp(0.0, 1.0) as f32;
            let col = Color::rgb(t0.r + (t1.r - t0.r) * t, t0.g + (t1.g - t0.g) * t, t0.b + (t1.b - t0.b) * t);
            let slab = Self::clip(&pts, y0, y1);
            if slab.len() >= 3 {
                c.fill_polygon(&slab, col);
            }
        }
    }

    /// Sutherland-Hodgman against the band y0...y1.
    pub(crate) fn clip(poly: &[CGPoint], y0: f64, y1: f64) -> Vec<CGPoint> {
        fn cut(pts: &[CGPoint], keep: impl Fn(CGPoint) -> bool, y: f64) -> Vec<CGPoint> {
            let mut out = Vec::new();
            for i in 0..pts.len() {
                let a = pts[i];
                let b = pts[(i + 1) % pts.len()];
                let (ia, ib) = (keep(a), keep(b));
                if ia {
                    out.push(a);
                }
                if ia != ib {
                    let t = (y - a.y) / (b.y - a.y);
                    out.push(CGPoint::new(a.x + (b.x - a.x) * t, y));
                }
            }
            out
        }
        let r = cut(poly, |p| p.y >= y0, y0);
        if r.is_empty() { Vec::new() } else { cut(&r, |p| p.y <= y1, y1) }
    }
}

fn face(p: &SQMascotPose, g: &Gfx, c: &mut Canvas) {
    use SQMascotKey as K;
    if p[K::Bl] > 0.0 {
        let a = p[K::Bl].min(1.0) as f32;
        for x in [286.0 - p[K::Bldx], 738.0 + p[K::Bldx]] {
            g.fill(&Path::ellipse(x, p[K::Bly], 50.0, 30.0), cheek().with_alpha(a), c);
        }
    }
    let xl = 384.5 + p[K::Ex] - p[K::Esp];
    let xr = 639.5 + p[K::Ex] + p[K::Esp];
    let eye_k = |e: &SQMascotShape, k: f64| (if e.kind == "pill" || e.kind == "rpill" { p.blink } else { 1.0 }) * k;
    eye(g, xl, 1.0, &p.e_l, p[K::Ey], eye_k(&p.e_l, p.k_eye_l), c);
    eye(g, xr, -1.0, &p.e_r, p[K::Ey], eye_k(&p.e_r, p.k_eye_r), c);
    for (x0, s, a) in [(xl, 1.0, p[K::BaL]), (xr, -1.0, p[K::BaR])] {
        if a < 0.06 {
            continue;
        }
        let mm = a.min(1.0);
        let x = x0 + s * p[K::Bdx];
        let hl = p[K::Bhl] * mm;
        let t = p[K::Btilt] * mm;
        let cy = p[K::Bcy];
        let mut b = Path::new();
        b.move_to(x - s * hl, cy + t);
        b.quad(x, cy - p[K::Bbow] * mm, x + s * hl, cy - t);
        g.stroke(&b, p[K::Bsw] * (0.6 + 0.4 * mm), ink(), false, c);
    }
    mouth(g, &p.m, p.k_mouth, c);
}

fn eye(g0: &Gfx, x: f64, side: f64, e: &SQMascotShape, ey: f64, k: f64, c: &mut Canvas) {
    let v = |i: usize| e.a.get(i).copied().unwrap_or(0.0);
    let s = side;
    let mut g = *g0;
    match e.kind.as_str() {
        "pill" | "rpill" => {} // squeezed in height below
        "up" | "dn" => {
            let cy = v(2) + ey + (if e.kind == "up" { -1.0 } else { 1.0 }) * v(1) * 0.4;
            if k < 0.995 {
                g = g0.squeezed(x, cy, 0.6 + 0.4 * k, k.max(0.1));
            }
        }
        "chev" | "heart" => {
            if k < 0.995 {
                g = g0.squeezed(x, v(0) + ey, 0.6 + 0.4 * k, k.max(0.1));
            }
        }
        _ => {
            if k < 0.995 {
                g = g0.squeezed(x, v(1) + ey, 0.6 + 0.4 * k, k.max(0.1));
            }
        }
    }
    match e.kind.as_str() {
        "pill" | "rpill" => {
            let w = v(0);
            let mut h = v(1);
            let mut cy = v(2) + ey;
            if k < 0.995 {
                let lo = h.min(30.0);
                let h2 = lo + (h - lo) * k;
                cy += (h - h2) * 0.12;
                h = h2;
            }
            let mut gg = g;
            if e.kind == "rpill" {
                gg.m = g.m.concat(Aff::move_by(x, cy)).concat(Aff::rotate(v(3) * s)).concat(Aff::move_by(-x, -cy));
            }
            gg.fill(&Path::rounded_rect(CGRect::new(x - w / 2.0, cy - h / 2.0, w, h), w.min(h) / 2.0), ink(), c);
        }
        "up" | "dn" => {
            let dir = if e.kind == "up" { -1.0 } else { 1.0 };
            let top = v(2) + ey;
            let mut p = Path::new();
            p.move_to(x - v(0), top);
            p.quad(x, top + dir * v(1), x + v(0), top);
            g.stroke(&p, v(3), ink(), false, c);
        }
        "chev" => {
            let cy = v(0) + ey;
            let mut p = Path::new();
            p.move_to(x - s * 50.0, cy - 56.0);
            p.line(x + s * 44.0, cy);
            p.line(x - s * 50.0, cy + 56.0);
            g.stroke(&p, 40.0, ink(), false, c);
        }
        "heart" => g.fill(&Path::heart(x, v(0) + ey, v(1)), ink(), c),
        _ => {
            let mut p = Path::new();
            let cy = v(1) + ey;
            p.move_to(x - v(0), cy);
            p.line(x + v(0), cy);
            g.stroke(&p, v(2), ink(), false, c);
        }
    }
}

fn mouth(g0: &Gfx, m: &SQMascotShape, k: f64, c: &mut Canvas) {
    let v = |i: usize| m.a.get(i).copied().unwrap_or(0.0);
    let mut g = *g0;
    if k < 0.995 {
        let ctr = match m.kind.as_str() {
            "smile" => ((v(0) + v(1)) / 2.0, v(2) + v(3) / 2.0),
            "open" => (v(0), v(1) + v(3) / 2.0),
            "o" => (v(0), v(1)),
            "wavy" => (512.0, v(0)),
            _ => (512.0, 795.0),
        };
        let q = 0.45 + 0.55 * k;
        g = g0.squeezed(ctr.0, ctr.1, q, q);
    }
    match m.kind.as_str() {
        "smile" => {
            let mut p = Path::new();
            p.move_to(v(0), v(2));
            p.quad((v(0) + v(1)) / 2.0, v(2) + v(3), v(1), v(2));
            g.stroke(&p, v(4), ink(), false, c);
        }
        "open" => {
            let (x, y, w, h) = (v(0), v(1), v(2), v(3));
            let (x0, x1) = (x - w / 2.0, x + w / 2.0);
            let mut p = Path::new();
            p.move_to(x0, y);
            p.line(x1, y);
            p.quad(x1, y + h, x, y + h);
            p.quad(x0, y + h, x0, y);
            g.fill(&p, ink(), c);
            g.stroke(&p, 22.0, ink(), true, c);
            if v(4) != 0.0 {
                let mut t = Path::new();
                t.move_to(x - w * 0.27, y + h * 0.74);
                t.quad(x, y + h * 0.42, x + w * 0.27, y + h * 0.74);
                t.quad(x + w * 0.14, y + h + 4.0, x, y + h + 4.0);
                t.quad(x - w * 0.14, y + h + 4.0, x - w * 0.27, y + h * 0.74);
                g.fill(&t, tongue(), c);
            }
        }
        "o" => g.fill(&Path::ellipse(v(0), v(1), v(2), v(3)), ink(), c),
        "wavy" => {
            let y = v(0);
            let mut p = Path::new();
            p.move_to(436.0, y);
            p.quad(461.0, y - 32.0, 486.0, y);
            p.quad(511.0, y + 32.0, 537.0, y);
            p.quad(563.0, y - 32.0, 588.0, y);
            g.stroke(&p, 30.0, ink(), false, c);
        }
        _ => {
            let mut p = Path::new();
            p.move_to(452.0, 790.0);
            p.quad(512.0, 812.0, 572.0, 790.0);
            g.stroke(&p, 33.0, ink(), false, c);
            let x0 = 548.0 + v(0);
            let mut t = Path::new();
            t.move_to(x0, 800.0);
            t.line(x0 + 60.0, 800.0);
            t.line(x0 + 60.0, 816.0);
            t.cubic(x0 + 60.0, 816.0 + 16.5, x0 + 30.0 + 16.5, 846.0, x0 + 30.0, 846.0);
            t.cubic(x0 + 30.0 - 16.5, 846.0, x0, 816.0 + 16.5, x0, 816.0);
            g.fill(&t, tongue(), c);
            g.stroke(&t, 12.0, ink(), true, c);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn quads(pose: &SQMascotPose, tight: bool) -> usize {
        let mut c = Canvas::with_size(200.0, 200.0, None, 1.0);
        ShellMascot::draw_pose(
            pose,
            tight,
            CGRect::new(0.0, 0.0, 1024.0, 1024.0),
            CGRect::new(0.0, 0.0, 200.0, 200.0),
            &mut c,
            brand_violet(),
        );
        c.list.quads().len()
    }

    fn base() -> SQMascotPose {
        SQMascotLibrary::shared().animation(SQMascotAnim::Work).still.clone()
    }

    fn with(p: &SQMascotPose, k: SQMascotKey, v: f64) -> SQMascotPose {
        let mut q = p.clone();
        q[k] = v;
        q
    }

    #[test]
    fn the_lens_appears_only_when_it_has_size_and_not_in_tight_mode() {
        let mut p = base();
        p[SQMascotKey::Mgs] = 0.0;
        let without = quads(&p, false);
        p[SQMascotKey::Mgs] = 1.0;
        p[SQMascotKey::Mgx] = 600.0;
        p[SQMascotKey::Mgy] = 600.0;
        p[SQMascotKey::Mgo] = 0.8;
        assert!(quads(&p, false) > without);
        assert_eq!(quads(&p, true), quads(&with(&p, SQMascotKey::Mgs, 0.0), true));
    }

    #[test]
    fn floating_marks_appear_outside_tight_mode() {
        use SQMascotKey as K;
        let mut p = base();
        for k in [K::Bs, K::D1, K::D2, K::D3, K::Z1, K::Z2, K::Z3, K::Sp, K::H1, K::H2] {
            p[k] = 0.0;
        }
        let none = quads(&p, false);
        for k in [K::Bs, K::D1, K::Z1, K::Sp, K::H1] {
            let q = with(&p, k, 1.0);
            assert!(quads(&q, false) > none, "{k:?}");
            assert_eq!(quads(&q, true), quads(&p, true), "{k:?} tight");
        }
    }

    #[test]
    fn a_blink_squeezes_the_eyes_and_changes_the_output() {
        let mut open = base();
        open.blink = 1.0;
        let mut shut = base();
        shut.blink = 0.0;
        let render = |p: &SQMascotPose| {
            let mut c = Canvas::with_size(200.0, 200.0, None, 1.0);
            let r = CGRect::new(0.0, 0.0, 200.0, 200.0);
            ShellMascot::draw_pose(p, false, CGRect::new(0.0, 0.0, 1024.0, 1024.0), r, &mut c, brand_violet());
            c.list.quads().to_vec()
        };
        assert_ne!(render(&open), render(&shut));
    }
}
