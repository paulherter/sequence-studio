// Swift: WorkPools.swift (the `WorkLimits.pools` getter waits for the machine limits type)
//! The three worker pools of the engine and their caps: decode/prefetch, GPU render and CPU fallback. Each pool is
//! capped on its own, so a flood of one kind never starves another.

/// Caps of the three pools, each at least 1.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct WorkPools {
    /// Decode/prefetch jobs (media engine and hardware decoder sessions).
    pub decode: i64,
    /// Frames in flight on the GPU queue.
    pub gpu: i64,
    /// Software-path jobs (software decode, analysis).
    pub cpu: i64,
}

impl WorkPools {
    /// Settings key of the debug preference that logs the caps at launch.
    pub const DEBUG_DEFAULTS_KEY: &'static str = "sq.debug.workPools";

    /// Caps below 1 become 1.
    pub fn new(decode: i64, gpu: i64, cpu: i64) -> WorkPools {
        WorkPools { decode: decode.max(1), gpu: gpu.max(1), cpu: cpu.max(1) }
    }

    /// One line for the log: `work pools: decode 4, gpu 2, cpu 3`.
    pub fn summary(&self) -> String {
        format!("work pools: decode {}, gpu {}, cpu {}", self.decode, self.gpu, self.cpu)
    }

    /// The summary when the debug preference (`DEBUG_DEFAULTS_KEY`, read by the caller) is on, else `None`.
    pub fn debug_line(&self, debug_enabled: bool) -> Option<String> {
        debug_enabled.then(|| self.summary())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn caps_never_drop_below_one() {
        assert_eq!(WorkPools::new(0, -2, 0), WorkPools::new(1, 1, 1));
    }

    #[test]
    fn debug_line_only_when_preference_is_on() {
        let p = WorkPools::new(4, 2, 3);
        assert_eq!(p.debug_line(false), None);
        assert_eq!(p.debug_line(true).as_deref(), Some("work pools: decode 4, gpu 2, cpu 3"));
    }
}
