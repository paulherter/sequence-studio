// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SQPlayback/PowerPolicy.swift, the policy half of MemoryBudget.swift
//! What the monitors and background work give up under thermal pressure, Low Power Mode or memory pressure. Pure.
//! The OS watchers are `system_watch` (`PowerMonitor`, `MemoryPressureRegistry`); the platform shell feeds them and hands the
//! policy to the engine, which reads only the policy's decode cap.
//! shortcut: the prefetch planner hook (`halves_prefetch`) is read by no planner yet.

use sq_media::video_decoding::DecodeScale;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ThermalLevel {
    Nominal,
    Fair,
    Serious,
    Critical,
}

impl ThermalLevel {
    /// `SQ_THERMAL=nominal|fair|serious|critical` forces a level (try the throttled behavior on a cool machine).
    pub fn from_environment(value: Option<&str>) -> Option<ThermalLevel> {
        match value?.to_lowercase().as_str() {
            "nominal" => Some(ThermalLevel::Nominal),
            "fair" => Some(ThermalLevel::Fair),
            "serious" => Some(ThermalLevel::Serious),
            "critical" => Some(ThermalLevel::Critical),
            _ => None,
        }
    }
}

/// System memory-pressure level (same three levels as the UI side's cache budgets).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum MemoryPressure {
    Normal,
    Warning,
    Critical,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PowerPolicy {
    pub pauses_background_jobs: bool,
    /// Largest viewer decode size (`Full` = no cap).
    pub decode_scale_cap: DecodeScale,
    pub halves_prefetch: bool,
}

fn rank(s: DecodeScale) -> u8 {
    match s {
        DecodeScale::Full => 0,
        DecodeScale::Half => 1,
        DecodeScale::Quarter => 2,
    }
}

impl PowerPolicy {
    pub const NORMAL: PowerPolicy =
        PowerPolicy { pauses_background_jobs: false, decode_scale_cap: DecodeScale::Full, halves_prefetch: false };

    /// fair or Low Power: background jobs start nothing new; serious / critical: also viewer at most half size and half
    /// the prefetch look-ahead.
    pub fn new(thermal: ThermalLevel, low_power: bool) -> PowerPolicy {
        let hot = thermal >= ThermalLevel::Serious;
        PowerPolicy {
            pauses_background_jobs: hot || thermal == ThermalLevel::Fair || low_power,
            decode_scale_cap: if hot { DecodeScale::Half } else { DecodeScale::Full },
            halves_prefetch: hot,
        }
    }

    /// The decode size the viewer uses for the user's choice: never larger than the cap, never larger than the choice.
    pub fn viewer_scale(&self, user: DecodeScale) -> DecodeScale {
        if rank(user) >= rank(self.decode_scale_cap) { user } else { self.decode_scale_cap }
    }

    /// While the system reports memory pressure: warning = viewer at most half size, half the prefetch look-ahead, no new
    /// background jobs; critical = quarter size. Never raises a cap that is already lower.
    pub fn under_memory_pressure(&self, level: MemoryPressure) -> PowerPolicy {
        let cap = match level {
            MemoryPressure::Normal => return *self,
            MemoryPressure::Warning => DecodeScale::Half,
            MemoryPressure::Critical => DecodeScale::Quarter,
        };
        PowerPolicy { pauses_background_jobs: true, decode_scale_cap: self.viewer_scale(cap), halves_prefetch: true }
    }

    /// What the monitors run with. With Auto preview quality pressure lowers the picture size; with a fixed quality it only
    /// pauses background work.
    pub fn combined(
        power: PowerPolicy,
        memory: MemoryPressure,
        auto_quality: bool,
        background_work: bool,
    ) -> PowerPolicy {
        let p = power.with_background_work(background_work);
        if auto_quality {
            return p.under_memory_pressure(memory);
        }
        if memory == MemoryPressure::Normal { p } else { p.with_background_work(false) }
    }

    /// Settings > Playback "Background Work" off: background jobs start nothing new.
    pub fn with_background_work(&self, on: bool) -> PowerPolicy {
        if on { *self } else { PowerPolicy { pauses_background_jobs: true, ..*self } }
    }
}

/// The look-ahead distances (seconds) of the prefetch; halved when `PowerPolicy::halves_prefetch` (Swift
/// `PowerPolicy.planner`: lookahead x 1/2).
pub(crate) fn prefetch_seconds(halved: bool) -> [f64; 5] {
    let base = [0.5, 1.0, 1.5, 2.5, 3.5];
    if halved { base.map(|s| s / 2.0) } else { base }
}

/// Where the paused warm-up looks for titles (seconds after the playhead): the first second of a play, in the pre-roll's reach.
/// How far ahead of a resting playhead the paused warm-up opens the lanes of clips that cut in (the prefetch looks 3.5 s ahead
/// once playing; the first seconds of a play are warmed before Play).
pub(crate) const START_CUT_SECONDS: [f64; 4] = [0.5, 1.0, 2.0, 3.0];

pub(crate) const START_WARM_SECONDS: [f64; 5] = [0.25, 0.5, 0.75, 1.0, 1.5];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_halved_prefetch_looks_half_as_far() {
        assert_eq!(prefetch_seconds(false), [0.5, 1.0, 1.5, 2.5, 3.5]);
        assert_eq!(prefetch_seconds(true), [0.25, 0.5, 0.75, 1.25, 1.75]);
    }

    #[test]
    fn nominal_is_normal() {
        assert_eq!(PowerPolicy::new(ThermalLevel::Nominal, false), PowerPolicy::NORMAL);
    }

    #[test]
    fn fair_and_low_power_pause_background_jobs_only() {
        let p = PowerPolicy::new(ThermalLevel::Fair, false);
        assert!(p.pauses_background_jobs && p.decode_scale_cap == DecodeScale::Full && !p.halves_prefetch);
        assert_eq!(PowerPolicy::new(ThermalLevel::Nominal, true), p);
    }

    #[test]
    fn serious_halves_decode_and_prefetch() {
        let p = PowerPolicy::new(ThermalLevel::Serious, false);
        assert!(p.pauses_background_jobs && p.decode_scale_cap == DecodeScale::Half && p.halves_prefetch);
        assert_eq!(PowerPolicy::new(ThermalLevel::Critical, true), p);
    }

    #[test]
    fn viewer_scale_never_raises_the_users_choice() {
        let serious = PowerPolicy::new(ThermalLevel::Serious, false);
        assert_eq!(serious.viewer_scale(DecodeScale::Full), DecodeScale::Half);
        assert_eq!(serious.viewer_scale(DecodeScale::Half), DecodeScale::Half);
        assert_eq!(serious.viewer_scale(DecodeScale::Quarter), DecodeScale::Quarter);
        assert_eq!(PowerPolicy::NORMAL.viewer_scale(DecodeScale::Quarter), DecodeScale::Quarter);
    }

    #[test]
    fn environment_override() {
        assert_eq!(ThermalLevel::from_environment(Some("serious")), Some(ThermalLevel::Serious));
        assert_eq!(ThermalLevel::from_environment(Some("FAIR")), Some(ThermalLevel::Fair));
        assert_eq!(ThermalLevel::from_environment(Some("bogus")), None);
        assert_eq!(ThermalLevel::from_environment(None), None);
    }

    #[test]
    fn memory_pressure_policy() {
        assert_eq!(PowerPolicy::NORMAL.under_memory_pressure(MemoryPressure::Normal), PowerPolicy::NORMAL);
        let w = PowerPolicy::NORMAL.under_memory_pressure(MemoryPressure::Warning);
        assert!(w.decode_scale_cap == DecodeScale::Half && w.halves_prefetch && w.pauses_background_jobs);
        assert_eq!(w.viewer_scale(DecodeScale::Quarter), DecodeScale::Quarter);
        let c = PowerPolicy::NORMAL.under_memory_pressure(MemoryPressure::Critical);
        assert_eq!(c.viewer_scale(DecodeScale::Half), DecodeScale::Quarter);
        let hot =
            PowerPolicy { pauses_background_jobs: true, decode_scale_cap: DecodeScale::Quarter, halves_prefetch: true };
        assert_eq!(hot.under_memory_pressure(MemoryPressure::Warning).decode_scale_cap, DecodeScale::Quarter);
    }

    #[test]
    fn combined_policy_follows_the_settings() {
        let auto = PowerPolicy::combined(PowerPolicy::NORMAL, MemoryPressure::Warning, true, true);
        assert!(auto.decode_scale_cap == DecodeScale::Half && auto.pauses_background_jobs);
        let fixed = PowerPolicy::combined(PowerPolicy::NORMAL, MemoryPressure::Critical, false, true);
        assert!(fixed.decode_scale_cap == DecodeScale::Full && fixed.pauses_background_jobs && !fixed.halves_prefetch);
        assert_eq!(PowerPolicy::combined(PowerPolicy::NORMAL, MemoryPressure::Normal, true, true), PowerPolicy::NORMAL);
        assert!(
            PowerPolicy::combined(PowerPolicy::NORMAL, MemoryPressure::Normal, false, false).pauses_background_jobs
        );
    }

    #[test]
    fn background_work_off_pauses_jobs_only() {
        let p = PowerPolicy::NORMAL.with_background_work(false);
        assert!(p.pauses_background_jobs && p.decode_scale_cap == DecodeScale::Full && !p.halves_prefetch);
        assert_eq!(PowerPolicy::NORMAL.with_background_work(true), PowerPolicy::NORMAL);
    }
}
