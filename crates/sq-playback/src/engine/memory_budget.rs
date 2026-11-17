// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SQPlayback/MemoryBudget.swift (the budget half; the pressure policy is in power_policy.rs)
//! Memory caps scaled to the machine's physical RAM. Pure: the RAM size is injected, so tests and the bench simulate an
//! 8 GB laptop on any machine (`SQ_RAM_GB=8`).
//!
//! Frame cache: ONE budget for both monitors together (Program 3/4, Source 1/4). 8 GB and smaller: 1/6 of RAM; larger: 1/4,
//! at most 8 GB. Auto preview quality is half on low-memory machines, full elsewhere.

use sq_core_project::work_limits::MachineResources;
use sq_media::video_decoding::DecodeScale;

pub const GIB: u64 = 1 << 30;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MemoryBudget {
    pub physical_memory: u64,
}

/// The monitor whose engine plays (only one plays at a time: starting one stops the other).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Monitor {
    Program,
    Source,
}

impl MemoryBudget {
    pub fn new(physical_memory: u64) -> MemoryBudget {
        MemoryBudget { physical_memory }
    }

    /// This machine, or a smaller one simulated with `SQ_RAM_GB` (never larger than the real RAM).
    pub fn current(environment: impl Fn(&str) -> Option<String>, physical_memory: u64) -> MemoryBudget {
        if let Some(v) = environment("SQ_RAM_GB").and_then(|s| s.parse::<f64>().ok())
            && v.is_finite()
            && v > 0.0
        {
            return MemoryBudget::new(physical_memory.min((v * GIB as f64) as u64));
        }
        MemoryBudget::new(physical_memory)
    }

    /// 8 GB or less.
    pub fn is_low_memory(&self) -> bool {
        self.physical_memory <= 8 * GIB
    }

    fn limits(&self) -> sq_core_project::work_limits::WorkLimits {
        MachineResources::new(self.physical_memory, 8, false).limits()
    }

    /// Frame cache of both monitors together when the setting is Auto.
    pub fn auto_frame_cache_bytes(&self) -> usize {
        usize::try_from(self.limits().frame_cache_bytes).unwrap_or(0)
    }

    /// Largest frame cache a user may choose: half the RAM.
    pub fn max_frame_cache_bytes(&self) -> usize {
        usize::try_from(self.physical_memory / 2).unwrap_or(usize::MAX)
    }

    /// The frame cache in force: `None` or 0 = Auto; otherwise the choice, at most half the RAM.
    pub fn frame_cache_bytes(&self, user_gb: Option<u64>) -> usize {
        match user_gb {
            Some(g) if g > 0 => {
                usize::try_from(g.saturating_mul(GIB)).unwrap_or(usize::MAX).min(self.max_frame_cache_bytes())
            }
            _ => self.auto_frame_cache_bytes(),
        }
    }

    /// Fixed sizes offered next to Auto: powers of two from 1 GB up to half the RAM.
    pub fn cache_choices_gb(&self) -> Vec<u64> {
        let max = self.physical_memory / 2;
        let mut out = Vec::new();
        let mut g = 1u64;
        while g * GIB <= max {
            out.push(g);
            g *= 2;
        }
        out
    }

    /// Program monitor 3/4, Source monitor the rest.
    pub fn split(total: usize) -> (usize, usize) {
        let p = total / 4 * 3;
        (p, total - p)
    }

    /// 8 GB and smaller: the playing monitor gets the 3/4 (a 1/4 Source cache dropped 103 of 1574 frames of a 4K 10-bit
    /// 4:2:2 long-GOP clip at half quality). Larger machines keep the fixed 3:1.
    pub fn follows_playing_monitor(&self) -> bool {
        self.is_low_memory()
    }

    pub fn split_playing(&self, total: usize, playing: Monitor) -> (usize, usize) {
        let (program, source) = Self::split(total);
        if self.follows_playing_monitor() && playing == Monitor::Source { (source, program) } else { (program, source) }
    }

    /// Byte cap of the compositor's free intermediate textures.
    pub fn intermediate_pool_bytes(&self) -> usize {
        usize::try_from(self.limits().intermediate_pool_bytes).unwrap_or(0)
    }

    /// Decoder sessions kept for media not needed right now: 1 on low-memory machines, 2 elsewhere.
    pub fn idle_decoders(&self) -> usize {
        if self.is_low_memory() { 1 } else { 2 }
    }

    /// Viewer decode size when the preview quality setting is Auto.
    pub fn auto_preview_quality(&self) -> DecodeScale {
        if self.is_low_memory() { DecodeScale::Half } else { DecodeScale::Full }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GB: u64 = GIB;

    #[test]
    fn eight_gigabyte_machine_is_low_memory() {
        assert!(MemoryBudget::new(8 * GB).is_low_memory());
        assert!(!MemoryBudget::new(16 * GB).is_low_memory());
    }

    #[test]
    fn auto_frame_cache_scales_with_ram() {
        assert_eq!(MemoryBudget::new(8 * GB).auto_frame_cache_bytes(), (8 * GB / 6) as usize);
        assert_eq!(MemoryBudget::new(16 * GB).auto_frame_cache_bytes(), (4 * GB) as usize);
        assert_eq!(MemoryBudget::new(32 * GB).auto_frame_cache_bytes(), (8 * GB) as usize);
        assert_eq!(MemoryBudget::new(128 * GB).auto_frame_cache_bytes(), (8 * GB) as usize);
    }

    #[test]
    fn user_choice_is_clamped_to_half_of_ram() {
        let b = MemoryBudget::new(8 * GB);
        assert_eq!(b.frame_cache_bytes(Some(0)), b.auto_frame_cache_bytes());
        assert_eq!(b.frame_cache_bytes(None), b.auto_frame_cache_bytes());
        assert_eq!(b.frame_cache_bytes(Some(2)), (2 * GB) as usize);
        assert_eq!(b.frame_cache_bytes(Some(16)), (4 * GB) as usize);
        assert_eq!(b.cache_choices_gb(), vec![1, 2, 4]);
        assert_eq!(MemoryBudget::new(32 * GB).cache_choices_gb(), vec![1, 2, 4, 8, 16]);
    }

    #[test]
    fn program_gets_three_quarters_source_the_rest() {
        assert_eq!(MemoryBudget::split(1000), (750, 250));
    }

    #[test]
    fn playing_monitor_gets_the_large_share_on_low_memory_machines() {
        let air = MemoryBudget::new(8 * GB);
        assert!(air.follows_playing_monitor());
        assert_eq!(air.split_playing(1000, Monitor::Source), (250, 750));
        assert_eq!(air.split_playing(1000, Monitor::Program), MemoryBudget::split(1000));
        let pro = MemoryBudget::new(32 * GB);
        assert!(!pro.follows_playing_monitor());
        assert_eq!(pro.split_playing(1000, Monitor::Source), MemoryBudget::split(1000));
    }

    #[test]
    fn intermediate_pool_scales_with_ram() {
        assert_eq!(MemoryBudget::new(8 * GB).intermediate_pool_bytes(), 256 << 20);
        assert_eq!(MemoryBudget::new(16 * GB).intermediate_pool_bytes(), 512 << 20);
        assert_eq!(MemoryBudget::new(64 * GB).intermediate_pool_bytes(), 1 << 30);
        assert_eq!(MemoryBudget::new(GB).intermediate_pool_bytes(), 128 << 20);
    }

    #[test]
    fn idle_decoders_and_preview_quality() {
        assert_eq!(MemoryBudget::new(8 * GB).idle_decoders(), 1);
        assert_eq!(MemoryBudget::new(4 * GB).idle_decoders(), 1);
        assert_eq!(MemoryBudget::new(16 * GB).idle_decoders(), 2);
        assert_eq!(MemoryBudget::new(8 * GB).auto_preview_quality(), DecodeScale::Half);
        assert_eq!(MemoryBudget::new(16 * GB).auto_preview_quality(), DecodeScale::Full);
    }

    #[test]
    fn environment_simulates_a_smaller_machine() {
        let env = |v: &'static str| move |k: &str| (k == "SQ_RAM_GB").then(|| v.to_string());
        assert_eq!(MemoryBudget::current(env("8"), 64 * GB).physical_memory, 8 * GB);
        assert_eq!(MemoryBudget::current(env("x"), 64 * GB).physical_memory, 64 * GB);
        assert_eq!(MemoryBudget::current(env("128"), 16 * GB).physical_memory, 16 * GB);
        assert_eq!(MemoryBudget::current(|_| None, 16 * GB).physical_memory, 16 * GB);
    }
}
