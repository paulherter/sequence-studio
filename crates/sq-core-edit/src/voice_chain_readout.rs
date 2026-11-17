//! Port of `VoiceChainReadout.swift`: loudness readout shown next to the Voice Chain: how far the selected dialogue clips
//! are from the Dialogue target (-14 LUFS, `AudioTag::Dialogue.target_lufs()`). A pure value; the measurement itself
//! belongs to the session.

use sq_core_audio::AudioGain;
use sq_core_model::AudioTag;

/// Where the measured loudness sits against the target.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VoiceChainStatus {
    /// More than the tolerance below the target.
    Quiet,
    /// Within the tolerance.
    OnTarget,
    /// More than the tolerance above the target.
    Loud,
}

/// The readout of one selection.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VoiceChainReadout {
    /// Loudness of the clips mixed by energy (an estimate of what playing them together measures).
    pub lufs: f64,
    /// The target the delta is measured against.
    pub target_lufs: f64,
}

impl VoiceChainReadout {
    /// Within this many LU of the target counts as on target.
    pub const TOLERANCE_LU: f64 = 1.0;

    /// `None` when no clip has a measurable loudness (all silent, unmeasured, or empty).
    pub fn new(measured_lufs: &[Option<f64>], target_lufs: f64) -> Option<VoiceChainReadout> {
        let v: Vec<f64> =
            measured_lufs.iter().flatten().copied().filter(|x| x.is_finite() && *x > AudioGain::SILENT_LUFS).collect();
        if v.is_empty() {
            return None;
        }
        let energy = v.iter().fold(0.0, |a, x| a + 10f64.powf(x / 10.0)) / v.len() as f64;
        Some(VoiceChainReadout { lufs: 10.0 * energy.log10(), target_lufs })
    }

    /// `new` against the Dialogue target (the Swift default argument).
    pub fn for_dialogue(measured_lufs: &[Option<f64>]) -> Option<VoiceChainReadout> {
        Self::new(measured_lufs, AudioTag::Dialogue.target_lufs())
    }

    /// Measured minus target (negative = quieter than the target).
    pub fn delta_lu(&self) -> f64 {
        self.lufs - self.target_lufs
    }

    /// Quiet, on target or loud.
    pub fn status(&self) -> VoiceChainStatus {
        let d = self.delta_lu();
        if d.abs() <= Self::TOLERANCE_LU {
            VoiceChainStatus::OnTarget
        } else if d < 0.0 {
            VoiceChainStatus::Quiet
        } else {
            VoiceChainStatus::Loud
        }
    }

    /// Loudness with one decimal.
    pub fn lufs_text(&self) -> String {
        format!("{:.1}", self.lufs)
    }

    /// Delta with one decimal and an explicit sign.
    pub fn delta_text(&self) -> String {
        format!("{:+.1}", self.delta_lu())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_delta_to_the_dialogue_target() {
        let r = VoiceChainReadout::for_dialogue(&[Some(-20.0), Some(-20.0)]).unwrap();
        assert!((r.lufs - -20.0).abs() < 0.001);
        assert_eq!(r.target_lufs, AudioTag::Dialogue.target_lufs());
        assert!((r.delta_lu() - -6.0).abs() < 0.001);
        assert_eq!(r.status(), VoiceChainStatus::Quiet);
    }

    #[test]
    fn status_bands() {
        let status = |x| VoiceChainReadout::for_dialogue(&[Some(x)]).map(|r| r.status());
        assert_eq!(status(-14.5), Some(VoiceChainStatus::OnTarget));
        assert_eq!(status(-9.0), Some(VoiceChainStatus::Loud));
        assert_eq!(status(-30.0), Some(VoiceChainStatus::Quiet));
    }

    #[test]
    fn silence_and_unmeasured_clips_are_ignored() {
        assert!(VoiceChainReadout::for_dialogue(&[]).is_none());
        assert!(VoiceChainReadout::for_dialogue(&[None, Some(-80.0), Some(f64::INFINITY)]).is_none());
        let r = VoiceChainReadout::for_dialogue(&[None, Some(-16.0), Some(-90.0)]).unwrap();
        assert!((r.lufs - -16.0).abs() < 0.001);
    }

    #[test]
    fn unequal_clips_mix_by_energy() {
        // -10 and -20 LUFS: energy mean is about -12.6, not the dB average -15.
        let r = VoiceChainReadout::for_dialogue(&[Some(-10.0), Some(-20.0)]).unwrap();
        assert!((r.lufs - -12.6).abs() < 0.05);
    }

    #[test]
    fn text_formats_one_decimal_with_signed_delta() {
        let r = VoiceChainReadout::for_dialogue(&[Some(-19.2)]).unwrap();
        assert_eq!(r.lufs_text(), "-19.2");
        assert_eq!(r.delta_text(), "-5.2");
        assert_eq!(VoiceChainReadout::for_dialogue(&[Some(-12.0)]).map(|r| r.delta_text()), Some("+2.0".to_string()));
    }
}
