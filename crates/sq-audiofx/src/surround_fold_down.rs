//! Port of `SQAudioFX/Sources/SQAudioFX/SurroundFoldDown.swift`.

/// 5.1 to stereo fold-down for a source that sits on a stereo track (FILMCRAFT-PRS #1036, #733). ITU-R BS.775:
/// Lo = L + C * 0.7071 + Ls * 0.7071, Ro = R + C * 0.7071 + Rs * 0.7071, the LFE channel is dropped. The coefficients
/// are applied as they are (no normalization): a loud surround mix can exceed full scale, the delivery limiter and
/// the track fader deal with that like with any hot source. `normalized` divides by the sum of the largest side
/// (1 + 2 * 0.7071) when a caller needs a guaranteed no-clip result.
pub enum SurroundFoldDown {}

/// Order of the six channels in the decoded buffer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ChannelOrder {
    /// WAV / SMPTE: L, R, C, LFE, Ls, Rs (what the mixer expects).
    Smpte,
    /// AAC element order: C, L, R, Ls, Rs, LFE (what some decoders deliver, #733).
    Aac,
    /// Film order: L, C, R, Ls, Rs, LFE.
    Film,
}

/// Index of each speaker in a buffer of one order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SpeakerIndex {
    pub l: usize,
    pub r: usize,
    pub c: usize,
    pub lfe: usize,
    pub ls: usize,
    pub rs: usize,
}

impl ChannelOrder {
    pub const ALL: [ChannelOrder; 3] = [ChannelOrder::Smpte, ChannelOrder::Aac, ChannelOrder::Film];

    /// Index of each speaker in a buffer of this order.
    pub fn index(self) -> SpeakerIndex {
        let (l, r, c, lfe, ls, rs) = match self {
            ChannelOrder::Smpte => (0, 1, 2, 3, 4, 5),
            ChannelOrder::Aac => (1, 2, 0, 5, 3, 4),
            ChannelOrder::Film => (0, 2, 1, 5, 3, 4),
        };
        SpeakerIndex { l, r, c, lfe, ls, rs }
    }
}

impl SurroundFoldDown {
    /// -3 dB: the weight of the center and of each surround channel on its side.
    pub const CENTER_GAIN: f32 = std::f32::consts::FRAC_1_SQRT_2;
    pub const SURROUND_GAIN: f32 = std::f32::consts::FRAC_1_SQRT_2;
    /// Channel count this fold-down handles.
    pub const CHANNEL_COUNT: usize = 6;

    /// Gain that keeps a full-scale signal on every contributing channel inside full scale.
    pub fn normalizing_gain() -> f32 {
        1.0 / (1.0 + Self::CENTER_GAIN + Self::SURROUND_GAIN)
    }

    /// Folds six channels (`channels[i]` is channel i of `order`, `frames` samples each) into `left` and `right`.
    /// Returns false (outputs untouched) when `channels` does not hold six channels.
    pub fn fold_channels(
        channels: &[&[f32]],
        order: ChannelOrder,
        frames: usize,
        left: &mut [f32],
        right: &mut [f32],
        normalized: bool,
    ) -> bool {
        if channels.len() != Self::CHANNEL_COUNT || frames == 0 {
            return false;
        }
        let ix = order.index();
        let (l, r, c, ls, rs) = (channels[ix.l], channels[ix.r], channels[ix.c], channels[ix.ls], channels[ix.rs]);
        let g: f32 = if normalized { Self::normalizing_gain() } else { 1.0 };
        for i in 0..frames {
            let center = c[i] * Self::CENTER_GAIN;
            left[i] = (l[i] + center + ls[i] * Self::SURROUND_GAIN) * g;
            right[i] = (r[i] + center + rs[i] * Self::SURROUND_GAIN) * g;
        }
        true
    }

    /// Interleaved variant: `samples` holds `frames * 6` values (channel-fastest); returns interleaved stereo
    /// (`frames * 2`), or None when the count does not match.
    pub fn fold_interleaved(samples: &[f32], order: ChannelOrder, normalized: bool) -> Option<Vec<f32>> {
        if !samples.len().is_multiple_of(Self::CHANNEL_COUNT) {
            return None;
        }
        let frames = samples.len() / Self::CHANNEL_COUNT;
        let ix = order.index();
        let g: f32 = if normalized { Self::normalizing_gain() } else { 1.0 };
        let mut out = vec![0.0_f32; frames * 2];
        for i in 0..frames {
            let o = i * Self::CHANNEL_COUNT;
            let center = samples[o + ix.c] * Self::CENTER_GAIN;
            out[i * 2] = (samples[o + ix.l] + center + samples[o + ix.ls] * Self::SURROUND_GAIN) * g;
            out[i * 2 + 1] = (samples[o + ix.r] + center + samples[o + ix.rs] * Self::SURROUND_GAIN) * g;
        }
        Some(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: f64 = 48_000.0;
    const FRAMES: usize = 4800;

    /// Speaker frequencies (whole periods in 0.1 s).
    fn hz(name: &str) -> f64 {
        match name {
            "L" => 500.0,
            "R" => 300.0,
            "C" => 400.0,
            "LFE" => 60.0,
            "Ls" => 700.0,
            _ => 800.0,
        }
    }

    fn tone(f: f64) -> Vec<f32> {
        (0..FRAMES).map(|i| (2.0 * std::f64::consts::PI * f * i as f64 / RATE).sin() as f32).collect()
    }

    fn amplitude(x: &[f32], f: f64) -> f64 {
        let (mut re, mut im) = (0.0, 0.0);
        for (i, &v) in x.iter().enumerate() {
            let p = 2.0 * std::f64::consts::PI * f * i as f64 / RATE;
            re += f64::from(v) * p.cos();
            im += f64::from(v) * p.sin();
        }
        2.0 * (re * re + im * im).sqrt() / x.len() as f64
    }

    fn names(order: ChannelOrder) -> [&'static str; 6] {
        match order {
            ChannelOrder::Smpte => ["L", "R", "C", "LFE", "Ls", "Rs"],
            ChannelOrder::Aac => ["C", "L", "R", "Ls", "Rs", "LFE"],
            ChannelOrder::Film => ["L", "C", "R", "Ls", "Rs", "LFE"],
        }
    }

    /// Interleaved 6-channel file whose channel order is `file`, folded as if it were `read`.
    fn fold(file: ChannelOrder, read: ChannelOrder) -> (Vec<f32>, Vec<f32>) {
        let tones: Vec<Vec<f32>> = names(file).iter().map(|n| tone(hz(n))).collect();
        let mut inter = vec![0.0_f32; FRAMES * 6];
        for i in 0..FRAMES {
            for c in 0..6 {
                inter[i * 6 + c] = tones[c][i];
            }
        }
        let out = SurroundFoldDown::fold_interleaved(&inter, read, false).unwrap_or_default();
        ((0..FRAMES).map(|i| out[i * 2]).collect(), (0..FRAMES).map(|i| out[i * 2 + 1]).collect())
    }

    #[test]
    fn every_channel_lands_on_the_right_side() {
        for order in ChannelOrder::ALL {
            let (l, r) = fold(order, order);
            let k = f64::from(SurroundFoldDown::CENTER_GAIN);
            assert!((amplitude(&l, 500.0) - 1.0).abs() < 0.01);
            assert!((amplitude(&l, 400.0) - k).abs() < 0.01);
            assert!((amplitude(&l, 700.0) - k).abs() < 0.01);
            assert!(amplitude(&l, 300.0) < 0.01 && amplitude(&l, 800.0) < 0.01);
            assert!((amplitude(&r, 300.0) - 1.0).abs() < 0.01);
            assert!((amplitude(&r, 400.0) - k).abs() < 0.01);
            assert!((amplitude(&r, 800.0) - k).abs() < 0.01);
            assert!(amplitude(&r, 500.0) < 0.01 && amplitude(&r, 700.0) < 0.01);
            assert!(amplitude(&l, 60.0) < 0.01 && amplitude(&r, 60.0) < 0.01); // LFE dropped
        }
    }

    #[test]
    fn reading_aac_order_as_smpte_moves_speakers() {
        // Premise of #733: the orders are not interchangeable, so the order has to be declared.
        let (l, _) = fold(ChannelOrder::Aac, ChannelOrder::Smpte);
        assert!(amplitude(&l, 500.0) < 0.01);
    }

    #[test]
    fn planar_matches_interleaved() {
        let tones: Vec<Vec<f32>> = names(ChannelOrder::Aac).iter().map(|n| tone(hz(n))).collect();
        let (mut l, mut r) = (vec![0.0_f32; FRAMES], vec![0.0_f32; FRAMES]);
        let refs: Vec<&[f32]> = tones.iter().map(Vec::as_slice).collect();
        let ok = SurroundFoldDown::fold_channels(&refs, ChannelOrder::Aac, FRAMES, &mut l, &mut r, false);
        assert!(ok);
        let reference = fold(ChannelOrder::Aac, ChannelOrder::Aac);
        assert!(l == reference.0 && r == reference.1);
    }

    #[test]
    fn normalizing_keeps_full_scale_inside_and_lfe_is_silent() {
        let ones = [1.0_f32; 6 * 4];
        let hot = SurroundFoldDown::fold_interleaved(&ones, ChannelOrder::Smpte, false).unwrap_or_default();
        assert!((hot[0] - (1.0 + 2.0 * SurroundFoldDown::CENTER_GAIN)).abs() < 1e-5);
        let safe = SurroundFoldDown::fold_interleaved(&ones, ChannelOrder::Smpte, true).unwrap_or_default();
        assert!((safe[0] - 1.0).abs() < 1e-5 && (safe[1] - 1.0).abs() < 1e-5);
        assert!(SurroundFoldDown::fold_interleaved(&[0.0, 0.0, 0.0], ChannelOrder::Smpte, false).is_none());
        let mut lfe_only = [0.0_f32; 6];
        lfe_only[3] = 1.0;
        assert_eq!(SurroundFoldDown::fold_interleaved(&lfe_only, ChannelOrder::Smpte, false), Some(vec![0.0, 0.0]));
    }

    #[test]
    fn refuses_wrong_channel_count() {
        let (mut l, mut r) = ([0.0_f32], [0.0_f32]);
        let x = [1.0_f32];
        assert!(!SurroundFoldDown::fold_channels(&[&x, &x], ChannelOrder::Smpte, 1, &mut l, &mut r, false));
    }
}
