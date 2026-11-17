//! Port of `SQAudioFX/Sources/SQAudioFX/RNNoiseDenoiser.swift`, plus the safe wrapper around the vendored RNNoise C library.

use crate::gain::AudioFXError;

/// The only place with `unsafe`: the C calls of the vendored RNNoise (`vendor/rnnoise`, built by `build.rs`).
#[allow(unsafe_code)]
mod ffi {
    use std::ffi::c_void;
    use std::ptr::NonNull;
    use std::sync::Once;

    unsafe extern "C" {
        fn rnnoise_create(model: *mut c_void) -> *mut c_void;
        fn rnnoise_destroy(st: *mut c_void);
        fn rnnoise_reset(st: *mut c_void);
        fn rnnoise_process_frame(st: *mut c_void, out: *mut f32, input: *const f32) -> f32;
    }

    /// Samples per RNNoise frame (480 at 48 kHz).
    pub const FRAME_SIZE: usize = 480;

    /// One RNNoise `DenoiseState` (one stream/channel), owned and freed on drop.
    pub struct DenoiseState(NonNull<c_void>);

    // SAFETY: a DenoiseState is a plain heap object without thread affinity; it is only used through `&mut self`.
    unsafe impl Send for DenoiseState {}

    impl DenoiseState {
        /// A fresh state with the built-in model; `None` when the C allocation fails.
        pub fn new() -> Option<DenoiseState> {
            // SAFETY: a null model selects the built-in model; the result is checked for null.
            NonNull::new(unsafe { rnnoise_create(std::ptr::null_mut()) }).map(DenoiseState)
        }

        /// Clears the history (a seek).
        pub fn reset(&mut self) {
            // SAFETY: `self.0` is a live state created by `rnnoise_create`.
            unsafe { rnnoise_reset(self.0.as_ptr()) }
        }

        /// Denoises one frame (`int16`-scaled floats): `input` -> `out`, both exactly `FRAME_SIZE` long.
        pub fn process_frame(&mut self, out: &mut [f32], input: &[f32]) {
            assert!(out.len() >= FRAME_SIZE && input.len() >= FRAME_SIZE, "RNNoise frames need {FRAME_SIZE} samples");
            // SAFETY: both slices hold at least FRAME_SIZE floats (checked above), `out` and `input` cannot alias
            // (`&mut` vs `&`), and `self.0` is a live state.
            unsafe { rnnoise_process_frame(self.0.as_ptr(), out.as_mut_ptr(), input.as_ptr()) };
        }
    }

    impl Drop for DenoiseState {
        fn drop(&mut self) {
            // SAFETY: `self.0` came from `rnnoise_create` and is freed exactly once.
            unsafe { rnnoise_destroy(self.0.as_ptr()) }
        }
    }

    /// RNNoise initializes unsynchronised globals lazily on its first frame (`check_init`: allocates the FFT twiddles).
    /// Forced once per process here, so it never runs on the render thread.
    pub fn global_init() {
        static INIT: Once = Once::new();
        INIT.call_once(|| {
            if let Some(mut st) = DenoiseState::new() {
                let input = [0.0_f32; FRAME_SIZE];
                let mut out = [0.0_f32; FRAME_SIZE];
                st.process_frame(&mut out, &input);
            }
        });
    }
}

pub(crate) use ffi::{DenoiseState, global_init};

/// RNNoise (Xiph/Mozilla, BSD-3-Clause) noise suppression, 48 kHz only.
///
/// Streaming, any buffer length. Output is delayed by `LATENCY_SAMPLES` (one frame): sample n of the
/// output is sample n - 480 of the processed input, so every call returns exactly as many samples
/// as it received and the result never depends on chunking. `flush()` returns the delayed tail.
/// Not thread-safe; use one instance per stream.
pub struct RNNoiseDenoiser {
    /// Wet/dry: 1 = fully denoised, 0 = delayed dry signal.
    pub mix: f32,
    channels: Vec<Channel>,
}

struct Channel {
    state: DenoiseState,
    /// Not yet processed, int16 scale.
    in_fifo: Vec<f32>,
    /// Processed, int16 scale.
    out_fifo: Vec<f32>,
    /// Dry samples matching `out_fifo` positions.
    dry_out: Vec<f32>,
}

impl RNNoiseDenoiser {
    pub const SAMPLE_RATE: i64 = 48000;
    pub const FRAME_SIZE: usize = ffi::FRAME_SIZE;
    pub const LATENCY_SAMPLES: usize = 480;

    pub fn new(channel_count: usize, sample_rate: i64) -> Result<RNNoiseDenoiser, AudioFXError> {
        if sample_rate != Self::SAMPLE_RATE {
            return Err(AudioFXError::UnsupportedSampleRate(sample_rate));
        }
        if channel_count == 0 {
            return Err(AudioFXError::InvalidChannelCount(0));
        }
        let mut channels = Vec::with_capacity(channel_count);
        for _ in 0..channel_count {
            let state = DenoiseState::new().ok_or(AudioFXError::DenoiserUnavailable)?;
            channels.push(Channel {
                state,
                in_fifo: Vec::new(),
                out_fifo: vec![0.0; Self::LATENCY_SAMPLES],
                dry_out: vec![0.0; Self::LATENCY_SAMPLES],
            });
        }
        Ok(RNNoiseDenoiser { mix: 1.0, channels })
    }

    pub fn channel_count(&self) -> usize {
        self.channels.len()
    }

    /// Feeds `input` (one array per channel, +-1.0 floats) and returns the same number of samples.
    pub fn process(&mut self, input: &[Vec<f32>]) -> Vec<Vec<f32>> {
        assert!(input.len() == self.channels.len(), "channel count mismatch");
        let n = input.first().map_or(0, Vec::len);
        let mix = self.mix.clamp(0.0, 1.0);
        let mut result = Vec::with_capacity(self.channels.len());
        for (ch, samples) in self.channels.iter_mut().zip(input) {
            assert!(samples.len() == n, "channels must have equal length");
            Self::feed(ch, samples);
            result.push(Self::take(ch, n, mix));
        }
        result
    }

    /// Returns the `LATENCY_SAMPLES` still held back, and resets the FIFOs (pads the last partial frame with silence).
    pub fn flush(&mut self) -> Vec<Vec<f32>> {
        let mix = self.mix.clamp(0.0, 1.0);
        let mut result = Vec::with_capacity(self.channels.len());
        for ch in &mut self.channels {
            let pending = ch.in_fifo.len();
            let pad = if pending % Self::FRAME_SIZE == 0 { 0 } else { Self::FRAME_SIZE - pending % Self::FRAME_SIZE };
            Self::feed(ch, &vec![0.0; pad]);
            // samples owed: everything real that has not been returned yet
            let owed = ch.out_fifo.len() - pad;
            result.push(Self::take(ch, owed, mix));
            ch.out_fifo.clear();
            ch.dry_out.clear();
            ch.in_fifo.clear();
        }
        result
    }

    fn feed(ch: &mut Channel, samples: &[f32]) {
        let scale: f32 = 32768.0;
        ch.in_fifo.reserve(samples.len());
        for s in samples {
            ch.in_fifo.push(s * scale);
        }
        let fs = Self::FRAME_SIZE;
        let mut pos = 0;
        let mut frame_out = vec![0.0_f32; fs];
        while ch.in_fifo.len() - pos >= fs {
            ch.state.process_frame(&mut frame_out, &ch.in_fifo[pos..pos + fs]);
            ch.dry_out.extend_from_slice(&ch.in_fifo[pos..pos + fs]);
            ch.out_fifo.extend_from_slice(&frame_out);
            pos += fs;
        }
        ch.in_fifo.drain(..pos);
    }

    fn take(ch: &mut Channel, n: usize, mix: f32) -> Vec<f32> {
        assert!(ch.out_fifo.len() >= n);
        let inv: f32 = 1.0 / 32768.0;
        let out = (0..n).map(|i| (ch.out_fifo[i] * mix + ch.dry_out[i] * (1.0 - mix)) * inv).collect();
        ch.out_fifo.drain(..n);
        ch.dry_out.drain(..n);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gain::sig;

    #[test]
    fn noise_is_attenuated() {
        let n = 48000 * 2;
        let noise = sig::low_noise(0.05, n, 1);
        let Ok(mut d) = RNNoiseDenoiser::new(1, 48000) else { panic!("denoiser") };
        let out = d.process(std::slice::from_ref(&noise)).swap_remove(0);
        assert_eq!(out.len(), n);
        let rin = sig::rms(&noise[48000..n]);
        let rout = sig::rms(&out[48000..n]);
        assert!(rout < rin * 0.1, "in {rin} out {rout}");
    }

    #[test]
    fn silence_stays_silent() {
        let Ok(mut d) = RNNoiseDenoiser::new(2, 48000) else { panic!("denoiser") };
        let out = d.process(&[vec![0.0; 10000], vec![0.0; 10000]]);
        for c in out {
            assert!(c.iter().all(|s| s.abs() < 1e-4));
        }
    }

    #[test]
    fn chunking_matches_one_shot() {
        let n = 48000;
        let x = vec![sig::noise(0.1, n, 3), sig::noise(0.1, n, 4)];
        let Ok(mut one_shot) = RNNoiseDenoiser::new(2, 48000) else { panic!("denoiser") };
        let one = one_shot.process(&x);
        let Ok(mut d) = RNNoiseDenoiser::new(2, 48000) else { panic!("denoiser") };
        let parts: Vec<_> = sig::chunked(&x, &[1, 479, 480, 481, 100, 4097, 3]).iter().map(|p| d.process(p)).collect();
        assert_eq!(sig::concat(&parts, 2), one);
    }

    #[test]
    fn mix_zero_is_delayed_dry() {
        let x = vec![sig::noise(0.1, 2000, 1)];
        let Ok(mut d) = RNNoiseDenoiser::new(1, 48000) else { panic!("denoiser") };
        d.mix = 0.0;
        let out = d.process(&x).swap_remove(0);
        let lat = RNNoiseDenoiser::LATENCY_SAMPLES;
        assert!(out[..lat].iter().all(|&s| s == 0.0));
        for i in lat..2000 {
            assert!((out[i] - x[0][i - lat]).abs() < 1e-6);
        }
    }

    #[test]
    fn flush_returns_tail() {
        let x = vec![sig::noise(0.1, 1000, 1)];
        let Ok(mut d) = RNNoiseDenoiser::new(1, 48000) else { panic!("denoiser") };
        let a = d.process(&x).swap_remove(0);
        let b = d.flush().swap_remove(0);
        assert_eq!(a.len() + b.len(), 1000 + RNNoiseDenoiser::LATENCY_SAMPLES);
    }

    #[test]
    fn rejects_wrong_rate() {
        assert!(matches!(RNNoiseDenoiser::new(1, 44100), Err(AudioFXError::UnsupportedSampleRate(44100))));
    }
}
