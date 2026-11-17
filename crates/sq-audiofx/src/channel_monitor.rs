//! Port of `SQAudioFX/Sources/SQAudioFX/ChannelMonitor.swift`.

/// Per-channel listening state of the timeline meter: Solo and Mute per output channel (L, R). Monitoring only: the engine
/// applies it after the meter measurement and only on the speaker path, so meters, loudness and export never see it.
/// Solo wins over Mute of other channels (any soloed channel silences every channel that is not soloed); Mute silences a
/// channel even when it is soloed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ChannelMonitor {
    mute_mask: u8,
    solo_mask: u8,
}

impl ChannelMonitor {
    pub const CHANNEL_COUNT: i64 = 2;

    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_masks(mute_mask: u8, solo_mask: u8) -> Self {
        let all: u8 = (1 << Self::CHANNEL_COUNT as u8) - 1;
        ChannelMonitor { mute_mask: mute_mask & all, solo_mask: solo_mask & all }
    }

    /// Bit i = channel i.
    pub fn mute_mask(&self) -> u8 {
        self.mute_mask
    }

    /// Bit i = channel i.
    pub fn solo_mask(&self) -> u8 {
        self.solo_mask
    }

    fn bit(channel: i64) -> Option<u8> {
        (0..Self::CHANNEL_COUNT).contains(&channel).then(|| 1 << channel as u8)
    }

    pub fn is_muted(&self, channel: i64) -> bool {
        Self::bit(channel).is_some_and(|b| self.mute_mask & b != 0)
    }

    pub fn is_soloed(&self, channel: i64) -> bool {
        Self::bit(channel).is_some_and(|b| self.solo_mask & b != 0)
    }

    pub fn is_neutral(&self) -> bool {
        self.mute_mask == 0 && self.solo_mask == 0
    }

    /// Whether `channel` is heard: not muted, and (no solo anywhere or this channel is soloed).
    pub fn is_audible(&self, channel: i64) -> bool {
        if Self::bit(channel).is_none() {
            return true;
        }
        if self.is_muted(channel) {
            return false;
        }
        self.solo_mask == 0 || self.is_soloed(channel)
    }

    /// Linear monitoring gain per channel (1 audible, 0 silenced).
    pub fn gains(&self) -> Vec<f32> {
        (0..Self::CHANNEL_COUNT).map(|c| if self.is_audible(c) { 1.0 } else { 0.0 }).collect()
    }

    pub fn toggle_mute(&mut self, channels: &[i64]) {
        let on = !channels.iter().all(|&c| self.is_muted(c));
        for &c in channels {
            if let Some(b) = Self::bit(c) {
                if on { self.mute_mask |= b } else { self.mute_mask &= !b }
            }
        }
    }

    pub fn toggle_solo(&mut self, channels: &[i64]) {
        let on = !channels.iter().all(|&c| self.is_soloed(c));
        for &c in channels {
            if let Some(b) = Self::bit(c) {
                if on { self.solo_mask |= b } else { self.solo_mask &= !b }
            }
        }
    }

    pub fn clear(&mut self) {
        self.mute_mask = 0;
        self.solo_mask = 0;
    }

    /// Linear gain ramp over a block (no click): `from` at the first frame, `to` after the last. Both 1 = untouched.
    pub fn apply_ramp(p: &mut [f32], from: f32, to: f32) {
        let count = p.len();
        if count == 0 {
            return;
        }
        if from == to {
            if to == 1.0 {
                return;
            }
            if to == 0.0 {
                p.fill(0.0);
                return;
            }
            for s in p.iter_mut() {
                *s *= to;
            }
            return;
        }
        let step = (to - from) / count as f32;
        let mut g = from;
        for s in p.iter_mut() {
            *s *= g;
            g += step;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn neutral_passes_both() {
        let m = ChannelMonitor::new();
        assert!(m.is_neutral());
        assert_eq!(m.gains(), vec![1.0, 1.0]);
    }

    #[test]
    fn mute_silences_only_that_channel() {
        let mut m = ChannelMonitor::new();
        m.toggle_mute(&[0]);
        assert_eq!(m.gains(), vec![0.0, 1.0]);
        m.toggle_mute(&[0]);
        assert!(m.is_neutral());
    }

    #[test]
    fn solo_silences_the_others() {
        let mut m = ChannelMonitor::new();
        m.toggle_solo(&[1]);
        assert_eq!(m.gains(), vec![0.0, 1.0]);
        m.toggle_solo(&[0]);
        assert_eq!(m.gains(), vec![1.0, 1.0]);
        m.toggle_solo(&[0, 1]);
        assert!(m.is_neutral());
    }

    #[test]
    fn mute_beats_solo() {
        let mut m = ChannelMonitor::new();
        m.toggle_solo(&[0]);
        m.toggle_mute(&[0]);
        assert_eq!(m.gains(), vec![0.0, 0.0]);
    }

    #[test]
    fn group_toggle_for_mono_bar() {
        let mut m = ChannelMonitor::new();
        m.toggle_mute(&[0, 1]);
        assert_eq!(m.gains(), vec![0.0, 0.0]);
        m.toggle_mute(&[0, 1]);
        assert!(m.is_neutral());
    }

    #[test]
    fn out_of_range_channel_is_ignored() {
        let mut m = ChannelMonitor::new();
        m.toggle_mute(&[5, -1]);
        assert!(m.is_neutral());
        assert!(m.is_audible(7));
        assert_eq!(ChannelMonitor::with_masks(0xFF, 0).mute_mask(), 0b11);
    }

    #[test]
    fn clear_resets() {
        let mut m = ChannelMonitor::new();
        m.toggle_mute(&[0]);
        m.toggle_solo(&[1]);
        m.clear();
        assert!(m.is_neutral());
    }

    #[test]
    fn ramp_identity_at_unity_and_silence_at_zero() {
        let mut a = [0.5_f32, -0.25, 1.0, 0.1];
        ChannelMonitor::apply_ramp(&mut a, 1.0, 1.0);
        assert_eq!(a, [0.5, -0.25, 1.0, 0.1]);
        ChannelMonitor::apply_ramp(&mut a, 0.0, 0.0);
        assert_eq!(a, [0.0, 0.0, 0.0, 0.0]);
    }

    #[test]
    fn ramp_fades_without_step() {
        let mut a = [1.0_f32; 4];
        ChannelMonitor::apply_ramp(&mut a, 1.0, 0.0);
        assert_eq!(a, [1.0, 0.75, 0.5, 0.25]);
    }
}
