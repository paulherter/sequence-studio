// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioRetimer.swift
//! Renders one channel of a retimed (speed != 100 % and/or reversed) clip, stateless per output sample so any split of
//! the timeline into render blocks gives identical samples (seek, scrub, export all agree).
//!
//! Output frame `o` (0 = the clip's first output frame) reads the source at `origin +/- o * speed`. Nothing outside the
//! clip's source range `[src_start, src_end)` is ever read as signal: samples outside it are silence.
//! - `keeps_pitch == false`, or speed exactly 100 % (plain reverse): resampling with linear interpolation (varispeed:
//!   pitch follows speed; reverse at 100 % is bit exact).
//! - `keeps_pitch == true` and speed != 100 %: time-stretch by overlap-add. Hann grains of `2 * HOP` samples start every
//!   `HOP` output frames; grain `k` is a contiguous, unstretched piece of the source that starts exactly at
//!   `origin + k * HOP * speed`, so pitch is kept while the clip advances `speed` source seconds per second. A grain that
//!   would reach past the range is moved back inside it. Window weights of two overlapping grains sum to 1 (the first
//!   `HOP` frames use a flat window, so the clip start has no fade). No waveform alignment.
//!
//! Reverse reads the grain (or the interpolation span) forwards and mirrors it. All buffers are allocated in `new`.

use sq_media::media_error::MediaError;

/// Reads up to `buf.len()` frames of one channel starting at `from` (>= 0). Returns frames written.
pub type Read<'a> = &'a mut dyn FnMut(i64, &mut [f32]) -> Result<usize, MediaError>;
/// Media position (frames) at an output frame, and whether it plays backwards there.
pub type Position<'a> = &'a dyn Fn(i64) -> (f64, bool);

/// The retimed-clip renderer; owned by the feeder thread.
pub struct AudioRetimer {
    max_frames: usize,
    work: Vec<f32>,
    grain: Vec<f32>,
    window: Vec<f32>,
}

/// A clip played at one constant speed and direction.
#[derive(Clone, Copy, Debug)]
pub struct ConstantRetime {
    /// Source frame at output frame 0 (forward: where the clip starts reading; reversed: the end it reads backwards from,
    /// exclusive).
    pub origin: f64,
    /// Source frames per output frame (> 0), at most 100.
    pub speed: f64,
    pub reversed: bool,
    /// Time-stretch (pitch kept) instead of resampling when the speed is not exactly 100 %.
    pub keeps_pitch: bool,
}

/// Source range a retimed clip may read, and where `out[0]` lies in the clip.
#[derive(Clone, Copy, Debug)]
pub struct RetimeSpan {
    /// The clip's source range in frames; reads outside it are silence.
    pub src_start: i64,
    pub src_end: i64,
    /// Index of `out[0]`; negative inside a transition's head extension (the clip plays before its start).
    pub first_output: i64,
    /// Output frames before 0 that are valid (the length of that extension).
    pub lead: i64,
}

fn floor_div(a: i64, b: i64) -> i64 {
    let q = a / b;
    if a % b != 0 && (a < 0) != (b < 0) { q - 1 } else { q }
}

/// Reads the frames of `[from, from + dst.len())` that lie inside `[lo, hi)`; everything else is zero.
fn fetch(read: Read, from: i64, lo: i64, hi: i64, dst: &mut [f32]) -> Result<(), MediaError> {
    dst.fill(0.0);
    let count = dst.len() as i64;
    let a = from.max(lo).max(0);
    let b = (from + count).min(hi);
    if b <= a {
        return Ok(());
    }
    let off = (a - from) as usize;
    let len = (b - a) as usize;
    let got = read(a, &mut dst[off..off + len])?;
    if got < len {
        dst[off + got..off + len].fill(0.0);
    }
    Ok(())
}

impl AudioRetimer {
    pub const HOP: usize = 1024;
    /// Largest speed (10000 %) the interpolation span has to cover.
    const MAX_SPEED: usize = 100;

    pub fn new(max_frames: usize) -> AudioRetimer {
        let n = 2 * Self::HOP;
        AudioRetimer {
            max_frames,
            work: vec![0.0; max_frames * Self::MAX_SPEED + 8],
            grain: vec![0.0; n],
            window: (0..n)
                .map(|i| (0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / n as f64).cos()) as f32)
                .collect(),
        }
    }

    /// Constant speed: output frame `o` reads the source at `origin +/- o * speed`. A block over `max_frames` gets silence
    /// for the excess and a clamped speed, never a panic.
    pub fn render(
        &mut self,
        read: Read,
        retime: ConstantRetime,
        span: RetimeSpan,
        out: &mut [f32],
    ) -> Result<(), MediaError> {
        let ConstantRetime { origin, speed, reversed, keeps_pitch } = retime;
        if out.is_empty() {
            return Ok(());
        }
        let n = out.len().min(self.max_frames);
        let speed = speed.min(Self::MAX_SPEED as f64);
        out[n..].fill(0.0);
        let out = &mut out[..n];
        if keeps_pitch && speed != 1.0 {
            let start = |g_start: i64| -> i64 {
                if reversed {
                    ((origin - g_start as f64 * speed).round() as i64) - 2 * Self::HOP as i64
                } else {
                    (origin + g_start as f64 * speed).round() as i64
                }
            };
            self.stretch(read, &|g| (start(g), reversed), span, out)
        } else {
            let pos = |o: i64| if reversed { origin - o as f64 * speed - 1.0 } else { origin + o as f64 * speed };
            self.resample(read, &pos, span, out)
        }
    }

    /// Variable speed (clips with a speed track and clips inside retimed nested clips): the source position comes from
    /// `position(o)` (media frames at output frame `o`, relative to the grid origin; `true` = playing backwards there).
    /// Positions beyond the work buffer (a chain faster than 100x) give silence.
    pub fn render_mapped(
        &mut self,
        read: Read,
        position: Position,
        keeps_pitch: bool,
        span: RetimeSpan,
        out: &mut [f32],
    ) -> Result<(), MediaError> {
        if out.is_empty() {
            return Ok(());
        }
        let n = out.len().min(self.max_frames);
        out[n..].fill(0.0);
        let out = &mut out[..n];
        if keeps_pitch {
            let g = 2 * Self::HOP as i64;
            let start = |g_start: i64| -> (i64, bool) {
                let (p, reversed) = position(g_start);
                (if reversed { p.round() as i64 - g } else { p.round() as i64 }, reversed)
            };
            self.stretch(read, &start, span, out)
        } else {
            let pos = |o: i64| {
                let (p0, r) = position(o);
                if r { p0 - 1.0 } else { p0 }
            };
            self.resample(read, &pos, span, out)
        }
    }

    /// Linear interpolation at `pos(output frame)`.
    fn resample(
        &mut self,
        read: Read,
        pos: &dyn Fn(i64) -> f64,
        span: RetimeSpan,
        out: &mut [f32],
    ) -> Result<(), MediaError> {
        let first = span.first_output;
        let (mut lo, mut hi) = (i64::MAX, i64::MIN);
        for i in 0..out.len() as i64 {
            let fl = pos(first + i).floor() as i64;
            lo = lo.min(fl);
            hi = hi.max(fl + 1);
        }
        let n = (hi - lo) as usize + 1;
        if n > self.work.len() {
            out.fill(0.0);
            return Ok(());
        }
        fetch(read, lo, span.src_start, span.src_end, &mut self.work[..n])?;
        for (i, o) in out.iter_mut().enumerate() {
            let p = pos(first + i as i64);
            let fl = p.floor();
            let k = (fl as i64 - lo) as usize;
            let fr = (p - fl) as f32;
            *o = if fr == 0.0 { self.work[k] } else { self.work[k] * (1.0 - fr) + self.work[k + 1] * fr };
        }
        Ok(())
    }

    /// Overlap-add of grains; `start(g)` gives the unclamped source start of the grain at output frame `g` and its direction.
    fn stretch(
        &mut self,
        read: Read,
        start: &dyn Fn(i64) -> (i64, bool),
        span: RetimeSpan,
        out: &mut [f32],
    ) -> Result<(), MediaError> {
        let h = Self::HOP as i64;
        let g = 2 * Self::HOP;
        let (s0, s1) = (span.src_start, span.src_end);
        out.fill(0.0);
        let first = span.first_output;
        let last = first + out.len() as i64 - 1;
        let k_min = floor_div(-span.lead.max(0), h); // 0 unless the clip plays before its start (transition handle)
        let k_first = k_min.max(floor_div(first, h) - 1);
        let k_last = floor_div(last, h);
        if k_first > k_last {
            return Ok(());
        }
        for k in k_first..=k_last {
            let g_start = k * h;
            let lo = first.max(g_start);
            let hi = (last + 1).min(g_start + 2 * h);
            if lo >= hi {
                continue;
            }
            let (s, reversed) = start(g_start);
            // A grain that would pass the range is moved back inside it; reversed grains end at the mirrored position.
            let mut src = s;
            if reversed {
                src = src.max(s0);
                if s0 + g as i64 <= s1 {
                    src = src.min(s1 - g as i64);
                }
            } else {
                if s0 + g as i64 <= s1 {
                    src = src.min(s1 - g as i64);
                }
                src = src.max(s0);
            }
            fetch(read, src, s0, s1, &mut self.grain)?;
            for o in lo..hi {
                let i = (o - g_start) as usize;
                // Flat window on the clip's very first hop (no grain before it to overlap with).
                let w = if k == k_min && i < Self::HOP { 1.0 } else { self.window[i] };
                let s = if reversed { self.grain[g - 1 - i] } else { self.grain[i] };
                out[(o - first) as usize] += s * w;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ones(_: i64, dst: &mut [f32]) -> Result<usize, MediaError> {
        dst.fill(1.0);
        Ok(dst.len())
    }

    fn span(src_end: i64) -> RetimeSpan {
        RetimeSpan { src_start: 0, src_end, first_output: 0, lead: 0 }
    }

    fn plain(speed: f64) -> ConstantRetime {
        ConstantRetime { origin: 0.0, speed, reversed: false, keeps_pitch: false }
    }

    // A caller bug (oversized block, speed over the cap) must not panic a release build: silence for the excess, clamped speed.
    #[test]
    fn oversized_block_is_silenced_instead_of_trapping() {
        let mut r = AudioRetimer::new(256);
        let mut out = vec![7.0f32; 400];
        r.render(&mut ones, plain(1.0), span(10_000), &mut out).unwrap();
        assert!(out[256..].iter().all(|v| *v == 0.0));
        assert_ne!(out[0], 7.0);
    }

    #[test]
    fn speed_over_cap_is_clamped() {
        let mut r = AudioRetimer::new(256);
        let mut out = vec![0.0f32; 128];
        r.render(&mut ones, plain(500.0), span(1_000_000), &mut out).unwrap();
        assert!(out.iter().all(|v| v.is_finite()));
    }

    #[test]
    fn mapped_oversized_block_is_silenced() {
        let mut r = AudioRetimer::new(64);
        let mut out = vec![7.0f32; 100];
        r.render_mapped(&mut ones, &|o| (o as f64, false), false, span(10_000), &mut out).unwrap();
        assert!(out[64..].iter().all(|v| *v == 0.0));
    }

    /// Source that is 1.0 inside `[lo, hi)` and 100 (loud, easy to spot) everywhere else, `total` frames long.
    fn reader(lo: i64, hi: i64) -> impl FnMut(i64, &mut [f32]) -> Result<usize, MediaError> {
        let total = 4_000_000i64;
        move |from, dst| {
            let n = (dst.len() as i64).min(total - from).max(0) as usize;
            for (i, d) in dst.iter_mut().enumerate().take(n) {
                let p = from + i as i64;
                *d = if p >= lo && p < hi { 1.0 } else { 100.0 };
            }
            Ok(n)
        }
    }

    /// Renders the whole clip in blocks of 1024 and returns it.
    fn render_all(speed: f64, reversed: bool, keeps_pitch: bool, lo: i64, hi: i64) -> Vec<f32> {
        let out_frames = ((hi - lo) as f64 / speed).floor() as usize;
        let origin = if reversed { hi as f64 } else { lo as f64 };
        let mut r = AudioRetimer::new(1024);
        let mut out = vec![0.0f32; out_frames];
        let mut o = 0;
        while o < out_frames {
            let n = 1024.min(out_frames - o);
            let span = RetimeSpan { src_start: lo, src_end: hi, first_output: o as i64, lead: 0 };
            let retime = ConstantRetime { origin, speed, reversed, keeps_pitch };
            r.render(&mut reader(lo, hi), retime, span, &mut out[o..o + n]).unwrap();
            o += n;
        }
        out
    }

    #[test]
    fn never_reads_outside_the_range_and_edges_are_inside() {
        let lo = 300_000;
        for (speed, hi) in [(4.0, lo + 400_000), (0.25, lo + 20_000), (100.0, lo + 3_000_000)] {
            for reversed in [false, true] {
                let out = render_all(speed, reversed, true, lo, hi);
                assert!(out.len() > 3000);
                let mx = out.iter().copied().fold(f32::MIN, f32::max);
                assert!(mx <= 1.0001, "speed {speed} reversed {reversed}: leak {mx}");
                assert!(
                    (out[0] - 1.0).abs() < 1e-4 && (out[out.len() - 1] - 1.0).abs() < 1e-4,
                    "speed {speed} reversed {reversed}: edges"
                );
                // No dip to silence in the body or at the end.
                assert!(out[10..].iter().all(|v| *v > 0.99), "speed {speed} reversed {reversed}: dip");
            }
        }
    }

    #[test]
    fn resample_path_stays_inside_the_range_too() {
        let (lo, hi) = (1000, 41_000);
        for (speed, reversed) in [(4.0, false), (4.0, true), (0.25, false), (0.25, true), (100.0, false)] {
            let out = render_all(speed, reversed, false, lo, hi);
            assert!(out.iter().all(|v| *v <= 1.0001), "speed {speed} reversed {reversed}");
            assert!((out[0] - 1.0).abs() < 1e-4);
        }
    }

    #[test]
    fn range_shorter_than_a_grain_is_zero_padded_not_leaked() {
        let out = render_all(2.0, false, true, 5000, 6500);
        assert!(out.iter().all(|v| *v <= 1.0001));
    }
}
