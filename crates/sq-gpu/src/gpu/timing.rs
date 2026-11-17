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
    *ON.get_or_init(|| std::env::var("SQ_GPU_TIMING").is_ok_and(|v| v == "1"))
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
