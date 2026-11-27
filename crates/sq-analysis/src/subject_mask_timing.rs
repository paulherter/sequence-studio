// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SubjectMaskTiming.swift
//! Where the time of a subject mask goes: `SQ_MASK_TIMING=1` logs, per run of the tracker and per model load, the wall time
//! and the stages counted in `SPENT`. The stages are counted always (a clock read per stage); only the log is switched.
use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::Instant;

/// Seconds and calls per part since the last `take_timings()` (the benchmark's per-part ms).
static SPENT: Mutex<BTreeMap<String, (f64, u64)>> = Mutex::new(BTreeMap::new());

fn spent() -> MutexGuard<'static, BTreeMap<String, (f64, u64)>> {
    SPENT.lock().unwrap_or_else(|e| e.into_inner())
}

/// Counting the stages of a subject mask.
pub struct SubjectMaskTiming;

impl SubjectMaskTiming {
    /// "name ms/call (xcalls)" per part, and clears them.
    pub fn take_timings() -> String {
        let all = std::mem::take(&mut *spent());
        all.iter()
            .map(|(name, (seconds, calls))| {
                format!("{name} {:.1} ms (x{calls})", seconds * 1000.0 / (*calls).max(1) as f64)
            })
            .collect::<Vec<_>>()
            .join(", ")
    }

    /// Adds the time since `began` (`now()` nanoseconds) to part `name`.
    pub fn count(name: &str, began: u64) {
        let took = Self::now().saturating_sub(began) as f64 / 1e9;
        let mut all = spent();
        let entry = all.entry(name.to_string()).or_insert((0.0, 0));
        entry.0 += took;
        entry.1 += 1;
    }

    /// Whether the log is switched on (`SQ_MASK_TIMING=1`).
    pub fn enabled() -> bool {
        static ON: OnceLock<bool> = OnceLock::new();
        *ON.get_or_init(|| std::env::var("SQ_MASK_TIMING").is_ok_and(|v| v == "1"))
    }

    /// `work`, counted under `name`.
    pub fn measure<T>(name: &str, work: impl FnOnce() -> T) -> T {
        let began = Self::now();
        let result = work();
        Self::count(name, began);
        result
    }

    /// Monotonic nanoseconds since the first call.
    pub fn now() -> u64 {
        static START: OnceLock<Instant> = OnceLock::new();
        u64::try_from(START.get_or_init(Instant::now).elapsed().as_nanos()).unwrap_or(u64::MAX)
    }

    /// Logs `what` with its wall time since `began` and the stages counted since the last log (and clears them).
    pub fn report(what: &str, began: u64, frames: Option<u64>) {
        if !Self::enabled() {
            return;
        }
        let wall = Self::now().saturating_sub(began) as f64 / 1e9;
        let per_frame = frames
            .map(|n| format!(", {n} frames, {:.1} ms/frame", wall * 1000.0 / n.max(1) as f64))
            .unwrap_or_default();
        sq_os::errln!("[SubjectMask] timing {what}: {wall:.2} s{per_frame}; {}", Self::take_timings());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stages_are_counted_per_part_and_cleared_when_taken() {
        let v = SubjectMaskTiming::measure("timing-test-part", || 5);
        assert_eq!(v, 5);
        SubjectMaskTiming::measure("timing-test-part", || ());
        let text = SubjectMaskTiming::take_timings();
        assert!(text.contains("timing-test-part") && text.contains("(x2)"), "{text}");
        assert!(!SubjectMaskTiming::take_timings().contains("timing-test-part"));
    }
}
