// Swift: AudioDelivery.swift (AudioAnalysis, AudioFinding, AudioPreflight), AudioDeliveryTarget.swift
//
// `OutputAudioVerifier` (decodes the written file again through AVFoundation) is not here: the encoder that writes the
// file reports the levels it measured in the file.

use super::error::{CancelToken, ExportError};
use super::loudness::{LoudnessMeasurement, LoudnessNormalizer, LoudnessReport};
use super::settings::LoudnessNormalization;
use super::traits::RewindableAudioSource;
use serde::{Deserialize, Serialize};
use sq_audiofx::loudness::LoudnessMeter;

/// What the audio pre-flight found in the mix of a sequence.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioAnalysis {
    /// Gated integrated loudness.
    pub integrated_lufs: f64,
    /// Maximum true peak in dBTP.
    pub true_peak_db: f64,
    /// Samples at or above full scale (0 dBFS): they are cut flat when the file is written.
    pub clipped_samples: usize,
    /// Stretches of at least one second below -60 dBFS, in every channel.
    pub gap_count: usize,
    /// Longest such stretch.
    pub longest_gap_seconds: f64,
    /// Stereo whose two channels are identical all the way through (a mono recording on both sides).
    pub is_dual_mono: bool,
    /// Length of the mix.
    pub duration_seconds: f64,
    /// EBU R128 loudness range in LU; `None` for mixes under 3 s or without sound.
    pub loudness_range_lu: Option<f64>,
}

impl AudioAnalysis {
    /// Nothing above the gate.
    pub fn is_silent(&self) -> bool {
        !self.integrated_lufs.is_finite()
    }
}

/// What a finding is about.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AudioFindingKind {
    /// Silent mix.
    Silent,
    /// Clipped samples.
    Clipping,
    /// Integrated loudness.
    Loudness,
    /// Loudness range.
    LoudnessRange,
    /// True peak.
    TruePeak,
    /// Silent gaps.
    Gaps,
    /// Dual mono.
    DualMono,
    /// Audio and picture out of sync.
    Unsynced,
}

impl AudioFindingKind {
    /// Swift raw value (the finding's id).
    pub fn raw_value(self) -> &'static str {
        match self {
            AudioFindingKind::Silent => "silent",
            AudioFindingKind::Clipping => "clipping",
            AudioFindingKind::Loudness => "loudness",
            AudioFindingKind::LoudnessRange => "loudnessRange",
            AudioFindingKind::TruePeak => "truePeak",
            AudioFindingKind::Gaps => "gaps",
            AudioFindingKind::DualMono => "dualMono",
            AudioFindingKind::Unsynced => "unsynced",
        }
    }
}

/// How serious a finding is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AudioSeverity {
    /// Fine.
    Pass,
    /// Worth a look.
    Warning,
    /// Does not meet the target.
    Fail,
}

/// One line of the audio check: a pass, a warning or a failure against the delivery target.
#[derive(Clone, Debug, PartialEq)]
pub struct AudioFinding {
    /// What it is about.
    pub kind: AudioFindingKind,
    /// How serious.
    pub severity: AudioSeverity,
    /// The line.
    pub message: String,
}

/// Audio pre-flight of an export: analyses the mix once (BS.1770 loudness, true peak, clipping, gaps, dual mono) and
/// judges it against the delivery target.
pub struct AudioPreflight;

impl AudioPreflight {
    /// A gap is silence of at least this long.
    pub const GAP_SECONDS: f64 = 1.0;
    /// -60 dBFS.
    const SILENCE_LEVEL: f32 = 0.001;
    /// Loudness within this many LU of the target passes.
    pub const LOUDNESS_TOLERANCE_LU: f64 = 1.0;

    /// Reads the whole source (from its start) and rewinds it afterwards.
    pub fn analyze(source: &mut dyn RewindableAudioSource, cancel: &CancelToken) -> Result<AudioAnalysis, ExportError> {
        source.rewind()?;
        let ch = source.channels().max(1);
        let rate = source.sample_rate().max(1);
        let mut meter = LoudnessMeter::new(rate, ch, None);
        let (mut clipped, mut frames, mut run, mut gaps, mut longest) = (0usize, 0usize, 0usize, 0usize, 0usize);
        let (mut identical, mut any_signal) = (ch == 2, false);
        let gap_frames = (Self::GAP_SECONDS * rate as f64) as usize;
        while let Some(chunk) = source.next_chunk(4096)? {
            cancel.check()?;
            let (n, c) = (chunk.frame_count(), chunk.channels);
            let mut planar = vec![vec![0.0f32; n]; ch];
            for i in 0..n {
                let mut loud: f32 = 0.0;
                for (k, plane) in planar.iter_mut().enumerate().take(c.min(ch)) {
                    let x = chunk.samples[i * c + k];
                    plane[i] = x;
                    let a = x.abs();
                    if a >= 0.9999 {
                        clipped += 1;
                    }
                    loud = loud.max(a);
                }
                if loud >= Self::SILENCE_LEVEL {
                    any_signal = true;
                    if run >= gap_frames {
                        gaps += 1;
                    }
                    longest = longest.max(run);
                    run = 0;
                } else {
                    run += 1;
                }
                if identical && c >= 2 && (chunk.samples[i * c] - chunk.samples[i * c + 1]).abs() > 1e-6 {
                    identical = false;
                }
            }
            frames += n;
            meter.process(&planar);
        }
        if run >= gap_frames {
            gaps += 1;
        }
        longest = longest.max(run);
        source.rewind()?;
        Ok(AudioAnalysis {
            integrated_lufs: meter.integrated(),
            true_peak_db: meter.true_peak_db().into_iter().fold(f64::NEG_INFINITY, f64::max),
            clipped_samples: clipped,
            gap_count: gaps,
            longest_gap_seconds: longest as f64 / rate as f64,
            is_dual_mono: identical && any_signal,
            duration_seconds: frames as f64 / rate as f64,
            loudness_range_lu: meter.loudness_range(),
        })
    }

    /// What the export will really do to this mix: the same plan `NormalizedAudioSource::make` settles on (gain, peak
    /// limiter behind it when the ceiling stops the plain gain, levels measured through the chain). Runs up to
    /// `MAX_SEARCH_PASSES` extra passes, and none when the plain gain reaches the target or the mix is silent.
    /// `a` supplies the measurement, so the mix is not measured again.
    pub fn predict(
        source: &mut dyn RewindableAudioSource,
        a: &AudioAnalysis,
        target: LoudnessNormalization,
        cancel: &CancelToken,
    ) -> Result<LoudnessReport, ExportError> {
        let m = LoudnessMeasurement { integrated_lufs: a.integrated_lufs, true_peak_db: a.true_peak_db };
        let plan = LoudnessNormalizer::plan(source, m, target, cancel)?;
        let mut r = LoudnessReport::new(m, target);
        r.gain_db = plan.gain_db;
        r.limiter_used = plan.limiter_ceiling_db.is_some();
        r.result_lufs = Some(plan.result.integrated_lufs);
        r.result_true_peak_db = Some(plan.result.true_peak_db);
        Ok(r)
    }

    /// Pass, warning or fail per check. `predicted` (from `predict`) makes the Normalize lines name the loudness the
    /// export reaches with the peak limiter, instead of the pessimistic ceiling-limited gain. With `normalizing` the
    /// export moves loudness to the target itself, so the loudness and peak lines say what the gain will do; clipping
    /// and gaps are never fixed by a gain.
    pub fn evaluate(
        a: &AudioAnalysis,
        target: LoudnessNormalization,
        normalizing: bool,
        unsynced_clips: usize,
        predicted: Option<&LoudnessReport>,
        tolerance_lu: f64,
    ) -> Vec<AudioFinding> {
        use AudioFindingKind as K;
        use AudioSeverity as S;
        let f = |v: f64| format!("{v:.1}");
        let sec = |v: f64| format!("{v:.1} s");
        let mut out: Vec<AudioFinding> = Vec::new();
        let mut add = |k: K, s: S, m: String| out.push(AudioFinding { kind: k, severity: s, message: m });
        let plural = |n: usize| if n == 1 { "" } else { "s" };
        if a.is_silent() {
            add(
                K::Silent,
                S::Fail,
                "The mix is silent: nothing above the gate. Check the audio tracks and their volume.".to_string(),
            );
        } else {
            if normalizing {
                let m = LoudnessMeasurement { integrated_lufs: a.integrated_lufs, true_peak_db: a.true_peak_db };
                let gain = LoudnessNormalizer::gain_db(m, target);
                let out_l = predicted.map_or(a.integrated_lufs + gain, LoudnessReport::output_lufs);
                let out_p = predicted.map_or(a.true_peak_db + gain, LoudnessReport::output_true_peak_db);
                let limited = predicted.is_some_and(|p| p.limiter_used);
                add(
                    K::Loudness,
                    S::Pass,
                    format!(
                        "{} LUFS; export moves it to {} LUFS (target {}){}",
                        f(a.integrated_lufs),
                        f(out_l),
                        f(target.target_lufs),
                        if limited { " with the peak limiter" } else { "" }
                    ),
                );
                add(
                    K::TruePeak,
                    S::Pass,
                    format!(
                        "{} dBTP; {} dBTP after {} (ceiling {})",
                        f(a.true_peak_db),
                        f(out_p),
                        if limited { "gain and peak limiter" } else { "gain" },
                        f(target.true_peak_ceiling_db)
                    ),
                );
            } else {
                let off = a.integrated_lufs - target.target_lufs;
                let ok = off.abs() <= tolerance_lu;
                add(
                    K::Loudness,
                    if ok { S::Pass } else { S::Fail },
                    format!(
                        "{} LUFS, target {} ({}{} LU){}",
                        f(a.integrated_lufs),
                        f(target.target_lufs),
                        if off >= 0.0 { "+" } else { "" },
                        f(off),
                        if ok { "" } else { "; turn on Normalize to fix" }
                    ),
                );
                let tp_ok = a.true_peak_db <= target.true_peak_ceiling_db;
                add(
                    K::TruePeak,
                    if tp_ok { S::Pass } else { S::Fail },
                    format!(
                        "{} dBTP, ceiling {}{}",
                        f(a.true_peak_db),
                        f(target.true_peak_ceiling_db),
                        if tp_ok { "" } else { "; turn on Normalize to fix" }
                    ),
                );
            }
            if let Some(lra) = a.loudness_range_lu {
                add(K::LoudnessRange, S::Pass, format!("Loudness range {} LU", f(lra)));
            }
            let n = a.clipped_samples;
            add(
                K::Clipping,
                if n == 0 { S::Pass } else { S::Fail },
                if n == 0 {
                    "No clipped samples".to_string()
                } else {
                    format!("{n} clipped sample{}: lower the clip or track volume", plural(n))
                },
            );
            let g = a.gap_count;
            add(
                K::Gaps,
                if g == 0 { S::Pass } else { S::Warning },
                if g == 0 {
                    "No silence over 1 s".to_string()
                } else {
                    format!("{g} gap{} of silence over 1 s (longest {})", plural(g), sec(a.longest_gap_seconds))
                },
            );
            if a.is_dual_mono {
                add(
                    K::DualMono,
                    S::Warning,
                    "Both channels are identical (dual mono); the file is stereo but carries one voice".to_string(),
                );
            }
        }
        let u = unsynced_clips;
        add(
            K::Unsynced,
            if u == 0 { S::Pass } else { S::Warning },
            if u == 0 {
                "Audio and picture are in sync".to_string()
            } else {
                format!("{u} audio clip{} out of sync with the picture", if u == 1 { " is" } else { "s are" })
            },
        );
        out
    }
}

/// Named loudness targets of audio delivery (streaming services and broadcast). The numbers are the services'
/// published normalization levels; the true-peak ceiling is -1 dBTP for all of them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum AudioDeliveryTarget {
    /// Spotify and YouTube, -14 LUFS.
    #[serde(rename = "spotify")]
    Spotify,
    /// Apple Music, -16 LUFS.
    #[serde(rename = "appleMusic")]
    AppleMusic,
    /// YouTube, -14 LUFS.
    #[serde(rename = "youtube")]
    Youtube,
    /// EBU R128, -23 LUFS.
    #[serde(rename = "ebuR128")]
    EbuR128,
}

impl AudioDeliveryTarget {
    /// The targets the Export dialog offers. YouTube is not listed on its own: it shares Spotify's level, so one row
    /// reads "Spotify / YouTube" (the stored `youtube` value still loads).
    pub const ALL: [AudioDeliveryTarget; 3] =
        [AudioDeliveryTarget::Spotify, AudioDeliveryTarget::AppleMusic, AudioDeliveryTarget::EbuR128];

    /// Loudness range (EBU Tech 3342) needs a program of at least this long to mean anything.
    pub const MINIMUM_LOUDNESS_RANGE_SECONDS: f64 = 60.0;

    /// Shown name.
    pub fn display_name(self) -> &'static str {
        match self {
            AudioDeliveryTarget::Spotify => "Spotify / YouTube (-14 LUFS)",
            AudioDeliveryTarget::AppleMusic => "Apple Music (-16 LUFS)",
            AudioDeliveryTarget::Youtube => "YouTube (-14 LUFS)",
            AudioDeliveryTarget::EbuR128 => "EBU R128 (-23 LUFS)",
        }
    }

    /// Target integrated loudness.
    pub fn target_lufs(self) -> f64 {
        match self {
            AudioDeliveryTarget::Spotify | AudioDeliveryTarget::Youtube => -14.0,
            AudioDeliveryTarget::AppleMusic => -16.0,
            AudioDeliveryTarget::EbuR128 => -23.0,
        }
    }

    /// True-peak ceiling.
    pub fn true_peak_ceiling_db(self) -> f64 {
        -1.0
    }

    /// Allowed deviation of the integrated loudness. EBU R128 is +/-0.5 LU; the streaming services normalize
    /// themselves, so the pre-flight keeps its general +/-1 LU there.
    pub fn tolerance_lu(self) -> f64 {
        if self == AudioDeliveryTarget::EbuR128 { 0.5 } else { AudioPreflight::LOUDNESS_TOLERANCE_LU }
    }

    /// The normalization setting of the target.
    pub fn normalization(self) -> LoudnessNormalization {
        LoudnessNormalization::new(self.target_lufs(), self.true_peak_ceiling_db())
    }

    /// The named target a normalization setting matches (same LUFS and ceiling), `None` for a custom value.
    pub fn matching(n: LoudnessNormalization) -> Option<AudioDeliveryTarget> {
        Self::ALL
            .into_iter()
            .find(|t| t.target_lufs() == n.target_lufs && t.true_peak_ceiling_db() == n.true_peak_ceiling_db)
    }

    /// Whether the Loudness Range readout is offered for a program of this length (greyed out under 60 s).
    pub fn loudness_range_available(duration_seconds: f64) -> bool {
        duration_seconds >= Self::MINIMUM_LOUDNESS_RANGE_SECONDS
    }
}
