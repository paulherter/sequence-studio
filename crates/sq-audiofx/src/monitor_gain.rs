// Swift: MonitorGain.swift
//! Listening level of the timeline output (F7.5): a volume slider and a Dim switch. It is an app preference (`sq.monitor.*`),
//! not project data, and is applied only at the very end of the monitoring output (the engine's output mixer volume, after
//! the meter tap). Export and bounce never read it.

use std::collections::BTreeSet;
use std::sync::Mutex;

/// The user settings the monitor level lives in (Swift `UserDefaults`), injected: the app provides the real store.
pub trait MonitorDefaults {
    /// The stored number; `None` when the key is not set (or holds no number).
    fn number(&self, key: &str) -> Option<f64>;
    /// The stored switch; false when the key is not set.
    fn flag(&self, key: &str) -> bool;
    /// Stores a number.
    fn set_number(&mut self, key: &str, value: f64);
    /// Stores a switch.
    fn set_flag(&mut self, key: &str, value: bool);
    /// Identity of the underlying store, so the launch rules run once per store (Swift `ObjectIdentifier`).
    fn store_id(&self) -> usize;
}

/// Namespace of the monitor level rules.
pub enum MonitorGain {}

impl MonitorGain {
    /// Defaults key of the level.
    pub const LEVEL_KEY: &'static str = "sq.monitor.levelDB";
    /// Defaults key of the Dim switch.
    pub const DIM_KEY: &'static str = "sq.monitor.dim";
    /// Slider floor = mute.
    pub const MIN_DB: f64 = -60.0;
    /// Never boosts above the mix.
    pub const MAX_DB: f64 = 0.0;
    /// What Dim subtracts.
    pub const DIM_DB: f64 = -20.0;
    /// A level below this at launch resets to 0 dB: the app never starts silent with nothing on screen explaining it.
    pub const LAUNCH_FLOOR_DB: f64 = -40.0;

    /// Launch rules: Dim starts off; a stored level below `LAUNCH_FLOOR_DB` (or a non-finite one) goes back to 0 dB.
    pub fn apply_launch_rules(defaults: &mut dyn MonitorDefaults) {
        let mut s = MonitorSetting::current(defaults);
        let raw = defaults.number(Self::LEVEL_KEY);
        let quiet = raw.is_some_and(|r| !(r.is_finite() && r >= Self::LAUNCH_FLOOR_DB));
        if s.dim || quiet {
            if s.dim {
                s.dim = false;
            }
            if quiet {
                s.level_db = 0.0;
            }
            Self::store(&s, defaults);
        }
    }

    /// Runs the launch rules once per process for these defaults (every engine and every monitor strip may call it; only the
    /// first call acts), so opening a project or a second engine mid-session never turns Dim off.
    pub fn apply_launch_rules_once(defaults: &mut dyn MonitorDefaults) {
        static LAUNCHED: Mutex<BTreeSet<usize>> = Mutex::new(BTreeSet::new());
        let first = LAUNCHED.lock().unwrap_or_else(std::sync::PoisonError::into_inner).insert(defaults.store_id());
        if first {
            Self::apply_launch_rules(defaults);
        }
    }

    /// Writes the setting.
    pub fn store(s: &MonitorSetting, defaults: &mut dyn MonitorDefaults) {
        defaults.set_number(Self::LEVEL_KEY, s.level_db);
        defaults.set_flag(Self::DIM_KEY, s.dim);
    }
}

/// The monitor level (dB) and the Dim switch.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MonitorSetting {
    /// Level in dB, `MIN_DB...MAX_DB`.
    pub level_db: f64,
    /// Dim switch.
    pub dim: bool,
}

impl Default for MonitorSetting {
    fn default() -> Self {
        MonitorSetting { level_db: 0.0, dim: false }
    }
}

impl MonitorSetting {
    /// Linear gain for the output mixer.
    pub fn linear(&self) -> f32 {
        let level =
            if self.level_db.is_finite() { self.level_db.clamp(MonitorGain::MIN_DB, MonitorGain::MAX_DB) } else { 0.0 };
        if level <= MonitorGain::MIN_DB {
            return 0.0;
        }
        let db = level + if self.dim { MonitorGain::DIM_DB } else { 0.0 };
        10.0_f64.powf(db / 20.0) as f32
    }

    /// The stored setting.
    pub fn current(defaults: &dyn MonitorDefaults) -> MonitorSetting {
        let raw = defaults.number(MonitorGain::LEVEL_KEY).unwrap_or(0.0);
        let level = if raw.is_finite() { raw.clamp(MonitorGain::MIN_DB, MonitorGain::MAX_DB) } else { 0.0 };
        MonitorSetting { level_db: level, dim: defaults.flag(MonitorGain::DIM_KEY) }
    }
}

/// Short gain ramp (about 30 ms in 6 steps) so a change never clicks. Stepped from a utility timer, not the render thread.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MonitorRamp {
    value: f32,
    target: f32,
    remaining: i64,
}

impl MonitorRamp {
    /// Steps from the old to the new gain.
    pub const STEPS: i64 = 6;
    /// Seconds between two steps.
    pub const STEP_SECONDS: f64 = 0.005;

    /// A ramp resting at `current`.
    pub fn new(current: f32) -> Self {
        MonitorRamp { value: current, target: current, remaining: 0 }
    }

    /// The gain now.
    pub fn value(&self) -> f32 {
        self.value
    }

    /// The gain the ramp runs to.
    pub fn target(&self) -> f32 {
        self.target
    }

    /// A new target restarts the ramp (Swift `didSet`).
    pub fn set_target(&mut self, target: f32) {
        if target != self.target {
            self.remaining = Self::STEPS;
        }
        self.target = target;
    }

    /// Next gain value, `None` once the target is reached.
    pub fn advance(&mut self) -> Option<f32> {
        if self.value == self.target {
            self.remaining = 0;
            return None;
        }
        self.remaining -= 1;
        if self.remaining <= 0 {
            self.value = self.target;
        } else {
            self.value += (self.target - self.value) / (self.remaining + 1) as f32;
        }
        Some(self.value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[derive(Default)]
    struct Store {
        numbers: BTreeMap<String, f64>,
        flags: BTreeMap<String, bool>,
    }

    impl MonitorDefaults for Store {
        fn number(&self, key: &str) -> Option<f64> {
            self.numbers.get(key).copied()
        }
        fn flag(&self, key: &str) -> bool {
            self.flags.get(key).copied().unwrap_or(false)
        }
        fn set_number(&mut self, key: &str, value: f64) {
            self.numbers.insert(key.to_string(), value);
        }
        fn set_flag(&mut self, key: &str, value: bool) {
            self.flags.insert(key.to_string(), value);
        }
        fn store_id(&self) -> usize {
            std::ptr::from_ref(self) as usize
        }
    }

    fn setting(level_db: f64, dim: bool) -> MonitorSetting {
        MonitorSetting { level_db, dim }
    }

    #[test]
    fn defaults_are_unity_and_not_dimmed() {
        let s = MonitorSetting::current(&Store::default());
        assert!(s.level_db == 0.0 && !s.dim);
        assert_eq!(s.linear(), 1.0);
    }

    #[test]
    fn gain_math_matches_decibels() {
        assert!((setting(-6.0, false).linear() - 0.501187).abs() < 1e-4);
        assert!((setting(0.0, true).linear() - 0.1).abs() < 1e-6);
        assert!((setting(-6.0, true).linear() - 0.0501187).abs() < 1e-5);
        assert_eq!(setting(MonitorGain::MIN_DB, false).linear(), 0.0);
        assert_eq!(setting(12.0, false).linear(), 1.0);
    }

    #[test]
    fn setting_round_trips_through_defaults() {
        let mut d = Store::default();
        MonitorGain::store(&setting(-12.0, true), &mut d);
        let s = MonitorSetting::current(&d);
        assert!(s.level_db == -12.0 && s.dim);
    }

    #[test]
    fn ramp_reaches_target_monotonically_without_big_steps() {
        let mut r = MonitorRamp::new(1.0);
        r.set_target(0.1);
        let mut prev = 1.0_f32;
        let mut steps = 0;
        while let Some(v) = r.advance() {
            assert!(v < prev);
            assert!(prev - v < 0.25);
            prev = v;
            steps += 1;
            if steps > 100 {
                break;
            }
        }
        assert!(prev == 0.1 && steps == MonitorRamp::STEPS);
    }

    #[test]
    fn non_finite_preference_falls_back_to_unity() {
        let mut d = Store::default();
        d.set_number(MonitorGain::LEVEL_KEY, f64::NAN);
        assert_eq!(MonitorSetting::current(&d).linear(), 1.0);
        assert_eq!(setting(f64::INFINITY, false).linear(), 1.0);
        assert_eq!(setting(f64::NEG_INFINITY, false).linear(), 1.0);
        MonitorGain::apply_launch_rules(&mut d);
        assert_eq!(MonitorSetting::current(&d).level_db, 0.0);
    }

    #[test]
    fn launch_rules_dim_off_and_quiet_level_resets() {
        let mut d = Store::default();
        MonitorGain::store(&setting(-25.0, true), &mut d);
        MonitorGain::apply_launch_rules(&mut d);
        let kept = MonitorSetting::current(&d);
        assert!(kept.level_db == -25.0 && !kept.dim); // level persists, Dim does not
        MonitorGain::store(&setting(-55.0, false), &mut d);
        MonitorGain::apply_launch_rules(&mut d);
        assert_eq!(MonitorSetting::current(&d).level_db, 0.0);
        MonitorGain::store(&setting(-40.0, false), &mut d);
        MonitorGain::apply_launch_rules(&mut d);
        assert_eq!(MonitorSetting::current(&d).level_db, -40.0);
    }
}
