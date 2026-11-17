//! Whisper's log-mel features in Rust: 16 kHz mono floats in, an 80 x 3000 matrix out (30 seconds, hop 10 ms), the same
//! numbers as OpenAI's / Hugging Face's `WhisperFeatureExtractor` (Hann window, reflect padding, Slaney mel filters, log10,
//! clamp to max - 8, scale by 4).

use std::f64::consts::PI;

/// Samples per second the models expect.
pub const SAMPLE_RATE: usize = 16_000;
/// FFT window length.
pub const N_FFT: usize = 400;
/// Samples between two frames.
pub const HOP: usize = 160;
/// One chunk is 30 seconds.
pub const CHUNK_SAMPLES: usize = SAMPLE_RATE * 30;
/// Frames of one chunk.
pub const N_FRAMES: usize = CHUNK_SAMPLES / HOP;
/// Frequency bins of the one-sided spectrum.
pub const N_BINS: usize = N_FFT / 2 + 1;

fn hz_to_mel(hz: f64) -> f64 {
    // Slaney: linear below 1 kHz, logarithmic above.
    let (f_sp, min_log_hz) = (200.0 / 3.0, 1000.0);
    if hz < min_log_hz { hz / f_sp } else { min_log_hz / f_sp + (hz / min_log_hz).ln() / (6.4f64.ln() / 27.0) }
}

fn mel_to_hz(mel: f64) -> f64 {
    let (f_sp, min_log_hz) = (200.0 / 3.0, 1000.0);
    let min_log_mel = min_log_hz / f_sp;
    if mel < min_log_mel { mel * f_sp } else { min_log_hz * ((mel - min_log_mel) * (6.4f64.ln() / 27.0)).exp() }
}

/// The triangular Slaney mel filter bank, `n_mels` rows of `N_BINS` weights (area normalized).
pub fn mel_filters(n_mels: usize) -> Vec<f32> {
    let top = hz_to_mel(SAMPLE_RATE as f64 / 2.0);
    let edges: Vec<f64> = (0..n_mels + 2).map(|i| mel_to_hz(top * i as f64 / (n_mels + 1) as f64)).collect();
    let mut out = vec![0f32; n_mels * N_BINS];
    for m in 0..n_mels {
        let (lo, mid, hi) = (edges[m], edges[m + 1], edges[m + 2]);
        let norm = 2.0 / (hi - lo);
        for k in 0..N_BINS {
            let f = SAMPLE_RATE as f64 / 2.0 * k as f64 / (N_BINS - 1) as f64;
            let w = ((f - lo) / (mid - lo)).min((hi - f) / (hi - mid)).max(0.0);
            out[m * N_BINS + k] = (w * norm) as f32;
        }
    }
    out
}

/// The feature extractor: tables are built once.
pub struct LogMel {
    n_mels: usize,
    filters: Vec<f32>,
    window: Vec<f32>,
    cos: Vec<f32>,
    sin: Vec<f32>,
}

impl LogMel {
    /// An extractor with `n_mels` (80 for tiny/base/small/medium, 128 for large-v3).
    pub fn new(n_mels: usize) -> LogMel {
        let window = (0..N_FFT).map(|n| (0.5 - 0.5 * (2.0 * PI * n as f64 / N_FFT as f64).cos()) as f32).collect();
        let cos = (0..N_FFT).map(|n| (2.0 * PI * n as f64 / N_FFT as f64).cos() as f32).collect();
        let sin = (0..N_FFT).map(|n| (2.0 * PI * n as f64 / N_FFT as f64).sin() as f32).collect();
        LogMel { n_mels, filters: mel_filters(n_mels), window, cos, sin }
    }

    /// Number of mel bands.
    pub fn n_mels(&self) -> usize {
        self.n_mels
    }

    /// Features of up to 30 seconds (shorter input is padded with silence, longer is cut): `n_mels * N_FRAMES` values, band-major.
    // shortcut: a direct DFT with sine/cosine tables (400 is not a power of two): ~240 M multiply-adds per chunk, about 0.3 s
    // in release; silent frames are skipped. Upgrade to a mixed-radix FFT when the feature step shows up in a profile.
    pub fn compute(&self, samples: &[f32]) -> Vec<f32> {
        let mut x = vec![0f32; CHUNK_SAMPLES];
        let n = samples.len().min(CHUNK_SAMPLES);
        x[..n].copy_from_slice(&samples[..n]);
        let pad = N_FFT / 2;
        // Reflect padding on both sides (`center=True`).
        let at = |i: isize| -> f32 {
            let len = CHUNK_SAMPLES as isize;
            let j = if i < 0 {
                -i
            } else if i >= len {
                2 * (len - 1) - i
            } else {
                i
            };
            x[j.clamp(0, len - 1) as usize]
        };
        let mut power = vec![0f32; N_BINS * N_FRAMES];
        let mut frame = vec![0f32; N_FFT];
        for t in 0..N_FRAMES {
            let start = (t * HOP) as isize - pad as isize;
            let mut any = false;
            for (i, f) in frame.iter_mut().enumerate() {
                *f = at(start + i as isize) * self.window[i];
                any |= *f != 0.0;
            }
            if !any {
                continue;
            }
            for k in 0..N_BINS {
                let (mut re, mut im) = (0f32, 0f32);
                let mut idx = 0usize;
                for &v in &frame {
                    re += v * self.cos[idx];
                    im -= v * self.sin[idx];
                    idx += k;
                    if idx >= N_FFT {
                        idx -= N_FFT;
                    }
                }
                power[k * N_FRAMES + t] = re * re + im * im;
            }
        }
        let mut mel = vec![0f32; self.n_mels * N_FRAMES];
        for m in 0..self.n_mels {
            for k in 0..N_BINS {
                let w = self.filters[m * N_BINS + k];
                if w == 0.0 {
                    continue;
                }
                let src = &power[k * N_FRAMES..(k + 1) * N_FRAMES];
                for (o, p) in mel[m * N_FRAMES..(m + 1) * N_FRAMES].iter_mut().zip(src) {
                    *o += w * p;
                }
            }
        }
        let mut max = f32::MIN;
        for v in &mut mel {
            *v = v.max(1e-10).log10();
            max = max.max(*v);
        }
        for v in &mut mel {
            *v = (v.max(max - 8.0) + 4.0) / 4.0;
        }
        mel
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mel_scale_round_trips_and_has_the_slaney_knee() {
        assert!((hz_to_mel(1000.0) - 15.0).abs() < 1e-9);
        for hz in [0.0, 100.0, 999.0, 1000.0, 4000.0, 8000.0] {
            assert!((mel_to_hz(hz_to_mel(hz)) - hz).abs() < 1e-6, "{hz}");
        }
    }

    #[test]
    fn the_first_filter_has_the_known_weight() {
        // OpenAI's mel_filters.npz: row 0, bin 1 is 0.02486...; the first bin (0 Hz) has weight 0.
        let f = mel_filters(80);
        assert_eq!(f.len(), 80 * N_BINS);
        assert_eq!(f[0], 0.0);
        assert!((f[1] - 0.0248626).abs() < 2e-4, "{}", f[1]);
        // Every band has weight somewhere.
        assert!((0..80).all(|m| f[m * N_BINS..(m + 1) * N_BINS].iter().any(|w| *w > 0.0)));
    }

    #[test]
    fn silence_is_the_floor_value() {
        let m = LogMel::new(80).compute(&[]);
        assert_eq!(m.len(), 80 * N_FRAMES);
        // log10(1e-10) = -10 everywhere, so (-10 + 4) / 4.
        assert!(m.iter().all(|v| (*v + 1.5).abs() < 1e-6));
    }

    #[test]
    fn a_1_khz_tone_lights_the_band_at_1_khz_for_its_whole_length() {
        let tone: Vec<f32> =
            (0..SAMPLE_RATE * 2).map(|i| (2.0 * PI * 1000.0 * i as f64 / SAMPLE_RATE as f64).sin() as f32).collect();
        let m = LogMel::new(80).compute(&tone);
        let frame = |t: usize| -> usize {
            (0..80).max_by(|a, b| m[a * N_FRAMES + t].total_cmp(&m[b * N_FRAMES + t])).unwrap_or(0)
        };
        // 1000 Hz = mel 15; bands are 45.25 / 81 mel apart, band m is centered at (m + 1) steps: m = 25.8.
        for t in [10, 100, 150] {
            assert!((24..=27).contains(&frame(t)), "frame {t}: band {}", frame(t));
        }
        // After the tone the padding is silent: the loudest band is far below.
        assert!(m[25 * N_FRAMES + 100] > m[25 * N_FRAMES + 2000] + 1.0);
        // The tone sets the maximum, so the loudest value is (max + 4) / 4 with the clamp 8 decades below.
        assert!(m.iter().all(|v| v.is_finite()));
        let min = m.iter().copied().fold(f32::MAX, f32::min);
        let max = m.iter().copied().fold(f32::MIN, f32::max);
        assert!((max - min - 2.0).abs() < 1e-4, "range {}", max - min);
    }
}
