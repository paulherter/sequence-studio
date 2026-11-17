//! Port of `SQAudioFX/Sources/SQAudioFX/CreatorStages.swift`.

// Creator stages of the per-clip chain: Stereo Width (mid/side) and Chorus. Plain DSP, state preallocated, `process` never
// allocates, zero latency (the chorus's wet copy is a delay, not look-ahead, so nothing is compensated).

/// Mid/side width. Only the first two channels are touched; a mono clip passes. The width moves linearly across the block.
#[derive(Default)]
pub(crate) struct StereoWidthStage;

impl StereoWidthStage {
    pub(crate) fn reset(&mut self) {}

    pub(crate) fn process(&mut self, buf: &mut [&mut [f32]], n: usize, w0: f64, w1: f64) {
        if buf.len() < 2 {
            return;
        }
        let a = w0.max(0.0) as f32;
        let step = (w1.max(0.0) as f32 - a) / n as f32;
        let (first, rest) = buf.split_at_mut(1);
        let (l, r) = (&mut first[0], &mut rest[0]);
        for i in 0..n {
            let w = a + step * i as f32;
            let m = (l[i] + r[i]) * 0.5;
            let s = (l[i] - r[i]) * 0.5 * w;
            l[i] = m + s;
            r[i] = m - s;
        }
    }
}

/// Chorus: per channel a delay line read at 15 ms +- depth by a sine LFO (linear interpolation), the right channel a quarter
/// cycle behind the left. Output = dry + (wet - dry) * mix. The line is sized for the largest sweep, so nothing allocates.
pub(crate) struct ChorusStage {
    fs: f64,
    channels: usize,
    size: usize,
    line: Vec<f32>,
    pos: usize,
    phase: f64,
    pub was_off: bool,
}

impl ChorusStage {
    const BASE_MS: f64 = 15.0;
    const MAX_DEPTH_MS: f64 = 10.0;

    pub(crate) fn new(sample_rate: f64, channels: usize) -> Self {
        let size = ((Self::BASE_MS + Self::MAX_DEPTH_MS) * 0.001 * sample_rate) as usize + 4;
        ChorusStage {
            fs: sample_rate,
            channels,
            size,
            line: vec![0.0; size * channels],
            pos: 0,
            phase: 0.0,
            was_off: false,
        }
    }

    pub(crate) fn reset(&mut self) {
        self.line.fill(0.0);
        self.pos = 0;
        self.phase = 0.0;
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn process(&mut self, buf: &mut [&mut [f32]], n: usize, rate_hz: f64, depth_ms: f64, m0: f64, m1: f64) {
        if self.was_off {
            self.reset();
            self.was_off = false;
        }
        let base = Self::BASE_MS * 0.001 * self.fs;
        let depth = depth_ms.clamp(0.0, Self::MAX_DEPTH_MS) * 0.001 * self.fs;
        let inc = rate_hz.max(0.0) / self.fs;
        let mix_a = m0.clamp(0.0, 1.0) as f32;
        let mix_step = (m1.clamp(0.0, 1.0) as f32 - mix_a) / n as f32;
        let count = buf.len().min(self.channels);
        let size = self.size;
        for i in 0..n {
            let mix = mix_a + mix_step * i as f32;
            for (c, chan) in buf.iter_mut().enumerate().take(count) {
                let ph = self.phase + if c % 2 == 1 { 0.25 } else { 0.0 };
                let d = base + depth * (2.0 * std::f64::consts::PI * ph).sin();
                let dry = chan[i];
                self.line[c * size + self.pos] = dry;
                let mut rp = self.pos as f64 - d;
                if rp < 0.0 {
                    rp += size as f64;
                }
                let mut i0 = rp as usize;
                if i0 >= size {
                    i0 -= size;
                }
                let f = (rp - i0 as f64).max(0.0) as f32;
                let i1 = if i0 + 1 >= size { 0 } else { i0 + 1 };
                let wet = self.line[c * size + i0] * (1.0 - f) + self.line[c * size + i1] * f;
                chan[i] = dry + (wet - dry) * mix;
            }
            self.pos += 1;
            if self.pos == size {
                self.pos = 0;
            }
            self.phase += inc;
            if self.phase >= 1.0 {
                self.phase -= 1.0;
            }
        }
    }
}
