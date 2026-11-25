//! GPU time per pass, for debugging and the play benchmark (`SQ_GPU_TIMING=1`). Every compute and render pass writes a
//! timestamp at its start and its end; the pairs are resolved into a buffer at the end of the command buffer and read after the
//! GPU finished it. A pass is named by the pipelines it ran (`Module.entry`), which maps to the effect behind the shader. The
//! timestamps cost a little GPU time, so nothing is recorded unless the switch is set and the adapter has `TIMESTAMP_QUERY`.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

/// Passes timed per command buffer (two timestamps each); later passes of one buffer run untimed.
const MAX_PASSES: u32 = 128;

/// Whether the debug switch `SQ_GPU_TIMING=1` is set.
pub fn requested() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var("SQ_GPU_TIMING").is_ok_and(|v| v == "1") || sq_os::trace::enabled())
}

static UPLOAD_TRACE: AtomicBool = AtomicBool::new(false);
static UPLOAD_NS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Switches the CPU time of texture uploads (`upload_texture` callers) on or off for the per-frame bench trace. Off by default.
pub fn set_upload_trace(on: bool) {
    UPLOAD_TRACE.store(on, Ordering::Relaxed);
}

/// Whether uploads are timed now: one relaxed load, the whole cost of the trace while it is off.
pub fn upload_trace() -> bool {
    UPLOAD_TRACE.load(Ordering::Relaxed)
}

/// Adds one timed upload.
pub fn add_upload(elapsed: std::time::Duration) {
    UPLOAD_NS.fetch_add(u64::try_from(elapsed.as_nanos()).unwrap_or(u64::MAX), Ordering::Relaxed);
}

/// The pieces of the compositor's layers phase that the per-frame trace times separately (`SQ_WINDOW_PLAYLOG`), to find
/// what inside `cp_layers_ms` waits. Nested pieces overlap (`Grade` contains `GradeInfo`, `GradeLoad`, `GradeAssemble`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sub {
    /// The engine's source closure of one layer (all of it).
    Source,
    /// Inside `Source`: `peek_key` and the picture lookup.
    Picture,
    /// Inside `Source`: a generator's raster (title, shape, Lottie).
    Raster,
    /// Inside `Source`: the Gyroflow warp map lookup.
    Gyro,
    /// `to_gpu` of a media layer (wrap or upload) and the gyro warp.
    ToGpu,
    /// The grade lookup of one layer (all of it).
    Grade,
    /// Inside `Grade`: the media info lookup (the media resolver's state mutex).
    GradeInfo,
    /// Inside `Grade`: `load` (file stamps, cached entry).
    GradeLoad,
    /// Inside `Grade`: assembling a pipeline.
    GradeAssemble,
    /// Waiting for the media resolver's state mutex.
    MediaLock,
    /// Waiting for the color resolver's state mutex.
    ColorLock,
    /// Time the media resolver's mutex was held by threads that are not in the layers phase (decoder lanes, the UI).
    MediaHeldElsewhere,
    /// Texture allocation, byte conversion and `write_texture` of a generator raster or a still that missed the plane cache
    /// (not part of `Source`: the compositor does it after the closure returned).
    RasterUpload,
}

/// How many [`Sub`] pieces there are.
pub const SUB_COUNT: usize = 13;
/// The CSV column of each [`Sub`], in order.
pub const SUB_COLUMNS: [&str; SUB_COUNT] = [
    "ly_source_ms",
    "ly_picture_ms",
    "ly_raster_ms",
    "ly_gyro_ms",
    "ly_togpu_ms",
    "ly_grade_ms",
    "ly_grade_info_ms",
    "ly_grade_load_ms",
    "ly_grade_assemble_ms",
    "ly_media_lock_ms",
    "ly_color_lock_ms",
    "ly_media_held_elsewhere_ms",
    "ly_raster_upload_ms",
];

static SUB_NS: [std::sync::atomic::AtomicU64; SUB_COUNT] = [const { std::sync::atomic::AtomicU64::new(0) }; SUB_COUNT];

thread_local! {
    static IN_LAYERS: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Marks the calling thread as inside the compositor's layers phase until dropped (see [`layers_scope`]).
pub struct LayersScope(bool);

impl Drop for LayersScope {
    fn drop(&mut self) {
        if self.0 {
            IN_LAYERS.with(|c| c.set(false));
        }
    }
}

/// Enters the layers phase on this thread; a no-op (one relaxed load) while the trace is off.
pub fn layers_scope() -> LayersScope {
    let on = upload_trace();
    if on {
        IN_LAYERS.with(|c| c.set(true));
    }
    LayersScope(on)
}

/// Whether this thread is in the layers phase and the trace is on.
pub fn in_layers() -> bool {
    upload_trace() && IN_LAYERS.with(std::cell::Cell::get)
}

/// Starts a timer for [`sub_add`]: `None` (free) while the trace is off or this thread is not in the layers phase.
pub fn sub_start() -> Option<std::time::Instant> {
    in_layers().then(std::time::Instant::now)
}

/// Books the time since `started` on `sub`.
pub fn sub_add(sub: Sub, started: Option<std::time::Instant>) {
    if let Some(t) = started {
        SUB_NS[sub as usize].fetch_add(u64::try_from(t.elapsed().as_nanos()).unwrap_or(u64::MAX), Ordering::Relaxed);
    }
}

/// Books `elapsed` on `sub` regardless of the thread (the trace must be on).
pub fn sub_add_duration(sub: Sub, elapsed: std::time::Duration) {
    if upload_trace() {
        SUB_NS[sub as usize].fetch_add(u64::try_from(elapsed.as_nanos()).unwrap_or(u64::MAX), Ordering::Relaxed);
    }
}

/// Times since the last call, in ms, in [`SUB_COLUMNS`] order.
pub fn take_sub_ms() -> [f64; SUB_COUNT] {
    std::array::from_fn(|i| SUB_NS[i].swap(0, Ordering::Relaxed) as f64 / 1e6)
}

/// The calling thread's CPU time now: total and the system (kernel) part of it. `None` (free) while the play-log trace is off
/// or the system does not say.
#[derive(Clone, Copy, Debug)]
pub struct CpuStamp {
    total: std::time::Duration,
    system: std::time::Duration,
}

/// Reads the calling thread's CPU time (see [`CpuStamp`]).
pub fn thread_cpu_now() -> Option<CpuStamp> {
    if !upload_trace() {
        return None;
    }
    let total = sq_os::thread::thread_cpu_time()?;
    let system = sq_os::thread::thread_cpu_split().map_or(std::time::Duration::ZERO, |(_, s)| s);
    Some(CpuStamp { total, system })
}

/// CPU ms between two [`thread_cpu_now`] readings, `[total, system]` (zeros when either is missing).
pub fn cpu_ms_between(from: Option<CpuStamp>, to: Option<CpuStamp>) -> [f64; 2] {
    match (from, to) {
        (Some(a), Some(b)) => {
            [b.total.saturating_sub(a.total).as_secs_f64() * 1e3, b.system.saturating_sub(a.system).as_secs_f64() * 1e3]
        }
        _ => [0.0; 2],
    }
}

/// Upload time since the last call, in ms.
pub fn take_upload_ms() -> f64 {
    UPLOAD_NS.swap(0, Ordering::Relaxed) as f64 / 1e6
}

/// GPU time of every timed pass finished so far, in ms (`None` without `SQ_GPU_TIMING=1` or timestamp queries). Never waits:
/// passes the GPU still runs count in a later call, so a per-frame difference lags the frame by a frame or two.
pub fn finished_total_ms() -> Option<f64> {
    if !requested() {
        return None;
    }
    collect(false);
    Some(registry().totals.values().map(|t| t.total_ms).sum())
}

/// The GPU time of the passes that ran one pipeline (or the same few pipelines), summed over a run.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PassTime {
    pub label: String,
    pub passes: u64,
    pub total_ms: f64,
    pub max_ms: f64,
}

/// A command buffer's timestamp queries while it is recorded.
pub(crate) struct Recorder {
    queries: wgpu::QuerySet,
    labels: Vec<String>,
}

/// Resolved timestamps of a submitted command buffer, read once the GPU finished it.
pub(crate) struct Pending {
    readback: wgpu::Buffer,
    labels: Vec<String>,
    device: wgpu::Device,
    /// Nanoseconds per timestamp tick.
    period: f32,
    pub(crate) index: Option<wgpu::SubmissionIndex>,
    pub(crate) done: Arc<AtomicBool>,
}

impl Recorder {
    pub(crate) fn new(device: &wgpu::Device) -> Self {
        let queries = device.create_query_set(&wgpu::QuerySetDescriptor {
            label: Some("pass timing"),
            ty: wgpu::QueryType::Timestamp,
            count: MAX_PASSES * 2,
        });
        Self { queries, labels: Vec::new() }
    }

    pub(crate) fn queries(&self) -> &wgpu::QuerySet {
        &self.queries
    }

    /// The timestamp slots (start, end) of the next pass, `None` when this buffer's queries are used up.
    pub(crate) fn next_pass(&mut self) -> Option<(u32, u32)> {
        let n = u32::try_from(self.labels.len()).ok().filter(|n| *n < MAX_PASSES)?;
        self.labels.push(String::new());
        Some((n * 2, n * 2 + 1))
    }

    /// The name of the pass `next_pass` handed out last.
    pub(crate) fn label_mut(&mut self) -> Option<&mut String> {
        self.labels.last_mut()
    }

    /// Resolves the timestamps into a readable buffer at the end of `encoder`.
    pub(crate) fn resolve(
        self,
        encoder: &mut wgpu::CommandEncoder,
        device: &wgpu::Device,
        period: f32,
    ) -> Option<Pending> {
        let n = u32::try_from(self.labels.len()).ok().filter(|n| *n > 0)?;
        let bytes = u64::from(n) * 2 * 8;
        let buffer = |usage| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("pass timing"),
                size: bytes,
                usage,
                mapped_at_creation: false,
            })
        };
        let resolved = buffer(wgpu::BufferUsages::QUERY_RESOLVE | wgpu::BufferUsages::COPY_SRC);
        let readback = buffer(wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST);
        encoder.resolve_query_set(&self.queries, 0..n * 2, &resolved, 0);
        encoder.copy_buffer_to_buffer(&resolved, 0, &readback, 0, bytes);
        Some(Pending {
            readback,
            labels: self.labels,
            device: device.clone(),
            period,
            index: None,
            done: Arc::default(),
        })
    }
}

/// Adds `label` to a pass's name unless it is in it already.
pub(crate) fn name_pass(pass: &mut String, label: &str) {
    if !pass.split('+').any(|p| p == label) {
        if !pass.is_empty() {
            pass.push('+');
        }
        pass.push_str(label);
    }
}

struct Registry {
    pending: Vec<Pending>,
    totals: HashMap<String, PassTime>,
}

fn registry() -> std::sync::MutexGuard<'static, Registry> {
    static R: OnceLock<Mutex<Registry>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(Registry { pending: Vec::new(), totals: HashMap::new() }))
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

pub(crate) fn submitted(pending: Pending) {
    registry().pending.push(pending);
}

/// Reads the timestamps of every submission the GPU finished; `all` waits for the others too.
pub(crate) fn collect(all: bool) {
    let pending = std::mem::take(&mut registry().pending);
    let mut waiting = Vec::new();
    for p in pending {
        if !all && !p.done.load(Ordering::Acquire) {
            waiting.push(p);
            continue;
        }
        if let Some(times) = read(&p) {
            let mut r = registry();
            for (label, ms) in times {
                // The pass ran earlier on the GPU; the trace places it at the collection time with its own length.
                sq_os::trace::ended_now("gpu", "gpu pass", std::time::Duration::from_secs_f64(ms / 1e3), || {
                    format!("label={label}")
                });
                let t = r.totals.entry(label.clone()).or_insert_with(|| PassTime { label, ..PassTime::default() });
                t.passes += 1;
                t.total_ms += ms;
                t.max_ms = t.max_ms.max(ms);
            }
        }
    }
    registry().pending.append(&mut waiting);
}

/// (label, milliseconds) of every timed pass of a finished submission.
fn read(p: &Pending) -> Option<Vec<(String, f64)>> {
    let slice = p.readback.slice(..);
    let (tx, rx) = std::sync::mpsc::channel();
    slice.map_async(wgpu::MapMode::Read, move |r| {
        let _ = tx.send(r.is_ok());
    });
    // The submission is finished (or waited for), so the map resolves in this poll.
    let _ = p.device.poll(wgpu::PollType::Wait {
        submission_index: p.index.clone(),
        timeout: Some(std::time::Duration::from_secs(2)),
    });
    if !rx.try_recv().unwrap_or(false) {
        return None;
    }
    let ticks: Vec<u64> = {
        let view = slice.get_mapped_range().ok()?;
        view.as_chunks::<8>().0.iter().map(|c| u64::from_le_bytes(*c)).collect()
    };
    p.readback.unmap();
    Some(
        p.labels
            .iter()
            .zip(ticks.as_chunks::<2>().0)
            .map(|(label, [start, end])| (label.clone(), end.saturating_sub(*start) as f64 * f64::from(p.period) / 1e6))
            .collect(),
    )
}

/// The GPU time per pass name since the last [`reset`], slowest first (waits for passes still running).
pub fn report() -> Vec<PassTime> {
    collect(true);
    let mut all: Vec<PassTime> = registry().totals.values().cloned().collect();
    all.sort_by(|a, b| b.total_ms.total_cmp(&a.total_ms));
    all
}

/// Forgets the times so far.
pub fn reset() {
    collect(true);
    registry().totals.clear();
}

#[cfg(test)]
mod tests {
    // One test: the sub-timers and their switch are process-wide state.
    #[test]
    fn sub_timers_book_only_in_the_layers_phase_of_a_traced_thread() {
        set_upload_trace(false);
        let _ = take_sub_ms();
        assert!(sub_start().is_none(), "trace off: no timer");
        set_upload_trace(true);
        assert!(sub_start().is_none(), "trace on, outside the layers phase: no timer");
        {
            let _scope = layers_scope();
            let t = sub_start();
            assert!(t.is_some());
            std::thread::sleep(std::time::Duration::from_millis(3));
            sub_add(Sub::MediaLock, t);
            // Another thread is not in the layers phase.
            std::thread::spawn(|| assert!(sub_start().is_none())).join().expect("thread");
        }
        assert!(sub_start().is_none(), "the scope ended with its guard");
        sub_add_duration(Sub::MediaHeldElsewhere, std::time::Duration::from_millis(2));
        let ms = take_sub_ms();
        assert!(ms[Sub::MediaLock as usize] >= 3.0, "{ms:?}");
        assert!(ms[Sub::MediaHeldElsewhere as usize] >= 2.0, "{ms:?}");
        assert_eq!(ms[Sub::Grade as usize], 0.0);
        assert_eq!(take_sub_ms().iter().sum::<f64>(), 0.0, "taking clears");
        set_upload_trace(false);
        assert_eq!(SUB_COLUMNS.len(), SUB_COUNT);
        assert_eq!(Sub::RasterUpload as usize, SUB_COUNT - 1);
    }

    use super::*;

    #[test]
    fn a_pass_is_named_by_the_pipelines_it_ran_once_each() {
        let mut name = String::new();
        name_pass(&mut name, "Blur.horizontal");
        name_pass(&mut name, "Blur.horizontal");
        name_pass(&mut name, "Blur.vertical");
        assert_eq!(name, "Blur.horizontal+Blur.vertical");
    }

    #[test]
    fn a_gpu_with_timestamps_times_a_pass_by_its_pipeline() {
        use crate::layout::PixelFormat;
        use crate::pipelines::{Blend, Primitive, RenderKey};
        // Needs SQ_GPU_TIMING=1 in the environment (read once per process) and an adapter with timestamp queries.
        if !requested() {
            return;
        }
        let Some(gpu) = crate::gpu::tests::test_gpu() else { return };
        if !gpu.timing_supported() {
            return;
        }
        let key = RenderKey {
            module: "Present",
            vertex: "presentVertex",
            fragment: "presentFragment",
            format: PixelFormat::Rgba8Unorm,
            blend: Blend::Replace,
            primitive: Primitive::Triangles,
        };
        let target = gpu.texture(64, 64, PixelFormat::Rgba8Unorm);
        let mut cmds = gpu.commands();
        {
            let mut pass = cmds.render(&target, Some([0.0; 4]));
            pass.set_pipeline(&gpu.render_pipeline(key).expect("pipeline"));
        }
        gpu.submit_and_wait(cmds).expect("submit");
        let timed = report().into_iter().find(|t| t.label == "Present.presentFragment");
        assert!(timed.is_some_and(|t| t.passes >= 1), "the pass is in the report");
    }
}
