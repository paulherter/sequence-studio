// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SpeedKeysEase.swift

use crate::{ClipSpeed, EaseShape, Rational, SpeedKeys, SpeedSegment};
use sq_core_time::{EaseHandle, Interpolation, Time};

/// Eased speed transitions: a ramp's speed follows the same cubic Bezier the keyframe curve popover edits
/// (`EaseShape`), instead of a straight line in timeline time.
///
/// ## Curve
/// In the ramp's unit box (normalized time `s = tau / T` across, normalized speed `E = (v - a) / (b - a)` up) the curve runs
/// from (0, 0) to (1, 1) through the control points `(x1, y1) = out` and `(x2, y2) = (1 - in.dx, 1 - in.dy)`, exactly like
/// `KeyframeTrack::bezier_progress`. Handles are clamped to the unit box (so the speed never leaves `a ... b` and never passes
/// through zero: the source mapping stays strictly monotone) and quantized to 1/2^20 (so they are exact rationals).
///
/// ## Integral (what keeps the source map consistent)
/// With the curve's parameter `u` (`s = Bx(u)`, `E = By(u)`), the source displacement is
///
/// ```text
/// D(tau) = a * tau + (b - a) * T * G(u),        G(u) = integral_0^u By(w) * Bx'(w) dw   (a degree-6 polynomial)
/// D(T)   = T * (a + (b - a) * A),               A = G(1)
/// ```
///
/// `A` is computed in exact rationals and then rounded once to a 1/2^32 grid (keeps the 128-bit sums of boundary positions
/// small); that one number is the span everywhere, so the boundary table stays consistent (a symmetric curve has A = 1/2
/// exactly: the same source as the linear ramp). Inside the ramp `u` has to be solved from `s` (a cubic): that is done in
/// `f64` by bisection (monotone, deterministic) and `G(u)` is quantized to 1/2^24 before it enters the exact sum, so the
/// interior positions are deterministic, monotone and within ~1e-7 of the true integral, and still meet the exact
/// boundary at both ends. The clip keeps its timeline length when a curve is set: the span follows the curve.
#[derive(Clone, Copy, Debug)]
pub(crate) struct SpeedEase {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
}

const GRID: f64 = 1_048_576.0;
const G_SCALE: i128 = 1 << 24;

fn q(v: f64) -> f64 {
    let v = if v.is_finite() { v } else { 0.0 };
    (v.clamp(0.0, 1.0) * GRID).round() / GRID
}

fn cubic(u: f64, p1: f64, p2: f64) -> f64 {
    let m = 1.0 - u;
    3.0 * m * m * u * p1 + 3.0 * m * u * u * p2 + u * u * u
}

/// Blossom of the cubic with control points (0, p1, p2, 1).
fn blossom(p1: f64, p2: f64, a: f64, b: f64, c: f64) -> f64 {
    let lerp = |x: f64, y: f64, t: f64| x + (y - x) * t;
    let (l0, l1, l2) = (lerp(0.0, p1, a), lerp(p1, p2, a), lerp(p2, 1.0, a));
    let (m0, m1) = (lerp(l0, l1, b), lerp(l1, l2, b));
    lerp(m0, m1, c)
}

fn quantised(v: f64) -> Rational {
    Rational::new((v * G_SCALE as f64).round() as i128, G_SCALE)
}

fn on_grid(v: f64) -> Rational {
    Rational::new((v * GRID).round() as i128, GRID as i128)
}

impl SpeedEase {
    pub(crate) fn new(shape: &EaseShape) -> SpeedEase {
        SpeedEase { x1: q(shape.out.dx), y1: q(shape.out.dy), x2: 1.0 - q(shape.r#in.dx), y2: 1.0 - q(shape.r#in.dy) }
    }

    /// The stored form of a speed curve: `None` for linear or hold, else a bezier with handles clamped and quantized.
    pub(crate) fn normalized(shape: &EaseShape) -> Option<EaseShape> {
        if shape.effective().interpolation() != Interpolation::Bezier {
            return None;
        }
        let out = EaseHandle { dx: q(shape.out.dx), dy: q(shape.out.dy) };
        let in_h = EaseHandle { dx: q(shape.r#in.dx), dy: q(shape.r#in.dy) };
        // Both control points on the diagonal: By == Bx, the speed is a straight ramp.
        if out.dx == out.dy && in_h.dx == in_h.dy {
            return None;
        }
        Some(EaseShape::new(Interpolation::Bezier, out, in_h))
    }

    fn bx(&self, u: f64) -> f64 {
        cubic(u, self.x1, self.x2)
    }

    /// Normalized speed `By(u)` in `f64`.
    pub(crate) fn by(&self, u: f64) -> f64 {
        cubic(u, self.y1, self.y2)
    }

    /// Curve parameter for normalized time `s` (bisection: monotone in `s`, deterministic).
    pub(crate) fn u_for_s(&self, s: f64) -> f64 {
        if s <= 0.0 {
            return 0.0;
        }
        if s >= 1.0 {
            return 1.0;
        }
        let (mut lo, mut hi) = (0.0, 1.0);
        for _ in 0..52 {
            let m = (lo + hi) / 2.0;
            if self.bx(m) < s {
                lo = m;
            } else {
                hi = m;
            }
        }
        (lo + hi) / 2.0
    }

    /// Power-basis coefficients of G (index = power, 0 ... 6), in `f64`.
    fn g_coefficients(&self) -> [f64; 7] {
        let x = [0.0, 3.0 * self.x1, 3.0 * self.x2 - 6.0 * self.x1, 1.0 + 3.0 * self.x1 - 3.0 * self.x2];
        let y = [0.0, 3.0 * self.y1, 3.0 * self.y2 - 6.0 * self.y1, 1.0 + 3.0 * self.y1 - 3.0 * self.y2];
        let dx = [x[1], 2.0 * x[2], 3.0 * x[3]];
        let mut p = [0.0; 6];
        for i in 1..=3 {
            for (j, d) in dx.iter().enumerate() {
                p[i + j] += y[i] * d;
            }
        }
        let mut g = [0.0; 7];
        for k in 0..6 {
            g[k + 1] = p[k] / (k + 1) as f64;
        }
        g
    }

    /// G(u) in `f64` (Horner).
    pub(crate) fn g(&self, u: f64) -> f64 {
        let c = self.g_coefficients();
        let mut r = 0.0;
        for k in (0..=6).rev() {
            r = r * u + c[k];
        }
        r
    }

    /// A = G(1), exact up to the one rounding to 1/2^32.
    fn area(&self) -> Rational {
        let (x1, x2, y1, y2) = (on_grid(self.x1), on_grid(self.x2), on_grid(self.y1), on_grid(self.y2));
        let (three, six, one) = (Rational::new(3, 1), Rational::new(6, 1), Rational::new(1, 1));
        let x = [Rational::new(0, 1), three * x1, three * x2 - six * x1, one + three * x1 - three * x2];
        let y = [Rational::new(0, 1), three * y1, three * y2 - six * y1, one + three * y1 - three * y2];
        let dx = [x[1], Rational::new(2, 1) * x[2], three * x[3]];
        let mut p = [Rational::new(0, 1); 6];
        for i in 1..=3 {
            for (j, d) in dx.iter().enumerate() {
                p[i + j] = p[i + j] + y[i] * *d;
            }
        }
        let mut a = Rational::new(0, 1);
        for (k, pk) in p.iter().enumerate().skip(1) {
            a = a + *pk / Rational::new(k as i128 + 1, 1);
        }
        // One rounding to 1/2^32 (nearest), so spans built from A keep small denominators.
        let m: i128 = 1 << 32;
        if a.d <= m {
            return a;
        }
        let (num, den) = (a.n * m * 2 + a.d, a.d * 2);
        Rational::new(num / den, m)
    }

    /// Unsigned span at offset `t` of a ramp of length `big_t` from speed `a` to `b` (see the type comment).
    pub(crate) fn span_at(&self, t: Rational, big_t: Rational, a: Rational, b: Rational) -> Rational {
        if t.n <= 0 {
            return Rational::new(0, 1);
        }
        let area = self.area();
        if (t - big_t).n >= 0 {
            return big_t * (a + (b - a) * area);
        }
        let mut gq = quantised(self.g(self.u_for_s((t / big_t).double())));
        if gq.n < 0 {
            gq = Rational::new(0, 1);
        }
        if (gq - area).n > 0 {
            gq = area;
        }
        a * t + (b - a) * big_t * gq
    }

    /// Normalized speed `By(u(s))` as a rational on the 1/2^24 grid, 0 and 1 exactly at the ends.
    pub(crate) fn progress(&self, s: Rational) -> Rational {
        if s.n <= 0 {
            return Rational::new(0, 1);
        }
        if s.n >= s.d {
            return Rational::new(1, 1);
        }
        let v = quantised(self.by(self.u_for_s(s.double())));
        if v.n < 0 {
            Rational::new(0, 1)
        } else if v.n > v.d {
            Rational::new(1, 1)
        } else {
            v
        }
    }

    /// The piece of the curve between normalized times `s0 < s1`, renormalised to its own unit box. `None` when that
    /// piece is flat (constant speed) or degenerate.
    pub(crate) fn piece(&self, s0: f64, s1: f64) -> Option<EaseShape> {
        let (u0, u1) = (self.u_for_s(s0), self.u_for_s(s1));
        let pts = |p1: f64, p2: f64| {
            [
                blossom(p1, p2, u0, u0, u0),
                blossom(p1, p2, u0, u0, u1),
                blossom(p1, p2, u0, u1, u1),
                blossom(p1, p2, u1, u1, u1),
            ]
        };
        let (x, y) = (pts(self.x1, self.x2), pts(self.y1, self.y2));
        let (dx, dy) = (x[3] - x[0], y[3] - y[0]);
        if dx <= 1e-12 || dy <= 1e-12 {
            return None;
        }
        Some(EaseShape::new(
            Interpolation::Bezier,
            EaseHandle { dx: (x[1] - x[0]) / dx, dy: (y[1] - y[0]) / dy },
            EaseHandle { dx: (x[3] - x[2]) / dx, dy: (y[3] - y[2]) / dy },
        ))
    }
}

impl SpeedSegment {
    /// The part of this segment between offsets `lo < hi`, as its own segment. A constant segment just gets shorter; a ramp
    /// runs between the speeds it has at the cuts; an eased ramp keeps the matching piece of its curve.
    pub(crate) fn sub_segment(&self, lo: Time, hi: Time) -> SpeedSegment {
        let mut n = self.clone();
        n.duration = hi - lo;
        if !(self.is_ramp() && (lo > Time::ZERO || hi < self.duration)) {
            return n;
        }
        if lo > Time::ZERO {
            n.from = ClipSpeed::from_rational(self.speed_at(lo));
        }
        if hi < self.duration {
            n.to = ClipSpeed::from_rational(self.speed_at(hi));
        }
        match self.curve() {
            Some(c) if n.is_ramp() => {
                let big_t = Rational::from_time(self.duration);
                n.set_ease(
                    c.piece((Rational::from_time(lo) / big_t).double(), (Rational::from_time(hi) / big_t).double()),
                );
            }
            _ => n.set_ease(None),
        }
        n
    }
}

impl SpeedKeys {
    /// The speed curve of segment `i` (linear for a linear ramp or a constant segment).
    pub fn ease_of_segment(&self, i: usize) -> EaseShape {
        self.segments.get(i).map_or(EaseShape::LINEAR, SpeedSegment::ease_shape)
    }

    /// Sets the speed curve of ramp `i` (linear / hold = straight ramp). The ramp keeps its timeline length and its end
    /// speeds; the source it covers follows the curve (a symmetric curve covers the same source). `None` when `i` is no ramp.
    pub fn setting_ease(&self, shape: &EaseShape, i: usize) -> Option<SpeedKeys> {
        if !self.segments.get(i)?.is_ramp() {
            return None;
        }
        let mut k = self.clone();
        k.segments[i].set_ease(Some(*shape));
        Some(k)
    }
}

impl SpeedSegment {
    /// The ramp's curve (linear when none is set).
    pub fn ease_shape(&self) -> EaseShape {
        self.ease().copied().unwrap_or(EaseShape::LINEAR)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::TimeRange;

    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }

    fn pct(p: f64) -> ClipSpeed {
        ClipSpeed::from_percent(p)
    }

    fn secs(t: Time) -> f64 {
        t.value() as f64 / t.timescale() as f64
    }

    fn shape(out: (f64, f64), r#in: (f64, f64)) -> EaseShape {
        EaseShape::new(
            Interpolation::Bezier,
            EaseHandle { dx: out.0, dy: out.1 },
            EaseHandle { dx: r#in.0, dy: r#in.1 },
        )
    }

    /// Flat at both ends (the default Bezier speed transition).
    fn ease_in_out() -> EaseShape {
        shape((0.5, 0.0), (0.5, 0.0))
    }

    /// Slow start only.
    fn ease_out_only() -> EaseShape {
        EaseShape::new(Interpolation::Bezier, EaseHandle { dx: 0.6, dy: 0.0 }, EaseHandle::LINEAR)
    }

    /// 1 s at 100 %, a 2 s ramp 100 % -> 300 %, 1 s at 300 %.
    fn ramped(ease: Option<EaseShape>, reversed: bool) -> SpeedKeys {
        let seg = |frames, from, to| SpeedSegment::new(f(frames), pct(from), Some(pct(to)), reversed, None);
        let k = SpeedKeys::new(
            vec![seg(30, 100.0, 100.0), seg(60, 100.0, 300.0), seg(30, 300.0, 300.0)],
            if reversed { Time::new(20, 1) } else { f(60) },
        );
        match ease {
            Some(e) => k.setting_ease(&e, 1).unwrap(),
            None => k,
        }
    }

    #[test]
    fn linear_ease_is_the_stored_default() {
        let k = ramped(None, false);
        assert!(k.segments[1].ease().is_none());
        assert_eq!(k.setting_ease(&EaseShape::LINEAR, 1), Some(k.clone()));
        let hold = EaseShape::new(Interpolation::Hold, EaseHandle::LINEAR, EaseHandle::LINEAR);
        assert_eq!(k.setting_ease(&hold, 1), Some(k.clone())); // a speed ramp cannot hold
        assert!(k.setting_ease(&ease_in_out(), 0).is_none()); // not a ramp
        assert_eq!(k.ease_of_segment(1), EaseShape::LINEAR);
        let e = ramped(Some(ease_in_out()), false);
        let stored = e.ease_of_segment(1);
        assert!((stored.out.dx - 0.5).abs() < 1e-3 && stored.out.dy == 0.0);
        assert_eq!(e.setting_ease(&EaseShape::LINEAR, 1), Some(k)); // back to linear equals untouched
    }

    #[test]
    fn symmetric_ease_keeps_span_duration_and_endpoints_exactly() {
        let (lin, e) = (ramped(None, false), ramped(Some(ease_in_out()), false));
        assert_eq!(e.duration(), lin.duration());
        assert_eq!(e.segments[1].span(), Time::new(4, 1)); // T (a + b) / 2, exact
        assert_eq!(e.boundary_positions(), lin.boundary_positions());
        assert_eq!(e.position(f(30)), f(60) + Time::new(1, 1));
        assert_eq!(e.position(f(90)), f(60) + Time::new(5, 1));
        assert_eq!(e.end_position(), lin.end_position());
        // Speed is a at the start, b at the end of the transition, and continuous with the neighbors.
        assert!((e.speed_value(f(30)) - 1.0).abs() < 1e-9);
        assert!((e.segments[1].speed_value(f(60)) - 3.0).abs() < 1e-9);
    }

    #[test]
    fn eased_speed_starts_flat_and_positions_lag_the_linear_ramp() {
        let (lin, e) = (ramped(None, false), ramped(Some(ease_in_out()), false));
        assert!(e.speed_value(f(45)) < lin.speed_value(f(45)) - 0.05);
        assert!(e.position(f(45)) < lin.position(f(45)));
        assert!(e.position(f(60)) < lin.position(f(60)));
        assert!(e.speed_value(f(75)) > lin.speed_value(f(75)) + 0.05);
    }

    #[test]
    fn source_mapping_is_monotonic_forward_and_reversed() {
        for shape in [ease_in_out(), ease_out_only(), shape((1.0, 0.0), (1.0, 0.0))] {
            for rev in [false, true] {
                let k = ramped(Some(shape), rev);
                let mut last = k.position(Time::ZERO);
                for i in 1..=(120 * 8) {
                    let p = k.position(Time::new(i, 240));
                    assert!(if rev { p < last } else { p > last }, "shape {shape:?} rev {rev} step {i}");
                    last = p;
                }
                for i in 0..=60 {
                    let v = k.segments[1].speed_value(f(i));
                    assert!((1.0 - 1e-9..=3.0 + 1e-9).contains(&v));
                }
            }
        }
    }

    #[test]
    fn overshooting_handles_are_clamped_so_the_speed_never_leaves_the_ramp() {
        let k = ramped(Some(shape((0.4, -2.0), (0.4, 3.0))), false);
        for i in 0..=60 {
            let v = k.segments[1].speed_value(f(i));
            assert!((1.0 - 1e-9..=3.0 + 1e-9).contains(&v));
        }
        let e = k.segments[1].ease().unwrap();
        assert!((0.0..=1.0).contains(&e.out.dy) && (0.0..=1.0).contains(&e.r#in.dy));
    }

    #[test]
    fn asymmetric_ease_changes_the_span_and_the_table_stays_consistent() {
        let e = ramped(Some(ease_out_only()), false);
        let s = &e.segments[1];
        // Slow start: less source than the linear 4 s, measured as the integral of speed (Simpson).
        let n = 600;
        let mut sum = 0.0;
        for i in 0..=n {
            let w = if i == 0 || i == n {
                1.0
            } else if i % 2 == 1 {
                4.0
            } else {
                2.0
            };
            sum += w * s.speed_value(Time::new(i * 2, n));
        }
        let integral = sum * (2.0 / n as f64) / 3.0;
        assert!((secs(s.span()) - integral).abs() < 1e-6);
        assert!(secs(s.span()) < 4.0 - 0.05);
        // The boundary table, the end of the ramp and the start of the next segment agree exactly.
        let b2 = e.boundary_positions()[2];
        assert_eq!(e.position(f(90)), b2);
        assert_eq!(b2, f(60) + Time::new(1, 1) + s.span());
        assert_eq!(e.position(f(105)), b2 + Time::new(3, 2)); // 0.5 s at 300 %
        let near = e.position(f(90) - Time::new(1, 2400));
        assert!(near < b2 && secs(b2) - secs(near) < 0.0013);
        assert_eq!(e.hull(), TimeRange::from_end(f(60), e.end_position()));
    }

    #[test]
    fn approximations_and_inverse_follow_the_eased_curve() {
        let e = ramped(Some(ease_out_only()), false);
        for i in (0..=120).step_by(7) {
            let t = f(i);
            assert!((e.position_approx(secs(t)) - secs(e.position(t))).abs() < 1e-6);
            let back = e.local_time_for_source(e.position(t));
            assert!((secs(back) - secs(t)).abs() < 1e-3, "frame {i}");
        }
    }

    #[test]
    fn slicing_an_eased_ramp_keeps_the_matching_piece_of_the_curve() {
        let e = ramped(Some(ease_in_out()), false);
        let cut = e.sliced(f(45), f(75));
        for i in 0..=30 {
            let (a, b) = (secs(cut.position(f(i))), secs(e.position(f(45 + i))));
            assert!((a - b).abs() < 1e-3, "frame {i}: {a} vs {b}");
        }
    }
}
