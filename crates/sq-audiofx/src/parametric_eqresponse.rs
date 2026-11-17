//! Port of `SQAudioFX/Sources/SQAudioFX/ParametricEQResponse.swift`.

use crate::clip_audio_fxchain::ClipAudioFXChain;
use crate::parametric_eq::PEQBiquad;
use sq_core_audio::audio_effects::AudioParametricEQValues;

/// Read-only frequency response of the 5-band Parametric EQ for drawing a curve. Uses the very coefficients the audio
/// stage runs (`PEQBiquad`), so the picture and the sound cannot drift apart.
pub enum ParametricEQResponse {}

impl ParametricEQResponse {
    /// Sample rate of the clip effect chain.
    pub const SAMPLE_RATE: f64 = ClipAudioFXChain::SAMPLE_RATE as f64;

    /// Response of filter `i` (0 HP, 1 low shelf, 2...6 peaks, 7 high shelf, 8 LP) alone in dB at `hz`; 0 when the band is off.
    pub fn band_db(values: &AudioParametricEQValues, filter: usize, hz: f64) -> f64 {
        let b = values.band(filter);
        if !b.on {
            return 0.0;
        }
        PEQBiquad::magnitude_db(&PEQBiquad::coef(filter, &b, Self::SAMPLE_RATE), hz, Self::SAMPLE_RATE)
    }

    /// Combined response of every enabled filter in dB at `hz`.
    pub fn total_db(values: &AudioParametricEQValues, hz: f64) -> f64 {
        PEQBiquad::total_magnitude_db(values, hz, Self::SAMPLE_RATE)
    }

    /// Combined response at each of `freqs`, written into `out` (resized; coefficients computed once per call, not per point).
    pub fn total_db_at(values: &AudioParametricEQValues, freqs: &[f64], out: &mut Vec<f64>) {
        out.clear();
        let mut coefs = Vec::new();
        for i in 0..AudioParametricEQValues::BAND_COUNT {
            let b = values.band(i);
            if b.on {
                coefs.push(PEQBiquad::coef(i, &b, Self::SAMPLE_RATE));
            }
        }
        for &hz in freqs {
            let mut sum = 0.0;
            for c in &coefs {
                sum += PEQBiquad::magnitude_db(c, hz, Self::SAMPLE_RATE);
            }
            out.push(sum);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parametric_eq::ParametricEQStage;
    use sq_core_audio::audio_effects::AudioPEQBand;

    fn band(on: bool, hz: f64, gain_db: f64, q: f64) -> AudioPEQBand {
        AudioPEQBand { on, hz, gain_db, q }
    }

    fn values() -> AudioParametricEQValues {
        let off = |hz| band(false, hz, 0.0, 1.0);
        // order: hp, low shelf, b1...b5, high shelf, lp
        AudioParametricEQValues {
            bands: [
                band(true, 80.0, 0.0, std::f64::consts::FRAC_1_SQRT_2),
                band(true, 120.0, 4.0, 0.71),
                off(100.0),
                band(true, 400.0, -6.0, 2.0),
                band(true, 1500.0, 9.0, 1.0),
                off(4000.0),
                off(10000.0),
                band(true, 8000.0, -3.0, 0.71),
                band(true, 16000.0, 0.0, std::f64::consts::FRAC_1_SQRT_2),
            ],
        }
    }

    /// Run the real stage on a sine and measure the output level; it must match the drawn magnitude.
    #[test]
    fn drawn_magnitude_matches_the_real_filter() {
        let v = values();
        let fs = ParametricEQResponse::SAMPLE_RATE;
        for hz in [60.0, 200.0, 400.0, 1500.0, 3000.0, 9000.0, 15000.0] {
            let n = 48_000;
            let mut buf: Vec<f32> =
                (0..n).map(|i| (2.0 * std::f64::consts::PI * hz * i as f64 / fs).sin() as f32).collect();
            let mut stage = ParametricEQStage::new(1);
            stage.process(&mut [buf.as_mut_slice()], n, &v, &v, fs);
            let peak = buf[n / 2..].iter().fold(0.0_f32, |m, s| m.max(s.abs()));
            let measured = 20.0 * f64::from(peak).log10();
            assert!((measured - ParametricEQResponse::total_db(&v, hz)).abs() < 0.15, "at {hz} Hz");
        }
    }

    #[test]
    fn off_bands_add_nothing_and_batch_equals_single() {
        let mut v = values();
        v.bands[3].on = false;
        assert_eq!(ParametricEQResponse::band_db(&v, 3, 400.0), 0.0);
        let f = [30.0, 400.0, 2000.0, 12000.0];
        let mut out = Vec::new();
        ParametricEQResponse::total_db_at(&v, &f, &mut out);
        for (i, hz) in f.iter().enumerate() {
            assert!((out[i] - ParametricEQResponse::total_db(&v, *hz)).abs() < 1e-9);
        }
    }

    #[test]
    fn peak_center_reaches_its_gain() {
        let v = values();
        assert!((ParametricEQResponse::band_db(&v, 4, 1500.0) - 9.0).abs() < 0.01);
    }
}
