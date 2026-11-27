//! Start-up pipeline warm-up and the on-disk pipeline cache.
//!
//! Compiling a pipeline costs 20-100 ms. The known set is built on a background thread as soon as the device exists, so the
//! first picture after opening a project, the first dissolve and the first title find their pipelines ready (trace
//! 2026-11-24: 824 ms of `pipeline create` inside the first compose). Vulkan additionally keeps the driver's compiled code
//! in a file (wgpu `PipelineCache`); Metal and D3D12 have their own driver caches.

use super::{Blend, Primitive, RenderKey};
use crate::gpu::Gpu;
use crate::layout::PixelFormat;
use std::path::PathBuf;
use std::sync::Arc;

/// Threads of the start-up warm-up; the 16-thread machines keep cores for decode and the UI.
const WARM_THREADS: usize = 3;

const F16: PixelFormat = PixelFormat::Rgba16Float;

/// Compute pipelines the compositor, the color chain, transitions and the display path use (module, entry, `out0` format).
pub(crate) const KNOWN_COMPUTE: &[(&str, &str, PixelFormat)] = &[
    ("ColorChainInPlace", "colorChainInPlace", F16), // the slowest (about 400 ms): first
    ("SourceConvert", "convertToRGB", F16),
    ("GyroWarp", "gyroWarp", F16),
    ("GyroWarp", "gyroWarpScaled", F16),
    // The first graded layer of a monitor-size preview builds it inside a playing compose (a 56-59 ms gap 2.7 s after Play).
    ("SourceConvert", "convertToRGBScaled", F16),
    ("Pointwise", "premultipliedLinearToEncoded709", F16),
    ("TransitionPreBlur", "transitionPreBlur", F16),
    ("TransitionCover", "transitionCoverMin", F16),
    ("FilmLook", "filmLook", F16),
    ("DisplayGamma", "displayGamma", PixelFormat::Rgba8Unorm),
];

/// The draws of the compositor (cut, dissolve, blend, additive stacks), the present pass and the draw UI.
pub(crate) fn known_render() -> Vec<RenderKey> {
    let layer = |module, fragment, blend| RenderKey {
        module,
        vertex: "compositeVertex",
        fragment,
        format: F16,
        blend,
        primitive: Primitive::TriangleStrip,
    };
    let mut keys = Vec::new();
    for blend in [Blend::PremultipliedOver, Blend::Additive] {
        keys.push(layer("Layer", "compositeFragment", blend));
        keys.push(layer("LayerTransition", "compositeFragmentTransition", blend));
    }
    keys.push(layer("Layer", "compositeFragmentBlend", Blend::Replace));
    for format in [PixelFormat::Rgba8Unorm, PixelFormat::Bgra8Unorm] {
        keys.push(RenderKey {
            module: "Present",
            vertex: "presentVertex",
            fragment: "presentFragment",
            format,
            blend: Blend::Replace,
            primitive: Primitive::Triangles,
        });
        keys.push(RenderKey {
            module: "DrawQuads",
            vertex: "quadVertex",
            fragment: "quadFragment",
            format,
            blend: Blend::StraightOver,
            primitive: Primitive::Triangles,
        });
    }
    keys
}

/// 64-bit FNV-1a, stable across Rust versions (a cache file name must not change with the toolchain).
fn fnv(text: &str) -> u64 {
    text.bytes().fold(0xcbf2_9ce4_8422_2325, |h, b| (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3))
}

/// The cache file name of one adapter and driver at this app build: a changed driver, adapter or build gives a new name, so
/// stale data is never loaded (wgpu and the driver validate the content again).
pub(crate) fn cache_file_name(info: &wgpu::AdapterInfo, build: &str) -> String {
    let id = format!(
        "{:?}|{:x}|{:x}|{}|{}|{}",
        info.backend, info.vendor, info.device, info.driver, info.driver_info, build
    );
    format!("pipelines-{:016x}.bin", fnv(&id))
}

fn cache_path(info: &wgpu::AdapterInfo) -> Option<PathBuf> {
    let base = match std::env::var_os("SQ_PIPELINE_CACHE_DIR") {
        Some(dir) => PathBuf::from(dir),
        None => sq_os::Platform::current().cache_dir(|k| std::env::var_os(k))?.join("SequenceStudio"),
    };
    let build = concat!(env!("CARGO_PKG_VERSION"), "+wgpu30.0.1");
    Some(base.join(cache_file_name(info, build)))
}

/// The driver cache of this device (Vulkan only: needs `Features::PIPELINE_CACHE`), seeded from the file when it exists.
#[allow(unsafe_code)]
pub(crate) fn open_cache(
    device: &wgpu::Device,
    info: &wgpu::AdapterInfo,
    features: wgpu::Features,
) -> Option<(wgpu::PipelineCache, PathBuf)> {
    if !features.contains(wgpu::Features::PIPELINE_CACHE) || std::env::var_os("SQ_NO_PIPELINE_CACHE").is_some() {
        return None;
    }
    let path = cache_path(info)?;
    let data = std::fs::read(&path).ok();
    // SAFETY: `fallback: true` makes wgpu drop data that fails its header check (other driver, other wgpu); the file name
    // already carries adapter, driver and build.
    let cache = unsafe {
        device.create_pipeline_cache(&wgpu::PipelineCacheDescriptor {
            label: Some("sq-pipelines"),
            data: data.as_deref(),
            fallback: true,
        })
    };
    Some((cache, path))
}

static PREWARM_DONE: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();

/// When the background prewarm finished (`None` while it runs or when it was off); the play bench reports it as a stage.
pub fn prewarm_done_at() -> Option<std::time::Instant> {
    PREWARM_DONE.get().copied()
}

impl Gpu {
    /// Builds every known pipeline on background threads (the caller does not wait) and then saves the driver cache.
    /// Errors are ignored here; the draw that needs the pipeline reports them.
    pub fn prewarm(self: &Arc<Self>) -> Option<std::thread::JoinHandle<()>> {
        if std::env::var_os("SQ_NO_PREWARM").is_some() {
            return None;
        }
        let gpu = Arc::clone(self);
        std::thread::Builder::new()
            .name("sq-gpu-prewarm".into())
            .spawn(move || {
                let _span = sq_os::trace::span("gpu", "pipeline prewarm");
                gpu.build_known();
                gpu.save_pipeline_cache();
                let _ = PREWARM_DONE.set(std::time::Instant::now());
            })
            .ok()
    }

    /// Builds the known set: the slowest pipelines first, on up to `WARM_THREADS` threads (the drivers compile in parallel).
    pub(crate) fn build_known(self: &Arc<Self>) {
        enum Job {
            Compute(&'static str, &'static str, PixelFormat),
            Render(RenderKey),
        }
        let mut jobs: Vec<Job> = KNOWN_COMPUTE.iter().map(|&(m, e, o)| Job::Compute(m, e, o)).collect();
        jobs.extend(known_render().into_iter().map(Job::Render));
        let jobs = Arc::new(std::sync::Mutex::new(jobs.into_iter().rev().collect::<Vec<_>>()));
        let workers: Vec<_> = (0..WARM_THREADS)
            .filter_map(|_| {
                let (gpu, jobs) = (Arc::clone(self), Arc::clone(&jobs));
                std::thread::Builder::new()
                    .name("sq-gpu-prewarm-w".into())
                    .spawn(move || {
                        loop {
                            let job = jobs.lock().unwrap_or_else(|e| e.into_inner()).pop();
                            match job {
                                Some(Job::Compute(m, e, o)) => drop(gpu.compute_pipeline(m, e, o)),
                                Some(Job::Render(k)) => drop(gpu.render_pipeline(k)),
                                None => break,
                            }
                        }
                    })
                    .ok()
            })
            .collect();
        for w in workers {
            let _ = w.join();
        }
    }

    /// Writes the driver cache to its file (atomically); no-op without a cache.
    pub fn save_pipeline_cache(&self) {
        let Some((cache, path)) = &self.pipeline_cache else { return };
        let Some(data) = cache.get_data() else { return };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let tmp = path.with_extension("tmp");
        if std::fs::write(&tmp, data).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pipelines::{ShaderStage, find};

    fn info(driver: &str) -> wgpu::AdapterInfo {
        let mut i = wgpu::AdapterInfo::new(wgpu::DeviceType::DiscreteGpu, wgpu::Backend::Vulkan);
        i.vendor = 0x1002;
        i.device = 0x7550;
        i.driver = driver.into();
        i
    }

    #[test]
    fn the_known_set_holds_the_previews_scaled_convert() {
        assert!(KNOWN_COMPUTE.iter().any(|&(m, e, o)| (m, e, o) == ("SourceConvert", "convertToRGBScaled", F16)));
    }

    #[test]
    fn cache_name_changes_with_driver_adapter_and_build() {
        let base = cache_file_name(&info("radv"), "0.2.1");
        assert_eq!(base, cache_file_name(&info("radv"), "0.2.1"));
        assert_ne!(base, cache_file_name(&info("amdvlk"), "0.2.1"));
        assert_ne!(base, cache_file_name(&info("radv"), "0.2.2"));
        let mut other = info("radv");
        other.device = 1;
        assert_ne!(base, cache_file_name(&other, "0.2.1"));
    }

    #[test]
    fn known_entries_exist_with_the_right_stage() {
        for &(module, entry, _) in KNOWN_COMPUTE {
            assert!(find(module, entry).is_some_and(|e| e.stage == ShaderStage::Compute), "{module}.{entry}");
        }
        for k in known_render() {
            assert!(find(k.module, k.vertex).is_some_and(|e| e.stage == ShaderStage::Vertex), "{}", k.module);
            assert!(find(k.module, k.fragment).is_some_and(|e| e.stage == ShaderStage::Fragment), "{}", k.module);
        }
    }

    #[test]
    fn prewarm_fills_the_caches_off_the_calling_thread() {
        let Some(gpu) = crate::gpu::tests::test_gpu() else { return };
        let handle = gpu.prewarm().expect("thread");
        handle.join().expect("prewarm thread");
        assert!(gpu.render.lock().map(|m| m.len()).unwrap_or(0) >= known_render().len());
        assert!(gpu.compute.lock().map(|m| m.len()).unwrap_or(0) >= KNOWN_COMPUTE.len());
    }

    #[test]
    fn two_threads_asking_for_one_pipeline_get_the_same_build() {
        let Some(gpu) = crate::gpu::tests::test_gpu() else { return };
        let ask = |gpu: Arc<Gpu>| {
            std::thread::spawn(move || gpu.compute_pipeline("FilmLook", "filmLook", F16).expect("pipeline"))
        };
        let (a, b) = (ask(Arc::clone(&gpu)), ask(Arc::clone(&gpu)));
        let (a, b) = (a.join().expect("a"), b.join().expect("b"));
        assert!(Arc::ptr_eq(&a, &b));
    }
}
