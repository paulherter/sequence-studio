// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SpeedRampPreset.swift
//! Speed Ramp presets: one-click speed tracks (slow, ramp up to a peak, hold, ramp down) built on the clip's source range,
//! with the peak optionally put on a beat.

use serde::{Deserialize, Serialize};
use sq_core_model::{ClipSpeed, EaseShape, Rational, SpeedKeys, SpeedSegment};
use sq_core_time::{EaseHandle, Interpolation, Time};

/// The built-in speed ramps.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SpeedRampPreset {
    /// Slow in, fast out.
    Surge,
    /// Fast in, slow out.
    Rush,
    /// Sharp burst, then slow motion.
    Punch,
    /// Quick swell and back.
    Pulse,
    /// Smooth rise, fast plateau, smooth fall.
    Crest,
}

/// Weight (relative timeline length), start speed, end speed (ratios).
#[derive(Clone, Copy)]
struct Piece {
    weight: f64,
    from: f64,
    to: f64,
}

const fn piece(weight: f64, from: f64, to: f64) -> Piece {
    Piece { weight, from, to }
}

impl SpeedRampPreset {
    /// Every preset, in menu order.
    pub const ALL: [SpeedRampPreset; 5] = [Self::Surge, Self::Rush, Self::Punch, Self::Pulse, Self::Crest];

    /// Menu title.
    pub fn title(self) -> &'static str {
        match self {
            Self::Surge => "Surge",
            Self::Rush => "Rush",
            Self::Punch => "Punch",
            Self::Pulse => "Pulse",
            Self::Crest => "Crest",
        }
    }

    /// One-line description.
    pub fn detail(self) -> &'static str {
        match self {
            Self::Surge => "Slow in, fast out",
            Self::Rush => "Fast in, slow out",
            Self::Punch => "Sharp burst, then slow motion",
            Self::Pulse => "Quick swell and back",
            Self::Crest => "Smooth rise, fast plateau, smooth fall",
        }
    }

    fn pieces(self) -> Vec<Piece> {
        match self {
            Self::Surge => {
                vec![piece(0.30, 0.4, 0.4), piece(0.30, 0.4, 2.8), piece(0.30, 2.8, 2.8), piece(0.10, 2.8, 1.0)]
            }
            Self::Rush => {
                vec![piece(0.10, 1.0, 2.8), piece(0.25, 2.8, 2.8), piece(0.30, 2.8, 0.4), piece(0.35, 0.4, 0.4)]
            }
            Self::Punch => vec![
                piece(0.20, 1.0, 1.0),
                piece(0.12, 1.0, 2.8),
                piece(0.08, 2.8, 2.8),
                piece(0.12, 2.8, 0.3),
                piece(0.28, 0.3, 0.3),
                piece(0.20, 0.3, 1.0),
            ],
            Self::Pulse => vec![
                piece(0.25, 1.0, 1.0),
                piece(0.20, 1.0, 2.5),
                piece(0.10, 2.5, 2.5),
                piece(0.20, 2.5, 1.0),
                piece(0.25, 1.0, 1.0),
            ],
            Self::Crest => vec![
                piece(0.15, 1.0, 1.0),
                piece(0.25, 1.0, 2.75),
                piece(0.20, 2.75, 2.75),
                piece(0.25, 2.75, 1.0),
                piece(0.15, 1.0, 1.0),
            ],
        }
    }

    /// Index of the constant segment at the peak speed (the first one when two tie, as Swift's `max(by:)`).
    fn peak_index(p: &[Piece]) -> usize {
        let mut best: Option<usize> = None;
        for i in (0..p.len()).filter(|&i| p[i].from == p[i].to) {
            if best.is_none_or(|b| p[b].from < p[i].from) {
                best = Some(i);
            }
        }
        best.unwrap_or(0)
    }

    /// Ease-in/out S-curve for the ramps.
    fn s_curve() -> EaseShape {
        EaseShape::new(Interpolation::Bezier, EaseHandle { dx: 0.42, dy: 0.0 }, EaseHandle { dx: 0.42, dy: 0.0 })
    }

    /// The preset's own peak position as a fraction of its length.
    fn default_peak(p: &[Piece]) -> f64 {
        let i = Self::peak_index(p);
        p[..i].iter().fold(0.0, |a, x| a + x.weight) + p[i].weight / 2.0
    }

    /// The speed track for a clip whose current track is `base`, over the same source range and direction.
    /// `peak_at` (clip-local) puts the peak at that time, clamped to the middle 84 % of the new clip; `None` keeps the
    /// preset's own.
    pub fn keys(self, base: &SpeedKeys, frame_duration: Time, peak_at: Option<Time>) -> SpeedKeys {
        let reversed = base.segments[0].reversed;
        let hull = base.hull();
        let origin = if reversed { hull.end() } else { hull.start };
        let fd_sec = Rational::from_time(frame_duration).double();
        let src_frames = Rational::from_time(hull.duration).double() / fd_sec;
        // The plateau keeps its share of the clip; the pieces before and after it share the rest around the peak center `r`.
        let all = self.pieces();
        let pi = Self::peak_index(&all);
        let (pre, plateau, post) = (&all[..pi], all[pi], &all[pi + 1..]);
        let q = plateau.weight;
        let avg = |ps: &[Piece]| ps.iter().fold(0.0, |a, x| a + x.weight * (x.from + x.to) / 2.0);
        let sum_w = |ps: &[Piece]| ps.iter().fold(0.0, |a, x| a + x.weight);
        let (pre_w, post_w) = (sum_w(pre), sum_w(post));
        // Timeline frames T for peak center r: source = T * (preShare * avgPre/preW + postShare * avgPost/postW + q * peak).
        let frames = |r: f64| {
            src_frames
                / ((r - q / 2.0) * (avg(pre) / pre_w) + (1.0 - r - q / 2.0) * (avg(post) / post_w) + q * plateau.from)
        };
        let mut r = Self::default_peak(&all);
        if let Some(b) = peak_at {
            let want = Rational::from_time(b).double() / fd_sec;
            // r * frames(r) rises with r (a Moebius map), so bisection finds the r that lands the peak on `want`.
            let (mut lo, mut hi) = (q / 2.0 + 0.06, 1.0 - q / 2.0 - 0.06);
            for _ in 0..50 {
                let mid = (lo + hi) / 2.0;
                if mid * frames(mid) < want {
                    lo = mid;
                } else {
                    hi = mid;
                }
            }
            r = (lo + hi) / 2.0;
        }
        let total = frames(r).max(8.0);
        // Boundaries in whole frames (cumulative rounding), at least one frame per segment.
        let mut edges = vec![0.0];
        let mut acc = 0.0;
        for pc in pre {
            acc += pc.weight / pre_w * (r - q / 2.0);
            edges.push(acc);
        }
        acc += q;
        edges.push(acc);
        for pc in post {
            acc += pc.weight / post_w * (1.0 - r - q / 2.0);
            edges.push(acc);
        }
        let mut bounds: Vec<i64> = vec![0];
        for (i, e) in edges.iter().enumerate().skip(1) {
            bounds.push(((e * total).round() as i64).max(bounds[i - 1] + 1));
        }
        let merged: Vec<Piece> = pre.iter().copied().chain([plateau]).chain(post.iter().copied()).collect();
        let mut out: Vec<SpeedSegment> = Vec::new();
        for (i, pc) in merged.iter().enumerate() {
            let ease = (pc.from != pc.to).then(Self::s_curve);
            let seg = SpeedSegment::new(
                frame_duration * (bounds[i + 1] - bounds[i]),
                ClipSpeed::from_percent(pc.from * 100.0),
                Some(ClipSpeed::from_percent(pc.to * 100.0)),
                reversed,
                ease,
            );
            // The two halves of the peak plateau are one constant stretch.
            match out.last_mut() {
                Some(last) if last.joins(&seg) => last.duration += seg.duration,
                _ => out.push(seg),
            }
        }
        SpeedKeys::new(out, origin)
    }
}

/// Swift `SpeedKeys.peakTime`.
pub trait SpeedKeysPeak {
    /// Clip-local time of the fastest point: the middle of the fastest constant stretch, else the fastest key.
    fn peak_time(&self) -> Time;
}

impl SpeedKeysPeak for SpeedKeys {
    fn peak_time(&self) -> Time {
        // A plateau beats the ramp that ends on it (a hair more, so the tie breaks to the plateau).
        let top = |s: &SpeedSegment| s.from.percent().max(s.to.percent()) + if s.is_ramp() { 0.0 } else { 0.001 };
        let b = self.boundaries();
        let mut best: Option<usize> = None;
        for i in 0..self.segments.len() {
            if best.is_none_or(|j| top(&self.segments[j]) < top(&self.segments[i])) {
                best = Some(i);
            }
        }
        let Some(i) = best else { return Time::ZERO };
        let s = &self.segments[i];
        if !s.is_ramp() {
            return b[i] + s.duration.halved();
        }
        if s.to.percent() >= s.from.percent() { b[i + 1] } else { b[i] }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, TrackKind};
    use sq_core_time::{Id, TimeRange};

    fn fd() -> Time {
        Time::new(1, 30)
    }

    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }

    fn clip() -> Clip {
        let source = TimeRange::new(f(300), f(150));
        let mut c = Clip::new(Id::from_u128(1), "c", Id::from_u128(2), TrackKind::Video, source, Time::ZERO);
        c.media_duration = Some(f(3000));
        c
    }

    fn peak(k: &SpeedKeys) -> f64 {
        k.segments.iter().map(|s| s.from.percent().max(s.to.percent()) / 100.0).fold(0.0, f64::max)
    }

    #[test]
    fn every_preset_peaks_between_250_and_300_percent_and_keeps_the_source() {
        let base = SpeedKeys::of(&clip());
        for p in SpeedRampPreset::ALL {
            let k = p.keys(&base, fd(), None);
            assert!(peak(&k) >= 2.5 && peak(&k) <= 3.0, "{p:?}");
            assert!(k.segments.len() > 1);
            let h = k.hull();
            // The whole source range stays in use (up to the frame rounding of the segment lengths).
            assert!((Rational::from_time(h.duration).double() - 5.0).abs() < 0.15, "{p:?}");
            assert_eq!(h.start, f(300));
            assert!(k.segments.iter().all(|s| s.duration >= fd()));
        }
    }

    #[test]
    fn each_ramp_is_an_ease_in_out_s_curve() {
        let k = SpeedRampPreset::Crest.keys(&SpeedKeys::of(&clip()), fd(), None);
        let ramps: Vec<_> = k.segments.iter().filter(|s| s.is_ramp()).collect();
        assert!(!ramps.is_empty());
        assert!(ramps.iter().all(|s| s.ease().is_some()));
    }

    #[test]
    fn hit_on_beat_puts_the_peak_on_the_beat() {
        let base = SpeedKeys::of(&clip());
        for p in SpeedRampPreset::ALL {
            for b in [f(35), f(45), f(55)] {
                let t = p.keys(&base, fd(), Some(b)).peak_time();
                assert!(Rational::from_time(t - b).double().abs() <= 2.0 / 30.0, "{p:?} beat {b:?} got {t:?}");
            }
        }
    }

    #[test]
    fn reversed_clips_stay_reversed() {
        let mut c = clip();
        c.reversed = true;
        let k = SpeedRampPreset::Punch.keys(&SpeedKeys::of(&c), fd(), None);
        assert!(k.segments.iter().all(|s| s.reversed));
        assert_eq!(k.origin, f(450));
    }

    #[test]
    fn titles_and_stored_names() {
        assert_eq!(SpeedRampPreset::Crest.title(), "Crest");
        assert_eq!(serde_json::to_string(&SpeedRampPreset::Surge).ok().as_deref(), Some("\"surge\""));
    }
}
