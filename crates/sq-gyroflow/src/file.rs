//! `GyroFile`: port of `Vendor/sqgyro/src/lib.rs` without the C ABI.

use gyroflow_core::gpu::{BufferDescription, BufferSource, Buffers};
use gyroflow_core::lens_profile_database::LensProfileDatabase;
use gyroflow_core::stabilization::{
    BGRA8, ComputeParams, Interpolation, Luma8, Luma16, PixelType, Stabilization, UV8, UV16,
};
use gyroflow_core::{StabilizationManager, filesystem};
use parking_lot::{Mutex, RwLock};
use sq_core_masks::stabilize_effect::GyroflowOptions;
use std::collections::{BTreeMap, HashMap};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering::SeqCst};
use std::sync::{Arc, Once, OnceLock};

/// Why a clip could not be opened or smoothed (the text the Analyze row shows).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GyroError(pub String);

impl std::fmt::Display for GyroError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for GyroError {}

/// What `GyroFile::open` found in the clip.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GyroInfo {
    pub width: u32,
    pub height: u32,
    pub fps: f64,
    pub duration_ms: f64,
    pub frame_count: u64,
    /// Rolling-shutter readout time from the lens profile or file, ms (0 = none known).
    pub readout_ms: f64,
    pub has_motion: bool,
    pub has_accurate_timestamps: bool,
    pub camera: String,
    pub lens: String,
}

/// Plane layouts `process_plane` can warp.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PlaneKind {
    /// Y plane, 8 bit.
    Luma8,
    /// Interleaved CbCr plane, 8 bit.
    Uv8,
    /// Y plane, 16 bit (10-bit MSB-aligned).
    Luma16,
    /// Interleaved CbCr plane, 16 bit.
    Uv16,
    /// Packed BGRA, 8 bit.
    Bgra8,
}

/// Plane layout, width, height, full range: one warp state each.
type PlaneKey = (PlaneKind, usize, usize, bool);

struct Plane {
    stab: Stabilization,
    generation: u64,
}

/// One opened clip: the smoothing state of one option set and one warp state per plane layout.
pub struct GyroFile {
    mgr: StabilizationManager,
    native_readout: f64,
    native_offsets: BTreeMap<i64, f64>,
    options: RwLock<GyroflowOptions>,
    generation: AtomicU64,
    compute: RwLock<Option<Arc<ComputeParams>>>,
    planes: Mutex<HashMap<PlaneKey, Arc<Mutex<Plane>>>>,
    offset_us: RwLock<i64>,
    /// Clockwise quarter turn (0/90/180/270) the file's rotation tag shows the frame with; only the horizon lock uses it.
    rotation: RwLock<f64>,
    info: GyroInfo,
}

fn shared_db() -> Arc<RwLock<LensProfileDatabase>> {
    static DB: OnceLock<Arc<RwLock<LensProfileDatabase>>> = OnceLock::new();
    Arc::clone(DB.get_or_init(|| {
        let mut db = LensProfileDatabase::default();
        db.load_all();
        Arc::new(RwLock::new(db))
    }))
}

fn init_once() {
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        let _ = catch_unwind(gyroflow_core::gpu::initialize_contexts);
    });
}

/// `<name>.gcsv` / `.GCSV` next to the clip (the rule of SQAnalysis `GyroDataProbe.sidecar`).
fn sidecar(path: &Path) -> Option<String> {
    ["gcsv", "GCSV"]
        .iter()
        .map(|e| path.with_extension(e))
        .find(|p| p.is_file())
        .and_then(|p| p.to_str().map(String::from))
}

/// Horizon-lock roll for a clip whose rotation tag turns the frame `rotation` degrees clockwise on screen: the plugins'
/// formula (Rotation = 360 - tag, plus 180 for quarter turns), see `Vendor/sqgyro` for the derivation.
pub fn horizon_roll(rotation: f64) -> f64 {
    let tag = rotation.rem_euclid(360.0);
    let video_rotation = (360.0 - tag).rem_euclid(360.0);
    let quarter_turn = (tag.rem_euclid(180.0) - 90.0).abs() < 1.0;
    (video_rotation + if quarter_turn { 180.0 } else { 0.0 }).rem_euclid(360.0)
}

/// Gyro clock in ms for a frame at `ts_us` (microseconds from the file start; absolute, no shift by the first sample).
pub fn gyro_clock_ms(ts_us: i64, offset_us: i64) -> f64 {
    (ts_us + offset_us) as f64 / 1000.0
}

fn err(text: impl Into<String>) -> GyroError {
    GyroError(text.into())
}

impl GyroFile {
    /// Opens a clip and reads its gyro data and lens profile (blocking; parses the whole file's telemetry).
    pub fn open(path: &Path) -> Result<GyroFile, GyroError> {
        catch_unwind(AssertUnwindSafe(|| open_impl(path)))
            .unwrap_or_else(|_| Err(err("gyroflow_core panicked while opening the file")))
    }

    pub fn info(&self) -> &GyroInfo {
        &self.info
    }

    /// Takes effect at the next `recompute`.
    pub fn set_options(&self, options: GyroflowOptions) {
        *self.options.write() = options;
    }

    /// Overrides the file's rotation tag (clockwise degrees, multiples of 90). Takes effect at the next `recompute`.
    pub fn set_rotation(&self, degrees: f64) {
        if degrees.is_finite() {
            *self.rotation.write() = (degrees / 90.0).round() * 90.0;
        }
    }

    /// A copy with the same file data and options, without reading the file again.
    pub fn fork(&self) -> Result<GyroFile, GyroError> {
        catch_unwind(AssertUnwindSafe(|| {
            let mgr = self.mgr.get_cloned();
            *mgr.camera_id.write() = self.mgr.camera_id.read().clone();
            {
                let mut s = mgr.stabilization.write();
                s.share_wgpu_instances = false;
                s.interpolation = Interpolation::Lanczos4;
            }
            GyroFile {
                mgr,
                native_readout: self.native_readout,
                native_offsets: self.native_offsets.clone(),
                options: RwLock::new(*self.options.read()),
                generation: AtomicU64::new(0),
                compute: RwLock::new(None),
                planes: Mutex::new(HashMap::new()),
                offset_us: RwLock::new(*self.offset_us.read()),
                rotation: RwLock::new(*self.rotation.read()),
                info: self.info.clone(),
            }
        }))
        .map_err(|_| err("gyroflow_core panicked while copying the clip"))
    }

    /// How far the horizon lock and smoothing turn the picture from the camera's own orientation at `ts_us`, degrees.
    pub fn correction_angle(&self, ts_us: i64) -> Option<f64> {
        let a = gyro_clock_ms(ts_us, *self.offset_us.read());
        catch_unwind(AssertUnwindSafe(|| self.mgr.gyro.read().smoothed_quat_at_timestamp(a).angle().to_degrees())).ok()
    }

    /// Camera rotation between `ts_us` and `ts_us + dt_us` in degrees: raw and after smoothing (the residual).
    pub fn motion_step(&self, ts_us: i64, dt_us: i64) -> Option<(f64, f64)> {
        catch_unwind(AssertUnwindSafe(|| {
            let gyro = self.mgr.gyro.read();
            let a = gyro_clock_ms(ts_us, *self.offset_us.read());
            let b = a + dt_us as f64 / 1000.0;
            let (ra, rb) = (gyro.org_quat_at_timestamp(a), gyro.org_quat_at_timestamp(b));
            let sa = ra * gyro.smoothed_quat_at_timestamp(a).inverse();
            let sb = rb * gyro.smoothed_quat_at_timestamp(b).inverse();
            ((ra.inverse() * rb).angle().to_degrees(), (sa.inverse() * sb).angle().to_degrees())
        }))
        .ok()
    }

    /// Smoothing and adaptive zoom over the whole clip with the current options (blocking, CPU; seconds on long clips).
    pub fn recompute(&self) -> Result<(), GyroError> {
        catch_unwind(AssertUnwindSafe(|| {
            let o = *self.options.read();
            let m = &self.mgr;
            m.set_fov((o.field_of_view / 100.0).clamp(0.1, 3.0));
            m.set_lens_correction_amount((o.lens_correction / 100.0).clamp(0.0, 1.0));
            let mut offsets = self.native_offsets.clone();
            if o.sync_offset_ms != 0.0 && o.sync_offset_ms.is_finite() {
                if offsets.is_empty() {
                    offsets.insert(0, 0.0);
                }
                for v in offsets.values_mut() {
                    *v += o.sync_offset_ms;
                }
            }
            m.gyro.write().set_offsets(offsets);
            m.keyframes.write().update_gyro(&m.gyro.read());
            m.smoothing
                .write()
                .current_mut()
                .as_mut()
                .set_parameter("smoothness", (o.smoothness / 100.0).clamp(0.001, 1.0));
            m.set_max_zoom(o.zoom_limit, 5);
            m.set_frame_readout_time(if o.rolling_shutter { self.native_readout } else { 0.0 });
            let roll = horizon_roll(*self.rotation.read());
            m.smoothing.write().horizon_lock.set_horizon(
                o.horizon_lock.clamp(0.0, 100.0),
                roll,
                false,
                0.0,
                false,
                5.0,
                500.0,
                1.0,
                f64::INFINITY,
            );
            m.invalidate_smoothing();
            m.recompute_blocking();
            *self.compute.write() = Some(Arc::new(ComputeParams::from_manager(m)));
            self.generation.fetch_add(1, SeqCst);
        }))
        .map_err(|_| err("gyroflow_core panicked while smoothing"))
    }

    /// Warps one plane of a frame (`ts_us` = the frame's start in the file). Rows are `stride` bytes; `width` and `height`
    /// are plane pixels (a reduced-quality decode may be smaller than the file: both are scaled). `false` when not
    /// smoothed yet or the warp failed.
    #[allow(clippy::too_many_arguments)] // the libsqgyro call, one argument per field of a plane
    pub fn process_plane(
        &self,
        ts_us: i64,
        kind: PlaneKind,
        (width, height): (usize, usize),
        input: &mut [u8],
        in_stride: usize,
        output: &mut [u8],
        out_stride: usize,
        full_range: bool,
    ) -> bool {
        if width < 4 || height < 4 || input.len() < in_stride * height || output.len() < out_stride * height {
            return false;
        }
        catch_unwind(AssertUnwindSafe(|| {
            self.process_impl(ts_us, kind, (width, height), input, in_stride, output, out_stride, full_range)
        }))
        .unwrap_or(false)
    }

    #[allow(clippy::too_many_arguments)]
    fn process_impl(
        &self,
        ts_us: i64,
        kind: PlaneKind,
        (w, ht): (usize, usize),
        input: &mut [u8],
        in_stride: usize,
        output: &mut [u8],
        out_stride: usize,
        full_range: bool,
    ) -> bool {
        let Some(compute) = self.compute.read().clone() else { return false };
        let generation = self.generation.load(SeqCst);
        let plane = {
            let mut planes = self.planes.lock();
            Arc::clone(planes.entry((kind, w, ht, full_range)).or_insert_with(|| {
                Arc::new(Mutex::new(Plane { stab: Stabilization::default(), generation: u64::MAX }))
            }))
        };
        let mut plane = plane.lock();
        let ts = ts_us + *self.offset_us.read();
        let mut buffers = Buffers {
            input: BufferDescription {
                size: (w, ht, in_stride),
                rect: None,
                rotation: None,
                data: BufferSource::Cpu { buffer: input },
                texture_copy: false,
            },
            output: BufferDescription {
                size: (w, ht, out_stride),
                rect: None,
                rotation: None,
                data: BufferSource::Cpu { buffer: output },
                texture_copy: false,
            },
        };
        macro_rules! run {
            ($t:ty, $yuvi:expr, $max:expr) => {{
                if plane.generation != generation {
                    let (size, out_size) = {
                        let p = self.mgr.params.read();
                        (p.size, p.output_size)
                    };
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
                if stab.initialized_backend.is_wgpu()
                    && <$t as PixelType>::wgpu_format().map(|x| x.2).unwrap_or_default()
                {
                    t.kernel_params.pixel_value_limit = 1.0;
                    t.kernel_params.max_pixel_value = 1.0;
                }
                t.kernel_params.plane_index = if $yuvi.len() == 2 { 1 } else { 0 };
                stab.process_pixels::<$t>(ts, None, &mut buffers, Some(&t)).is_ok()
            }};
        }
        match kind {
            PlaneKind::Luma8 => run!(Luma8, [0usize], 255.0),
            PlaneKind::Uv8 => run!(UV8, [1usize, 2], 255.0),
            PlaneKind::Luma16 => run!(Luma16, [0usize], 65535.0),
            PlaneKind::Uv16 => run!(UV16, [1usize, 2], 65535.0),
            PlaneKind::Bgra8 => run!(BGRA8, [] as [usize; 0], 255.0),
        }
    }
}

fn open_impl(path: &Path) -> Result<GyroFile, GyroError> {
    init_once();
    let path_text = path.to_str().ok_or_else(|| err("the path is not text"))?;
    let mgr = StabilizationManager { lens_profile_db: shared_db(), ..StabilizationManager::default() };
    {
        let mut s = mgr.stabilization.write();
        s.share_wgpu_instances = false;
        s.interpolation = Interpolation::Lanczos4;
    }
    let url = filesystem::path_to_url(path_text);
    let mut file = filesystem::open_file(&url, false, false).map_err(|e| err(format!("cannot open file: {e:?}")))?;
    let size = file.size;
    let meta = mgr
        .load_video_file(file.get_file(), size, &url, None, true)
        .map_err(|e| err(format!("cannot read file: {e:?}")))?;
    drop(file);
    let rotation = (f64::from(meta.rotation.rem_euclid(360)) / 90.0).round() * 90.0 % 360.0;
    let (w, h, dur) = {
        let p = mgr.params.read();
        (p.size.0, p.size.1, p.duration_ms)
    };
    if w == 0 || h == 0 || dur <= 0.0 {
        return Err(err("no video track"));
    }
    // A Gyroflow CSV log next to the clip wins over (or stands in for) the file's own metadata.
    if let Some(gcsv) = sidecar(path) {
        let gurl = filesystem::path_to_url(&gcsv);
        let mut gf =
            filesystem::open_file(&gurl, false, false).map_err(|e| err(format!("cannot open gyro log: {e:?}")))?;
        let gsize = gf.size;
        mgr.load_gyro_data(
            gf.get_file(),
            gsize,
            &gurl,
            true,
            &Default::default(),
            |_| (),
            Arc::new(std::sync::atomic::AtomicBool::new(false)),
        )
        .map_err(|e| err(format!("cannot read gyro log: {e:?}")))?;
    }
    if !mgr.gyro.read().has_motion() {
        return Err(err("No gyro data in this file."));
    }
    // Output = input size: the clip keeps its frame; the adaptive zoom fills it.
    mgr.set_size(w, h);
    mgr.set_output_size(w, h);
    mgr.set_background_color(nalgebra::Vector4::new(0.0, 0.0, 0.0, 1.0));
    let native_readout = mgr.params.read().frame_readout_time;
    let native_offsets = mgr.gyro.read().get_offsets().clone();
    let offset_us = {
        let p = mgr.params.read();
        (p.frame_offset as f64 / p.fps * 1_000_000.0).round() as i64
    };
    let p = mgr.params.read();
    let camera = mgr
        .camera_id
        .read()
        .as_ref()
        .map(|c| format!("{} {}", c.brand, c.model).trim().to_string())
        .unwrap_or_default();
    let info = GyroInfo {
        width: w as u32,
        height: h as u32,
        fps: p.fps,
        duration_ms: p.duration_ms,
        frame_count: p.frame_count as u64,
        readout_ms: native_readout,
        has_motion: true,
        has_accurate_timestamps: mgr.gyro.read().file_metadata.read().has_accurate_timestamps,
        camera,
        lens: mgr.lens.read().get_display_name(),
    };
    drop(p);
    Ok(GyroFile {
        mgr,
        native_readout,
        native_offsets,
        options: RwLock::new(GyroflowOptions::default()),
        generation: AtomicU64::new(0),
        compute: RwLock::new(None),
        planes: Mutex::new(HashMap::new()),
        offset_us: RwLock::new(offset_us),
        rotation: RwLock::new(rotation),
        info,
    })
}

/// Full scale of the probe planes (16-bit). Below 65535 so that filter overshoot never clips.
const ENCODE_SCALE: f32 = 60000.0;
/// The map's long side stays near 480 texels (a quarter up to 1920 wide; 4K gets 480x270).
const MAP_LONG_SIDE: usize = 480;
/// Refill passes: each extends the clean map by one texel. The probe filter spoils 4 texels on each side of the picture
/// border; 10 reach past it, and anything further out is background anyway.
const FILL_PASSES: usize = 10;

/// Size of the warp map for a frame: a quarter per side or larger so the long side stays near 480; at least 16.
pub fn warp_map_size(frame_width: usize, frame_height: usize) -> (usize, usize) {
    let divisor = 4.max(frame_width.max(frame_height).div_ceil(MAP_LONG_SIDE));
    (16.max(frame_width.div_ceil(divisor)), 16.max(frame_height.div_ceil(divisor)))
}

/// Probe planes: `xy` interleaved x and y ramps (the 2-channel CbCr layout), `coverage` a constant at full scale.
fn probe_planes(width: usize, height: usize) -> (Vec<u16>, Vec<u16>) {
    let sx = ENCODE_SCALE / (width.max(2) - 1) as f32;
    let sy = ENCODE_SCALE / (height.max(2) - 1) as f32;
    let mut xy = vec![0u16; width * height * 2];
    for j in 0..height {
        let vy = (j as f32 * sy).round() as u16;
        for i in 0..width {
            xy[2 * (j * width + i)] = (i as f32 * sx).round() as u16;
            xy[2 * (j * width + i) + 1] = vy;
        }
    }
    (xy, vec![ENCODE_SCALE as u16; width * height])
}

/// The warped probes to a map: a texel is clean when the probe filter's weights all fell inside the picture (coverage at
/// full scale); the others take the mean of the straight-line extrapolations (2*p1 - p2) along the 8 directions with two
/// clean texels (`FILL_PASSES` times). Mirrors the Swift/Metal `sq_gyro_map_decode` and `sq_gyro_map_fill`.
pub fn decode_map(width: usize, height: usize, xy: &[u16], coverage: &[u16]) -> sq_render::program::WarpMap {
    let k = [(width - 1) as f32 / width as f32 / ENCODE_SCALE, (height - 1) as f32 / height as f32 / ENCODE_SCALE];
    let mut map: Vec<[f32; 4]> = (0..width * height)
        .map(|i| {
            if (f32::from(coverage[i]) - ENCODE_SCALE).abs() <= 2.0 {
                [f32::from(xy[2 * i]) * k[0], f32::from(xy[2 * i + 1]) * k[1], 1.0, 0.0]
            } else {
                [0.0; 4]
            }
        })
        .collect();
    const DIRS: [(i64, i64); 8] = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)];
    for _ in 0..FILL_PASSES {
        let src = map.clone();
        for y in 0..height as i64 {
            for x in 0..width as i64 {
                let here = src[y as usize * width + x as usize];
                if here[2] > 0.5 {
                    continue;
                }
                let (mut sum, mut count) = ([0.0f32; 2], 0.0f32);
                for (dx, dy) in DIRS {
                    let (ax, ay, bx, by) = (x + dx, y + dy, x + 2 * dx, y + 2 * dy);
                    let inside = |a: i64, b: i64| a >= 0 && b >= 0 && a < width as i64 && b < height as i64;
                    if !inside(ax, ay) || !inside(bx, by) {
                        continue;
                    }
                    let (pa, pb) = (src[ay as usize * width + ax as usize], src[by as usize * width + bx as usize]);
                    if pa[2] > 0.5 && pb[2] > 0.5 {
                        sum[0] += 2.0 * pa[0] - pb[0];
                        sum[1] += 2.0 * pa[1] - pb[1];
                        count += 1.0;
                    }
                }
                if count > 0.0 {
                    map[y as usize * width + x as usize] = [sum[0] / count, sum[1] / count, 1.0, 0.0];
                }
            }
        }
    }
    sq_render::program::WarpMap { width: width as u32, height: height as u32, texels: map }
}

impl GyroFile {
    /// The warp map of the frame at `ts_us`: two probe warps (an x/y ramp and a constant) at the map size, through the same
    /// gyroflow_core path as `process_plane`. Whatever gyroflow_core does (lens model, rolling shutter, adaptive zoom, horizon
    /// lock) is in the map. `None` when not smoothed yet or a warp failed.
    pub fn warp_map(&self, ts_us: i64) -> Option<sq_render::program::WarpMap> {
        let (fw, fh) = (self.info.width as usize, self.info.height as usize);
        let (mw, mh) = warp_map_size(fw.max(1), fh.max(1));
        let (xy, cov) = probe_planes(mw, mh);
        let le = |v: &[u16]| -> Vec<u8> { v.iter().flat_map(|x| x.to_le_bytes()).collect() };
        let (mut xy_in, mut cov_in) = (le(&xy), le(&cov));
        let (mut xy_out, mut cov_out) = (vec![0u8; mw * mh * 4], vec![0u8; mw * mh * 2]);
        // Full range: the 1-channel probe's background is 0, so a filter reaching outside the picture shows.
        let ok = self.process_plane(ts_us, PlaneKind::Uv16, (mw, mh), &mut xy_in, mw * 4, &mut xy_out, mw * 4, true)
            && self.process_plane(ts_us, PlaneKind::Luma16, (mw, mh), &mut cov_in, mw * 2, &mut cov_out, mw * 2, true);
        let words = |v: &[u8]| -> Vec<u16> { v.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect() };
        ok.then(|| decode_map(mw, mh, &words(&xy_out), &words(&cov_out)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gyroflow_core::gyro_source::{FileMetadata, Quat64};
    use nalgebra::Vector3;

    #[test]
    fn horizon_roll_matches_the_plugin_formula() {
        for (tag, plugin) in [(0.0, 0.0), (90.0, 90.0), (180.0, 180.0), (270.0, 270.0)] {
            assert_eq!(horizon_roll(tag), plugin, "tag {tag}");
        }
        assert_ne!(horizon_roll(90.0), horizon_roll(270.0));
        assert_eq!(horizon_roll(450.0), 90.0);
        assert_eq!(horizon_roll(-90.0), 270.0);
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

    /// First gyro sample at 500 ms: earlier frames hold the first pose, and the sample at t lines up with the frame at pts t.
    #[test]
    fn late_first_gyro_sample_holds_then_lines_up_with_pts() {
        let m = manager_with_gyro_from(500);
        for ts in [0, 100_000, 499_000, 500_000] {
            assert!(angle_deg(&m, ts).abs() < 1e-6, "ts {ts}");
        }
        assert!((angle_deg(&m, 1_000_000) - 5.0).abs() < 1e-6);
        assert!((angle_deg(&m, 3_000_000) - 15.0).abs() < 1e-6, "last pose holds");
    }

    #[test]
    fn gyro_clock_is_absolute_pts() {
        let a = manager_with_gyro_from(0);
        assert!((angle_deg(&a, 500_000) - 5.0).abs() < 1e-6);
        assert!((gyro_clock_ms(1_500_000, 33_333) - 1533.333).abs() < 1e-9);
    }

    #[test]
    fn a_clip_without_gyro_data_is_refused_with_a_reason() {
        let Some(e) = GyroFile::open(Path::new("definitely-missing.mp4")).err() else { panic!("opened") };
        assert!(!e.0.is_empty());
    }

    /// A synthetic clip (ffmpeg testsrc) with a `.gcsv` sidecar of a shaky camera: open reads the sidecar, `recompute`
    /// smooths, and a luma plane is warped (the picture moves where the camera shook, the corners fill from the zoom).
    #[test]
    fn a_clip_with_a_gcsv_sidecar_opens_smooths_and_warps_a_plane() {
        let dir = std::env::temp_dir().join(format!("sq-gyro-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let clip = dir.join("shaky.mp4");
        let made = std::process::Command::new("ffmpeg")
            .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=d=2:s=320x180:r=30", "-c:v", "mpeg4"])
            .arg(&clip)
            .stdin(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if !made {
            return; // no ffmpeg on this machine
        }
        // Gyroflow CSV: z rotation oscillating +-0.5 rad/s, 1 kHz, raw units scaled by gscale.
        let mut csv = String::from(
            "GYROFLOW IMU LOG\nversion,1.1\nid,sqtest\ntscale,0.001\ngscale,0.001\nascale,0.001\nt,gx,gy,gz,ax,ay,az\n",
        );
        for t in 0..2000 {
            let gz = (500.0 * (f64::from(t) * 0.02).sin()).round();
            csv.push_str(&format!("{t},0,0,{gz},0,0,1000\n"));
        }
        std::fs::write(dir.join("shaky.gcsv"), csv).expect("sidecar");
        let file = match GyroFile::open(&clip) {
            Ok(f) => f,
            Err(e) => panic!("open: {e}"),
        };
        assert_eq!((file.info().width, file.info().height), (320, 180));
        assert!(file.info().has_motion);
        file.set_options(GyroflowOptions { smoothness: 100.0, ..GyroflowOptions::default() });
        let mut input: Vec<u8> = (0..320 * 180).map(|i| ((i % 320) * 255 / 320) as u8).collect();
        let mut output = vec![0u8; 320 * 180];
        assert!(
            !file.process_plane(500_000, PlaneKind::Luma8, (320, 180), &mut input, 320, &mut output, 320, false),
            "not smoothed yet"
        );
        file.recompute().expect("recompute");
        let angle = file.correction_angle(500_000).expect("angle");
        assert!(angle.is_finite());
        let ok = file.process_plane(500_000, PlaneKind::Luma8, (320, 180), &mut input, 320, &mut output, 320, false);
        assert!(ok, "the plane is warped");
        assert!(output.iter().any(|v| *v > 0), "the warped picture is not empty");
        let (raw, smooth) = file.motion_step(500_000, 33_000).expect("step");
        assert!(smooth <= raw + 1e-9, "smoothing keeps less motion than the camera had: raw {raw} smooth {smooth}");
        let _ = std::fs::remove_dir_all(dir);
    }
}
