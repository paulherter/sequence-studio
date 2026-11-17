// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: BeatDetector.swift
//! Non-ML beat tracker: log-magnitude spectral flux onset envelope, autocorrelation tempo with a log-normal prior around
//! 120 BPM, dynamic-programming beat tracking (Ellis 2007) and a downbeat phase picked by accumulated onset strength.
//!
//! Same limit as Swift: assumes a fixed meter (`beats_per_bar`, default 4) and a roughly steady tempo; no ML model is shipped (same
//! limit as Swift). The FFT is a plain radix-2 (the Mac uses vDSP); the Hann window is the plain 0.5(1-cos) one, so the
//! onset values differ from Accelerate's normalized window by a constant factor that the envelope normalization removes.

use crate::beat_grid::BeatGrid;
use sq_core_time::Time;

/// Tracker settings.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BeatSettings {
    /// Slowest tempo searched.
    pub minimum_bpm: f64,
    /// Fastest tempo searched.
    pub maximum_bpm: f64,
    /// Beats in a bar.
    pub beats_per_bar: usize,
    /// How strongly beats are pulled toward the tempo period (higher = more rigid).
    pub tightness: f64,
}

impl Default for BeatSettings {
    fn default() -> BeatSettings {
        BeatSettings { minimum_bpm: 60.0, maximum_bpm: 200.0, beats_per_bar: 4, tightness: 100.0 }
    }
}

const FFT_SIZE: usize = 1024;

/// Mono samples at `sample_rate`. `None` for silence, noise without a pulse, or less than three seconds.
// Swift: BeatDetector.swift:21
pub fn analyze(samples: &[f32], sample_rate: i64, s: &BeatSettings) -> Option<BeatGrid> {
    if sample_rate <= 0 || s.beats_per_bar == 0 || (samples.len() as i64) < sample_rate * 3 {
        return None;
    }
    let hop = ((sample_rate as f64 / 100.0).round() as usize).max(1);
    let mut env = onset_envelope(samples, hop);
    if env.len() <= 100 {
        return None;
    }
    normalize(&mut env);
    let period = tempo_period(&env, sample_rate as f64 / hop as f64, s)?;
    let frames = track_beats(&env, period, s.tightness);
    if frames.len() < 4 {
        return None;
    }
    let phase = downbeat_phase(&frames, &env, s.beats_per_bar);
    // Onset flux peaks about a quarter window before the event (Hann slope), so shift forward.
    let bias = FFT_SIZE / 4;
    let beats: Vec<Time> = frames.iter().map(|f| Time::new((f * hop + bias) as i64, sample_rate)).collect();
    let downs: Vec<usize> = (phase..beats.len()).step_by(s.beats_per_bar).collect();
    let bpm = 60.0 * sample_rate as f64 / hop as f64 / period;
    Some(BeatGrid { beats, downbeat_beat_indices: downs, beats_per_bar: s.beats_per_bar as i64, bpm })
}

/// In-place radix-2 FFT of `re`/`im` (length a power of two).
fn fft(re: &mut [f32], im: &mut [f32]) {
    let n = re.len();
    let mut j = 0;
    for i in 1..n {
        let mut bit = n >> 1;
        while j & bit != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j |= bit;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }
    let mut len = 2;
    while len <= n {
        let ang = -2.0 * std::f64::consts::PI / len as f64;
        let (wr, wi) = (ang.cos() as f32, ang.sin() as f32);
        for start in (0..n).step_by(len) {
            let (mut cr, mut ci) = (1.0f32, 0.0f32);
            for k in 0..len / 2 {
                let (a, b) = (start + k, start + k + len / 2);
                let (tr, ti) = (re[b] * cr - im[b] * ci, re[b] * ci + im[b] * cr);
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
                let nr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = nr;
            }
        }
        len <<= 1;
    }
}

// Swift: BeatDetector.swift:43
fn onset_envelope(samples: &[f32], hop: usize) -> Vec<f32> {
    let (n, half) = (FFT_SIZE, FFT_SIZE / 2);
    let window: Vec<f32> =
        (0..n).map(|k| (0.5 * (1.0 - (2.0 * std::f64::consts::PI * k as f64 / n as f64).cos())) as f32).collect();
    let frame_count = samples.len() / hop;
    let mut prev = vec![0.0f32; half];
    let mut out = vec![0.0f32; frame_count];
    let (mut re, mut im) = (vec![0.0f32; n], vec![0.0f32; n]);
    for (f, o) in out.iter_mut().enumerate() {
        let start = (f * hop) as i64 - half as i64;
        for k in 0..n {
            let idx = start + k as i64;
            re[k] = if idx >= 0 && (idx as usize) < samples.len() { samples[idx as usize] * window[k] } else { 0.0 };
            im[k] = 0.0;
        }
        fft(&mut re, &mut im);
        let mut flux = 0.0f32;
        for k in 1..half {
            // vDSP's real FFT output is twice the plain DFT.
            let m = (2.0 * (re[k] * re[k] + im[k] * im[k]).sqrt()).ln_1p();
            flux += (m - prev[k]).max(0.0);
            prev[k] = m;
        }
        *o = flux;
    }
    out
}

/// Subtracts a ~0.5 s moving mean, clamps at 0, scales to unit standard deviation.
// Swift: BeatDetector.swift:79
fn normalize(env: &mut Vec<f32>) {
    let (n, w) = (env.len(), 25usize);
    let mut cum = vec![0.0f64; n + 1];
    for i in 0..n {
        cum[i + 1] = cum[i] + f64::from(env[i]);
    }
    let out: Vec<f32> = (0..n)
        .map(|i| {
            let (lo, hi) = (i.saturating_sub(w), (i + w + 1).min(n));
            let mean = (cum[hi] - cum[lo]) / (hi - lo) as f64;
            (env[i] - mean as f32).max(0.0)
        })
        .collect();
    let (mut sum, mut sq) = (0.0f64, 0.0f64);
    for v in &out {
        sum += f64::from(*v);
        sq += f64::from(*v) * f64::from(*v);
    }
    let mean = sum / n as f64;
    let sd = (sq / n as f64 - mean * mean).max(0.0).sqrt();
    *env = if sd < 1e-4 { vec![0.0; n] } else { out.iter().map(|v| v / sd as f32).collect() };
}

/// Beat period in frames (fractional), or `None` when the envelope has no pulse.
// Swift: BeatDetector.swift:98
fn tempo_period(env: &[f32], fps: f64, s: &BeatSettings) -> Option<f64> {
    let n = env.len();
    let min_lag = 2.max((60.0 * fps / s.maximum_bpm).floor() as usize);
    let max_lag = (n / 2).min((60.0 * fps / s.minimum_bpm).ceil() as usize);
    if min_lag >= max_lag {
        return None;
    }
    let acf = |lag: usize| -> f64 {
        let d: f32 = env[..n - lag].iter().zip(&env[lag..]).map(|(a, b)| a * b).sum();
        f64::from(d) / (n - lag) as f64
    };
    let mut scores = vec![0.0f64; max_lag + 2];
    for (lag, score) in scores.iter_mut().enumerate().skip(min_lag - 1) {
        if lag >= 1 && lag < n {
            *score = acf(lag);
        }
    }
    let (mut best, mut best_lag) = (-1.0f64, 0usize);
    for (lag, &lag_score) in scores.iter().enumerate().take(max_lag + 1).skip(min_lag) {
        let bpm = 60.0 * fps / lag as f64;
        let o = (bpm / 120.0).log2() / 0.8;
        let v = lag_score * (-0.5 * o * o).exp();
        if v > best {
            best = v;
            best_lag = lag;
        }
    }
    if best_lag == 0 || best <= 0.02 {
        return None;
    }
    let (a, b, c) = (scores[best_lag - 1], scores[best_lag], scores[best_lag + 1]);
    let denom = a - 2.0 * b + c;
    let shift = if denom.abs() > 1e-9 { 0.5 * (a - c) / denom } else { 0.0 };
    Some(best_lag as f64 + shift.clamp(-1.0, 1.0))
}

// Swift: BeatDetector.swift:128
fn track_beats(env: &[f32], period: f64, tightness: f64) -> Vec<usize> {
    let n = env.len();
    let mut score: Vec<f64> = env.iter().map(|v| f64::from(*v)).collect();
    let mut back = vec![-1i64; n];
    let lo = 1.max((period / 2.0).floor() as usize);
    let hi = (period * 2.0).ceil() as usize;
    for i in 0..n {
        if i < lo {
            continue;
        }
        let (mut best, mut arg) = (0.0f64, -1i64);
        for (j, &sj) in score.iter().enumerate().take(i - lo + 1).skip(i.saturating_sub(hi)) {
            let r = ((i - j) as f64 / period).ln();
            let v = sj - tightness * r * r;
            if arg < 0 || v > best {
                best = v;
                arg = j as i64;
            }
        }
        if arg >= 0 && best > 0.0 {
            score[i] = f64::from(env[i]) + best;
            back[i] = arg;
        }
    }
    let tail = n.saturating_sub((period * 1.5) as usize);
    // Swift `max(by:)` keeps the last of equal scores.
    let mut cur = (tail..n).fold(None::<usize>, |m, i| match m {
        Some(b) if score[i] < score[b] => Some(b),
        _ => Some(i),
    });
    let mut frames: Vec<usize> = vec![];
    while let Some(c) = cur {
        frames.push(c);
        cur = (back[c] >= 0).then(|| back[c] as usize);
    }
    frames.reverse();
    let strength = |f: usize| -> f32 { (f.saturating_sub(2)..=(n - 1).min(f + 2)).map(|k| env[k]).fold(0.0, f32::max) };
    let mut sorted: Vec<f32> = frames.iter().map(|f| strength(*f)).collect();
    sorted.sort_by(|a, b| a.total_cmp(b));
    if sorted.is_empty() {
        return vec![];
    }
    let floor = sorted[sorted.len() / 2] * 0.25;
    while frames.first().is_some_and(|f| strength(*f) < floor) {
        frames.remove(0);
    }
    while frames.last().is_some_and(|f| strength(*f) < floor) {
        frames.pop();
    }
    frames
}

/// The beat phase (0..beats_per_bar) whose beats carry the most onset strength on average.
// Swift: BeatDetector.swift:166
fn downbeat_phase(frames: &[usize], env: &[f32], beats_per_bar: usize) -> usize {
    if beats_per_bar <= 1 {
        return 0;
    }
    let (mut sum, mut cnt) = (vec![0.0f64; beats_per_bar], vec![0usize; beats_per_bar]);
    for (i, f) in frames.iter().enumerate() {
        let m = (f.saturating_sub(2)..=(env.len() - 1).min(f + 2)).map(|k| env[k]).fold(0.0, f32::max);
        sum[i % beats_per_bar] += f64::from(m);
        cnt[i % beats_per_bar] += 1;
    }
    let (mut best, mut best_v) = (0usize, -1.0f64);
    for p in 0..beats_per_bar {
        if cnt[p] > 0 {
            let v = sum[p] / cnt[p] as f64;
            if v > best_v + 1e-9 {
                best_v = v;
                best = p;
            }
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secs(t: Time) -> f64 {
        t.value() as f64 / t.timescale() as f64
    }

    /// A click track: a short decaying burst every `period` samples, the first of each bar louder.
    fn clicks(rate: usize, seconds: usize, bpm: f64) -> Vec<f32> {
        let mut v = vec![0.0f32; rate * seconds];
        let step = rate as f64 * 60.0 / bpm;
        let mut i = 0usize;
        loop {
            let at = (i as f64 * step) as usize;
            if at + 400 >= v.len() {
                break;
            }
            let gain = if i.is_multiple_of(4) { 1.0 } else { 0.5 };
            for k in 0..400 {
                v[at + k] += gain * (-(k as f32) / 60.0).exp() * ((k as f32) * 0.9).sin();
            }
            i += 1;
        }
        v
    }

    #[test]
    fn a_120_bpm_click_track_gives_half_second_beats_and_the_loud_click_as_downbeat() {
        let g = analyze(&clicks(22050, 14, 120.0), 22050, &BeatSettings::default()).expect("grid");
        assert!((g.bpm - 120.0).abs() < 3.0, "bpm {}", g.bpm);
        let gaps: Vec<f64> = g.beats.windows(2).map(|w| secs(w[1] - w[0])).collect();
        assert!(gaps.iter().all(|d| (d - 0.5).abs() < 0.05), "{gaps:?}");
        assert_eq!(g.beats_per_bar, 4);
        // The loud clicks sit at 0, 2, 4 ... s: a downbeat is within 50 ms of a multiple of 2 s.
        let d = secs(g.beats[g.downbeat_beat_indices[1]]);
        assert!(((d / 2.0) - (d / 2.0).round()).abs() * 2.0 < 0.05, "downbeat at {d}");
    }

    #[test]
    fn silence_and_short_audio_have_no_beats() {
        assert!(analyze(&vec![0.0; 22050 * 10], 22050, &BeatSettings::default()).is_none());
        assert!(analyze(&clicks(22050, 2, 120.0), 22050, &BeatSettings::default()).is_none());
        assert!(analyze(&[0.1; 10], 0, &BeatSettings::default()).is_none());
    }
}
