// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PlaybackEngine.swift:35 (powerPolicy), MemoryBudget.swift:99 (PowerPolicy.combined), MemoryPressureRegistry
//! Brings the system load (thermal state, Low Power Mode, memory pressure) to the session and to the caches: the power
//! monitor's policy and the shared registry's level are read once a turn; the Preferences switches (Auto preview quality,
//! Background Work) are read again when the load changed or a second has passed.

use sq_playback::engine::power_policy::{MemoryPressure, PowerPolicy};
use sq_playback::engine::system_watch::{shared_memory_pressure, system_power};
use sq_uikit::waveform_drawing::MemoryPressure as CacheLevel;
use std::time::{Duration, Instant};

/// How often the switches are read when the load stays the same.
const RECHECK: Duration = Duration::from_secs(1);

/// What a turn found: the combined policy for the monitors and the level for the caches.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Load {
    pub policy: PowerPolicy,
    pub level: CacheLevel,
}

#[derive(Default)]
pub struct LoadWatch {
    seen: Option<(PowerPolicy, MemoryPressure)>,
    checked: Option<Instant>,
    applied: Option<Load>,
}

/// The cache level of an engine level (the same three levels, two enums for the crate layering).
pub fn cache_level(level: MemoryPressure) -> CacheLevel {
    match level {
        MemoryPressure::Normal => CacheLevel::Normal,
        MemoryPressure::Warning => CacheLevel::Warning,
        MemoryPressure::Critical => CacheLevel::Critical,
    }
}

impl LoadWatch {
    /// The load to apply now, or `None` when nothing changed. `switches` gives (Auto preview quality, Background Work),
    /// read only when the load changed or a second has passed.
    pub fn poll(
        &mut self,
        now: Instant,
        power: PowerPolicy,
        level: MemoryPressure,
        switches: impl FnOnce() -> (bool, bool),
    ) -> Option<Load> {
        let same = self.seen == Some((power, level));
        let fresh = self.checked.is_some_and(|c| now.duration_since(c) < RECHECK);
        if same && fresh {
            return None;
        }
        self.seen = Some((power, level));
        self.checked = Some(now);
        let (auto_quality, background_work) = switches();
        let load = Load {
            policy: PowerPolicy::combined(power, level, auto_quality, background_work),
            level: cache_level(level),
        };
        if self.applied == Some(load) {
            return None;
        }
        self.applied = Some(load);
        Some(load)
    }

    /// `poll` over the process-wide sources.
    pub fn poll_system(&mut self, switches: impl FnOnce() -> (bool, bool)) -> Option<Load> {
        self.poll(Instant::now(), system_power(), shared_memory_pressure().level(), switches)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn warning_pressure_halves_the_viewer_and_pauses_background_work_once() {
        let mut w = LoadWatch::default();
        let t0 = Instant::now();
        let first =
            w.poll(t0, PowerPolicy::NORMAL, MemoryPressure::Normal, || (true, true)).expect("first turn applies");
        assert_eq!(first.policy, PowerPolicy::NORMAL);
        assert!(w.poll(t0, PowerPolicy::NORMAL, MemoryPressure::Normal, || panic!("not read again")).is_none());
        let warn = w.poll(t0, PowerPolicy::NORMAL, MemoryPressure::Warning, || (true, true)).expect("level changed");
        assert!(warn.policy.pauses_background_jobs && warn.policy.halves_prefetch);
        assert_eq!(warn.policy.decode_scale_cap, sq_media::video_decoding::DecodeScale::Half);
        assert_eq!(warn.level, CacheLevel::Warning);
        assert!(w.poll(t0, PowerPolicy::NORMAL, MemoryPressure::Warning, || panic!("not read again")).is_none());
    }

    #[test]
    fn the_switches_are_read_again_after_a_second() {
        let mut w = LoadWatch::default();
        let t0 = Instant::now();
        assert!(w.poll(t0, PowerPolicy::NORMAL, MemoryPressure::Normal, || (true, true)).is_some());
        let off =
            w.poll(t0 + Duration::from_millis(1100), PowerPolicy::NORMAL, MemoryPressure::Normal, || (true, false));
        assert!(off.expect("Background Work off").policy.pauses_background_jobs);
    }

    #[test]
    fn a_fixed_quality_keeps_the_size_under_pressure() {
        let mut w = LoadWatch::default();
        let l =
            w.poll(Instant::now(), PowerPolicy::NORMAL, MemoryPressure::Critical, || (false, true)).expect("applies");
        assert_eq!(l.policy.decode_scale_cap, sq_media::video_decoding::DecodeScale::Full);
        assert!(l.policy.pauses_background_jobs);
    }
}
