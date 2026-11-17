// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioTimeMap.swift
//! The audio side of the one time mapping (`Clip::source_instant` / `SpeedKeys::position`): top-sequence time -> media
//! time through a chain of clips, in `f64` seconds. Audio only needs positions to a fraction of a sample, so nothing is
//! accumulated: every evaluation is closed form (constant: `source +/- speed * local`; ramp: `a t + (b - a) t^2 / 2T`, the
//! same formula as `SpeedSegment::span`). Direction is the product of the chain's signs.

use sq_core_model::{Clip, SpeedKeys};
use sq_core_time::Time;

#[derive(Clone, Copy, Debug)]
struct Segment {
    /// Clip-local seconds.
    start: f64,
    duration: f64,
    from: f64,
    to: f64,
    sign: f64,
    /// Source seconds at the segment start.
    pos: f64,
}

#[derive(Clone, Debug)]
struct Level {
    clip_start: f64,
    segments: Vec<Segment>,
    total: f64,
}

impl Level {
    /// Source seconds at `t` and the direction sign there.
    fn eval(&self, t: f64) -> (f64, f64) {
        let raw = t - self.clip_start;
        // Outside the clip (a transition's handle) the track runs on at its end speed and direction.
        if raw < 0.0 {
            let s = self.segments[0];
            return (s.pos + s.sign * s.from * raw, s.sign);
        }
        if raw > self.total
            && let Some(l) = self.segments.last()
        {
            return (l.pos + l.sign * l.duration * (l.from + l.to) / 2.0 + l.sign * l.to * (raw - self.total), l.sign);
        }
        let local = raw;
        let mut i = self.segments.len() - 1;
        for (j, s) in self.segments.iter().enumerate() {
            if local < s.start + s.duration {
                i = j;
                break;
            }
        }
        let s = self.segments[i];
        let tau = (local - s.start).max(0.0).min(s.duration);
        let d = if s.to == s.from || s.duration == 0.0 {
            s.from * tau
        } else {
            s.from * tau + (s.to - s.from) * tau * tau / (2.0 * s.duration)
        };
        (s.pos + s.sign * d, s.sign)
    }
}

/// Media position of a chain of clips (outermost nested clip first, the media clip last).
#[derive(Clone, Debug)]
pub struct AudioTimeMap {
    levels: Vec<Level>,
}

fn sec(t: Time) -> f64 {
    t.value() as f64 / t.timescale() as f64
}

fn ratio(s: sq_core_model::ClipSpeed) -> f64 {
    s.num() as f64 / s.den() as f64
}

fn level(c: &Clip) -> Level {
    let keys = SpeedKeys::of(c);
    let mut segs = Vec::with_capacity(keys.segments.len());
    let (mut t, mut pos) = (0.0, sec(keys.origin));
    for s in &keys.segments {
        let sign = if s.reversed { -1.0 } else { 1.0 };
        let (d, a, b) = (sec(s.duration), ratio(s.from), ratio(s.to));
        segs.push(Segment { start: t, duration: d, from: a, to: b, sign, pos });
        pos += sign * d * (a + b) / 2.0;
        t += d;
    }
    Level { clip_start: sec(c.start), segments: segs, total: t }
}

impl AudioTimeMap {
    /// `chain`: nested clips outermost first, then the clip that plays media.
    pub fn new<'a>(chain: impl IntoIterator<Item = &'a Clip>) -> AudioTimeMap {
        AudioTimeMap { levels: chain.into_iter().map(level).collect() }
    }

    /// Media position in frames of `rate` at top-sequence frame `frame` (absolute, may be fractional), and whether it plays
    /// backwards.
    pub fn position(&self, frame: f64, rate: f64) -> (f64, bool) {
        let mut t = frame / rate;
        let mut negative = false;
        for l in &self.levels {
            let (p, s) = l.eval(t);
            t = p;
            if s < 0.0 {
                negative = !negative;
            }
        }
        (t * rate, negative)
    }
}
