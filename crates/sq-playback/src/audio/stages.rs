// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MonitorGainStage.swift, ChannelMonitorStage.swift (stages), AudioMeterStore.swift, AudioPlaying.swift (meter types)
//! Render-thread stages after the meter (listening level, Solo/Mute per output channel) and the timeline meter.

use sq_audio_out::ring::{RingConsumer, RingProducer, ring};
use sq_audiofx::channel_monitor::ChannelMonitor;
use sq_audiofx::loudness::LoudnessMeter;
use sq_audiofx::monitor_gain::MonitorSetting;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::Duration;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Listening level applied on the render thread (the output has no mixer volume to drive). Runs after the meter push, so
/// meters and loudness never move with it; export never creates one. A change ramps over one block (no click).
/// `set` may come from any thread; `process` runs on one render thread only (its ramp state is not shared).
#[derive(Debug)]
pub struct MonitorGainStage {
    target: AtomicU32,
    current: f32,
}

impl MonitorGainStage {
    pub fn new(linear: f32) -> MonitorGainStage {
        MonitorGainStage { target: AtomicU32::new(linear.to_bits()), current: linear }
    }

    pub fn set(&self, setting: &MonitorSetting) {
        self.set_linear(setting.linear());
    }

    pub fn set_linear(&self, linear: f32) {
        self.target.store(linear.max(0.0).to_bits(), Ordering::Release);
    }

    pub fn linear(&self) -> f32 {
        f32::from_bits(self.target.load(Ordering::Acquire))
    }

    /// No allocation: safe on the render thread.
    pub fn process(&mut self, left: &mut [f32], right: &mut [f32]) {
        let to = self.linear();
        ChannelMonitor::apply_ramp(left, self.current, to);
        ChannelMonitor::apply_ramp(right, self.current, to);
        self.current = to;
    }
}

impl Default for MonitorGainStage {
    fn default() -> Self {
        Self::new(1.0)
    }
}

/// Monitoring-only Solo/Mute of the output channels, applied after the block was handed to the meter, so a muted channel
/// still moves its meter bar and loudness; export never creates one. `set` may come from any thread; `process` runs on
/// one render thread only.
#[derive(Debug)]
pub struct ChannelMonitorStage {
    mute: AtomicU8,
    solo: AtomicU8,
    current: (f32, f32),
}

impl ChannelMonitorStage {
    pub fn new() -> ChannelMonitorStage {
        ChannelMonitorStage { mute: AtomicU8::new(0), solo: AtomicU8::new(0), current: (1.0, 1.0) }
    }

    pub fn set(&self, m: ChannelMonitor) {
        self.mute.store(m.mute_mask(), Ordering::Release);
        self.solo.store(m.solo_mask(), Ordering::Release);
    }

    pub fn state(&self) -> ChannelMonitor {
        ChannelMonitor::with_masks(self.mute.load(Ordering::Acquire), self.solo.load(Ordering::Acquire))
    }

    /// No allocation: safe on the render thread.
    pub fn process(&mut self, left: &mut [f32], right: &mut [f32]) {
        let s = self.state();
        let l = if s.is_audible(0) { 1.0 } else { 0.0 };
        let r = if s.is_audible(1) { 1.0 } else { 0.0 };
        ChannelMonitor::apply_ramp(left, self.current.0, l);
        ChannelMonitor::apply_ramp(right, self.current.1, r);
        self.current = (l, r);
    }
}

impl Default for ChannelMonitorStage {
    fn default() -> Self {
        Self::new()
    }
}

/// Peak and RMS of one channel over the last metered buffer (linear, 1 = full scale).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct AudioMeterLevel {
    pub peak: f32,
    pub rms: f32,
}

/// BS.1770 / R128 readings of the metered timeline signal (`None` = not enough signal yet; integrated `None` = nothing
/// passes the gates).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LoudnessLevels {
    pub momentary: Option<f64>,
    pub short_term: Option<f64>,
    pub integrated: Option<f64>,
    pub true_peak_db: f64,
}

impl Default for LoudnessLevels {
    fn default() -> Self {
        LoudnessLevels { momentary: None, short_term: None, integrated: None, true_peak_db: f64::NEG_INFINITY }
    }
}

/// Timeline audio meter reading (pre monitoring gain, i.e. the mixed timeline signal). `sequence` counts metered buffers.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct AudioMeterSnapshot {
    pub left: AudioMeterLevel,
    pub right: AudioMeterLevel,
    pub loudness: LoudnessLevels,
    pub sequence: u64,
}

struct MeterState {
    snapshot: AudioMeterSnapshot,
    loudness: LoudnessMeter,
}

/// Peak/RMS of the last metered buffer, written by the drain thread, read by the UI.
pub struct AudioMeterStore {
    state: Mutex<MeterState>,
}

impl Default for AudioMeterStore {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioMeterStore {
    pub fn new() -> AudioMeterStore {
        AudioMeterStore {
            state: Mutex::new(MeterState {
                snapshot: AudioMeterSnapshot::default(),
                loudness: LoudnessMeter::new(48_000, 2, None),
            }),
        }
    }

    pub fn snapshot(&self) -> AudioMeterSnapshot {
        lock(&self.state).snapshot
    }

    /// Measures one buffer: peak/RMS per channel, then the BS.1770 meter (the one the export normalizer uses).
    pub fn measure(&self, l: &[f32], r: &[f32]) {
        fn level(p: &[f32]) -> AudioMeterLevel {
            let (mut peak, mut sum) = (0.0f32, 0.0f32);
            for &v in p {
                peak = peak.max(v.abs());
                sum += v * v;
            }
            AudioMeterLevel { peak, rms: if p.is_empty() { 0.0 } else { (sum / p.len() as f32).sqrt() } }
        }
        let (a, b) = (level(l), level(r));
        let mut s = lock(&self.state);
        s.snapshot.left = a;
        s.snapshot.right = b;
        s.snapshot.sequence += 1;
        s.loudness.process(&[l.to_vec(), r.to_vec()]);
        s.snapshot.loudness = Self::levels(&s.loudness);
    }

    /// Restarts the integrated value and the true-peak hold.
    pub fn reset_loudness(&self) {
        let mut s = lock(&self.state);
        s.loudness.reset();
        s.snapshot.loudness = Self::levels(&s.loudness);
    }

    fn levels(m: &LoudnessMeter) -> LoudnessLevels {
        let i = m.integrated();
        LoudnessLevels {
            momentary: m.momentary(),
            short_term: m.short_term(),
            integrated: i.is_finite().then_some(i),
            true_peak_db: m.true_peak_db().into_iter().fold(f64::NEG_INFINITY, f64::max),
        }
    }
}

/// Render-thread side of the meter feed: pushes the unprocessed (pre monitoring gain) block into a lock-free ring.
pub struct MeterTap {
    ring: RingProducer,
}

impl MeterTap {
    pub fn push(&mut self, left: &[f32], right: &[f32]) {
        self.ring.push(left, right);
    }
}

/// Meter feed off the render thread: a timer thread measures the tap's blocks in 1024-frame buffers. The measurement
/// (copies, a mutex, BS.1770 filters) never runs in the render callback.
pub struct MeterDrain {
    ring: RingConsumer,
    store: Arc<AudioMeterStore>,
    left: Vec<f32>,
    right: Vec<f32>,
}

impl MeterDrain {
    pub const BUFFER_FRAMES: usize = 1024;

    /// The tap for the render thread and the drain for the measuring side.
    pub fn new(store: Arc<AudioMeterStore>) -> (MeterTap, MeterDrain) {
        let (producer, consumer) = ring(1 << 14, 0, Duration::from_secs(3600));
        (
            MeterTap { ring: producer },
            MeterDrain {
                ring: consumer,
                store,
                left: vec![0.0; Self::BUFFER_FRAMES],
                right: vec![0.0; Self::BUFFER_FRAMES],
            },
        )
    }

    /// Measures every complete buffer waiting; returns how many were measured.
    pub fn drain_once(&mut self) -> usize {
        let mut n = 0;
        while self.ring.shared().available_to_read() >= Self::BUFFER_FRAMES {
            self.ring.pop(&mut self.left, &mut self.right);
            self.store.measure(&self.left, &self.right);
            n += 1;
        }
        n
    }

    /// Runs `drain_once` every 10 ms on a utility thread until the returned handle is stopped or dropped.
    pub fn start(mut self) -> MeterThread {
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        let handle = std::thread::Builder::new().name("sq-audio-meter".into()).spawn(move || {
            while !flag.load(Ordering::Acquire) {
                self.drain_once();
                std::thread::sleep(Duration::from_millis(10));
            }
        });
        MeterThread { stop, handle: handle.ok() }
    }
}

/// The running meter thread; stops on drop.
pub struct MeterThread {
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl MeterThread {
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for MeterThread {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block(v: f32, n: usize) -> Vec<f32> {
        vec![v; n]
    }

    fn run_gain(stage: &mut MonitorGainStage, v: f32, n: usize) -> (Vec<f32>, Vec<f32>) {
        let (mut l, mut r) = (block(v, n), block(v, n));
        stage.process(&mut l, &mut r);
        (l, r)
    }

    #[test]
    fn full_level_leaves_the_block_untouched() {
        let (l, r) = run_gain(&mut MonitorGainStage::default(), 0.5, 8);
        assert_eq!(l, block(0.5, 8));
        assert_eq!(l, r);
    }

    #[test]
    fn dim_ramps_over_one_block_then_holds() {
        let mut stage = MonitorGainStage::default();
        let setting = MonitorSetting { level_db: 0.0, dim: true };
        stage.set(&setting);
        let target = setting.linear();
        let (first_l, first_r) = run_gain(&mut stage, 1.0, 4);
        assert!(first_l[0] == 1.0 && first_l[3] < first_l[0] && first_l[3] > target, "no jump: a ramp");
        assert_eq!(first_l, first_r);
        let (second, _) = run_gain(&mut stage, 1.0, 4);
        assert!(second.iter().all(|v| (v - target).abs() < 1e-6));
    }

    #[test]
    fn slider_floor_mutes() {
        let mut stage = MonitorGainStage::default();
        stage.set(&MonitorSetting { level_db: sq_audiofx::monitor_gain::MonitorGain::MIN_DB, dim: false });
        run_gain(&mut stage, 1.0, 4);
        assert_eq!(run_gain(&mut stage, 1.0, 4).0, block(0.0, 4));
    }

    #[test]
    fn neutral_channel_stage_leaves_the_block_untouched() {
        let mut stage = ChannelMonitorStage::new();
        let (mut l, mut r) = (block(0.5, 8), block(-0.25, 8));
        stage.process(&mut l, &mut r);
        assert_eq!((l, r), (block(0.5, 8), block(-0.25, 8)));
    }

    #[test]
    fn mute_silences_after_the_ramp_and_keeps_the_other_channel() {
        let mut stage = ChannelMonitorStage::new();
        let mut m = ChannelMonitor::new();
        m.toggle_mute(&[0]);
        stage.set(m);
        let (mut l, mut r) = (block(1.0, 4), block(1.0, 4));
        stage.process(&mut l, &mut r); // ramps 1 -> 0
        assert_eq!(r, block(1.0, 4));
        assert!(l[0] == 1.0 && l[3] < l[0]);
        let (mut l2, mut r2) = (block(1.0, 4), block(1.0, 4));
        stage.process(&mut l2, &mut r2); // settled
        assert_eq!((l2, r2), (block(0.0, 4), block(1.0, 4)));
    }

    #[test]
    fn solo_keeps_only_the_soloed_channel() {
        let mut stage = ChannelMonitorStage::new();
        let mut m = ChannelMonitor::new();
        m.toggle_solo(&[1]);
        stage.set(m);
        for _ in 0..2 {
            let (mut l, mut r) = (block(1.0, 4), block(1.0, 4));
            stage.process(&mut l, &mut r);
            if l == block(0.0, 4) {
                assert_eq!(r, block(1.0, 4));
            }
        }
        assert_eq!(stage.state().gains(), vec![0.0, 1.0]);
    }

    /// The meter reads the block before the stage: a muted channel still shows its level.
    #[test]
    fn meter_still_sees_a_muted_channel() {
        let store = Arc::new(AudioMeterStore::new());
        let (mut tap, mut drain) = MeterDrain::new(Arc::clone(&store));
        let mut stage = ChannelMonitorStage::new();
        let mut m = ChannelMonitor::new();
        m.toggle_mute(&[0, 1]);
        stage.set(m);
        let n = MeterDrain::BUFFER_FRAMES;
        for _ in 0..2 {
            let (mut l, mut r) = (block(0.5, n), block(0.25, n));
            tap.push(&l, &r);
            stage.process(&mut l, &mut r);
        }
        assert_eq!(drain.drain_once(), 2);
        let s = store.snapshot();
        assert!(s.left.peak == 0.5 && s.right.peak == 0.25 && s.sequence == 2);
    }
}
