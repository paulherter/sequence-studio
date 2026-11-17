// Swift: LoudnessNormalizer.swift

use super::error::{CancelToken, ExportError};
use super::settings::LoudnessNormalization;
use super::traits::{AudioChunk, AudioSource, RewindableAudioSource};
use sq_audiofx::gain::GainMath;
use sq_audiofx::limiter::MasterLimiter;
use sq_audiofx::loudness::LoudnessMeter;

/// Integrated loudness and true peak of a stretch of audio.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LoudnessMeasurement {
    /// Gated integrated loudness; -infinity for silence.
    pub integrated_lufs: f64,
    /// Maximum true peak over all channels in dBTP.
    pub true_peak_db: f64,
}

/// What normalization did to an export: measured values, applied gain and the resulting (predicted) levels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LoudnessReport {
    /// Measured integrated loudness.
    pub measured_lufs: f64,
    /// Measured true peak.
    pub measured_true_peak_db: f64,
    /// Target loudness.
    pub target_lufs: f64,
    /// True-peak ceiling.
    pub ceiling_db: f64,
    /// Gain applied.
    pub gain_db: f64,
    /// True when the ceiling, not the target, decided the gain.
    pub limited_by_ceiling: bool,
    /// Levels measured in the written file (decoded again after the encode); `None` when not checked.
    pub verified: Option<LoudnessMeasurement>,
    /// True when a peak limiter behind the gain brought the loudness closer to the target than the ceiling-limited gain.
    pub limiter_used: bool,
    /// Levels the chain measured for the output (through gain and limiter); `None` = measured + gain.
    pub result_lufs: Option<f64>,
    /// True peak the chain measured for the output.
    pub result_true_peak_db: Option<f64>,
}

impl LoudnessReport {
    /// Tolerance of the post-encode check: the lossy encoder may move the peak a little (dB).
    pub const VERIFY_TOLERANCE_DB: f64 = 0.05;

    /// The plain-gain report for a measurement.
    pub fn new(m: LoudnessMeasurement, settings: LoudnessNormalization) -> LoudnessReport {
        LoudnessReport {
            measured_lufs: m.integrated_lufs,
            measured_true_peak_db: m.true_peak_db,
            target_lufs: settings.target_lufs,
            ceiling_db: settings.true_peak_ceiling_db,
            gain_db: LoudnessNormalizer::gain_db(m, settings),
            limited_by_ceiling: m.integrated_lufs.is_finite()
                && m.true_peak_db.is_finite()
                && settings.target_lufs - m.integrated_lufs > settings.true_peak_ceiling_db - m.true_peak_db,
            verified: None,
            limiter_used: false,
            result_lufs: None,
            result_true_peak_db: None,
        }
    }

    /// What `NormalizedAudioSource::make` really settled on: gain, limiter and the levels it measured through them.
    pub fn from_normalized(n: &NormalizedAudioSource, settings: LoudnessNormalization) -> LoudnessReport {
        let mut r = LoudnessReport::new(n.measurement, settings);
        r.gain_db = n.gain_db;
        r.limiter_used = n.limiter_ceiling_db.is_some();
        r.result_lufs = Some(n.result.integrated_lufs);
        r.result_true_peak_db = Some(n.result.true_peak_db);
        r
    }

    /// How far the written file's true peak is above the ceiling (dB), `None` when within tolerance or not measured.
    pub fn overshoot_db(&self) -> Option<f64> {
        let v = self.verified.filter(|v| v.true_peak_db.is_finite())?;
        let over = v.true_peak_db - self.ceiling_db;
        (over > Self::VERIFY_TOLERANCE_DB).then_some(over)
    }

    /// Loudness of the output.
    pub fn output_lufs(&self) -> f64 {
        self.result_lufs.unwrap_or(self.measured_lufs + self.gain_db)
    }

    /// True peak of the output.
    pub fn output_true_peak_db(&self) -> f64 {
        self.result_true_peak_db.unwrap_or(self.measured_true_peak_db + self.gain_db)
    }

    /// One line for the queue.
    pub fn summary(&self) -> String {
        if !self.measured_lufs.is_finite() {
            return "Audio is silent, loudness unchanged".to_string();
        }
        let f = |v: f64| format!("{v:.1}");
        let mut s = format!(
            "{} LUFS, {} dBTP (gain {}{} dB",
            f(self.output_lufs()),
            f(self.output_true_peak_db()),
            if self.gain_db >= 0.0 { "+" } else { "" },
            f(self.gain_db)
        );
        if self.limiter_used {
            s += &format!(", peak limiter at {} dBTP ceiling)", f(self.ceiling_db));
        } else if self.limited_by_ceiling {
            s += &format!(", limited by {} dBTP ceiling)", f(self.ceiling_db));
        } else {
            s += ")";
        }
        if let Some(v) = self.verified.filter(|v| v.integrated_lufs.is_finite()) {
            s += &format!("; in the file {} LUFS, {} dBTP", f(v.integrated_lufs), f(v.true_peak_db));
            if let Some(o) = self.overshoot_db() {
                s += &format!(", {} dB above the ceiling", f(o));
            }
        }
        s
    }
}

/// One constant gain, then an optional peak limiter: what the export applies to the mix and what the search measures.
pub struct LoudnessChain {
    gain: f32,
    limiter: Option<MasterLimiter>,
}

impl LoudnessChain {
    /// A chain of `gain_db` and, when given, a limiter at `limiter_ceiling_db`.
    pub fn new(gain_db: f64, limiter_ceiling_db: Option<f64>, sample_rate: i64) -> LoudnessChain {
        LoudnessChain {
            gain: GainMath::linear_from_db(gain_db) as f32,
            limiter: limiter_ceiling_db.map(|c| MasterLimiter::new(sample_rate, c)),
        }
    }

    /// Clears the limiter state.
    pub fn reset(&mut self) {
        if let Some(l) = self.limiter.as_mut() {
            l.reset();
        }
    }

    /// Applies gain, then the limiter, in place.
    pub fn apply(&mut self, chunk: &mut AudioChunk) {
        if self.gain != 1.0 {
            let g = self.gain;
            for s in &mut chunk.samples {
                *s *= g;
            }
        }
        let (n, ch) = (chunk.frame_count(), chunk.channels);
        if ch == 0 || n == 0 {
            return;
        }
        if let Some(l) = self.limiter.as_mut() {
            l.process_interleaved(&mut chunk.samples, ch, n);
        }
    }
}

/// The gain (and limiter) the export applies, and the levels measured for it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LoudnessPlan {
    /// Linear gain in dB.
    pub gain_db: f64,
    /// Ceiling of the limiter behind the gain; `None` = gain only.
    pub limiter_ceiling_db: Option<f64>,
    /// The levels measured through the chain.
    pub result: LoudnessMeasurement,
}

/// Loudness normalization. Pass 1 measures (BS.1770 via `LoudnessMeter`), pass 2 applies one linear gain. When the
/// true-peak ceiling stops that gain short of the target (a peaky mix), a bounded search raises the gain behind a peak
/// limiter and keeps the result closest to the target that still holds the ceiling.
pub struct LoudnessNormalizer;

impl LoudnessNormalizer {
    /// Extra measuring passes the search may spend at most (each runs the whole mix again).
    pub const MAX_SEARCH_PASSES: usize = 3;
    /// Within this many LU of the target the search stops.
    pub const TOLERANCE_LU: f64 = 0.1;
    /// The search never raises the gain more than this above the ceiling-limited gain (more limiting is audible).
    pub const MAX_EXTRA_GAIN_DB: f64 = 6.0;

    /// Reads the whole source (from its start) and rewinds it afterwards.
    pub fn measure(
        source: &mut dyn RewindableAudioSource,
        cancel: &CancelToken,
    ) -> Result<LoudnessMeasurement, ExportError> {
        Self::measure_through(source, None, cancel)
    }

    /// `measure` with `chain` applied to every chunk first.
    pub fn measure_through(
        source: &mut dyn RewindableAudioSource,
        mut chain: Option<LoudnessChain>,
        cancel: &CancelToken,
    ) -> Result<LoudnessMeasurement, ExportError> {
        source.rewind()?;
        let mut meter = LoudnessMeter::new(source.sample_rate(), source.channels(), None);
        while let Some(mut chunk) = source.next_chunk(4096)? {
            cancel.check()?;
            if let Some(c) = chain.as_mut() {
                c.apply(&mut chunk);
            }
            meter.process(&deinterleave(&chunk, chunk.channels));
        }
        source.rewind()?;
        let peak = meter.true_peak_db().into_iter().fold(f64::NEG_INFINITY, f64::max);
        Ok(LoudnessMeasurement { integrated_lufs: meter.integrated(), true_peak_db: peak })
    }

    /// target - measured, reduced so the true peak after gain is at most the ceiling. Silence gets 0 dB.
    pub fn gain_db(m: LoudnessMeasurement, settings: LoudnessNormalization) -> f64 {
        if !m.integrated_lufs.is_finite() {
            return 0.0;
        }
        let wanted = settings.target_lufs - m.integrated_lufs;
        if !m.true_peak_db.is_finite() {
            return wanted;
        }
        wanted.min(settings.true_peak_ceiling_db - m.true_peak_db)
    }

    /// `m` is the measurement of `source` as it is. Plain gain when the ceiling does not decide; otherwise at most
    /// `MAX_SEARCH_PASSES` limited passes. Every candidate is measured through the real chain (true peak included); a
    /// true-peak overshoot (inter-sample peaks the sample limiter cannot see) lowers the limiter ceiling. The
    /// ceiling-limited plain gain stays the answer unless a candidate is clearly closer to the target.
    pub fn plan(
        source: &mut dyn RewindableAudioSource,
        m: LoudnessMeasurement,
        settings: LoudnessNormalization,
        cancel: &CancelToken,
    ) -> Result<LoudnessPlan, ExportError> {
        let plain = Self::gain_db(m, settings);
        let mut best = LoudnessPlan {
            gain_db: plain,
            limiter_ceiling_db: None,
            result: LoudnessMeasurement {
                integrated_lufs: m.integrated_lufs + plain,
                true_peak_db: m.true_peak_db + plain,
            },
        };
        if !(m.integrated_lufs.is_finite()
            && m.true_peak_db.is_finite()
            && settings.target_lufs - best.result.integrated_lufs > Self::TOLERANCE_LU)
        {
            return Ok(best);
        }
        let (ceiling, target) = (settings.true_peak_ceiling_db, settings.target_lufs);
        let cap = plain + Self::MAX_EXTRA_GAIN_DB;
        let (mut gain, mut last_l, mut limiter_ceiling) = (plain, best.result.integrated_lufs, ceiling);
        let (mut passes, mut first) = (0, true);
        while passes < Self::MAX_SEARCH_PASSES {
            let next = if first { target - m.integrated_lufs } else { gain + (target - last_l) }.min(cap);
            if !first && next <= gain + 0.01 {
                break; // the cap (or nothing to add) is reached
            }
            gain = next;
            let rate = source.sample_rate();
            let r = Self::measure_through(source, Some(LoudnessChain::new(gain, Some(limiter_ceiling), rate)), cancel)?;
            passes += 1;
            if r.true_peak_db > ceiling + LoudnessReport::VERIFY_TOLERANCE_DB {
                limiter_ceiling -= r.true_peak_db - ceiling; // inter-sample overshoot: the limiter needs more room
                last_l = r.integrated_lufs;
                first = false;
                continue;
            }
            let err = (target - r.integrated_lufs).abs();
            if err < (target - best.result.integrated_lufs).abs() - 0.05 {
                best = LoudnessPlan { gain_db: gain, limiter_ceiling_db: Some(limiter_ceiling), result: r };
            }
            if err <= Self::TOLERANCE_LU {
                break;
            }
            if !first && r.integrated_lufs - last_l < 0.05 {
                break; // more gain no longer comes out louder
            }
            last_l = r.integrated_lufs;
            first = false;
        }
        Ok(best)
    }
}

/// Planar copy of an interleaved chunk (`channels` planes; missing channels stay silent).
fn deinterleave(chunk: &AudioChunk, channels: usize) -> Vec<Vec<f32>> {
    let (n, c) = (chunk.frame_count(), chunk.channels);
    let mut planar = vec![vec![0.0f32; n]; channels];
    for (k, plane) in planar.iter_mut().enumerate().take(c) {
        for (i, dst) in plane.iter_mut().enumerate() {
            *dst = chunk.samples[i * c + k];
        }
    }
    planar
}

/// Applies the planned gain (and peak limiter) to another source. Build with `make`, which runs the measuring pass(es).
pub struct NormalizedAudioSource {
    base: Box<dyn RewindableAudioSource>,
    /// Gain applied, dB.
    pub gain_db: f64,
    /// Ceiling of the peak limiter behind the gain; `None` = gain only.
    pub limiter_ceiling_db: Option<f64>,
    /// The source as it is.
    pub measurement: LoudnessMeasurement,
    /// The levels measured through gain and limiter.
    pub result: LoudnessMeasurement,
    chain: LoudnessChain,
}

impl NormalizedAudioSource {
    /// Measures `base` and plans the gain.
    pub fn make(
        mut base: Box<dyn RewindableAudioSource>,
        settings: LoudnessNormalization,
        cancel: &CancelToken,
    ) -> Result<NormalizedAudioSource, ExportError> {
        let m = LoudnessNormalizer::measure(base.as_mut(), cancel)?;
        let plan = LoudnessNormalizer::plan(base.as_mut(), m, settings, cancel)?;
        let chain = LoudnessChain::new(plan.gain_db, plan.limiter_ceiling_db, base.sample_rate());
        Ok(NormalizedAudioSource {
            base,
            gain_db: plan.gain_db,
            limiter_ceiling_db: plan.limiter_ceiling_db,
            measurement: m,
            result: plan.result,
            chain,
        })
    }
}

impl AudioSource for NormalizedAudioSource {
    fn sample_rate(&self) -> i64 {
        self.base.sample_rate()
    }

    fn channels(&self) -> usize {
        self.base.channels()
    }

    fn next_chunk(&mut self, max_frames: usize) -> Result<Option<AudioChunk>, ExportError> {
        let Some(mut chunk) = self.base.next_chunk(max_frames)? else { return Ok(None) };
        self.chain.apply(&mut chunk);
        Ok(Some(chunk))
    }

    fn as_rewindable(&mut self) -> Option<&mut dyn RewindableAudioSource> {
        Some(self)
    }
}

impl RewindableAudioSource for NormalizedAudioSource {
    fn rewind(&mut self) -> Result<(), ExportError> {
        self.chain.reset();
        self.base.rewind()
    }
}
