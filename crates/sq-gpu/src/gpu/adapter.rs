//! Adapter choice: every adapter of the platform backend is a candidate, the best one that can run the engine wins.
//!
//! The first version asked wgpu for "the high-performance adapter" once; on a machine whose first pick lacks a feature or
//! cannot present (hybrid laptops, a remote desktop, a driver without passthrough shaders) the app then stopped with an
//! error although another adapter would have worked. Now: discrete, then integrated, then virtual, then anything else, a
//! software adapter (WARP) last; `SQ_GPU_ADAPTER=<part of the name>` forces one (the log line names the choice).

/// One adapter as the choice sees it.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Candidate {
    pub name: String,
    pub device_type: wgpu::DeviceType,
    /// Has every feature the engine needs.
    pub features_ok: bool,
    /// Can present to the window surface (true when the device opens without a surface).
    pub surface_ok: bool,
}

fn type_rank(t: wgpu::DeviceType) -> u32 {
    match t {
        wgpu::DeviceType::DiscreteGpu => 4,
        wgpu::DeviceType::IntegratedGpu => 3,
        wgpu::DeviceType::VirtualGpu => 2,
        wgpu::DeviceType::Other => 1,
        wgpu::DeviceType::Cpu => 0,
    }
}

/// The index of the adapter to open: `wanted` (a case-insensitive part of the name) when a usable adapter matches it,
/// else the best usable one by type; the first of equals wins (the order the system lists them in). `None` = no usable one.
pub(crate) fn choose(candidates: &[Candidate], wanted: Option<&str>) -> Option<usize> {
    let usable = |c: &Candidate| c.features_ok && c.surface_ok;
    if let Some(part) = wanted.map(str::to_lowercase).filter(|p| !p.is_empty())
        && let Some(i) = candidates.iter().position(|c| usable(c) && c.name.to_lowercase().contains(&part))
    {
        return Some(i);
    }
    candidates
        .iter()
        .enumerate()
        .filter(|(_, c)| usable(c))
        .max_by_key(|(i, c)| (type_rank(c.device_type), std::cmp::Reverse(*i)))
        .map(|(i, _)| i)
}

#[cfg(test)]
mod tests {
    use super::*;
    use wgpu::DeviceType::*;

    fn c(name: &str, device_type: wgpu::DeviceType, features_ok: bool, surface_ok: bool) -> Candidate {
        Candidate { name: name.into(), device_type, features_ok, surface_ok }
    }

    #[test]
    fn discrete_beats_integrated_beats_software() {
        let list = [
            c("Microsoft Basic Render Driver", Cpu, true, true),
            c("Intel UHD", IntegratedGpu, true, true),
            c("RX 9070 XT", DiscreteGpu, true, true),
        ];
        assert_eq!(choose(&list, None), Some(2));
        assert_eq!(choose(&list[..2], None), Some(1));
        assert_eq!(choose(&list[..1], None), Some(0));
    }

    #[test]
    fn an_adapter_that_lacks_a_feature_or_cannot_present_is_skipped() {
        let list = [
            c("NVIDIA", DiscreteGpu, false, true),
            c("Other", DiscreteGpu, true, false),
            c("Intel", IntegratedGpu, true, true),
        ];
        assert_eq!(choose(&list, None), Some(2));
        assert_eq!(choose(&list[..2], None), None);
        assert_eq!(choose(&[], None), None);
    }

    #[test]
    fn a_named_adapter_wins_when_usable_else_the_best() {
        let list = [c("NVIDIA GeForce RTX 4070", DiscreteGpu, true, true), c("Intel UHD", IntegratedGpu, true, true)];
        assert_eq!(choose(&list, Some("intel")), Some(1));
        assert_eq!(choose(&list, Some("radeon")), Some(0));
        assert_eq!(choose(&list, Some("")), Some(0));
    }

    #[test]
    fn equal_adapters_keep_the_system_order() {
        let list = [c("A", DiscreteGpu, true, true), c("B", DiscreteGpu, true, true)];
        assert_eq!(choose(&list, None), Some(0));
    }
}
