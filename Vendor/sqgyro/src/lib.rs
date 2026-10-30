// sqgyro: Sequence Studio's C shim around gyroflow_core (GPL-3.0-or-later, like gyroflow).
// Pattern follows the official Gyroflow plugins (gyroflow-plugins, common/src/lib.rs `stab_manager`) for loading a video
// file, and the Gyroflow app's renderer (gyroflow src/rendering/mod.rs `create_planes_proc!`) for warping bi-planar
// Y'CbCr frames plane by plane. Header: include/sqgyro.h. docs/GYROFLOW.md has the plan.
//
// Threading: every function may be called from any thread. A handle holds one StabilizationManager (smoothing, zoom,
// gyro) and one undistortion state per plane layout. `sqgyro_recompute` is the slow, blocking part (call it off the
// render thread); `sqgyro_process_plane` only warps.

use std::ffi::{CStr, c_char};
use std::collections::HashMap;
use std::sync::{Arc, Once};
use std::sync::atomic::{AtomicU64, Ordering::SeqCst};
use parking_lot::{Mutex, RwLock};

use gyroflow_core::{StabilizationManager, filesystem};
use gyroflow_core::gpu::{BufferDescription, BufferSource, Buffers};
use gyroflow_core::stabilization::{ComputeParams, Stabilization, Interpolation};
use gyroflow_core::stabilization::{PixelType, Luma8, Luma16, UV8, UV16, BGRA8};
use gyroflow_core::lens_profile_database::LensProfileDatabase;

/// What `sqgyro_open` found in the file.
#[repr(C)]
pub struct SQGyroInfo {
    pub width: u32,
    pub height: u32,
    pub fps: f64,
    pub duration_ms: f64,
    pub frame_count: u64,
    /// Rolling-shutter readout time from the lens profile / file, ms (0 = none known).
    pub readout_ms: f64,
    pub has_motion: u8,
    pub has_accurate_timestamps: u8,
    /// Camera / lens as Gyroflow names them (NUL-terminated, may be empty).
    pub camera: [c_char; 128],
    pub lens: [c_char; 128],
}

/// Plane layouts `sqgyro_process_plane` can warp.
pub const SQGYRO_LUMA8: u32 = 0;   // Y plane, 8 bit
pub const SQGYRO_UV8: u32 = 1;     // interleaved CbCr plane, 8 bit
pub const SQGYRO_LUMA16: u32 = 2;  // Y plane, 16 bit (10-bit MSB-aligned)
pub const SQGYRO_UV16: u32 = 3;    // interleaved CbCr plane, 16 bit
pub const SQGYRO_BGRA8: u32 = 4;   // packed BGRA, 8 bit

#[derive(Clone, Copy, PartialEq)]
struct Settings { smoothness: f64, zoom_limit: f64, rolling_shutter: bool, horizon_lock: f64,
                  fov: f64, lens_correction: f64, sync_offset_ms: f64 }

const DEFAULT_SETTINGS: Settings = Settings { smoothness: 50.0, zoom_limit: 130.0, rolling_shutter: true, horizon_lock: 0.0,
                                              fov: 1.0, lens_correction: 1.0, sync_offset_ms: 0.0 };

struct Plane {
    stab: Stabilization,
    generation: u64,
}

pub struct Handle {
    mgr: StabilizationManager,
    /// Readout time the file / lens profile gave (restored when rolling shutter is switched back on).
    native_readout: f64,
    /// Sync offsets (gyro vs video, ms by video time µs) the file / sidecar brought; the user's offset is added to these.
    native_offsets: std::collections::BTreeMap<i64, f64>,
    settings: RwLock<Option<Settings>>,
    /// Bumped by every `sqgyro_recompute`; planes rebuild their compute params when theirs is older.
    generation: AtomicU64,
    compute: RwLock<Option<Arc<ComputeParams>>>,
    planes: Mutex<HashMap<(u32, usize, usize, bool), Arc<Mutex<Plane>>>>,
    offset_us: RwLock<i64>,
    /// Clockwise quarter turn (0/90/180/270) the file's rotation tag shows the frame with. The frames reach `process_plane`
    /// unrotated (the host turns them after the warp), so Gyroflow's image rotation stays 0 and this only tilts the
    /// horizon lock (Gyroflow adds `video_rotation` to the lock roll).
    rotation: RwLock<f64>,
}

static INIT: Once = Once::new();

/// One lens-profile database for every handle (loading it parses ~1.5 MB of compressed profiles).
fn shared_db() -> Arc<RwLock<LensProfileDatabase>> {
    static DB: std::sync::OnceLock<Arc<RwLock<LensProfileDatabase>>> = std::sync::OnceLock::new();
    DB.get_or_init(|| {
        let mut db = LensProfileDatabase::default();
        db.load_all();
        Arc::new(RwLock::new(db))
    }).clone()
}

fn init_once() {
    INIT.call_once(|| {
        let _ = std::panic::catch_unwind(|| { gyroflow_core::gpu::initialize_contexts(); });
    });
}

fn copy_str(dst: &mut [c_char; 128], s: &str) {
    let bytes = s.as_bytes();
    let n = bytes.len().min(127);
    for i in 0..n { dst[i] = bytes[i] as c_char; }
    dst[n] = 0;
}

fn write_err(err: *mut c_char, err_len: usize, msg: &str) {
    if err.is_null() || err_len == 0 { return; }
    let bytes = msg.as_bytes();
    let n = bytes.len().min(err_len - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, err, n);
        *err.add(n) = 0;
    }
}

/// Opens a video file (or a file with a `.gcsv` sidecar handled by gyroflow_core), reads its gyro data and lens profile.
/// Returns null on failure (reason in `err`). Blocking (parses the whole file's telemetry).
#[unsafe(no_mangle)]
pub extern "C" fn sqgyro_open(path: *const c_char, info: *mut SQGyroInfo, err: *mut c_char, err_len: usize) -> *mut Handle {
    if path.is_null() { write_err(err, err_len, "no path"); return std::ptr::null_mut(); }
    let path = unsafe { CStr::from_ptr(path) }.to_string_lossy().to_string();
    let result = std::panic::catch_unwind(|| open_impl(&path));
    match result {
        Ok(Ok(h)) => {
            if !info.is_null() {
                let info = unsafe { &mut *info };
                let p = h.mgr.params.read();
                info.width = p.size.0 as u32;
                info.height = p.size.1 as u32;
                info.fps = p.fps;
                info.duration_ms = p.duration_ms;
                info.frame_count = p.frame_count as u64;
                info.readout_ms = h.native_readout;
                drop(p);
                let gyro = h.mgr.gyro.read();
                info.has_motion = gyro.has_motion() as u8;
                info.has_accurate_timestamps = gyro.file_metadata.read().has_accurate_timestamps as u8;
                drop(gyro);
                let camera = h.mgr.camera_id.read().as_ref().map(|c| format!("{} {}", c.brand, c.model).trim().to_string()).unwrap_or_default();
                copy_str(&mut info.camera, &camera);
                copy_str(&mut info.lens, &h.mgr.lens.read().get_display_name());
            }
            Box::into_raw(Box::new(h))
        }
        Ok(Err(e)) => { write_err(err, err_len, &e); std::ptr::null_mut() }
        Err(_) => { write_err(err, err_len, "gyroflow_core panicked while opening the file"); std::ptr::null_mut() }
    }
}

fn open_impl(path: &str) -> Result<Handle, String> {
    init_once();
    let mut mgr = StabilizationManager::default();
    mgr.lens_profile_db = shared_db();
    {
        let mut s = mgr.stabilization.write();
        s.share_wgpu_instances = false;
        s.interpolation = Interpolation::Lanczos4;
    }
    let url = filesystem::path_to_url(path);
    let mut file = filesystem::open_file(&url, false, false).map_err(|e| format!("cannot open file: {e:?}"))?;
    let size = file.size;
    let meta = mgr.load_video_file(file.get_file(), size, &url, None, true).map_err(|e| format!("cannot read file: {e:?}"))?;
    drop(file);
    let rotation = (meta.rotation.rem_euclid(360) as f64 / 90.0).round() * 90.0 % 360.0;
    let (w, h, dur) = { let p = mgr.params.read(); (p.size.0, p.size.1, p.duration_ms) };
    if w == 0 || h == 0 || dur <= 0.0 { return Err("no video track".into()); }
    // A Gyroflow CSV log next to the clip (`<name>.gcsv`) wins over (or stands in for) the file's own metadata, like the
    // Gyroflow app's "load motion data" for a sidecar. It may carry a lens profile and readout time.
    if let Some(gcsv) = sidecar(path) {
        let gurl = filesystem::path_to_url(&gcsv);
        let mut gf = filesystem::open_file(&gurl, false, false).map_err(|e| format!("cannot open gyro log: {e:?}"))?;
        let gsize = gf.size;
        mgr.load_gyro_data(gf.get_file(), gsize, &gurl, true, &Default::default(), |_| (), Arc::new(std::sync::atomic::AtomicBool::new(false)))
            .map_err(|e| format!("cannot read gyro log: {e:?}"))?;
    }
    if !mgr.gyro.read().has_motion() { return Err("no gyro data in this file".into()); }
    // Output = input size: the clip keeps its frame; adaptive zoom fills it.
    mgr.set_size(w, h);
    mgr.set_output_size(w, h);
    mgr.set_background_color(nalgebra_vec4(0.0, 0.0, 0.0, 1.0));
    let native_readout = mgr.params.read().frame_readout_time;
    let native_offsets = mgr.gyro.read().get_offsets().clone();
    let offset_us = { let p = mgr.params.read(); (p.frame_offset as f64 / p.fps * 1_000_000.0).round() as i64 };
    Ok(Handle {
        mgr, native_readout, native_offsets,
        settings: RwLock::new(None),
        generation: AtomicU64::new(0),
        compute: RwLock::new(None),
        planes: Mutex::new(HashMap::new()),
        offset_us: RwLock::new(offset_us),
        rotation: RwLock::new(rotation),
    })
}

/// `<name>.gcsv` / `.GCSV` next to the clip (same rule as SQAnalysis `GyroDataProbe.sidecar`).
fn sidecar(path: &str) -> Option<String> {
    let p = std::path::Path::new(path);
    for ext in ["gcsv", "GCSV"] {
        let s = p.with_extension(ext);
        if s.is_file() { return s.to_str().map(|x| x.to_string()); }
    }
    None
}

fn nalgebra_vec4(a: f32, b: f32, c: f32, d: f32) -> nalgebra::Vector4<f32> { nalgebra::Vector4::new(a, b, c, d) }

/// Sets the options. Takes effect at the next `sqgyro_recompute`.
/// smoothness: % (1...100; Gyroflow's 0.001...1 range, values above 100 are clamped); zoom_limit: % (100...300; <= 100 = no zoom limit beyond 1x... see
/// Gyroflow: values <= 50 mean "no limit"); rolling_shutter: 0/1; horizon_lock: % (0...100).
#[unsafe(no_mangle)]
pub extern "C" fn sqgyro_set_params(h: *mut Handle, smoothness: f64, zoom_limit: f64, rolling_shutter: u8, horizon_lock: f64) {
    let Some(h) = (unsafe { h.as_ref() }) else { return };
    let mut s = h.settings.read().unwrap_or(DEFAULT_SETTINGS);
    s.smoothness = smoothness; s.zoom_limit = zoom_limit; s.rolling_shutter = rolling_shutter != 0; s.horizon_lock = horizon_lock;
    *h.settings.write() = Some(s);
}

/// Lens and sync options. Takes effect at the next `sqgyro_recompute`.
/// fov: output field of view (Gyroflow's FOV, 1 = as framed; 0.1...3); lens_correction: 0...1 (0 = keep the lens
/// distortion, 1 = undo it fully); sync_offset_ms: added to every gyro sync offset the file brings (Gyroflow's sign:
/// Gyroflow looks the gyro up at `video time - offset`, so a positive offset takes an EARLIER gyro sample).
#[unsafe(no_mangle)]
pub extern "C" fn sqgyro_set_lens_params(h: *mut Handle, fov: f64, lens_correction: f64, sync_offset_ms: f64) {
    let Some(h) = (unsafe { h.as_ref() }) else { return };
    let mut s = h.settings.read().unwrap_or(DEFAULT_SETTINGS);
    if fov.is_finite() { s.fov = fov.clamp(0.1, 3.0); }
    if lens_correction.is_finite() { s.lens_correction = lens_correction.clamp(0.0, 1.0); }
    if sync_offset_ms.is_finite() { s.sync_offset_ms = sync_offset_ms; }
    *h.settings.write() = Some(s);
}

/// Horizon-lock roll for a clip whose rotation tag turns the frame `rotation` degrees clockwise on screen. The frames
/// reach `sqgyro_process_plane` unrotated, so Gyroflow's image rotation stays 0 and only the lock needs the turn: the
/// official plugins end at the same roll (their `Rotation` param, which Gyroflow adds to the lock roll, plus the 180
/// degrees they add for quarter turns, `cache_keyframes` in common/src/lib.rs) = the tag's rotation.
///
/// Derived the way the plugins do it, so the sign is pinned by construction: InputRotation = Rotation = (360 - tag) % 360
/// (`input_rotation_from_metadata`), Gyroflow adds that Rotation to the lock roll, and `cache_keyframes` adds 180 more for
/// quarter turns (a vertical clip would come out upside down otherwise). The Gyroflow app itself (render_queue.rs) skips
/// the 180 and so locks a portrait clip upside down; we follow the plugins.
fn horizon_roll(rotation: f64) -> f64 {
    let tag = rotation.rem_euclid(360.0);
    let video_rotation = (360.0 - tag).rem_euclid(360.0);
    let quarter_turn = (tag.rem_euclid(180.0) - 90.0).abs() < 1.0;
    (video_rotation + if quarter_turn { 180.0 } else { 0.0 }).rem_euclid(360.0)
}

/// Gyro clock in ms for a frame at `ts_us` (microseconds from the file start, the same clock as the gyro samples).
/// Gyroflow looks samples up by absolute time and holds the first/last pose outside their range, so a log whose first
/// sample is at t > 0 (a late start, a camera that begins logging after the first frame) needs no shift: the frames
/// before it keep the first pose (no correction), and a sample at t lines up with the frame at pts t.
fn gyro_clock_ms(ts_us: i64, offset_us: i64) -> f64 { (ts_us + offset_us) as f64 / 1000.0 }

/// Overrides the rotation tag read from the file (clockwise degrees, multiples of 90). Takes effect at the next
/// `sqgyro_recompute`; only the horizon lock uses it.
#[unsafe(no_mangle)]
pub extern "C" fn sqgyro_set_rotation(h: *mut Handle, degrees: f64) {
    let Some(h) = (unsafe { h.as_ref() }) else { return };
    if degrees.is_finite() { *h.rotation.write() = (degrees / 90.0).round() * 90.0; }
}

/// A new handle with the same file data (gyro samples, lens profile, sync offsets) and settings, without reading the
/// file again: an option change smooths a copy while the old handle keeps serving frames. Null on failure.
#[unsafe(no_mangle)]
pub extern "C" fn sqgyro_fork(h: *mut Handle) -> *mut Handle {
    let Some(h) = (unsafe { h.as_ref() }) else { return std::ptr::null_mut() };
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mgr = h.mgr.get_cloned();
        // `get_cloned` leaves these out; the shim reads or sets them.
        *mgr.camera_id.write() = h.mgr.camera_id.read().clone();
        {
            let mut s = mgr.stabilization.write();
            s.share_wgpu_instances = false;
            s.interpolation = Interpolation::Lanczos4;
        }
        Handle {
            mgr,
            native_readout: h.native_readout,
            native_offsets: h.native_offsets.clone(),
            settings: RwLock::new(*h.settings.read()),
            generation: AtomicU64::new(0),
            compute: RwLock::new(None),
            planes: Mutex::new(HashMap::new()),
            offset_us: RwLock::new(*h.offset_us.read()),
            rotation: RwLock::new(*h.rotation.read()),
        }
    }));
    match r { Ok(n) => Box::into_raw(Box::new(n)), Err(_) => std::ptr::null_mut() }
}

/// Measuring aid: how far the horizon lock / smoothing turns the picture from the camera's own orientation at `ts_us`,
/// degrees (total angle of the correction). Valid after `sqgyro_recompute`.
#[unsafe(no_mangle)]
pub extern "C" fn sqgyro_correction_angle(h: *mut Handle, ts_us: i64, deg: *mut f64) -> i32 {
    let Some(h) = (unsafe { h.as_ref() }) else { return 0 };
    if deg.is_null() { return 0; }
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let a = gyro_clock_ms(ts_us, *h.offset_us.read());
        h.mgr.gyro.read().smoothed_quat_at_timestamp(a).angle().to_degrees()
    }));
    match r { Ok(v) => { unsafe { *deg = v; } 1 } Err(_) => 0 }
}

/// Smoothing + adaptive zoom over the whole clip with the last options (blocking, CPU; seconds on long clips).
/// Returns 1 on success.
#[unsafe(no_mangle)]
pub extern "C" fn sqgyro_recompute(h: *mut Handle) -> i32 {
    let Some(h) = (unsafe { h.as_ref() }) else { return 0 };
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let s = h.settings.read().unwrap_or(DEFAULT_SETTINGS);
        let m = &h.mgr;
        m.set_fov(s.fov);
        m.set_lens_correction_amount(s.lens_correction);
        let mut offsets = h.native_offsets.clone();
        if s.sync_offset_ms != 0.0 {
            if offsets.is_empty() { offsets.insert(0, 0.0); }
            for v in offsets.values_mut() { *v += s.sync_offset_ms; }
        }
        m.gyro.write().set_offsets(offsets);
        m.keyframes.write().update_gyro(&m.gyro.read());
        m.smoothing.write().current_mut().as_mut().set_parameter("smoothness", (s.smoothness / 100.0).clamp(0.001, 1.0));
        m.set_max_zoom(s.zoom_limit, 5);
        m.set_frame_readout_time(if s.rolling_shutter { h.native_readout } else { 0.0 });
        m.smoothing.write().horizon_lock.set_horizon(s.horizon_lock.clamp(0.0, 100.0), horizon_roll(*h.rotation.read()), false, 0.0, false, 5.0, 500.0, 1.0, f64::INFINITY);
        m.invalidate_smoothing();
        m.recompute_blocking();
        let compute = ComputeParams::from_manager(m);
        *h.compute.write() = Some(Arc::new(compute));
        h.generation.fetch_add(1, SeqCst);
    }));
    if r.is_ok() { 1 } else { 0 }
}

/// Warps one plane of a frame. `ts_us`: the frame's time in the file, µs (frame start, as Gyroflow's plugins pass it:
/// Gyroflow itself centers the rolling-shutter readout on this time, `start = ts - readout / 2`, so no half-readout shift
/// is added here).
/// in/out: CPU memory of the plane (rows of `stride` bytes); `width`/`height` in plane pixels (a CbCr plane of 4:2:0 is
/// half size; a reduced-quality decode may be smaller than the file: both are scaled). `full_range`: Y'CbCr range of
/// the source (for the background colour). Returns 1 on success, 0 when not ready (no recompute yet) or failed.
#[unsafe(no_mangle)]
pub extern "C" fn sqgyro_process_plane(h: *mut Handle, ts_us: i64, kind: u32, width: u32, height: u32,
                                       input: *mut u8, in_stride: usize, output: *mut u8, out_stride: usize, full_range: u8) -> i32 {
    let Some(h) = (unsafe { h.as_ref() }) else { return 0 };
    if input.is_null() || output.is_null() || width < 4 || height < 4 { return 0; }
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        process_impl(h, ts_us, kind, width as usize, height as usize, input, in_stride, output, out_stride, full_range != 0)
    }));
    match r { Ok(true) => 1, _ => 0 }
}

fn process_impl(h: &Handle, ts_us: i64, kind: u32, w: usize, ht: usize, input: *mut u8, in_stride: usize,
                output: *mut u8, out_stride: usize, full_range: bool) -> bool {
    let Some(compute) = h.compute.read().clone() else { return false };
    let generation = h.generation.load(SeqCst);
    let plane = {
        let mut planes = h.planes.lock();
        planes.entry((kind, w, ht, full_range)).or_insert_with(|| Arc::new(Mutex::new(Plane { stab: Stabilization::default(), generation: u64::MAX }))).clone()
    };
    let mut plane = plane.lock();
    let ts = ts_us + *h.offset_us.read();
    let in_buf = unsafe { std::slice::from_raw_parts_mut(input, in_stride * ht) };
    let out_buf = unsafe { std::slice::from_raw_parts_mut(output, out_stride * ht) };
    let mut buffers = Buffers {
        input: BufferDescription { size: (w, ht, in_stride), rect: None, rotation: None, data: BufferSource::Cpu { buffer: in_buf }, texture_copy: false },
        output: BufferDescription { size: (w, ht, out_stride), rect: None, rotation: None, data: BufferSource::Cpu { buffer: out_buf }, texture_copy: false },
    };
    macro_rules! run { ($t:ty, $yuvi:expr, $max:expr) => {{
        if plane.generation != generation {
            let (size, out_size) = { let p = h.mgr.params.read(); (p.size, p.output_size) };
            let mut c = (*compute).clone();
            c.background = <$t as PixelType>::from_rgb_color(c.background, &$yuvi, !full_range);
            let stab = &mut plane.stab;
            stab.interpolation = Interpolation::Lanczos4;
            stab.share_wgpu_instances = false;
            stab.init_size(size, out_size);
            stab.set_compute_params(c);
            plane.generation = generation;
        }
        let stab = &mut plane.stab;
        if stab.initialized_backend.is_none() {
            stab.ensure_ready_for_processing::<$t>(ts, None, &mut buffers);
            stab.stab_data.clear();
        }
        let mut t = stab.get_frame_transform_at::<$t>(ts, None, &buffers);
        t.kernel_params.pixel_value_limit = $max;
        t.kernel_params.max_pixel_value = $max;
        if stab.initialized_backend.is_wgpu() && <$t as PixelType>::wgpu_format().map(|x| x.2).unwrap_or_default() {
            t.kernel_params.pixel_value_limit = 1.0;
            t.kernel_params.max_pixel_value = 1.0;
        }
        t.kernel_params.plane_index = if $yuvi.len() == 2 { 1 } else { 0 };
        stab.process_pixels::<$t>(ts, None, &mut buffers, Some(&t)).is_ok()
    }}}
    match kind {
        SQGYRO_LUMA8 => run!(Luma8, [0usize], 255.0),
        SQGYRO_UV8 => run!(UV8, [1usize, 2], 255.0),
        SQGYRO_LUMA16 => run!(Luma16, [0usize], 65535.0),
        SQGYRO_UV16 => run!(UV16, [1usize, 2], 65535.0),
        SQGYRO_BGRA8 => run!(BGRA8, [] as [usize; 0], 255.0),
        _ => false,
    }
}

/// Measuring aid: how far the camera turns between `ts_us` and `ts_us + dt_us`, in degrees, raw (`raw_deg`, what the
/// unstabilised picture shows) and after smoothing (`smooth_deg`, the residual the stabilised picture keeps). Valid after
/// `sqgyro_recompute`. Returns 1 when known.
#[unsafe(no_mangle)]
pub extern "C" fn sqgyro_motion_step(h: *mut Handle, ts_us: i64, dt_us: i64, raw_deg: *mut f64, smooth_deg: *mut f64) -> i32 {
    let Some(h) = (unsafe { h.as_ref() }) else { return 0 };
    if raw_deg.is_null() || smooth_deg.is_null() { return 0; }
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let gyro = h.mgr.gyro.read();
        let a = gyro_clock_ms(ts_us, *h.offset_us.read());
        let b = a + dt_us as f64 / 1000.0;
        // `smoothed_quaternions` holds the correction (smooth⁻¹ · raw, gyro_source recompute_smoothness), so the
        // smoothed orientation is raw · correction⁻¹.
        let (ra, rb) = (gyro.org_quat_at_timestamp(a), gyro.org_quat_at_timestamp(b));
        let sa = ra * gyro.smoothed_quat_at_timestamp(a).inverse();
        let sb = rb * gyro.smoothed_quat_at_timestamp(b).inverse();
        let raw = ra.inverse() * rb;
        let smooth = sa.inverse() * sb;
        (raw.angle().to_degrees(), smooth.angle().to_degrees())
    }));
    match r {
        Ok((raw, smooth)) => { unsafe { *raw_deg = raw; *smooth_deg = smooth; } 1 }
        Err(_) => 0,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn sqgyro_free(h: *mut Handle) {
    if h.is_null() { return; }
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe { drop(Box::from_raw(h)); }));
}


#[cfg(test)]
mod tests {
    use super::{horizon_roll, gyro_clock_ms};
    use gyroflow_core::StabilizationManager;
    use gyroflow_core::gyro_source::{FileMetadata, Quat64};
    use nalgebra::Vector3;
    use std::collections::BTreeMap;

    // Portrait sign pin: the plugins' formula (Rotation = 360 - tag, + 180 for quarter turns) written out by hand.
    #[test]
    fn horizon_roll_matches_the_plugin_formula() {
        for (tag, plugin) in [(0.0, 0.0), (90.0, (270.0 + 180.0) % 360.0), (180.0, 180.0), (270.0, (90.0 + 180.0) % 360.0)] {
            assert_eq!(horizon_roll(tag), plugin, "tag {tag}");
        }
        // 90 and 270 must stay different (the sign): a portrait clip turned the other way rolls the other way.
        assert_ne!(horizon_roll(90.0), horizon_roll(270.0));
        assert_eq!(horizon_roll(90.0) + horizon_roll(270.0), 360.0);
        assert_eq!(horizon_roll(450.0), 90.0);
    }

    fn manager_with_gyro_from(first_sample_ms: i64) -> StabilizationManager {
        let m = StabilizationManager::default();
        m.init_from_video_data(2000.0, 30.0, 60, (1920, 1080));
        // 10 deg/s about Z, one pose every 10 ms from `first_sample_ms` to 2000 ms; pose(t) = (t - first) * 10 deg/s.
        let mut quats = BTreeMap::new();
        let mut t = first_sample_ms;
        while t <= 2000 {
            let deg = (t - first_sample_ms) as f64 / 1000.0 * 10.0;
            quats.insert(t * 1000, Quat64::from_axis_angle(&Vector3::z_axis(), deg.to_radians()));
            t += 10;
        }
        m.gyro.write().init_from_params(&m.params.read());
        m.gyro.write().load_from_telemetry(FileMetadata { quaternions: quats, ..Default::default() });
        m
    }

    fn angle_deg(m: &StabilizationManager, ts_us: i64) -> f64 {
        m.gyro.read().org_quat_at_timestamp(gyro_clock_ms(ts_us, 0)).angle().to_degrees()
    }

    // First gyro sample at 500 ms: frames before it hold the first pose (no jump, no backwards extrapolation), and the
    // sample at t lines up with the frame at pts t (same clock, no shift by the first sample's time).
    #[test]
    fn late_first_gyro_sample_holds_then_lines_up_with_pts() {
        let m = manager_with_gyro_from(500);
        for ts in [0, 100_000, 499_000, 500_000] { assert!(angle_deg(&m, ts).abs() < 1e-6, "ts {ts}"); }
        assert!((angle_deg(&m, 1_000_000) - 5.0).abs() < 1e-6);
        assert!((angle_deg(&m, 1_500_000) - 10.0).abs() < 1e-6);
        assert!((angle_deg(&m, 3_000_000) - 15.0).abs() < 1e-6, "last pose holds");
    }

    #[test]
    fn gyro_clock_is_absolute_pts() {
        let a = manager_with_gyro_from(0);
        assert!((angle_deg(&a, 500_000) - 5.0).abs() < 1e-6, "got {}", angle_deg(&a, 500_000));
        assert!((gyro_clock_ms(1_500_000, 33_333) - 1533.333).abs() < 1e-9);
    }

    // Quarter turns map to the tag rotation (see `horizon_roll`).
    #[test]
    fn horizon_roll_follows_the_tag() {
        assert_eq!(horizon_roll(0.0), 0.0);
        assert_eq!(horizon_roll(90.0), 90.0);
        assert_eq!(horizon_roll(180.0), 180.0);
        assert_eq!(horizon_roll(270.0), 270.0);
        assert_eq!(horizon_roll(-90.0), 270.0);
    }
}
