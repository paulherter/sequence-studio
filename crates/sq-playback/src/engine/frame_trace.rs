// SPDX-License-Identifier: GPL-3.0-or-later
//! Per-frame truth for the play benchmark (`SQ_BENCH_CSV=<file>`, plan H2a): one row per shown frame with the stand-in flag and
//! decode time of each layer, upload, compose and present time, GPU time and the audio ring fill. Off by default: every
//! recording site first reads [`enabled`] (one relaxed load), so a run without the switch pays nothing else.
//!
//! The recorders live here, in the shared engine, so every platform's bench writes the same columns. Times that happen on other
//! threads (decode on the lanes, audio in the device callback) are collected between two shown frames and booked on the row of
//! the frame that follows them.

use sq_core_time::Id;
use sq_gpu::gpu::timing::SUB_COUNT;

/// The layers-phase sub-timers (`SQ_WINDOW_PLAYLOG`), for the crates that sit above the engine but time its inputs.
pub use sq_gpu::gpu::timing::{Sub, sub_add, sub_add_duration, sub_start, upload_trace as trace_on};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Instant;

static ENABLED: AtomicBool = AtomicBool::new(false);

/// Smallest audio ring fill (frames) since the last call.
pub type AudioProbe = Arc<dyn Fn() -> Option<u64> + Send + Sync>;

/// What the engine knows about one layer of a shown frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LayerIn {
    pub media: Id,
    /// A stand-in (or another size) was drawn: the exact picture of the frame was not in the cache.
    pub standin: bool,
    /// Frames between the picture drawn and the wanted frame.
    pub lag: i64,
}

/// One shown frame.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FrameRow {
    pub frame: i64,
    pub pts_s: f64,
    /// Milliseconds since the first row.
    pub at_ms: f64,
    pub standin: Vec<bool>,
    pub lag: Vec<i64>,
    /// Decode (and convert) ms of the pictures of each layer's file that arrived since the previous row.
    pub decode_ms: Vec<f64>,
    /// Texture upload ms since the previous row (a part of `compose_ms`).
    pub upload_ms: f64,
    /// Wall ms of every composite since the previous row (the render thread, uploads included).
    pub compose_ms: f64,
    pub composites: u32,
    /// The publish of the frame (`display`): mailbox, wake of the UI.
    pub present_ms: f64,
    /// Ms the render thread waited for a message since the previous row.
    pub idle_ms: f64,
    /// GPU ms of the passes finished since the previous row (needs `SQ_GPU_TIMING=1`).
    pub gpu_ms: Option<f64>,
    /// Smallest audio ring fill in frames since the previous row (a real output device only).
    pub audio_fill: Option<u64>,
    /// The decode quality of the engine at this frame (`full`, `half`, `quarter`).
    pub quality: &'static str,
    /// Host time (the display timing's epoch, us) the composite was published; 0 without a display timing.
    pub host_us: i64,
    /// Ms the composites since the previous row waited for the GPU to finish an earlier frame (a part of `compose_ms`).
    pub gpu_wait_ms: f64,
    /// Where the composites since the previous row spent their time (summed): layers and uploads, drawing, submit, poll.
    pub phase_ms: [f64; 4],
    /// CPU ms the render thread used in those composites: the layers phase, the whole render (`cp_layers_cpu_ms`,
    /// `cp_total_cpu_ms`) and the system (kernel) part of each (`cp_layers_sys_ms`, `cp_total_sys_ms`).
    /// Compare with `cp_layers_ms` and the sum of the `cp_*` wall columns.
    pub cpu_ms: [f64; 4],
    /// Where the layers phase spent its time, summed over the composites since the previous row, in
    /// `sq_gpu::gpu::timing::SUB_COLUMNS` order (source, picture, raster, gyro, to_gpu, grade, grade info / load /
    /// assemble, the two resolver mutex waits, the media mutex held by other threads).
    pub sub_ms: [f64; SUB_COUNT],
    /// Ms of `render_with` before `render` starts (the caption rasters), summed over the composites since the previous row.
    pub pre_render_ms: f64,
}

#[derive(Default)]
struct Inner {
    started: Option<Instant>,
    decode: Vec<(Id, f64)>,
    compose_ms: f64,
    gpu_wait_ms: f64,
    phase_ms: [f64; 4],
    cpu_ms: [f64; 4],
    sub_ms: [f64; SUB_COUNT],
    pre_render_ms: f64,
    composites: u32,
    /// Idle ms per render thread (a session can run more than one engine; only the thread that shows frames is booked).
    idle_ms: Vec<(std::thread::ThreadId, f64)>,
    gpu_prev: Option<f64>,
    audio: Option<AudioProbe>,
    rows: Vec<FrameRow>,
}

static INNER: Mutex<Inner> = Mutex::new(Inner {
    started: None,
    decode: Vec::new(),
    compose_ms: 0.0,
    gpu_wait_ms: 0.0,
    phase_ms: [0.0; 4],
    cpu_ms: [0.0; 4],
    sub_ms: [0.0; SUB_COUNT],
    pre_render_ms: 0.0,
    composites: 0,
    idle_ms: Vec::new(),
    gpu_prev: None,
    audio: None,
    rows: Vec::new(),
});

fn inner() -> MutexGuard<'static, Inner> {
    INNER.lock().unwrap_or_else(PoisonError::into_inner)
}

static PACING: Mutex<Vec<[i64; 4]>> = Mutex::new(Vec::new());
/// The timeline frame of the newest pacer choice (`i64::MIN`: none yet), for the window's per-present log.
static CHOSEN: AtomicI64 = AtomicI64::new(i64::MIN);

/// Switches the trace on or off (also the upload timer in the GPU crate) and clears what was recorded.
/// One frame choice of the display pacer: host time (the display timing's epoch, us), the master clock's position (us), the
/// timeline frame chosen, and the glass time the choice was made for (us, 0: none). `SQ_WINDOW_PLAYLOG` writes them to
/// `<file>.pacing.csv`: a clock that jitters against the host shows up as `clock_us - host_us` wandering.
pub fn note_pacing(host_us: i64, clock_us: i64, frame: i64, glass_us: i64) {
    if enabled() {
        CHOSEN.store(frame, Ordering::Relaxed);
        let mut p = PACING.lock().unwrap_or_else(PoisonError::into_inner);
        if p.len() < 200_000 {
            p.push([host_us, clock_us, frame, glass_us]);
        }
    }
}

/// The timeline frame the pacer chose last (`None` before the first choice or while the trace is off).
pub fn chosen_frame() -> Option<i64> {
    Some(CHOSEN.load(Ordering::Relaxed)).filter(|f| *f != i64::MIN)
}

/// The pacing rows as CSV, and clears them.
pub fn take_pacing_csv() -> String {
    let rows = std::mem::take(&mut *PACING.lock().unwrap_or_else(PoisonError::into_inner));
    let mut out = String::from("host_us,clock_us,frame,glass_us\n");
    for r in rows {
        out += &format!("{},{},{},{}\n", r[0], r[1], r[2], r[3]);
    }
    out
}

pub fn set_enabled(on: bool) {
    ENABLED.store(on, Ordering::Relaxed);
    sq_gpu::gpu::timing::set_upload_trace(on);
    let _ = sq_gpu::gpu::timing::take_upload_ms();
    CHOSEN.store(i64::MIN, Ordering::Relaxed);
    WANTED_PICTURES.store(0, Ordering::Relaxed);
    let mut i = inner();
    let audio = i.audio.take();
    *i = Inner { audio, ..Inner::default() };
}

pub fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

/// Where the engine reads the audio ring fill (the host sets it when it opens an output; kept across `set_enabled`).
pub fn set_audio_probe(probe: Option<AudioProbe>) {
    inner().audio = probe;
}

/// One decoded picture of `media` took `ms` (decode and conversion, on a lane thread).
pub fn note_decode(media: Id, ms: f64) {
    if enabled() {
        inner().decode.push((media, ms));
    }
}

static WANTED_PICTURES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// A composite wanted `n` media pictures (trace only): decoded pictures per wanted picture shows re-decoding.
pub fn note_wanted(n: usize) {
    if enabled() {
        WANTED_PICTURES.fetch_add(n, std::sync::atomic::Ordering::Relaxed);
    }
}

/// Media pictures the traced composites wanted so far.
pub fn wanted_pictures() -> usize {
    WANTED_PICTURES.load(std::sync::atomic::Ordering::Relaxed)
}

/// One composite took `ms` of wall time on the render thread.
pub fn note_compose(ms: f64) {
    if enabled() {
        let mut i = inner();
        i.compose_ms += ms;
        i.composites += 1;
    }
}

/// One composite waited `ms` for the GPU to finish an earlier frame before it could record (back-pressure).
pub fn note_gpu_wait(ms: f64) {
    if enabled() {
        inner().gpu_wait_ms += ms;
    }
}

/// Where one composite spent its wall time: layers and uploads, drawing the nodes, submit, poll (ms); and the render
/// thread's CPU time of the layers phase and of the whole render.
pub fn note_compose_phases(phase_ms: [f64; 4], cpu_ms: [f64; 4]) {
    if enabled() {
        let mut i = inner();
        for (sum, ms) in i.phase_ms.iter_mut().zip(phase_ms) {
            *sum += ms;
        }
        for (sum, ms) in i.cpu_ms.iter_mut().zip(cpu_ms) {
            *sum += ms;
        }
        for (sum, ms) in i.sub_ms.iter_mut().zip(sq_gpu::gpu::timing::take_sub_ms()) {
            *sum += ms;
        }
    }
}

/// One composite spent `ms` in `render_with` before `render` (setup and the caption rasters).
pub fn note_pre_render(ms: f64) {
    if enabled() {
        inner().pre_render_ms += ms;
    }
}

/// The render thread waited `ms` for a message.
pub fn note_idle(ms: f64) {
    if enabled() {
        let me = std::thread::current().id();
        let mut i = inner();
        match i.idle_ms.iter_mut().find(|(t, _)| *t == me) {
            Some((_, v)) => *v += ms,
            None => i.idle_ms.push((me, ms)),
        }
    }
}

/// Books a shown frame: takes everything noted since the previous one.
pub fn note_frame(frame: i64, pts_s: f64, layers: &[LayerIn], present_ms: f64, quality: &'static str, host_us: i64) {
    if !enabled() {
        return;
    }
    let upload_ms = sq_gpu::gpu::timing::take_upload_ms();
    let gpu_total = sq_gpu::gpu::timing::finished_total_ms();
    let mut i = inner();
    let at_ms = i.started.get_or_insert_with(Instant::now).elapsed().as_secs_f64() * 1e3;
    let decode = std::mem::take(&mut i.decode);
    let decode_ms =
        layers.iter().map(|l| decode.iter().filter(|(m, _)| *m == l.media).fold(0.0, |a, (_, ms)| a + ms)).collect();
    let gpu_ms = gpu_total.map(|t| {
        let d = t - i.gpu_prev.unwrap_or(t);
        i.gpu_prev = Some(t);
        d
    });
    let audio_fill = i.audio.clone().and_then(|p| p());
    let me = std::thread::current().id();
    let idle_ms = i.idle_ms.iter_mut().find(|(t, _)| *t == me).map_or(0.0, |(_, v)| std::mem::take(v));
    let (compose_ms, composites) = (std::mem::take(&mut i.compose_ms), std::mem::take(&mut i.composites));
    let gpu_wait_ms = std::mem::take(&mut i.gpu_wait_ms);
    let phase_ms = std::mem::take(&mut i.phase_ms);
    let cpu_ms = std::mem::take(&mut i.cpu_ms);
    let sub_ms = std::mem::take(&mut i.sub_ms);
    let pre_render_ms = std::mem::take(&mut i.pre_render_ms);
    i.rows.push(FrameRow {
        frame,
        pts_s,
        at_ms,
        standin: layers.iter().map(|l| l.standin).collect(),
        lag: layers.iter().map(|l| l.lag).collect(),
        decode_ms,
        upload_ms,
        compose_ms,
        composites,
        present_ms,
        idle_ms,
        gpu_ms,
        audio_fill,
        quality,
        host_us,
        gpu_wait_ms,
        phase_ms,
        cpu_ms,
        sub_ms,
        pre_render_ms,
    });
}

/// What was recorded and not yet booked on a row (a paused engine, an export, books none): decode ms summed over the lane threads,
/// compose ms, composites, GPU wait ms, phases (layers, draw, submit, poll), idle ms of every engine thread, upload ms.
pub fn unbooked() -> (f64, f64, u32, f64, [f64; 4], f64, f64) {
    let upload = sq_gpu::gpu::timing::take_upload_ms();
    let i = inner();
    (
        i.decode.iter().map(|d| d.1).sum(),
        i.compose_ms,
        i.composites,
        i.gpu_wait_ms,
        i.phase_ms,
        i.idle_ms.iter().map(|d| d.1).sum(),
        upload,
    )
}

/// Trace only: per media the pictures decoded and their summed decode ms (`SQ_EXPORT_TRACE`: which lane carries the export), by ms descending.
pub fn decode_by_media() -> Vec<(Id, usize, f64)> {
    let mut by: std::collections::HashMap<Id, (usize, f64)> = std::collections::HashMap::new();
    for (m, ms) in &inner().decode {
        let e = by.entry(*m).or_default();
        e.0 += 1;
        e.1 += ms;
    }
    let mut v: Vec<(Id, usize, f64)> = by.into_iter().map(|(m, (n, ms))| (m, n, ms)).collect();
    v.sort_by(|a, b| b.2.total_cmp(&a.2));
    v
}

/// The rows so far (the trace keeps recording).
pub fn rows() -> Vec<FrameRow> {
    inner().rows.clone()
}

/// The CSV header.
pub const CSV_HEADER: &str = "frame,pts_s,at_ms,interval_ms,layers,standin,lag_frames,decode_ms,decode_sum_ms,upload_ms,compose_ms,composites,present_ms,idle_ms,other_ms,gpu_ms,audio_fill_frames,quality,host_us,gpu_wait_ms,cp_layers_ms,cp_draw_ms,cp_submit_ms,cp_poll_ms,ly_source_ms,ly_picture_ms,ly_raster_ms,ly_gyro_ms,ly_togpu_ms,ly_grade_ms,ly_grade_info_ms,ly_grade_load_ms,ly_grade_assemble_ms,ly_media_lock_ms,ly_color_lock_ms,ly_media_held_elsewhere_ms,ly_raster_upload_ms,cp_layers_cpu_ms,cp_total_cpu_ms,cp_layers_sys_ms,cp_total_sys_ms,cp_pre_render_ms";

/// The rows as CSV (`other_ms` = interval - compose - present - idle: render-thread work no column names; empty on the first row): per-layer cells join the layers with `;` (top of the stack last); empty cells mean "not measured".
pub fn to_csv(rows: &[FrameRow]) -> String {
    let join = |v: Vec<String>| v.join(";");
    let opt = |v: Option<String>| v.unwrap_or_default();
    let mut out = String::from(CSV_HEADER);
    out.push('\n');
    for (n, r) in rows.iter().enumerate() {
        let interval = if n == 0 { String::new() } else { format!("{:.3}", r.at_ms - rows[n - 1].at_ms) };
        out += &format!(
            "{},{:.4},{:.3},{},{},{},{},{},{:.3},{:.3},{:.3},{},{:.3},{:.3},{},{},{},{},{},{:.3},{:.3},{:.3},{:.3},{:.3}{},{:.3},{:.3},{:.3},{:.3},{:.3}\n",
            r.frame,
            r.pts_s,
            r.at_ms,
            interval,
            r.standin.len(),
            join(r.standin.iter().map(|s| u8::from(*s).to_string()).collect()),
            join(r.lag.iter().map(ToString::to_string).collect()),
            join(r.decode_ms.iter().map(|d| format!("{d:.3}")).collect()),
            r.decode_ms.iter().fold(0.0, |a, d| a + d),
            r.upload_ms,
            r.compose_ms,
            r.composites,
            r.present_ms,
            r.idle_ms,
            if n == 0 {
                String::new()
            } else {
                format!("{:.3}", r.at_ms - rows[n - 1].at_ms - r.compose_ms - r.present_ms - r.idle_ms)
            },
            opt(r.gpu_ms.map(|g| format!("{g:.3}"))),
            opt(r.audio_fill.map(|a| a.to_string())),
            r.quality,
            r.host_us,
            r.gpu_wait_ms,
            r.phase_ms[0],
            r.phase_ms[1],
            r.phase_ms[2],
            r.phase_ms[3],
            r.sub_ms.iter().map(|v| format!(",{v:.3}")).collect::<String>(),
            r.cpu_ms[0],
            r.cpu_ms[1],
            r.cpu_ms[2],
            r.cpu_ms[3],
            r.pre_render_ms,
        );
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_gpu::gpu::timing::SUB_COLUMNS;

    fn lines_quality(csv: &str) -> bool {
        let quality = CSV_HEADER.split(',').position(|c| c == "quality").expect("quality column");
        csv.lines().skip(1).all(|l| l.split(',').nth(quality) == Some("half"))
    }

    // One test: the trace is process-wide state.
    #[test]
    fn rows_collect_what_happened_between_two_frames_and_off_records_nothing() {
        set_enabled(false);
        note_decode(Id::from_u128(1), 5.0);
        note_compose(2.0);
        note_frame(0, 0.0, &[], 0.1, "full", 0);
        assert!(rows().is_empty(), "off: nothing recorded");

        set_enabled(true);
        set_audio_probe(Some(Arc::new(|| Some(4800))));
        let (a, b) = (Id::from_u128(1), Id::from_u128(2));
        note_decode(a, 5.0);
        note_decode(a, 3.0);
        note_decode(b, 7.0);
        note_decode(Id::from_u128(9), 100.0); // a prefetch for a file that is no layer of this frame
        note_compose(2.0);
        note_compose(1.5);
        note_compose_phases([1.0, 2.0, 3.0, 4.0], [0.5, 0.75, 0.25, 0.5]);
        note_gpu_wait(6.0);
        note_gpu_wait(2.5);
        note_pacing(100, 100, 42, 200);
        note_idle(4.0);
        let layers = [LayerIn { media: a, standin: false, lag: 0 }, LayerIn { media: b, standin: true, lag: 3 }];
        note_frame(10, 0.4, &layers, 0.2, "half", 5_000);
        note_frame(11, 0.44, &layers[..1], 0.1, "half", 9_000);
        let r = rows();
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].decode_ms, vec![8.0, 7.0]);
        assert_eq!((r[0].composites, r[0].compose_ms), (2, 3.5));
        assert_eq!(r[0].standin, vec![false, true]);
        assert_eq!(r[0].audio_fill, Some(4800));
        assert_eq!(r[0].idle_ms, 4.0);
        assert_eq!((r[0].host_us, r[0].gpu_wait_ms, r[1].gpu_wait_ms), (5_000, 8.5, 0.0));
        assert_eq!(r[0].phase_ms, [1.0, 2.0, 3.0, 4.0]);
        assert_eq!(r[0].cpu_ms, [0.5, 0.75, 0.25, 0.5]);
        assert!(to_csv(&r).lines().nth(1).is_some_and(|l| l.ends_with(",0.500,0.750,0.250,0.500,0.000")));
        assert_eq!(chosen_frame(), Some(42));
        assert!(lines_quality(&to_csv(&r)));
        assert_eq!((r[1].composites, r[1].decode_ms.clone()), (0, vec![0.0]));
        let csv = to_csv(&r);
        let lines: Vec<&str> = csv.lines().collect();
        assert_eq!(lines[0], CSV_HEADER);
        assert!(
            lines[1].starts_with("10,0.4000,") && lines[1].contains(",2,0;1,0;3,8.000;7.000,15.000,"),
            "{}",
            lines[1]
        );
        assert_eq!(lines[1].split(',').count(), CSV_HEADER.split(',').count());
        assert_eq!(lines[2].split(',').count(), CSV_HEADER.split(',').count());
        assert!(lines[1].contains(",half,5000,8.500,1.000,2.000,3.000,4.000,"), "{}", lines[1]);
        assert_eq!(CSV_HEADER.split(',').count(), 24 + SUB_COUNT + 5);
        assert_eq!(CSV_HEADER.split(',').skip(24).take(SUB_COUNT).collect::<Vec<_>>(), SUB_COLUMNS);
        assert!(
            CSV_HEADER.ends_with(",cp_layers_cpu_ms,cp_total_cpu_ms,cp_layers_sys_ms,cp_total_sys_ms,cp_pre_render_ms")
        );
        set_audio_probe(None);
        set_enabled(false);
        assert_eq!(chosen_frame(), None, "switching the trace clears the choice");
    }
}
