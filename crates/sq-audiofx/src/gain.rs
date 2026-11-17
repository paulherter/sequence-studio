//! Port of `SQAudioFX/Sources/SQAudioFX/Gain.swift`.

use serde::{Deserialize, Serialize};
use sq_core_time::{KeyframeTrack, Time};

/// Errors of the audio effects.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AudioFXError {
    UnsupportedSampleRate(i64),
    InvalidChannelCount(i64),
    /// The RNNoise C library could not allocate its state.
    DenoiserUnavailable,
}

impl std::fmt::Display for AudioFXError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AudioFXError::UnsupportedSampleRate(r) => write!(f, "unsupported sample rate {r}"),
            AudioFXError::InvalidChannelCount(c) => write!(f, "invalid channel count {c}"),
            AudioFXError::DenoiserUnavailable => f.write_str("noise reduction is unavailable"),
        }
    }
}

impl std::error::Error for AudioFXError {}

pub enum GainMath {}

impl GainMath {
    /// At or below this the gain is exact silence.
    pub const SILENCE_FLOOR_DB: f64 = -120.0;

    pub fn linear_from_db(db: f64) -> f64 {
        if db.is_nan() || db <= Self::SILENCE_FLOOR_DB {
            return 0.0;
        }
        10.0_f64.powf(db / 20.0)
    }

    pub fn db_from_linear(g: f64) -> f64 {
        if g <= 0.0 { f64::NEG_INFINITY } else { 20.0 * g.log10() }
    }
}

/// Clip/track volume in dB (static or keyframed) plus optional constant-power pan.
///
/// Gain is evaluated on an absolute-sample control grid (every `CONTROL_INTERVAL` samples) and
/// interpolated linearly per sample, so the result is sample-accurate, free of zipper noise,
/// and independent of how the audio is chunked.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct VolumeAutomation {
    #[serde(rename = "staticDB")]
    pub static_db: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track: Option<KeyframeTrack<f64>>,
    /// -1 (left) ... +1 (right); None = no pan processing. Stereo only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pan: Option<f64>,
    #[serde(rename = "panTrack", default, skip_serializing_if = "Option::is_none")]
    pub pan_track: Option<KeyframeTrack<f64>>,
}

impl Default for VolumeAutomation {
    fn default() -> Self {
        VolumeAutomation { static_db: 0.0, track: None, pan: None, pan_track: None }
    }
}

impl VolumeAutomation {
    pub const CONTROL_INTERVAL: i64 = 64;

    pub fn new(static_db: f64, track: Option<KeyframeTrack<f64>>, pan: Option<f64>) -> Self {
        VolumeAutomation { static_db, track, pan, pan_track: None }
    }

    pub fn db_at(&self, t: Time) -> f64 {
        if let Some(v) = self.track.as_ref().and_then(|tr| tr.value(t)) {
            return v;
        }
        self.static_db
    }

    pub(crate) fn pan_value(&self, t: Time) -> Option<f64> {
        if let Some(v) = self.pan_track.as_ref().and_then(|tr| tr.value(t)) {
            return Some(v.clamp(-1.0, 1.0));
        }
        self.pan.map(|p| p.clamp(-1.0, 1.0))
    }

    /// (left, right) gains, unity at center, constant power.
    pub(crate) fn pan_gains(p: f64) -> (f64, f64) {
        let a = (p + 1.0) * std::f64::consts::PI / 4.0;
        (a.cos() * 2.0_f64.sqrt(), a.sin() * 2.0_f64.sqrt())
    }

    /// Applies gain (and pan) in place. `start` is the timeline time of sample 0 of `buffer`.
    pub fn apply_to(&self, buffer: &mut [Vec<f32>], start: Time, sample_rate: i64) {
        let n = buffer.first().map_or(0, Vec::len);
        if n == 0 || sample_rate <= 0 {
            return;
        }
        let start_sample = Self::sample_index(start, sample_rate);
        let mut chans: Vec<&mut [f32]> = buffer.iter_mut().map(Vec::as_mut_slice).collect();
        self.apply(&mut chans, n, start_sample, sample_rate);
    }

    /// Allocation-free core (realtime path). `start_sample` = absolute sample index of sample 0.
    pub(crate) fn apply(&self, buffer: &mut [&mut [f32]], n: usize, start_sample: i64, sample_rate: i64) {
        if n == 0 || sample_rate <= 0 {
            return;
        }
        let rate = sample_rate;
        let step = Self::CONTROL_INTERVAL;
        let stereo_pan = buffer.len() == 2 && (self.pan.is_some() || self.pan_track.is_some());

        let gains = |abs: i64| -> (f64, f64) {
            let t = Time::new(abs, rate);
            let g = GainMath::linear_from_db(self.db_at(t));
            if stereo_pan && let Some(p) = self.pan_value(t) {
                let (l, r) = Self::pan_gains(p);
                return (g * l, g * r);
            }
            (g, g)
        };

        let mut k = (start_sample as f64 / step as f64).floor() as i64; // control point index
        let mut g0 = gains(k * step);
        let mut g1 = gains((k + 1) * step);
        for i in 0..n {
            let abs = start_sample + i as i64;
            while abs >= (k + 1) * step {
                k += 1;
                g0 = g1;
                g1 = gains((k + 1) * step);
            }
            let f = (abs - k * step) as f64 / step as f64;
            let gl = g0.0 + (g1.0 - g0.0) * f;
            let gr = g0.1 + (g1.1 - g0.1) * f;
            for (c, ch) in buffer.iter_mut().enumerate() {
                ch[i] *= (if c == 1 { gr } else { gl }) as f32;
            }
        }
    }

    pub(crate) fn sample_index(t: Time, rate: i64) -> i64 {
        let num = i128::from(t.value()) * i128::from(rate);
        let den = i128::from(t.timescale());
        let (q, r) = (num / den, num % den);
        let mut res = q;
        if r * 2 >= den {
            res += 1;
        } else if r * 2 <= -den {
            res -= 1;
        }
        res as i64
    }
}

/// Deterministic test signals shared by the DSP tests of this crate (Swift `Support.swift`).
#[cfg(test)]
pub(crate) mod sig {
    pub fn sine(freq: f64, amplitude_db: f64, seconds: f64, rate: i64, channels: usize, phase: f64) -> Vec<Vec<f32>> {
        let n = (seconds * rate as f64) as usize;
        let a = 10.0_f64.powf(amplitude_db / 20.0);
        let ch: Vec<f32> = (0..n)
            .map(|i| (a * (2.0 * std::f64::consts::PI * freq * i as f64 / rate as f64 + phase).sin()) as f32)
            .collect();
        vec![ch; channels]
    }

    /// Deterministic white noise, uniform in +-amp.
    pub fn noise(amplitude: f32, count: usize, seed: u64) -> Vec<f32> {
        let mut s = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (0..count)
            .map(|_| {
                s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                let u = ((s >> 40) & 0xFFFFFF) as f32 / 0xFFFFFF as f32;
                (u * 2.0 - 1.0) * amplitude
            })
            .collect()
    }

    /// Room/fan-like noise: white noise through a one-pole low-pass.
    pub fn low_noise(amplitude: f32, count: usize, seed: u64) -> Vec<f32> {
        let x = noise(amplitude, count, seed);
        let mut s: f32 = 0.0;
        x.iter()
            .map(|v| {
                s += 0.1 * (v - s);
                s * 3.0
            })
            .collect()
    }

    pub fn rms(x: &[f32]) -> f64 {
        if x.is_empty() {
            return 0.0;
        }
        (x.iter().fold(0.0, |a, &v| a + f64::from(v) * f64::from(v)) / x.len() as f64).sqrt()
    }

    /// Amplitude of the sinusoidal component at `freq` (single-bin DFT; use whole periods for exactness).
    pub fn amplitude(x: &[f32], freq: f64, rate: i64) -> f64 {
        let (mut re, mut im) = (0.0, 0.0);
        for (k, &v) in x.iter().enumerate() {
            let w = 2.0 * std::f64::consts::PI * freq * k as f64 / rate as f64;
            re += f64::from(v) * w.cos();
            im += f64::from(v) * w.sin();
        }
        2.0 * (re * re + im * im).sqrt() / x.len() as f64
    }

    pub fn db(a: f64) -> f64 {
        20.0 * a.max(1e-12).log10()
    }

    pub fn mono(freq: f64, amplitude_db: f64, seconds: f64, rate: i64) -> Vec<f32> {
        sine(freq, amplitude_db, seconds, rate, 1, 0.0).swap_remove(0)
    }

    /// Splits `x` into blocks of the given sizes (cycled).
    pub fn chunked(x: &[Vec<f32>], sizes: &[usize]) -> Vec<Vec<Vec<f32>>> {
        let n = x[0].len();
        let (mut out, mut pos, mut i) = (Vec::new(), 0, 0);
        while pos < n {
            let len = sizes[i % sizes.len()].min(n - pos);
            out.push(x.iter().map(|c| c[pos..pos + len].to_vec()).collect());
            pos += len;
            i += 1;
        }
        out
    }

    pub fn concat(parts: &[Vec<Vec<f32>>], channels: usize) -> Vec<Vec<f32>> {
        (0..channels).map(|c| parts.iter().flat_map(|p| p[c].iter().copied()).collect()).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::{Id, Interpolation, Keyframe};

    fn key(n: u128, t: Time, v: f64) -> Keyframe<f64> {
        Keyframe::new(Id::from_u128(n), t, v)
    }

    #[test]
    fn db_conversion() {
        assert_eq!(GainMath::linear_from_db(0.0), 1.0);
        assert!((GainMath::linear_from_db(6.0206) - 2.0).abs() < 1e-4);
        assert_eq!(GainMath::linear_from_db(f64::NEG_INFINITY), 0.0);
        assert_eq!(GainMath::linear_from_db(-120.0), 0.0);
        assert_eq!(GainMath::db_from_linear(0.0), f64::NEG_INFINITY);
        assert!((GainMath::db_from_linear(0.5) + 6.0206).abs() < 1e-3);
        assert!((GainMath::db_from_linear(GainMath::linear_from_db(-17.3)) + 17.3).abs() < 1e-9);
    }

    #[test]
    fn static_gain() {
        let v = VolumeAutomation::new(-6.0206, None, None);
        let mut b = vec![vec![1.0_f32; 200]; 2];
        v.apply_to(&mut b, Time::ZERO, 48000);
        for c in &b {
            for s in c {
                assert!((s - 0.5).abs() < 1e-4);
            }
        }
    }

    #[test]
    fn mute_is_exact_silence() {
        let v = VolumeAutomation::new(f64::NEG_INFINITY, None, None);
        let mut b = vec![vec![0.7_f32; 100]];
        v.apply_to(&mut b, Time::ZERO, 48000);
        assert!(b[0].iter().all(|&s| s == 0.0));
    }

    #[test]
    fn keyframed_ramp_follows_track() {
        let mut track = KeyframeTrack::<f64>::new();
        track.insert(key(1, Time::ZERO, 0.0));
        track.insert(key(2, Time::new(1, 1), -20.0));
        let v = VolumeAutomation::new(0.0, Some(track), None);
        let mut b = vec![vec![1.0_f32; 48000]];
        v.apply_to(&mut b, Time::ZERO, 48000);
        // half way: -10 dB
        let mid = f64::from(b[0][24000]);
        assert!((20.0 * mid.log10() + 10.0).abs() < 0.05);
        assert!((b[0][0] - 1.0).abs() < 1e-6);
    }

    #[test]
    fn chunking_gives_identical_result_and_no_steps() {
        let mut track = KeyframeTrack::<f64>::new();
        track.insert(key(1, Time::new(1, 10), 0.0));
        let mut k2 = key(2, Time::new(3, 10), -30.0);
        k2.interpolation = Interpolation::Bezier;
        track.insert(k2);
        let v = VolumeAutomation::new(0.0, Some(track), None);
        let n = 24000;
        let ones = vec![vec![1.0_f32; n]];
        let mut whole = ones.clone();
        v.apply_to(&mut whole, Time::ZERO, 48000);
        let mut parts: Vec<f32> = Vec::new();
        let mut pos = 0;
        let mut lens = vec![1, 63, 64, 65, 1000, 7, 4096];
        lens.extend(std::iter::repeat_n(333, 100));
        for len in lens {
            if pos >= n {
                break;
            }
            let l = len.min(n - pos);
            let mut p = vec![ones[0][pos..pos + l].to_vec()];
            v.apply_to(&mut p, Time::new(pos as i64, 48000), 48000);
            parts.extend_from_slice(&p[0]);
            pos += l;
        }
        assert_eq!(parts, whole[0]);
        // zipper check: max sample-to-sample gain step is tiny
        let mut max_step: f32 = 0.0;
        for i in 1..n {
            max_step = max_step.max((whole[0][i] - whole[0][i - 1]).abs());
        }
        assert!(max_step < 0.001);
    }

    #[test]
    fn pan_constant_power() {
        let mut v = VolumeAutomation::new(0.0, None, None);
        v.pan = Some(0.0);
        let mut b = vec![vec![1.0_f32; 10]; 2];
        v.apply_to(&mut b, Time::ZERO, 48000);
        assert!((b[0][5] - 1.0).abs() < 1e-5 && (b[1][5] - 1.0).abs() < 1e-5);
        v.pan = Some(1.0);
        b = vec![vec![1.0_f32; 10]; 2];
        v.apply_to(&mut b, Time::ZERO, 48000);
        assert!(b[0][5].abs() < 1e-5);
        assert!((b[1][5] - 2.0_f32.sqrt()).abs() < 1e-4);
        v.pan = Some(-0.5);
        b = vec![vec![1.0_f32; 10]; 2];
        v.apply_to(&mut b, Time::ZERO, 48000);
        assert!((b[0][5] * b[0][5] + b[1][5] * b[1][5] - 2.0).abs() < 1e-4);
    }

    #[test]
    fn codable_round_trip() {
        let mut t = KeyframeTrack::<f64>::new();
        t.insert(key(1, Time::ZERO, -3.0));
        let mut v = VolumeAutomation::new(2.0, Some(t), None);
        v.pan = Some(0.25);
        let d = serde_json::to_string(&v).unwrap_or_default();
        assert_eq!(serde_json::from_str::<VolumeAutomation>(&d).ok(), Some(v));
    }
}
