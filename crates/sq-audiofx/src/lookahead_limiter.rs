// Swift: LookaheadLimiter.swift
//! Stereo-linked look-ahead brickwall limiter (the Multiband Compressor's output limiter).
//!
//! The signal is delayed by `lookahead` samples; the gain that every sample needs (`ceiling / peak`) is known that much
//! earlier, so the gain can fall smoothly *before* a peak arrives instead of clipping it. Gain path per sample: sliding
//! minimum of the needed gain over `lookahead + 1` samples, then release (one-pole back up, instant down), then a moving
//! average over `attack` samples (`attack <= lookahead`). Because every value in the average window already includes the peak
//! that leaves the delay line now, the applied gain is never above what that peak needs: the ceiling holds by construction,
//! without a hard clip. A final clamp at the ceiling catches Float rounding and the first `lookahead` samples after the
//! limiter is switched on (they were already in the delay line). It applies to every sample that entered or leaves while the
//! limiter is active, so switching it off (or `delay_only`) never lets the driven samples still in the line through.
//!
//! Latency: exactly `lookahead` samples, always (also while `active` is false), so a chain's latency never changes.
//! Realtime-safe: all memory is allocated in `new`; `process` never allocates or locks. Not thread-safe.

use crate::gain::GainMath;

/// The look-ahead limiter.
#[derive(Clone, Debug)]
pub struct LookaheadLimiter {
    lookahead: usize,
    channels: usize,
    ceiling_db: f64,
    ceiling: f64,
    ceiling_f: f32,
    release_ms: f64,
    release_coef: f64,
    attack_samples: usize,
    /// Current applied gain (1 = no reduction).
    gain: f64,
    /// `channels` x `lookahead` ring.
    delay: Vec<f32>,
    d_pos: usize,
    // Sliding minimum: monotonic deque of (sample index, needed gain), ring of lookahead + 2.
    dq_idx: Vec<i64>,
    dq_val: Vec<f64>,
    dq_cap: usize,
    dq_head: usize,
    dq_count: usize,
    index: i64,
    /// Samples that entered at an index below this were taken in while the limiter was active (they stay clamped).
    active_end: i64,
    released: f64,
    // Moving average of `released` over `attack_samples`.
    boxcar: Vec<f64>,
    b_pos: usize,
    b_sum: f64,
    sample_rate: f64,
}

impl LookaheadLimiter {
    /// Default look-ahead 5 ms, ceiling -0.1 dB, release 500 ms, attack 5 ms.
    pub fn new(sample_rate: f64, channels: usize) -> Self {
        Self::with_times(sample_rate, channels, 5.0, -0.1, 500.0, 5.0)
    }

    /// Limiter with explicit look-ahead, ceiling (dB), release (ms) and attack (ms).
    pub fn with_times(
        sample_rate: f64,
        channels: usize,
        lookahead_ms: f64,
        ceiling_db: f64,
        release_ms: f64,
        attack_ms: f64,
    ) -> Self {
        let channels = channels.max(1);
        let lookahead = ((sample_rate * lookahead_ms / 1000.0).round() as i64).max(1) as usize;
        let dq_cap = lookahead + 2;
        let mut l = LookaheadLimiter {
            lookahead,
            channels,
            ceiling_db: f64::NAN,
            ceiling: 1.0,
            ceiling_f: 1.0,
            release_ms: f64::NAN,
            release_coef: 0.0,
            attack_samples: 1,
            gain: 1.0,
            delay: vec![0.0; channels * lookahead],
            d_pos: 0,
            dq_idx: vec![0; dq_cap],
            dq_val: vec![1.0; dq_cap],
            dq_cap,
            dq_head: 0,
            dq_count: 0,
            index: 0,
            active_end: i64::MIN,
            released: 1.0,
            boxcar: vec![1.0; lookahead],
            b_pos: 0,
            b_sum: 0.0,
            sample_rate,
        };
        l.configure(ceiling_db, release_ms, attack_ms);
        l.reset();
        l
    }

    /// Look-ahead in samples = the latency.
    pub fn lookahead(&self) -> usize {
        self.lookahead
    }

    /// Channels the limiter links.
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Ceiling now, dB.
    pub fn ceiling_db(&self) -> f64 {
        self.ceiling_db
    }

    /// Release now, ms.
    pub fn release_ms(&self) -> f64 {
        self.release_ms
    }

    /// Attack in samples now.
    pub fn attack_samples(&self) -> usize {
        self.attack_samples
    }

    /// Current applied gain (1 = no reduction).
    pub fn gain(&self) -> f64 {
        self.gain
    }

    /// Gain reduction now, in dB (0 or negative).
    pub fn gain_reduction_db(&self) -> f64 {
        if self.gain >= 1.0 { 0.0 } else { GainMath::db_from_linear(self.gain) }
    }

    /// Empties the delay line and the gain history. Allocation-free.
    pub fn reset(&mut self) {
        self.delay.fill(0.0);
        self.d_pos = 0;
        self.dq_head = 0;
        self.dq_count = 0;
        self.index = 0;
        self.active_end = i64::MIN;
        self.released = 1.0;
        self.gain = 1.0;
        self.boxcar.fill(1.0);
        self.b_pos = 0;
        self.b_sum = self.attack_samples as f64;
    }

    /// Ceiling (dB, <= 0), release (ms) and attack (ms, clamped to 1 sample...lookahead). Keeps the gain state: a changed
    /// value never jumps. Allocation-free.
    pub fn configure(&mut self, ceiling_db: f64, release_ms: f64, attack_ms: f64) {
        if ceiling_db != self.ceiling_db {
            self.ceiling_db = ceiling_db;
            let exact = GainMath::linear_from_db(ceiling_db);
            let mut f = exact as f32;
            if f64::from(f) > exact {
                f = f.next_down();
            }
            self.ceiling_f = f;
            self.ceiling = f64::from(f);
        }
        if release_ms != self.release_ms {
            self.release_ms = release_ms;
            self.release_coef = (-1.0 / (self.sample_rate * release_ms / 1000.0).max(1.0)).exp();
        }
        let a = if attack_ms.is_nan() { 0.0 } else { attack_ms };
        let atk = (((self.sample_rate * a / 1000.0).round() as i64).max(1) as usize).min(self.lookahead);
        if atk != self.attack_samples {
            // Refill the average at the current gain: no jump, and the ceiling clamp covers the switch.
            self.attack_samples = atk;
            self.boxcar.fill(self.gain);
            self.b_pos = 0;
            self.b_sum = self.gain * atk as f64;
        }
    }

    /// In place on all channels (linked). `active` false: the needed gain is 1 (the gain releases back to unity), the delay
    /// stays.
    pub fn process(&mut self, buf: &mut [&mut [f32]], n: usize, active: bool) {
        let c = buf.len().min(self.channels);
        let (l, a) = (self.lookahead, self.attack_samples);
        let (ceil, cf, rc) = (self.ceiling, self.ceiling_f, self.release_coef);
        let (mut r, mut g, mut sum, mut bp, mut dp) = (self.released, self.gain, self.b_sum, self.b_pos, self.d_pos);
        let (mut head, mut count, mut idx, mut ae) = (self.dq_head, self.dq_count, self.index, self.active_end);
        for i in 0..n {
            let mut peak = 0.0_f32;
            for ch in buf.iter().take(c) {
                peak = peak.max(ch[i].abs());
            }
            let need = if active && f64::from(peak) > ceil { ceil / f64::from(peak) } else { 1.0 };
            // Sliding minimum over [idx - L, idx].
            while count > 0 {
                let back = (head + count - 1) % self.dq_cap;
                if self.dq_val[back] >= need {
                    count -= 1;
                } else {
                    break;
                }
            }
            let slot = (head + count) % self.dq_cap;
            self.dq_idx[slot] = idx;
            self.dq_val[slot] = need;
            count += 1;
            while self.dq_idx[head] < idx - l as i64 {
                head = (head + 1) % self.dq_cap;
                count -= 1;
            }
            let h = self.dq_val[head];
            r = if h < r { h } else { h + (r - h) * rc };
            if h >= 1.0 && r > 0.999_999_9 {
                r = 1.0; // snap to unity only when nothing in the window needs less
            }
            if active {
                ae = idx + 1;
            }
            let clamp = active || idx - (l as i64) < ae; // the sample leaving now entered at idx - L
            sum += r - self.boxcar[bp];
            self.boxcar[bp] = r;
            bp += 1;
            if bp == a {
                bp = 0;
            }
            g = (sum / a as f64).min(1.0);
            for (ch, chan) in buf.iter_mut().enumerate().take(c) {
                let line = &mut self.delay[ch * l..(ch + 1) * l];
                let x = chan[i];
                let y = line[dp];
                line[dp] = x;
                let o = if g >= 1.0 { y } else { (f64::from(y) * g) as f32 };
                chan[i] = if clamp { o.max(-cf).min(cf) } else { o };
            }
            dp += 1;
            if dp == l {
                dp = 0;
            }
            idx += 1;
        }
        // Re-sum the window once per block so rounding in the running sum cannot drift.
        let mut s = 0.0;
        for k in 0..a {
            s += self.boxcar[k];
        }
        self.b_sum = s;
        self.released = r;
        self.gain = g;
        self.b_pos = bp;
        self.d_pos = dp;
        self.dq_head = head;
        self.dq_count = count;
        self.index = idx;
        self.active_end = ae;
    }

    /// A disabled stage: keeps the latency. Runs the gain path with nothing needing reduction, so the samples still in the
    /// line from the active limiter leave limited and clamped, and the gain releases smoothly to unity (no click, no
    /// overshoot); after that the output is the plain delayed input.
    pub fn delay_only(&mut self, buf: &mut [&mut [f32]], n: usize) {
        self.process(buf, n, false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(lim: &mut LookaheadLimiter, x: &mut [f32], active: bool) {
        let n = x.len();
        lim.process(&mut [&mut *x], n, active);
    }

    #[test]
    fn delays_by_the_lookahead_and_holds_the_ceiling() {
        let mut lim = LookaheadLimiter::with_times(48_000.0, 1, 5.0, -6.0, 200.0, 5.0);
        assert_eq!(lim.lookahead(), 240);
        let mut x: Vec<f32> = (0..9600).map(|i| if (4000..4100).contains(&i) { 1.5 } else { 0.1 }).collect();
        let before = x.clone();
        run(&mut lim, &mut x, true);
        let ceil = lim.ceiling;
        assert!(x.iter().all(|v| f64::from(v.abs()) <= ceil));
        // The quiet part before the burst is the input delayed by the look-ahead (the ceiling is above 0.1).
        assert_eq!(x[300], before[300 - 240]);
        assert!(lim.gain_reduction_db() <= 0.0);
    }

    #[test]
    fn delay_only_releases_to_the_plain_delayed_input() {
        let mut lim = LookaheadLimiter::new(48_000.0, 1);
        let mut loud = vec![1.4_f32; 2000];
        run(&mut lim, &mut loud, true);
        let mut quiet = vec![0.2_f32; 480_000];
        lim.delay_only(&mut [quiet.as_mut_slice()], 480_000);
        assert_eq!(quiet[479_999], 0.2);
        assert_eq!(lim.gain(), 1.0);
    }

    #[test]
    fn limiter_never_passes_the_ceiling_by_an_ulp() {
        // Unit level: a gain releasing back toward 1 (the near-unity snap) meets samples a few ulps over the ceiling.
        let mut lim = LookaheadLimiter::with_times(48_000.0, 1, 5.0, -0.1, 5.0, 1.0);
        let cf = GainMath::linear_from_db(-0.1) as f32;
        let mut p = vec![0.0_f32; 100];
        let (mut worst, mut seed) = (0.0_f32, 3_u64);
        for k in 0..2000 {
            for (i, s) in p.iter_mut().enumerate() {
                seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
                let ulps = seed >> 61; // 0...7 ulps over
                let mut v = cf;
                for _ in 0..ulps {
                    v = v.next_up();
                }
                *s = (if k % 4 == 0 {
                    v
                } else if k % 4 == 1 {
                    cf * 0.5
                } else {
                    v.next_up()
                }) * if i % 2 == 0 { 1.0 } else { -1.0 };
            }
            lim.process(&mut [p.as_mut_slice()], 100, true);
            if k > 0 {
                worst = p.iter().fold(worst, |m, v| m.max(v.abs()));
            }
        }
        assert!(worst <= cf, "{worst} > {cf}");
    }
}
