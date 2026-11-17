// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SpeedKeys.swift

use crate::speed_keys_ease::SpeedEase;
use crate::{ClipSpeed, EaseShape};
use serde::{Deserialize, Serialize, Serializer};
use sq_core_time::{Time, TimeRange};
use std::ops::{Add, Div, Mul, Sub};

/// Time remapping: a piecewise speed track over the clip's own timeline (project file v23).
///
/// ## Model
/// A keyed clip carries `SpeedKeys`: an ordered list of segments laid end to end from clip-local time 0. Each segment has a
/// timeline `duration` (whole frames, chosen by the editing functions), a speed `from` at its start, a speed `to` at its end
/// (`from == to` is a constant segment, otherwise a ramp: linear in timeline time, or a Bezier curve, see
/// `speed_keys_ease.rs`) and a direction (`reversed`). Key points are the boundaries between segments; a "split key" (two
/// halves with a ramp between them) is a ramp segment. `origin` is the source time shown at clip-local 0 (forward: where
/// reading starts; reversed: the end it reads backwards from). `Clip::source` of a keyed clip is always the hull of every
/// source time the track visits, so handles, trims and the media limits keep working on one range.
///
/// ## Formula (the one mapping, exact)
/// Source displacement over a segment at local offset `tau` (0 ... T), with speeds `a = from`, `b = to` (ratios, source seconds
/// per timeline second):
///
/// ```text
/// D(tau) = a * tau + (b - a) * tau^2 / (2 T)         (constant: a * tau)
/// D(T)   = T * (a + b) / 2                            (the segment's whole span)
/// ```
///
/// Source time at clip-local `x` = `origin + sum over earlier segments of sign * D(T_i) + sign * D(x - start_i)`, with
/// `sign = -1` for reversed segments. All of it is evaluated in exact integer rationals (128 bit). The only rounding is
/// `Rational::time`: a result whose reduced denominator is above `Rational::MAX_DENOMINATOR` (2^20) is rounded to the
/// nearest 1/2^20 s; this happens in that one place, deterministically, and keeps `Time` arithmetic downstream from
/// overflowing. A constant-speed clip never builds `SpeedKeys` (`None`), so it keeps its original `ClipSpeed::scale`
/// arithmetic bit for bit.
///
/// ## Frame convention
/// Forward: the frame shown at timeline frame `[x, x + fd)` starts at `position(x)`. Reversed: it is the source frame that
/// ends at `position(x)`, so it starts at `position(x + fd)`. This is exactly the constant-speed rule
/// (`source.end - speed * (local + fd)`), so a one-segment track equals the constant clip.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "SpeedSegmentWire")]
pub struct SpeedSegment {
    /// Timeline length of the piece.
    pub duration: Time,
    /// Speed at the start.
    pub from: ClipSpeed,
    /// Speed at the end.
    pub to: ClipSpeed,
    /// Plays backwards.
    pub reversed: bool,
    /// Bezier shape of a ramp's speed curve; `None` = linear. Only a normalized bezier is stored (handles clamped to the
    /// unit box and quantized to 1/2^20), so equal curves compare equal and old files decode.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ease: Option<EaseShape>,
}

/// `SpeedSegment` as stored; the curve goes through `set_ease` (a hand-edited or older file cannot store an unclamped or
/// linear curve).
#[derive(Deserialize)]
struct SpeedSegmentWire {
    duration: Time,
    from: ClipSpeed,
    to: ClipSpeed,
    reversed: bool,
    #[serde(default)]
    ease: Option<EaseShape>,
}

impl From<SpeedSegmentWire> for SpeedSegment {
    fn from(w: SpeedSegmentWire) -> SpeedSegment {
        SpeedSegment::new(w.duration, w.from, Some(w.to), w.reversed, w.ease)
    }
}

impl SpeedSegment {
    /// A segment; `to` defaults to `from` (constant), and only a normalized bezier `ease` is kept.
    pub fn new(
        duration: Time,
        from: ClipSpeed,
        to: Option<ClipSpeed>,
        reversed: bool,
        ease: Option<EaseShape>,
    ) -> Self {
        SpeedSegment {
            duration,
            from,
            to: to.unwrap_or(from),
            reversed,
            ease: ease.as_ref().and_then(SpeedEase::normalized),
        }
    }

    /// A constant segment.
    pub fn constant(duration: Time, speed: ClipSpeed, reversed: bool) -> Self {
        SpeedSegment::new(duration, speed, None, reversed, None)
    }

    /// Ramp shape; `None` = linear.
    pub fn ease(&self) -> Option<&EaseShape> {
        self.ease.as_ref()
    }

    /// Speed changes over the segment.
    pub fn is_ramp(&self) -> bool {
        self.from != self.to
    }

    /// Sets the speed curve; linear or hold clears it.
    pub fn set_ease(&mut self, shape: Option<EaseShape>) {
        self.ease = shape.as_ref().and_then(SpeedEase::normalized);
    }

    /// The eased curve of a ramp, `None` for constant segments and linear ramps.
    pub(crate) fn curve(&self) -> Option<SpeedEase> {
        if self.is_ramp() { self.ease.as_ref().map(SpeedEase::new) } else { None }
    }

    /// Unsigned source span at timeline offset `tau` (clamped to `0 ..= duration`), exact.
    pub(crate) fn span_at(&self, tau: Time) -> Rational {
        let t = Rational::from_time(tau.max(Time::ZERO).min(self.duration));
        let a = Rational::from_speed(self.from);
        if !self.is_ramp() {
            return a * t;
        }
        let b = Rational::from_speed(self.to);
        if let Some(c) = self.curve() {
            return c.span_at(t, Rational::from_time(self.duration), a, b);
        }
        a * t + (b - a) * t * t / (Rational::from_time(self.duration) * Rational::new(2, 1))
    }

    /// Unsigned source span of the whole segment: `T * (a + b) / 2` (linear), `T * (a + (b - a) * A)` (eased).
    pub fn span(&self) -> Time {
        self.span_at(self.duration).time()
    }

    /// Speed at offset `tau` as an exact rational (a ratio, not a duration).
    pub(crate) fn speed_at(&self, tau: Time) -> Rational {
        let a = Rational::from_speed(self.from);
        if !self.is_ramp() {
            return a;
        }
        let t = Rational::from_time(tau.max(Time::ZERO).min(self.duration));
        let big_t = Rational::from_time(self.duration);
        if let Some(c) = self.curve() {
            return a + (Rational::from_speed(self.to) - a) * c.progress(t / big_t);
        }
        a + (Rational::from_speed(self.to) - a) * t / big_t
    }

    /// Speed at `tau` for display and audio (`f64` is fine: nothing is accumulated from it).
    pub fn speed_value(&self, tau: Time) -> f64 {
        let Some(c) = self.curve() else { return self.speed_at(tau).double() };
        let (a, b) = (Rational::from_speed(self.from).double(), Rational::from_speed(self.to).double());
        let s = (Rational::from_time(tau).double() / Rational::from_time(self.duration).double()).clamp(0.0, 1.0);
        a + (b - a) * c.by(c.u_for_s(s))
    }

    /// Unsigned span at `tau` seconds as an `f64` (planning, display inverse).
    pub(crate) fn span_approx(&self, tau: f64) -> f64 {
        let a = self.from.num() as f64 / self.from.den() as f64;
        let b = self.to.num() as f64 / self.to.den() as f64;
        let big_t = Rational::from_time(self.duration).double();
        let t = tau.clamp(0.0, big_t);
        if !self.is_ramp() {
            return a * t;
        }
        if let Some(c) = self.curve() {
            return a * t + (b - a) * big_t * c.g(c.u_for_s(t / big_t));
        }
        a * t + (b - a) * t * t / (2.0 * big_t)
    }

    /// `other` continues this constant segment (same speed and direction): the two read as one stretch.
    pub fn joins(&self, other: &SpeedSegment) -> bool {
        !self.is_ramp() && !other.is_ramp() && self.from == other.from && self.reversed == other.reversed
    }
}

/// A speed track: segments starting at source time `origin`.
#[derive(Clone, Debug, PartialEq)]
pub struct SpeedKeys {
    /// The pieces, at least one.
    pub segments: Vec<SpeedSegment>,
    /// Source time at the clip start. When it is the rounding of an exact value (a slice or head trim of a ramp),
    /// `origin_exact` carries the exact rational so the mapping stays frame-for-frame identical; assigning `origin`
    /// without resetting `origin_exact` is a bug: use `SpeedKeys::new`.
    pub origin: Time,
    /// Exact origin when it does not fit `Time`; coded as `originNum`/`originDen`.
    #[doc(hidden)]
    pub origin_exact: Option<Rational>,
}

/// `SpeedKeys` as stored.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SpeedKeysWire {
    segments: Vec<SpeedSegment>,
    origin: Time,
    #[serde(default)]
    origin_num: Option<i64>,
    #[serde(default)]
    origin_den: Option<i64>,
}

impl<'de> Deserialize<'de> for SpeedKeys {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<SpeedKeys, D::Error> {
        let w = SpeedKeysWire::deserialize(d)?;
        if w.segments.is_empty() {
            return Err(serde::de::Error::custom("empty speed track"));
        }
        Ok(match (w.origin_num, w.origin_den) {
            (Some(n), Some(den)) if den > 0 => {
                SpeedKeys::with_exact_origin(w.segments, Rational::new(n as i128, den as i128))
            }
            _ => SpeedKeys::new(w.segments, w.origin),
        })
    }
}

impl Serialize for SpeedKeys {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Out<'a> {
            segments: &'a [SpeedSegment],
            origin: Time,
            #[serde(skip_serializing_if = "Option::is_none")]
            origin_num: Option<i64>,
            #[serde(skip_serializing_if = "Option::is_none")]
            origin_den: Option<i64>,
        }
        let q = self.origin_exact.map(|x| x.reduced_to_fit());
        Out {
            segments: &self.segments,
            origin: self.origin,
            origin_num: q.map(|(n, _)| n as i64),
            origin_den: q.map(|(_, d)| d as i64),
        }
        .serialize(s)
    }
}

/// Segment starts and exact source positions at the boundaries, built from the segments and the origin.
// shortcut: rebuilt on every query (Swift caches it behind `didSet`); the fields are public so a cache could go stale.
// Upgrade when a profile shows it: make `segments` and `origin` private with setters, as `EaseShape::set_interpolation`.
struct Table {
    starts: Vec<Time>,
    starts_d: Vec<f64>,
    pos: Vec<Rational>,
    pos_t: Vec<Time>,
    pos_d: Vec<f64>,
}

fn sign(reversed: bool) -> Rational {
    Rational::new(if reversed { -1 } else { 1 }, 1)
}

fn seconds(t: Time) -> f64 {
    t.value() as f64 / t.timescale() as f64
}

impl SpeedKeys {
    /// A track starting at source time `origin`. Panics on an empty segment list (a Swift precondition).
    pub fn new(segments: Vec<SpeedSegment>, origin: Time) -> SpeedKeys {
        assert!(!segments.is_empty(), "speed track needs a segment");
        SpeedKeys { segments, origin, origin_exact: None }
    }

    /// A track whose origin is the exact rational `origin` (`origin` itself holds its rounding).
    #[doc(hidden)]
    pub fn with_exact_origin(segments: Vec<SpeedSegment>, origin: Rational) -> SpeedKeys {
        assert!(!segments.is_empty(), "speed track needs a segment");
        SpeedKeys { segments, origin: origin.time(), origin_exact: Some(origin) }
    }

    /// One constant segment: what a constant-speed clip of `duration` looks like as a track.
    pub fn constant(speed: ClipSpeed, reversed: bool, duration: Time, origin: Time) -> SpeedKeys {
        SpeedKeys::new(vec![SpeedSegment::constant(duration, speed, reversed)], origin)
    }

    fn origin_q(&self) -> Rational {
        self.origin_exact.unwrap_or_else(|| Rational::from_time(self.origin))
    }

    fn table(&self) -> Table {
        let mut pos = self.origin_q();
        let mut start = Time::ZERO;
        let mut t = Table {
            starts: vec![Time::ZERO],
            starts_d: Vec::new(),
            pos: vec![pos],
            pos_t: Vec::new(),
            pos_d: Vec::new(),
        };
        for s in &self.segments {
            pos = pos + sign(s.reversed) * s.span_at(s.duration);
            start += s.duration;
            t.pos.push(pos);
            t.starts.push(start);
        }
        t.starts_d = t.starts.iter().map(|s| seconds(*s)).collect();
        t.pos_t = t.pos.iter().map(|p| p.time()).collect();
        t.pos_d = t.pos.iter().map(|p| p.double()).collect();
        t
    }

    /// Timeline length of the clip.
    pub fn duration(&self) -> Time {
        self.segments.iter().fold(Time::ZERO, |acc, s| acc + s.duration)
    }

    /// Clip-local start of each segment, plus the end as the last element (count + 1 entries).
    pub fn boundaries(&self) -> Vec<Time> {
        self.table().starts
    }

    /// Index of the segment shown at `local` (the last one for `local >= duration`): binary search.
    fn index_containing(starts: &[Time], count: usize, local: Time) -> usize {
        let (mut lo, mut hi) = (0, count - 1);
        while lo < hi {
            let mid = (lo + hi).div_ceil(2);
            if starts[mid] <= local {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        lo
    }

    fn position_q(&self, local: Time) -> Rational {
        let t = self.table();
        let x = local.max(Time::ZERO);
        let n = self.segments.len();
        if x >= t.starts[n] {
            return t.pos[n];
        }
        let i = Self::index_containing(&t.starts, n, x);
        let s = &self.segments[i];
        t.pos[i] + sign(s.reversed) * s.span_at(x - t.starts[i])
    }

    /// Source position in seconds as an `f64`, for planning and eviction (not for the presented frame): no rationals.
    pub fn position_approx(&self, x: f64) -> f64 {
        let t = self.table();
        let n = self.segments.len();
        if x <= 0.0 {
            return t.pos_d[0];
        }
        if x >= t.starts_d[n] {
            return t.pos_d[n];
        }
        let (mut lo, mut hi) = (0, n - 1);
        while lo < hi {
            let mid = (lo + hi).div_ceil(2);
            if t.starts_d[mid] <= x {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        let s = &self.segments[lo];
        let d = s.span_approx(x - t.starts_d[lo]);
        t.pos_d[lo] + if s.reversed { -d } else { d }
    }

    /// Source time at clip-local `local` (the instant, not a frame). Clamped to `0 ..= duration`.
    pub fn position(&self, local: Time) -> Time {
        self.position_q(local).time()
    }

    /// Source time at every boundary (`segments.len() + 1` entries).
    pub fn boundary_positions(&self) -> Vec<Time> {
        self.table().pos_t
    }

    /// Source range the track visits (within a segment the path is monotone, so the extremes sit on boundaries).
    pub fn hull(&self) -> TimeRange {
        let p = self.boundary_positions();
        let lo = p.iter().copied().min().unwrap_or(Time::ZERO);
        let hi = p.iter().copied().max().unwrap_or(Time::ZERO);
        TimeRange::from_end(lo, hi)
    }

    /// Source time at the end of the track.
    pub fn end_position(&self) -> Time {
        self.table().pos_t[self.segments.len()]
    }

    fn segment_index(&self, local: Time) -> usize {
        Self::index_containing(&self.table().starts, self.segments.len(), local)
    }

    /// Direction of the segment shown at `local`.
    pub fn is_reversed(&self, local: Time) -> bool {
        self.segments[self.segment_index(local)].reversed
    }

    /// Speed at `local` (source seconds per second, unsigned), for display.
    pub fn speed_value(&self, local: Time) -> f64 {
        let t = self.table();
        let i = Self::index_containing(&t.starts, self.segments.len(), local);
        self.segments[i].speed_value(local - t.starts[i])
    }

    /// The source time of the frame shown at clip-local `local` (see "Frame convention").
    /// Outside `0 ..= duration` (a transition reading a handle before the head or after the tail) the track runs on at its
    /// end speed and direction: see `position_extended`.
    pub fn source_time(&self, local: Time, fd: Time) -> Time {
        let last = self.segments.len() - 1;
        let reversed = if local < Time::ZERO {
            self.segments[0].reversed
        } else if local >= self.duration() {
            self.segments[last].reversed
        } else {
            self.segments[self.segment_index(local)].reversed
        };
        self.position_extended(if reversed { local + fd } else { local })
    }

    /// `position` that continues linearly past both ends: before 0 at the first segment's start speed and direction, after
    /// `duration` at the last segment's end speed and direction (the media beyond a clip's edges, for transitions and audio).
    pub fn position_extended(&self, local: Time) -> Time {
        if local < Time::ZERO {
            let s = &self.segments[0];
            return (self.origin_q() + sign(s.reversed) * Rational::from_speed(s.from) * Rational::from_time(local))
                .time();
        }
        let duration = self.duration();
        if local > duration {
            let n = self.segments.len();
            let s = &self.segments[n - 1];
            let end = self.table().pos[n];
            return (end + sign(s.reversed) * Rational::from_speed(s.to) * Rational::from_time(local - duration))
                .time();
        }
        self.position(local)
    }

    /// Clip-local time at which source time `s` is shown: the inverse of `position` (first visit when the track revisits
    /// a source time). A source time the track never reaches maps to the nearest end. Ramps are solved with a `f64`
    /// quadratic and rounded to 1/2^20 s; constant segments are exact. Used for display mappings only.
    pub fn local_time_for_source(&self, s: Time) -> Time {
        if let Some(first) = self.local_times_for_source(s).first() {
            return *first;
        }
        let (pos, starts, hull) = (self.boundary_positions(), self.boundaries(), self.hull());
        if s < hull.start {
            pos.iter().position(|p| *p == hull.start).map_or(Time::ZERO, |i| starts[i])
        } else {
            pos.iter().rposition(|p| *p == hull.end()).map_or_else(|| self.duration(), |i| starts[i])
        }
    }

    /// Every clip-local time at which the track passes source time `s`, in time order (one per segment that contains it).
    pub fn local_times_for_source(&self, s: Time) -> Vec<Time> {
        let (pos, starts) = (self.boundary_positions(), self.boundaries());
        let mut out = Vec::new();
        for (i, seg) in self.segments.iter().enumerate() {
            let (p0, p1) = (pos[i], pos[i + 1]);
            let (lo, hi) = (p0.min(p1), p0.max(p1));
            if !(s >= lo && s <= hi) {
                continue;
            }
            // Unsigned distance into the segment.
            let d = Rational::from_time(if seg.reversed { p0 - s } else { s - p0 });
            if !seg.is_ramp() {
                out.push(starts[i] + (d / Rational::from_speed(seg.from)).time());
                continue;
            }
            let a = Rational::from_speed(seg.from).double();
            let b = Rational::from_speed(seg.to).double();
            let big_t = Rational::from_time(seg.duration).double();
            let dd = d.double();
            let mut tau = 2.0 * dd / (a + (a * a + 2.0 * (b - a) * dd / big_t).sqrt());
            if seg.curve().is_some() {
                // Eased: the span is monotone in tau, bisect it.
                let (mut lo, mut hi) = (0.0, big_t);
                for _ in 0..60 {
                    let m = (lo + hi) / 2.0;
                    if seg.span_approx(m) < dd {
                        lo = m;
                    } else {
                        hi = m;
                    }
                }
                tau = (lo + hi) / 2.0;
            }
            let scale: i64 = 1 << 20;
            out.push(starts[i] + Time::new((tau.clamp(0.0, big_t) * scale as f64).round() as i64, scale));
        }
        out
    }

    /// The part of the track in `[a, b)` (clip-local, `0 <= a < b <= duration`), re-based so `a` becomes 0.
    /// A cut ramp keeps its slope: the sub-ramp runs between the speeds the ramp has at the cut points (an eased ramp keeps
    /// the matching piece of its curve, see `SpeedSegment::sub_segment`).
    pub fn sliced(&self, a: Time, b: Time) -> SpeedKeys {
        let a = a.max(Time::ZERO);
        let b = b.min(self.duration());
        assert!(a < b, "empty slice");
        let mut out = Vec::new();
        let mut t = Time::ZERO;
        for s in &self.segments {
            let (s0, s1) = (t, t + s.duration);
            t = s1;
            if !(s1 > a && s0 < b) {
                continue;
            }
            let (lo, hi) = (s0.max(a), s1.min(b));
            out.push(s.sub_segment(lo - s0, hi - s0));
        }
        SpeedKeys::with_exact_origin(out, self.position_q(a))
    }

    /// Grows the track by `g` at the tail with a constant segment at the end speed and direction (negative = cuts `-g`).
    pub fn extended_tail(&self, g: Time) -> SpeedKeys {
        if g == Time::ZERO {
            return self.clone();
        }
        if g < Time::ZERO {
            return self.sliced(Time::ZERO, self.duration() + g);
        }
        let mut k = self.clone();
        let n = k.segments.len();
        let last = k.segments[n - 1].clone();
        if !last.is_ramp() {
            k.segments[n - 1].duration += g;
        } else {
            k.segments.push(SpeedSegment::constant(g, last.to, last.reversed));
        }
        k
    }

    /// Grows the track by `g` at the head (negative = cuts `-g` off the head). The new head plays at the first
    /// speed/direction.
    pub fn extended_head(&self, g: Time) -> SpeedKeys {
        if g == Time::ZERO {
            return self.clone();
        }
        if g < Time::ZERO {
            return self.sliced(Time::ZERO - g, self.duration());
        }
        let mut k = self.clone();
        let first = k.segments[0].clone();
        let lead = SpeedSegment::constant(g, first.from, first.reversed);
        let new_origin = self.origin_q() - sign(first.reversed) * lead.span_at(g);
        if !first.is_ramp() {
            k.segments[0].duration += g;
        } else {
            k.segments.insert(0, lead);
        }
        SpeedKeys::with_exact_origin(k.segments, new_origin)
    }

    /// Total path length through the source (sum of segment spans, direction ignored). The average speed is this / duration.
    pub fn path_length(&self) -> Time {
        let mut r = Rational::new(0, 1);
        for s in &self.segments {
            r = r + s.span_at(s.duration);
        }
        r.time()
    }

    /// True when every segment is constant at one speed and direction (the track plays like a constant clip, keys or not).
    pub fn is_uniform(&self) -> bool {
        let Some(f) = self.segments.first() else { return true };
        self.segments.iter().all(|s| !s.is_ramp() && s.from == f.from && s.reversed == f.reversed)
    }

    /// Drops empty segments. A uniform track collapses to one segment (`collapsing_uniform`, the default: it equals a
    /// constant clip). Any other key stays, also one between two equal speeds (a key the user placed; the Effect Controls
    /// diamond adds one without changing the speed).
    pub fn normalized(&self, collapsing_uniform: bool) -> SpeedKeys {
        let out: Vec<SpeedSegment> = self.segments.iter().filter(|s| s.duration > Time::ZERO).cloned().collect();
        if out.is_empty() {
            return self.clone();
        }
        if collapsing_uniform
            && out.len() > 1
            && SpeedKeys::with_exact_origin(out.clone(), self.origin_q()).is_uniform()
        {
            let mut one = out[0].clone();
            one.duration = out.iter().fold(Time::ZERO, |acc, s| acc + s.duration);
            return SpeedKeys::with_exact_origin(vec![one], self.origin_q());
        }
        SpeedKeys::with_exact_origin(out, self.origin_q())
    }
}

impl ClipSpeed {
    /// From an exact ratio of speeds; clamped like `ClipSpeed::new`. The ratio is reduced to fit 63 bits first.
    pub(crate) fn from_rational(r: Rational) -> ClipSpeed {
        let (n, d) = r.reduced_to_fit();
        ClipSpeed::new(n as i64, d as i64)
    }
}

/// Exact fraction with `i128` parts for speed math. Operations that would overflow shed low bits of the operands first
/// (deterministic, only reachable with absurd inputs).
#[doc(hidden)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Rational {
    /// Numerator.
    pub n: i128,
    /// Denominator.
    pub d: i128,
}

fn gcd(mut a: i128, mut b: i128) -> i128 {
    while b != 0 {
        (a, b) = (b, a % b);
    }
    a
}

fn abs(n: i128) -> i128 {
    if n < 0 { -n } else { n }
}

impl Rational {
    /// The largest denominator `time()` keeps exactly.
    pub const MAX_DENOMINATOR: i128 = 1 << 20;

    /// `n / d`, reduced, with a positive denominator.
    pub fn new(n: i128, d: i128) -> Rational {
        let (mut n, mut d) = (n, d);
        if d < 0 {
            n = -n;
            d = -d;
        }
        let g = gcd(abs(n), d);
        if g > 1 {
            n /= g;
            d /= g;
        }
        Rational { n, d }
    }

    /// A time as a fraction of seconds.
    pub fn from_time(t: Time) -> Rational {
        Rational::new(t.value() as i128, t.timescale() as i128)
    }

    /// A speed as a ratio.
    pub fn from_speed(s: ClipSpeed) -> Rational {
        Rational::new(s.num() as i128, s.den() as i128)
    }

    /// The value as `f64`.
    pub fn double(self) -> f64 {
        self.n as f64 / self.d as f64
    }

    /// `n / d` with both parts reduced together (by dropping low bits) until they fit in 62 bits: exact for every ordinary
    /// value, a relative error below 2^-60 for the huge fractions a long chain of off-frame edits can build. Products and
    /// sums of fitted parts stay below 2^125, so the arithmetic below never overflows `i128`.
    fn fit(n: i128, d: i128) -> (i128, i128) {
        let (mut n, mut d) = (n, d);
        let lim: i128 = 1 << 62;
        while abs(n) >= lim || d >= lim {
            n >>= 1;
            d >>= 1;
        }
        (n, d.max(1))
    }

    /// The fraction with numerator and denominator reduced (by dropping low bits) until both fit in 62 bits.
    pub fn reduced_to_fit(self) -> (i128, i128) {
        Self::fit(self.n, self.d)
    }

    /// The single rounding point. Exact when the reduced denominator is at most `MAX_DENOMINATOR`; otherwise rounded to
    /// the nearest multiple of 1/`MAX_DENOMINATOR` (ties up).
    pub fn time(self) -> Time {
        if self.d <= Self::MAX_DENOMINATOR {
            let (n, d) = self.reduced_to_fit();
            return Time::new(n as i64, d as i64);
        }
        let m = Self::MAX_DENOMINATOR;
        // Nearest integer of n * m / d, floor((2 n m + d) / (2 d)). Both parts below 2^62 first (a chain of off-frame edits
        // can grow them to the i128 limit), so 2 n m + d stays below 2^84; a result beyond i64 is clamped (never traps).
        let (rn, rd) = self.reduced_to_fit();
        let (num, den) = (rn * m * 2 + rd, rd * 2);
        let mut q = num / den;
        if num % den != 0 && (num < 0) != (den < 0) {
            q -= 1;
        }
        Time::new(q.clamp(i64::MIN as i128, i64::MAX as i128) as i64, m as i64)
    }
}

impl Mul for Rational {
    type Output = Rational;

    fn mul(self, y: Rational) -> Rational {
        let x = self;
        // Cross-reduce first to keep numbers small (xn/xd and yn/yd keep the product).
        let (g1, g2) = (gcd(abs(x.n), y.d), gcd(abs(y.n), x.d));
        let (xn, yd) = if g1 > 1 { (x.n / g1, y.d / g1) } else { (x.n, y.d) };
        let (yn, xd) = if g2 > 1 { (y.n / g2, x.d / g2) } else { (y.n, x.d) };
        let (a, b) = (Rational::fit(xn, xd), Rational::fit(yn, yd));
        Rational::new(a.0 * b.0, (a.1 * b.1).max(1))
    }
}

impl Div for Rational {
    type Output = Rational;

    fn div(self, y: Rational) -> Rational {
        self * Rational::new(y.d, if y.n == 0 { 1 } else { y.n })
    }
}

impl Add for Rational {
    type Output = Rational;

    fn add(self, y: Rational) -> Rational {
        let (a, b) = (Rational::fit(self.n, self.d), Rational::fit(y.n, y.d));
        let g = gcd(a.1, b.1);
        let (xs, ys) = (b.1 / g, a.1 / g);
        Rational::new(a.0 * xs + b.0 * ys, (a.1 * xs).max(1))
    }
}

impl Sub for Rational {
    type Output = Rational;

    fn sub(self, y: Rational) -> Rational {
        self + Rational::new(-y.n, y.d)
    }
}

/// How a slowed-down clip fills the frames between two source frames. Separate from the speed itself (constant speed or
/// the speed curve): one choice per clip.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TimeInterpolation {
    /// Repeat the source frame that covers the instant (nearest frame).
    FrameSampling,
    /// Mix the two source frames around the instant by the fractional source position.
    FrameBlend,
    /// Move the pixels of both source frames along their measured motion to the instant, falling back to the plain mix
    /// where the motion cannot be trusted.
    OpticalFlow,
}

impl TimeInterpolation {
    /// Shown name.
    pub fn title(self) -> &'static str {
        match self {
            TimeInterpolation::FrameSampling => "Repeat frames",
            TimeInterpolation::FrameBlend => "Blend frames",
            TimeInterpolation::OpticalFlow => "Optical flow",
        }
    }

    /// Whether a source time between two frames needs the next source frame too (blend and optical flow).
    pub fn mixes_frames(self) -> bool {
        self != TimeInterpolation::FrameSampling
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FD: Time = Time::new(1, 30);

    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }

    fn pct(p: f64) -> ClipSpeed {
        ClipSpeed::from_percent(p)
    }

    fn seg(frames: i64, a: f64, b: Option<f64>, rev: bool) -> SpeedSegment {
        SpeedSegment::new(f(frames), pct(a), Some(pct(b.unwrap_or(a))), rev, None)
    }

    #[test]
    fn two_constant_segments_give_exact_boundary_times() {
        // 30 frames at 100 %, then 30 frames at 200 %: boundary at 1 s of source, end at 3 s.
        let k = SpeedKeys::new(vec![seg(30, 100.0, None, false), seg(30, 200.0, None, false)], f(60));
        assert_eq!(k.duration(), f(60));
        assert_eq!(k.position(f(30)), f(60) + Time::new(1, 1));
        assert_eq!(k.position(f(60)), f(60) + Time::new(3, 1));
        assert_eq!(k.position(f(45)), f(60) + Time::new(2, 1));
        assert_eq!(k.hull(), TimeRange::new(f(60), Time::new(3, 1)));
    }

    #[test]
    fn ramp_uses_the_closed_form_exactly() {
        // 1x -> 3x over 2 s: span T(a+b)/2 = 4 s; at 1 s: a t + (b-a) t^2 / 2T = 1 + 2/4 = 1.5 s.
        let k = SpeedKeys::new(
            vec![SpeedSegment::new(Time::new(2, 1), pct(100.0), Some(pct(300.0)), false, None)],
            Time::ZERO,
        );
        assert_eq!(k.position(Time::new(2, 1)), Time::new(4, 1));
        assert_eq!(k.position(Time::new(1, 1)), Time::new(3, 2));
        assert_eq!(k.segments[0].span(), Time::new(4, 1));
    }

    #[test]
    fn reversed_segments_are_allowed() {
        // Forward 1 s at 100 %, then backwards 0.5 s of source (30 frames at 50 %).
        let k = SpeedKeys::new(vec![seg(30, 100.0, None, false), seg(30, 50.0, None, true)], Time::ZERO);
        assert_eq!(k.position(f(30)), Time::new(1, 1));
        assert_eq!(k.position(f(60)), Time::new(1, 2));
        assert_eq!(k.hull(), TimeRange::from_end(Time::ZERO, Time::new(1, 1)));
        assert!(k.is_reversed(f(45)) && !k.is_reversed(f(10)));
        // Reversed frame convention: the frame shown for [x, x+fd) starts at position(x + fd).
        assert_eq!(k.source_time(f(30), FD), k.position(f(31)));
        assert_eq!(k.source_time(f(10), FD), k.position(f(10)));
    }

    #[test]
    fn position_is_monotone_for_positive_speeds() {
        let mut seed: u64 = 42;
        let mut next = |n: i64| {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((seed >> 33) as i64) % n
        };
        for _ in 0..40 {
            let mut segs = Vec::new();
            for _ in 0..(2 + next(4)) {
                let frames = 1 + next(40);
                let a = (1 + next(900)) as f64 + 0.5;
                let b = if next(3) == 0 { None } else { Some((1 + next(900)) as f64 + 0.5) };
                segs.push(seg(frames, a, b, false));
            }
            let k = SpeedKeys::new(segs, f(next(1000)));
            let mut prev = k.position(Time::ZERO);
            for i in 1..=k.duration().frame_index(FD) {
                let p = k.position(f(i));
                assert!(p >= prev);
                prev = p;
            }
        }
    }

    #[test]
    fn slice_keeps_the_mapping_of_the_kept_part() {
        let k = SpeedKeys::new(vec![seg(30, 100.0, None, false), seg(30, 100.0, Some(300.0), false)], f(10));
        let s = k.sliced(f(15), f(45));
        assert_eq!(s.duration(), f(30));
        for i in 0..=30 {
            assert_eq!(s.position(f(i)), k.position(f(15 + i)), "frame {i}");
        }
    }

    #[test]
    fn extending_and_cutting_the_ends() {
        let k = SpeedKeys::new(vec![seg(30, 100.0, None, false), seg(30, 200.0, None, false)], f(60));
        assert_eq!(k.extended_tail(f(10)).duration(), f(70));
        assert_eq!(k.extended_tail(f(0) - f(10)).duration(), f(50));
        let head = k.extended_head(f(30));
        assert_eq!(head.duration(), f(90));
        assert_eq!(head.position(f(30)), k.position(Time::ZERO));
        assert_eq!(k.extended_head(Time::ZERO - f(10)).position(Time::ZERO), k.position(f(10)));
    }

    #[test]
    fn normalizing_collapses_a_uniform_track_unless_asked_not_to() {
        let k = SpeedKeys::new(
            vec![seg(10, 100.0, None, false), seg(0, 200.0, None, false), seg(20, 100.0, None, false)],
            Time::ZERO,
        );
        assert_eq!(k.normalized(true).segments.len(), 1);
        assert_eq!(k.normalized(true).segments[0].duration, f(30));
        assert_eq!(k.normalized(false).segments.len(), 2);
        assert!(k.normalized(false).is_uniform());
    }

    #[test]
    fn local_time_is_the_inverse_of_position() {
        let k = SpeedKeys::new(vec![seg(30, 100.0, None, false), seg(30, 200.0, None, false)], f(60));
        assert_eq!(k.local_time_for_source(k.position(f(45))), f(45));
        // Beyond the hull maps to the nearest end.
        assert_eq!(k.local_time_for_source(Time::ZERO), Time::ZERO);
        assert_eq!(k.local_time_for_source(Time::new(100, 1)), f(60));
    }

    #[test]
    fn rational_time_rounds_to_a_quarter_million_grid() {
        let r = Rational::new(1, 3_000_000);
        assert_eq!(r.time(), Time::new(0, 1 << 20));
        assert_eq!(Rational::new(1, 3).time(), Time::new(1, 3));
        assert_eq!(Rational::new(1, 3) + Rational::new(1, 6), Rational::new(1, 2));
        assert_eq!(Rational::new(1, 2) / Rational::new(1, 4), Rational::new(2, 1));
    }

    #[test]
    fn coding_round_trips_with_and_without_an_exact_origin() {
        let plain = SpeedKeys::new(vec![seg(30, 100.0, None, false)], f(5));
        let text = serde_json::to_string(&plain).unwrap();
        assert!(!text.contains("originNum"));
        assert_eq!(serde_json::from_str::<SpeedKeys>(&text).unwrap(), plain);

        let ramp = SpeedKeys::new(vec![seg(30, 100.0, Some(300.0), false)], Time::ZERO);
        let cut = ramp.sliced(f(7), f(20));
        assert!(cut.origin_exact.is_some());
        let value = serde_json::to_value(&cut).unwrap();
        assert!(value.get("originNum").is_some() && value.get("originDen").is_some());
        assert_eq!(serde_json::from_value::<SpeedKeys>(value).unwrap(), cut);
    }

    #[test]
    fn empty_tracks_and_unclamped_curves_are_normalized_on_read() {
        assert!(serde_json::from_str::<SpeedKeys>(r#"{"segments":[],"origin":{"value":0,"timescale":1}}"#).is_err());
        let seg = r#"{"duration":{"value":1,"timescale":1},"from":{"num":1,"den":1},"to":{"num":2,"den":1},
            "reversed":false,"ease":{"interpolation":"bezier","out":{"dx":0.5,"dy":0.5},"in":{"dx":0.5,"dy":0.5}}}"#;
        let s: SpeedSegment = serde_json::from_str(seg).unwrap();
        assert!(s.ease().is_none(), "a diagonal curve is a straight ramp");
    }

    #[test]
    fn time_interpolation_titles() {
        assert_eq!(TimeInterpolation::FrameBlend.title(), "Blend frames");
        assert!(TimeInterpolation::OpticalFlow.mixes_frames() && !TimeInterpolation::FrameSampling.mixes_frames());
    }
}
