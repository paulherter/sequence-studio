//! Port of `SQMedia/Sources/SQMedia/ToneAudioSource.swift`.

use crate::media_error::MediaError;
use crate::memory_audio_source::AudioSource;
use sq_core_audio::ToneSpec;
use sq_core_time::Id;

/// The sound of a Tone generator clip (`ToneSpec`): an endless mono sine at the mixer rate. Pure function of the source
/// frame, so any split of a read into blocks, a seek or a reversed read gives identical samples and the phase never jumps.
#[derive(Clone, Debug)]
pub struct ToneAudioSource {
    pub spec: ToneSpec,
    pub sample_rate: i64,
    amplitude: f64,
}

impl ToneAudioSource {
    /// The mixer rate of Swift's default argument.
    pub const DEFAULT_SAMPLE_RATE: i64 = 48_000;

    pub fn new(spec: ToneSpec, sample_rate: i64) -> ToneAudioSource {
        ToneAudioSource { spec, sample_rate, amplitude: spec.amplitude() }
    }

    /// The tone behind a media ID, `None` when the ID is an ordinary media UUID.
    pub fn source(media: Id, sample_rate: i64) -> Option<ToneAudioSource> {
        ToneSpec::from_media_id(media).map(|spec| ToneAudioSource::new(spec, sample_rate))
    }

    /// Sample at `frame`. The phase is computed in integers (millihertz x frame modulo one cycle), so it stays exact for hours.
    pub fn sample_at(&self, frame: i64) -> f32 {
        let cycle = self.sample_rate * 1000;
        let phase = (i128::from(self.spec.frequency_milli_hz()) * i128::from(frame)) % i128::from(cycle);
        let p = phase as i64;
        let p = if p < 0 { p + cycle } else { p };
        (self.amplitude * (2.0 * std::f64::consts::PI * p as f64 / cycle as f64).sin()) as f32
    }
}

impl AudioSource for ToneAudioSource {
    fn is_mono(&self) -> bool {
        true
    }

    fn read(&self, source_frame: i64, buffer: &mut [f32], _channel: usize) -> Result<usize, MediaError> {
        for (k, out) in buffer.iter_mut().enumerate() {
            *out = self.sample_at(source_frame + k as i64);
        }
        Ok(buffer.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(s: &ToneAudioSource, from: i64, n: usize) -> Vec<f32> {
        let mut out = vec![9f32; n];
        assert_eq!(s.read(from, &mut out, 0), Ok(n));
        out
    }

    #[test]
    fn one_kilohertz_at_minus_twelve_has_the_right_samples() {
        let s = ToneAudioSource::new(ToneSpec::DEFAULT, 48_000);
        let x = read(&s, 0, 96);
        let a = 10f64.powf(-12.0 / 20.0) as f32;
        assert_eq!(x[0], 0.0);
        for (k, v) in x.iter().enumerate() {
            let want = a * (2.0 * std::f64::consts::PI * k as f64 / 48.0).sin() as f32; // 48 samples per cycle
            assert!((v - want).abs() < 1e-6, "sample {k}");
        }
        assert!((x[12] - a).abs() < 1e-6 && (x[36] + a).abs() < 1e-6); // peaks at quarter cycles
        assert!(x.iter().map(|v| v.abs()).fold(0.0, f32::max) <= a + 1e-6);
    }

    #[test]
    fn phase_is_continuous_across_blocks_and_seeks() {
        let s = ToneAudioSource::new(ToneSpec::from_hz_db(997.3, -12.0), 48_000);
        let whole = read(&s, 1_000_000, 4096);
        let mut pieces: Vec<f32> = Vec::new();
        for st in (0..4096).step_by(333) {
            pieces.extend(read(&s, 1_000_000 + st as i64, 333.min(4096 - st)));
        }
        assert_eq!(pieces, whole);
        let step = whole.windows(2).map(|w| (w[1] - w[0]).abs()).fold(0.0, f32::max);
        assert!(step < 0.2512 * 2.0 * std::f32::consts::PI * 997.3 / 48_000.0 * 1.01); // never steeper than the sine itself
    }

    #[test]
    fn late_frames_stay_exact() {
        // Ten hours in: integer phase keeps the sample equal to the one a whole number of cycles earlier.
        let s = ToneAudioSource::new(ToneSpec::DEFAULT, 48_000);
        let late: i64 = 48_000 * 36_000;
        assert_eq!(read(&s, late, 64), read(&s, 0, 64));
    }

    #[test]
    fn only_tone_ids_resolve() {
        assert_eq!(
            ToneAudioSource::source(ToneSpec::DEFAULT.media_id(), 48_000).map(|s| s.spec),
            Some(ToneSpec::DEFAULT)
        );
        assert!(ToneAudioSource::source(Id::from_u128(7), 48_000).is_none());
        assert!(ToneAudioSource::new(ToneSpec::DEFAULT, 48_000).is_mono());
    }

    #[test]
    fn negative_frames_wrap_into_the_cycle() {
        let s = ToneAudioSource::new(ToneSpec::DEFAULT, 48_000);
        assert_eq!(s.sample_at(-48), s.sample_at(0));
        assert_eq!(s.sample_at(-36), s.sample_at(12));
    }
}
