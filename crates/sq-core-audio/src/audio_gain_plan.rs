// Swift: AudioGainPlan.swift
//! The Audio Gain dialog's logic, shared by the Mac sheet and the portable shell form.

use crate::audio_gain::{AudioGain, AudioGainMode};
use sq_core_model::Clip;
use sq_core_time::Id;
use std::collections::BTreeMap;

/// What the Audio Gain dialog does to the selected audio clips (Set Gain to, Adjust Gain by, Normalize Max Peak to,
/// Normalize All Peaks to).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AudioGainChoice {
    /// Gain becomes this value.
    Set(f64),
    /// Gain changes by this many dB.
    Adjust(f64),
    /// Each clip's peak reaches the target.
    NormalizeEach {
        /// Target peak in dB.
        target_db: f64,
    },
    /// One gain for all clips, the loudest peak reaches the target.
    NormalizeTogether {
        /// Target peak in dB.
        target_db: f64,
    },
    /// Integrated loudness (LUFS) of each clip, measured from its source, brought to the target by Audio Gain.
    NormalizeLoudness {
        /// Target in LUFS.
        target_lufs: f64,
    },
}

/// One clip row of the dialog.
#[derive(Clone, Debug, PartialEq)]
pub struct AudioGainItem {
    /// The clip.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Gain the clip has now.
    pub gain_db: f64,
    /// Linear sample peak of the clip's source range; `None` when unknown (waveform not read yet).
    pub peak: Option<f64>,
    /// Loudest Volume level of the clip (linear; its keys included): the normalized output peak is
    /// `peak x volume x gain`, so the target is reached after the Volume line, not before it.
    pub volume: f64,
    /// Integrated loudness of the source range in LUFS (before gain and Volume); `None` while it is not measured.
    pub lufs: Option<f64>,
}

impl AudioGainItem {
    /// A row with volume 1 and no loudness measurement.
    pub fn new(id: Id, name: &str, gain_db: f64, peak: Option<f64>) -> AudioGainItem {
        AudioGainItem { id, name: name.to_string(), gain_db, peak, volume: 1.0, lufs: None }
    }

    /// Peak as heard before the Audio Gain stage.
    fn effective_peak(&self) -> Option<f64> {
        self.peak.map(|p| p * self.volume)
    }
}

/// Namespace of the dialog logic.
pub enum AudioGainPlan {}

impl AudioGainPlan {
    /// The dialog's rows in order: Set, Adjust, Normalize Max Peak, Normalize All Peaks, Normalize Loudness. An index
    /// outside the rows is a Swift trap; here it falls back to the last row.
    pub fn choice(index: usize, value: f64) -> AudioGainChoice {
        match index {
            0 => AudioGainChoice::Set(value),
            1 => AudioGainChoice::Adjust(value),
            2 => AudioGainChoice::NormalizeEach { target_db: value },
            3 => AudioGainChoice::NormalizeTogether { target_db: value },
            _ => AudioGainChoice::NormalizeLoudness { target_lufs: value },
        }
    }

    /// New gain per clip. Clips that cannot change (silent, peak unknown) are left out.
    pub fn plan(choice: AudioGainChoice, items: &[AudioGainItem]) -> BTreeMap<Id, f64> {
        let mut out = BTreeMap::new();
        match choice {
            AudioGainChoice::Set(v) => {
                for i in items {
                    if let Some(g) = AudioGain::apply(AudioGainMode::Set(v), i.gain_db, None) {
                        out.insert(i.id, g);
                    }
                }
            }
            AudioGainChoice::Adjust(d) => {
                for i in items {
                    if let Some(g) = AudioGain::apply(AudioGainMode::Adjust(d), i.gain_db, None) {
                        out.insert(i.id, g);
                    }
                }
            }
            AudioGainChoice::NormalizeEach { target_db } => {
                for i in items {
                    let mode = AudioGainMode::Normalize { target_db };
                    if let Some(g) = AudioGain::apply(mode, i.gain_db, i.effective_peak()) {
                        out.insert(i.id, g);
                    }
                }
            }
            AudioGainChoice::NormalizeLoudness { target_lufs } => {
                for i in items {
                    if let Some(g) = AudioGain::match_loudness(i.lufs, target_lufs) {
                        out.insert(i.id, g);
                    }
                }
            }
            AudioGainChoice::NormalizeTogether { target_db } => {
                let known: Vec<(&AudioGainItem, f64)> =
                    items.iter().filter_map(|i| i.effective_peak().map(|p| (i, p))).collect();
                let peaks: Vec<f64> = known.iter().map(|(_, p)| *p).collect();
                if let Some(gains) = AudioGain::normalize_together(&peaks, target_db) {
                    for ((i, _), g) in known.iter().zip(gains) {
                        out.insert(i.id, g);
                    }
                }
            }
        }
        out
    }

    /// Clips whose peak (after Volume) would end above 0 dBFS with the gain `choice` gives them. Clips without a peak
    /// count as fine (nothing is known).
    pub fn clipping_clips(choice: AudioGainChoice, items: &[AudioGainItem]) -> Vec<Id> {
        let gains = Self::plan(choice, items);
        items
            .iter()
            .filter_map(|i| {
                let g = gains.get(&i.id)?;
                let p = i.effective_peak()?;
                (p * AudioGain::linear_from_db(*g) > 1.0005).then_some(i.id)
            })
            .collect()
    }

    /// Loudest Volume level of a clip: its constant level, or the highest key.
    pub fn volume_peak(clip: &Clip) -> f64 {
        let v = &clip.animation.volume;
        if v.track.is_empty() {
            v.value.max(0.0)
        } else {
            v.track.keys.iter().map(|k| k.value).reduce(f64::max).unwrap_or(v.value).max(0.0)
        }
    }

    /// Loudest peak among `items` in dB (`None` when none is known).
    pub fn loudest_db(items: &[AudioGainItem]) -> Option<f64> {
        items.iter().filter_map(|i| i.effective_peak()).reduce(f64::max).map(AudioGain::db_from_linear)
    }

    /// "Loudness: -23.4 LUFS" (a range for several clips), "measuring..." while the measurement runs.
    pub fn loudness_text(items: &[AudioGainItem], measuring: bool) -> String {
        let values: Vec<f64> = items.iter().filter_map(|i| i.lufs).filter(|l| *l > AudioGain::SILENT_LUFS).collect();
        if values.is_empty() {
            return if measuring { "Loudness: measuring..." } else { "Loudness: silent or unknown" }.to_string();
        }
        let f = |v: f64| format!("{v:.1}").replace('-', "\u{2212}");
        let lo = values.iter().copied().reduce(f64::min).unwrap_or(0.0);
        let hi = values.iter().copied().reduce(f64::max).unwrap_or(0.0);
        let head = if f(lo) == f(hi) { f(lo) } else { format!("{} to {}", f(lo), f(hi)) };
        format!("Loudness: {head} LUFS{}", if measuring { " (measuring...)" } else { "" })
    }

    /// One line when the chosen gain pushes clips above 0 dB, `None` otherwise.
    pub fn warning_text(choice: AudioGainChoice, items: &[AudioGainItem]) -> Option<String> {
        match Self::clipping_clips(choice, items).len() {
            0 => None,
            1 => Some("1 clip would peak above 0 dB.".to_string()),
            n => Some(format!("{n} clips would peak above 0 dB.")),
        }
    }

    /// Clip name (or clip count) plus the peak amplitude, for one clip as well as for several.
    pub fn info_text(items: &[AudioGainItem]) -> String {
        let head = match items {
            [one] => one.name.clone(),
            _ => format!("{} clips", items.len()),
        };
        head + &Self::loudest_db(items).map_or(String::new(), |db| format!("\nPeak amplitude: {db:.1} dB"))
    }

    /// Explains the two peak modes; shown only when several clips are selected, `None` for one clip.
    pub fn peak_mode_note(item_count: usize) -> Option<&'static str> {
        (item_count > 1).then_some(
            "Max Peak: each clip is raised on its own. All Peaks: one gain for all, the balance between clips stays.",
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio_gain::VolumeLineExt;
    use crate::audio_role::tests::clip;
    use sq_core_time::{SequentialIds, Time};

    fn item(n: u128, gain: f64, peak: Option<f64>) -> AudioGainItem {
        AudioGainItem::new(Id::from_u128(n), "c", gain, peak)
    }
    fn get(m: &BTreeMap<Id, f64>, i: &AudioGainItem) -> f64 {
        m.get(&i.id).copied().unwrap_or(f64::NAN)
    }

    #[test]
    fn note_only_for_several_clips() {
        assert_eq!(AudioGainPlan::peak_mode_note(1), None);
        assert!(AudioGainPlan::peak_mode_note(3).is_some_and(|n| n.contains("All Peaks")));
    }

    #[test]
    fn choice_rows_in_dialog_order() {
        assert_eq!(AudioGainPlan::choice(0, 3.0), AudioGainChoice::Set(3.0));
        assert_eq!(AudioGainPlan::choice(1, 3.0), AudioGainChoice::Adjust(3.0));
        assert_eq!(AudioGainPlan::choice(2, -1.0), AudioGainChoice::NormalizeEach { target_db: -1.0 });
        assert_eq!(AudioGainPlan::choice(3, -1.0), AudioGainChoice::NormalizeTogether { target_db: -1.0 });
        assert_eq!(AudioGainPlan::choice(4, -14.0), AudioGainChoice::NormalizeLoudness { target_lufs: -14.0 });
    }

    #[test]
    fn set_and_adjust() {
        let (a, b) = (item(1, 2.0, Some(0.5)), item(2, -1.0, Some(0.5)));
        let set = AudioGainPlan::plan(AudioGainChoice::Set(5.0), &[a.clone(), b.clone()]);
        assert!(get(&set, &a) == 5.0 && get(&set, &b) == 5.0);
        let adj = AudioGainPlan::plan(AudioGainChoice::Adjust(3.0), &[a.clone(), b.clone()]);
        assert!(get(&adj, &a) == 5.0 && get(&adj, &b) == 2.0);
    }

    #[test]
    fn normalize_each_gives_every_clip_its_own_gain() {
        let (loud, quiet) = (item(1, 0.0, Some(0.5)), item(2, 0.0, Some(0.25)));
        let (unknown, silent) = (item(3, 0.0, None), item(4, 0.0, Some(0.0)));
        let items = [loud.clone(), quiet.clone(), unknown.clone(), silent.clone()];
        let r = AudioGainPlan::plan(AudioGainChoice::NormalizeEach { target_db: 0.0 }, &items);
        assert!((get(&r, &loud) - 6.0206).abs() < 1e-3 && (get(&r, &quiet) - 12.0412).abs() < 1e-3);
        assert!(!r.contains_key(&unknown.id) && !r.contains_key(&silent.id));
    }

    #[test]
    fn normalize_together_keeps_the_balance() {
        let (loud, quiet, unknown) = (item(1, 0.0, Some(0.5)), item(2, 0.0, Some(0.25)), item(3, 0.0, None));
        let r = AudioGainPlan::plan(
            AudioGainChoice::NormalizeTogether { target_db: -6.0 },
            &[loud.clone(), quiet.clone(), unknown.clone()],
        );
        assert!((get(&r, &loud) - 0.0206).abs() < 1e-3 && (get(&r, &quiet) - 0.0206).abs() < 1e-3);
        assert!(!r.contains_key(&unknown.id));
    }

    #[test]
    fn normalize_counts_the_volume_level() {
        // Peak 0.5 at Volume +6 dB (x2) is already at 0 dBFS; normalizing to -6 dB needs -6 dB of gain.
        let mut it = item(1, 0.0, Some(0.5));
        it.volume = 2.0;
        let r = AudioGainPlan::plan(AudioGainChoice::NormalizeEach { target_db: -6.0206 }, std::slice::from_ref(&it));
        assert!((get(&r, &it) + 6.0206).abs() < 1e-3);
        let mut c = clip(0, 4, None);
        assert_eq!(AudioGainPlan::volume_peak(&c), 1.0);
        let mut ids = SequentialIds::default();
        let k1 = c.add_volume_key(Time::ZERO, &mut ids);
        let k2 = c.add_volume_key(Time::new(2, 1), &mut ids);
        c.animation.volume.track.set(k1, 0.5);
        c.animation.volume.track.set(k2, 1.5);
        assert_eq!(AudioGainPlan::volume_peak(&c), 1.5);
    }

    #[test]
    fn normalize_loudness_uses_the_measured_value() {
        let mut a = item(1, 3.0, Some(0.1));
        a.lufs = Some(-26.0);
        let b = item(2, 0.0, Some(0.1));
        let mut silent = item(3, 0.0, Some(0.1));
        silent.lufs = Some(-80.0);
        let r = AudioGainPlan::plan(
            AudioGainChoice::NormalizeLoudness { target_lufs: -14.0 },
            &[a.clone(), b.clone(), silent.clone()],
        );
        assert_eq!(get(&r, &a), 12.0); // absolute gain from the measurement, not relative to the old gain
        assert!(!r.contains_key(&b.id) && !r.contains_key(&silent.id));
    }

    #[test]
    fn clip_warning_counts_clips_that_end_above_full_scale() {
        let mut quiet = item(1, 0.0, Some(0.05)); // +16 dB: 0.05 -> 0.32
        quiet.lufs = Some(-30.0);
        let mut peaky = item(2, 0.0, Some(0.9)); // +6 dB: 0.9 -> 1.8
        peaky.lufs = Some(-20.0);
        let mut unknown_peak = item(3, 0.0, None);
        unknown_peak.lufs = Some(-20.0);
        let choice = AudioGainChoice::NormalizeLoudness { target_lufs: -14.0 };
        assert_eq!(
            AudioGainPlan::clipping_clips(choice, &[quiet.clone(), peaky.clone(), unknown_peak]),
            vec![peaky.id]
        );
        let one = Some("1 clip would peak above 0 dB.".to_string());
        assert_eq!(AudioGainPlan::warning_text(choice, &[quiet.clone(), peaky.clone()]), one);
        assert_eq!(AudioGainPlan::warning_text(choice, std::slice::from_ref(&quiet)), None);
        assert_eq!(AudioGainPlan::warning_text(AudioGainChoice::Adjust(12.0), &[peaky.clone(), quiet]), one);
        assert_eq!(AudioGainPlan::warning_text(AudioGainChoice::NormalizeEach { target_db: 0.0 }, &[peaky]), None);
    }

    #[test]
    fn loudness_line() {
        let mut a = item(1, 0.0, Some(0.1));
        a.lufs = Some(-23.44);
        let mut b = item(2, 0.0, Some(0.1));
        b.lufs = Some(-18.0);
        assert_eq!(AudioGainPlan::loudness_text(std::slice::from_ref(&a), false), "Loudness: \u{2212}23.4 LUFS");
        assert_eq!(AudioGainPlan::loudness_text(&[a.clone(), b], false), "Loudness: \u{2212}23.4 to \u{2212}18.0 LUFS");
        assert_eq!(
            AudioGainPlan::loudness_text(std::slice::from_ref(&a), true),
            "Loudness: \u{2212}23.4 LUFS (measuring...)"
        );
        let none = item(3, 0.0, Some(0.1));
        assert_eq!(AudioGainPlan::loudness_text(std::slice::from_ref(&none), true), "Loudness: measuring...");
        assert_eq!(AudioGainPlan::loudness_text(&[none], false), "Loudness: silent or unknown");
    }

    #[test]
    fn info_line() {
        let one = AudioGainItem::new(Id::from_u128(1), "Interview", 0.0, Some(0.5));
        assert_eq!(AudioGainPlan::info_text(&[one]), "Interview\nPeak amplitude: -6.0 dB");
        assert_eq!(AudioGainPlan::info_text(&[AudioGainItem::new(Id::from_u128(2), "X", 0.0, None)]), "X");
    }
}
