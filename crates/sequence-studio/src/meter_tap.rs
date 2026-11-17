// Swift: PlaybackEngine.meterStore / AudioEngine meter tap (ProgramEngine.meterReading, loudnessLevels)
//! The Program engine's audio meter feed: a renderer wrapper that hands every mixed block (before the monitoring gain) to a
//! lock-free ring, and a utility thread that measures it into the [`AudioMeterStore`] the meter panel reads.

use sq_audio_out::output::Renderer;
use sq_audiofx::channel_monitor::ChannelMonitor;
use sq_audiofx::monitor_gain::MonitorSetting;
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use sq_playback::audio::{AudioMeterStore, ChannelMonitorStage, MeterDrain, MeterTap, MeterThread, MonitorGainStage};

use std::sync::Arc;
use std::sync::atomic::{AtomicU8, AtomicU32, Ordering};

/// The listening level, Dim, Solo and Mute the meter panel sets, read by the render thread once per block (any thread may
/// write). Swift: `MonitorGainStage` / `ChannelMonitorStage` held by the output.
#[derive(Debug)]
pub struct MonitorControl {
    gain: AtomicU32,
    mute: AtomicU8,
    solo: AtomicU8,
}

impl MonitorControl {
    fn new() -> MonitorControl {
        MonitorControl { gain: AtomicU32::new(1.0f32.to_bits()), mute: AtomicU8::new(0), solo: AtomicU8::new(0) }
    }
    pub fn set_gain(&self, s: &MonitorSetting) {
        self.gain.store(s.linear().max(0.0).to_bits(), Ordering::Release);
    }
    pub fn set_channels(&self, m: ChannelMonitor) {
        self.mute.store(m.mute_mask(), Ordering::Release);
        self.solo.store(m.solo_mask(), Ordering::Release);
    }
}

/// Wraps the mixer: renders through `inner`, then pushes the left and right channel to the meter ring.
pub struct MeteringRenderer {
    inner: Box<dyn Renderer>,
    tap: MeterTap,
    left: Vec<f32>,
    right: Vec<f32>,
    control: Arc<MonitorControl>,
    gain: MonitorGainStage,
    channels: ChannelMonitorStage,
}

impl MeteringRenderer {
    /// The wrapper, the store the panel reads and the running measuring thread (keep it alive with the output).
    pub fn new(inner: Box<dyn Renderer>) -> (MeteringRenderer, Arc<AudioMeterStore>, MeterThread, Arc<MonitorControl>) {
        let store = Arc::new(AudioMeterStore::new());
        let (tap, drain) = MeterDrain::new(Arc::clone(&store));
        let control = Arc::new(MonitorControl::new());
        let renderer = MeteringRenderer {
            inner,
            tap,
            left: Vec::new(),
            right: Vec::new(),
            control: Arc::clone(&control),
            gain: MonitorGainStage::default(),
            channels: ChannelMonitorStage::new(),
        };
        (renderer, store, drain.start(), control)
    }
}

impl Renderer for MeteringRenderer {
    fn render(&mut self, out: &mut [f32]) {
        self.inner.render(out);
        let frames = out.len() / 2;
        self.left.resize(frames, 0.0);
        self.right.resize(frames, 0.0);
        for (i, f) in out.as_chunks::<2>().0.iter().enumerate() {
            self.left[i] = f[0];
            self.right[i] = f[1];
        }
        self.tap.push(&self.left, &self.right);
        // After the meter: speakers only, the meter and loudness never move with them (as in Swift).
        self.gain.set_linear(f32::from_bits(self.control.gain.load(Ordering::Acquire)));
        self.channels.set(ChannelMonitor::with_masks(
            self.control.mute.load(Ordering::Acquire),
            self.control.solo.load(Ordering::Acquire),
        ));
        self.gain.process(&mut self.left, &mut self.right);
        self.channels.process(&mut self.left, &mut self.right);
        for (i, f) in out.as_chunks_mut::<2>().0.iter_mut().enumerate() {
            f[0] = self.left[i];
            f[1] = self.right[i];
        }
    }
    fn flush(&mut self, anchor: Time, rate: PlaybackRate) {
        self.inner.flush(anchor, rate);
    }
    fn latency_frames(&self) -> u32 {
        self.inner.latency_frames()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Steady(f32, f32);
    impl Renderer for Steady {
        fn render(&mut self, out: &mut [f32]) {
            for f in out.as_chunks_mut::<2>().0 {
                f[0] = self.0;
                f[1] = self.1;
            }
        }
        fn flush(&mut self, _: Time, _: PlaybackRate) {}
    }

    #[test]
    fn the_store_sees_the_peaks_of_the_mixed_blocks() {
        let (mut r, store, mut thread, _) = MeteringRenderer::new(Box::new(Steady(0.5, 0.25)));
        let mut block = vec![0.0f32; 2048];
        for _ in 0..4 {
            r.render(&mut block);
        }
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while store.snapshot().sequence == 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        thread.stop();
        let s = store.snapshot();
        assert!(s.sequence > 0);
        assert!((s.left.peak - 0.5).abs() < 1e-6 && (s.right.peak - 0.25).abs() < 1e-6);
        assert_eq!(block[..2], [0.5, 0.25], "the block passes through unchanged");
    }

    /// Renders two blocks (the first ramps) and returns the second, which holds the target.
    fn settled(r: &mut MeteringRenderer) -> Vec<f32> {
        let mut block = vec![0.0f32; 512];
        r.render(&mut block);
        r.render(&mut block);
        block
    }

    fn db(a: f32, b: f32) -> f32 {
        20.0 * (a / b).log10()
    }

    #[test]
    fn dim_and_the_listening_level_change_the_output_by_the_expected_db_but_not_the_meter() {
        let (mut r, store, mut thread, control) = MeteringRenderer::new(Box::new(Steady(0.5, 0.5)));
        let flat = settled(&mut r);
        control.set_gain(&MonitorSetting { level_db: -6.0, dim: false });
        let level = settled(&mut r);
        assert!((db(level[0], flat[0]) + 6.0).abs() < 0.01, "level moved by {} dB", db(level[0], flat[0]));
        control.set_gain(&MonitorSetting { level_db: -6.0, dim: true });
        let dim = settled(&mut r);
        assert!((db(dim[0], level[0]) + 20.0).abs() < 0.01, "Dim moved by {} dB", db(dim[0], level[0]));
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while store.snapshot().sequence == 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        thread.stop();
        assert!((store.snapshot().left.peak - 0.5).abs() < 1e-6, "the meter stays on the unattenuated mix");
    }

    #[test]
    fn mute_and_solo_silence_the_other_channel_only() {
        let (mut r, _store, mut thread, control) = MeteringRenderer::new(Box::new(Steady(0.5, 0.25)));
        let mut m = ChannelMonitor::new();
        m.toggle_mute(&[0]);
        control.set_channels(m);
        let out = settled(&mut r);
        assert_eq!(out[0], 0.0, "left muted");
        assert_eq!(out[1], 0.25, "right untouched");
        let mut s = ChannelMonitor::new();
        s.toggle_solo(&[0]);
        control.set_channels(s);
        let out = settled(&mut r);
        assert_eq!((out[0], out[1]), (0.5, 0.0), "solo left silences right");
        thread.stop();
    }
}
