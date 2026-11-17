//! Port of `SQAudioFX/Sources/SQAudioFX/DeClick.swift`.

use std::sync::{Arc, Mutex};

/// Read access to the on/off setting (Swift reads `UserDefaults`); the app shell supplies the real store.
pub trait BoolDefaults: Send + Sync {
    /// The stored boolean for `key`, or None when absent.
    fn bool_for(&self, key: &str) -> Option<bool>;
}

/// Automatic de-click fades: a few milliseconds of linear gain ramp at every audio clip boundary (head from silence,
/// tail to silence), so a hard cut never jumps in the waveform. A pure per-sample function of the absolute frame, so any
/// split of the timeline into render blocks gives identical samples (playback, scrub and export share it).
pub enum AudioDeClick {}

impl AudioDeClick {
    /// Settings key of the on/off setting (default on).
    pub const DEFAULTS_KEY: &'static str = "sq.audio.autoDeClick";
    pub const FADE_MILLISECONDS: f64 = 3.0;

    /// The setting read from `defaults`; absent means on.
    pub fn is_enabled_in(defaults: &dyn BoolDefaults) -> bool {
        defaults.bool_for(Self::DEFAULTS_KEY).unwrap_or(true)
    }

    /// Fade length in frames at `sample_rate`, or 0 when the setting is off. Playback and export both take it from here.
    pub fn current_fade_frames(sample_rate: i64, defaults: &dyn BoolDefaults) -> i64 {
        if Self::is_enabled_in(defaults) { Self::fade_frames(sample_rate) } else { 0 }
    }

    pub fn fade_frames(sample_rate: i64) -> i64 {
        ((Self::FADE_MILLISECONDS / 1000.0 * sample_rate as f64).round() as i64).max(1)
    }

    /// Effective fade of a segment `[start, end)`: shrinks to half the segment for very short ones.
    pub(crate) fn effective_fade(fade: i64, start: i64, end: i64) -> i64 {
        fade.min(((end - start) / 2).max(1))
    }

    /// Gain at absolute `frame` of a segment covering `[start, end)`.
    pub fn edge_gain(frame: i64, start: i64, end: i64, fade: i64) -> f32 {
        if fade <= 0 {
            return 1.0;
        }
        let f = Self::effective_fade(fade, start, end);
        let k = (frame - start).min(end - 1 - frame);
        if k >= f { 1.0 } else { k.max(0) as f32 / f as f32 }
    }

    /// Multiplies `samples` (frames `first_frame..<first_frame+samples.len()` of the segment `[start, end)`) by the edge gain.
    pub fn apply(samples: &mut [f32], first_frame: i64, start: i64, end: i64, fade: i64) {
        let count = samples.len();
        if fade <= 0 || count == 0 {
            return;
        }
        let f = Self::effective_fade(fade, start, end);
        let head_end = (start + f - first_frame).min(count as i64).max(0); // block indices < head_end are in the head fade
        let tail_begin = (end - f - first_frame).max(0).min(count as i64); // indices >= tail_begin are in the tail fade
        for (i, s) in samples.iter_mut().enumerate().take(head_end as usize) {
            *s *= Self::edge_gain(first_frame + i as i64, start, end, fade);
        }
        for (i, s) in samples.iter_mut().enumerate().skip(tail_begin.max(head_end) as usize) {
            *s *= Self::edge_gain(first_frame + i as i64, start, end, fade);
        }
    }
}

/// Re-reads the de-click setting when `refresh` is called (the shell calls it whenever the defaults change) and reports the
/// new fade length, so playback follows the Preferences toggle live (no restart). `on_change` fires only when the value
/// actually changed; keep it to an atomic store.
pub struct AudioDeClickObserver {
    defaults: Arc<dyn BoolDefaults>,
    sample_rate: i64,
    on_change: Box<dyn Fn(i64) + Send + Sync>,
    last: Mutex<i64>,
}

impl AudioDeClickObserver {
    pub fn new(defaults: Arc<dyn BoolDefaults>, sample_rate: i64, on_change: Box<dyn Fn(i64) + Send + Sync>) -> Self {
        let last = Mutex::new(AudioDeClick::current_fade_frames(sample_rate, defaults.as_ref()));
        AudioDeClickObserver { defaults, sample_rate, on_change, last }
    }

    /// Applies the current value if it differs from the last reported one.
    pub fn refresh(&self) {
        let now = AudioDeClick::current_fade_frames(self.sample_rate, self.defaults.as_ref());
        let changed = {
            let Ok(mut old) = self.last.lock() else { return };
            let changed = *old != now;
            *old = now;
            changed
        };
        if changed {
            (self.on_change)(now);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct MemoryDefaults(Mutex<HashMap<String, bool>>);

    impl MemoryDefaults {
        fn set(&self, key: &str, v: bool) {
            if let Ok(mut m) = self.0.lock() {
                m.insert(key.to_string(), v);
            }
        }
    }

    impl BoolDefaults for MemoryDefaults {
        fn bool_for(&self, key: &str) -> Option<bool> {
            self.0.lock().ok().and_then(|m| m.get(key).copied())
        }
    }

    #[test]
    fn fade_length_is_about_three_milliseconds() {
        assert_eq!(AudioDeClick::fade_frames(48_000), 144);
    }

    #[test]
    fn setting_toggle_controls_frames() {
        let d = MemoryDefaults::default();
        assert_eq!(AudioDeClick::current_fade_frames(48_000, &d), 144); // default on
        d.set(AudioDeClick::DEFAULTS_KEY, false);
        assert_eq!(AudioDeClick::current_fade_frames(48_000, &d), 0);
        d.set(AudioDeClick::DEFAULTS_KEY, true);
        assert_eq!(AudioDeClick::current_fade_frames(48_000, &d), 144);
    }

    #[test]
    fn observer_reports_live_changes_only_when_value_changes() {
        let d = Arc::new(MemoryDefaults::default());
        let seen = Arc::new(Mutex::new(Vec::<i64>::new()));
        let sink = Arc::clone(&seen);
        let obs = AudioDeClickObserver::new(
            Arc::clone(&d) as Arc<dyn BoolDefaults>,
            48_000,
            Box::new(move |n| {
                if let Ok(mut s) = sink.lock() {
                    s.push(n);
                }
            }),
        );
        d.set(AudioDeClick::DEFAULTS_KEY, false);
        obs.refresh();
        d.set(AudioDeClick::DEFAULTS_KEY, false); // no change, no callback
        obs.refresh();
        d.set(AudioDeClick::DEFAULTS_KEY, true);
        obs.refresh();
        assert_eq!(seen.lock().map(|s| s.clone()).unwrap_or_default(), vec![0, 144]);
        assert_eq!(AudioDeClick::current_fade_frames(48_000, d.as_ref()), 144);
    }

    #[test]
    fn edges_ramp_from_and_to_silence_interior_untouched() {
        let g: Vec<f32> = (0..1000).map(|i| AudioDeClick::edge_gain(500 + i, 500, 1500, 100)).collect();
        assert!(g[0] == 0.0 && g[999] == 0.0);
        assert!(g[100] == 1.0 && g[899] == 1.0 && g[500] == 1.0);
        assert_eq!(g[50], 0.5);
        for i in 0..99 {
            assert!(g[i + 1] > g[i]);
        }
    }

    #[test]
    fn short_segments_fade_inside_themselves() {
        let g: Vec<f32> = (0..10).map(|i| AudioDeClick::edge_gain(i, 0, 10, 144)).collect();
        assert!(g[0] == 0.0 && g[9] == 0.0);
        assert!(g.iter().all(|&v| v <= 1.0));
    }

    #[test]
    fn zero_fade_is_identity_and_apply_matches_gain() {
        assert_eq!(AudioDeClick::edge_gain(0, 0, 10, 0), 1.0);
        let mut a = vec![1.0_f32; 600];
        AudioDeClick::apply(&mut a[..300], 650, 600, 1200, 144);
        for (i, v) in a.iter().enumerate().take(300) {
            assert_eq!(*v, AudioDeClick::edge_gain(650 + i as i64, 600, 1200, 144));
        }
        assert_eq!(a[300], 1.0);
    }

    #[test]
    fn block_split_gives_identical_samples() {
        let mut whole = vec![1.0_f32; 1000];
        AudioDeClick::apply(&mut whole, 0, 0, 1000, 144);
        let mut parts = vec![1.0_f32; 1000];
        for s in (0..1000).step_by(77) {
            let e = (s + 77).min(1000);
            AudioDeClick::apply(&mut parts[s..e], s as i64, 0, 1000, 144);
        }
        assert_eq!(whole, parts);
        assert!(whole[0] == 0.0 && whole[999] == 0.0 && whole[500] == 1.0);
    }
}
