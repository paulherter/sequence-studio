//! The mix as the encoder wants it: loudness gain, 1 or 2 channels, exact lengths.

use crate::core::{
    AudioChunk, AudioSettings, AudioSource, CancelToken, ExportError, LoudnessChain, LoudnessNormalizer, LoudnessReport,
};

/// Reads an `AudioSource` in encoder-sized pieces, applies the planned loudness chain and remixes to `channels`.
pub(super) struct AudioFeed<'a> {
    source: &'a mut dyn AudioSource,
    chain: Option<LoudnessChain>,
    channels: usize,
    ended: bool,
}

impl<'a> AudioFeed<'a> {
    /// Measures and plans the loudness gain when `settings` ask for it (the Mac `ExportWriter.normalizedAudio`; the
    /// source is borrowed, so the chain runs here instead of in a `NormalizedAudioSource`).
    pub fn new(
        source: &'a mut dyn AudioSource,
        settings: &AudioSettings,
        channels: usize,
        cancel: &CancelToken,
    ) -> Result<(AudioFeed<'a>, Option<LoudnessReport>), ExportError> {
        let mut chain = None;
        let mut report = None;
        if let Some(l) = settings.loudness {
            let rate = source.sample_rate();
            let base = source.as_rewindable().ok_or(ExportError::LoudnessNeedsRewindableSource)?;
            let m = LoudnessNormalizer::measure(base, cancel)?;
            let plan = LoudnessNormalizer::plan(base, m, l, cancel)?;
            chain = Some(LoudnessChain::new(plan.gain_db, plan.limiter_ceiling_db, rate));
            let mut r = LoudnessReport::new(m, l);
            r.gain_db = plan.gain_db;
            r.limiter_used = plan.limiter_ceiling_db.is_some();
            r.result_lufs = Some(plan.result.integrated_lufs);
            r.result_true_peak_db = Some(plan.result.true_peak_db);
            report = Some(r);
        }
        Ok((AudioFeed { source, chain, channels, ended: false }, report))
    }

    pub fn sample_rate(&self) -> i64 {
        self.source.sample_rate()
    }

    /// Up to `want` frames of interleaved samples in the output channel count; silence after the source ends.
    /// `cut` drops what a source returns beyond `want`.
    pub fn read(&mut self, want: usize, cut: bool) -> Result<Vec<f32>, ExportError> {
        if !self.ended {
            if let Some(mut chunk) = self.source.next_chunk(want)?.filter(|c| c.frame_count() > 0) {
                if let Some(chain) = self.chain.as_mut() {
                    chain.apply(&mut chunk);
                }
                let mut out = remix(&chunk, self.channels);
                if cut {
                    out.truncate(want * self.channels);
                }
                return Ok(out);
            }
            self.ended = true;
        }
        Ok(vec![0.0; want * self.channels])
    }
}

/// Interleaved samples in `channels` (1 or 2): mono doubles, more channels keep the first two (or average to mono).
pub(super) fn remix(c: &AudioChunk, channels: usize) -> Vec<f32> {
    let n = c.frame_count();
    let src = c.channels.max(1);
    if src == channels {
        return c.samples.clone();
    }
    let mut out = vec![0.0f32; n * channels];
    for k in 0..n {
        let l = c.samples[k * src];
        let r = if src > 1 { c.samples[k * src + 1] } else { l };
        if channels == 2 {
            out[2 * k] = l;
            out[2 * k + 1] = r;
        } else {
            out[k] = (l + r) * 0.5;
        }
    }
    out
}
