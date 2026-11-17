//! The Stabilizer analysis of a clip's media: FFmpeg frames are shrunk to 256 px, registered pair by pair with the ported
//! photometric registration and the motions go into the [`StabilizationStore`]; finished runs are kept on disk under the
//! support folder, so the next launch does not measure again.
// The Swift Mac app also registers with Vision where the feature tracker and the photometric registration are weak; here
// that second fallback is `vision_motion` (sq-platform-vision: Apple Vision on the Mac, no match on Windows and Linux).

use super::ffmpeg_frames::{DecodedPicture, FfmpegFrameReader};
use super::magic_job::WakeFn;
use super::stabilization_store::StabilizationStore;
use sq_analysis::analysis_turn::{CancelToken, Cancelled};
use sq_analysis::feature_tracker::{FeaturePyramid, FeatureTracker};
use sq_analysis::registration_math::Registration;
use sq_analysis::rolling_shutter_measure::RollingShutterMeasure;
use sq_analysis::stabilization_analyzing::{Progress, StabilizationAnalyzing, StabilizationError};
use sq_analysis::stabilization_check::{GrayFrame, PhotometricRegistration};
use sq_core_masks::rolling_shutter::RollingShutterSample;
use sq_core_masks::stabilization_cuts::StabilizationCuts;
use sq_core_masks::stabilizer::{CameraMotion, StabilizationAnalysis};
use sq_core_masks::stabilizer_perspective::PerspectiveResidual;
use sq_core_time::{Time, TimeRange};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::{Receiver, channel};

/// Long side of the pictures the motion is measured on (the size `MIN_TEXTURE` was calibrated at).
const MEASURE_SIDE: usize = 256;
const LEVELS: usize = 4;
/// Mean gray difference left after the alignment above which a pair is a cut, not a camera move.
const CUT_RESIDUAL: f64 = 40.0;

/// `g` turned clockwise by `quarter_turns` quarter turns (the picture upright, see `SubjectFrame::upright`).
fn rotate_gray(g: &GrayFrame, quarter_turns: i64) -> GrayFrame {
    let q = quarter_turns.rem_euclid(4);
    if q == 0 {
        return g.clone();
    }
    let (w, h) = (g.width, g.height);
    let (nw, nh) = if q == 2 { (w, h) } else { (h, w) };
    let mut out = vec![0.0_f32; g.pixels.len()];
    for y in 0..h {
        for x in 0..w {
            let (dx, dy) = match q {
                1 => (h - 1 - y, x),
                2 => (w - 1 - x, h - 1 - y),
                _ => (y, w - 1 - x),
            };
            out[dy * nw + dx] = g.pixels[y * w + x];
        }
    }
    GrayFrame::new(nw, nh, out)
}

fn gray(p: &DecodedPicture) -> GrayFrame {
    let px = p
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .map(|c| 0.299 * f32::from(c[0]) + 0.587 * f32::from(c[1]) + 0.114 * f32::from(c[2]));
    GrayFrame::new(p.width, p.height, px.collect())
}

/// Confidence of a frame whose motion only Vision found (the feature tracker and the photometric registration were weak).
// shortcut: a fixed 0.5, not a measure of Vision's own certainty (it reports none); revisit with real footage numbers.
const VISION_CONFIDENCE: f64 = 0.5;

/// 8-bit gray of a measuring frame.
fn gray8(g: &GrayFrame) -> Vec<u8> {
    g.pixels.iter().map(|v| v.round().clamp(0.0, 255.0) as u8).collect()
}

/// The second fallback (Swift `Registration.matched`): Vision's homography, then its translation, between two measuring
/// frames; `None` off the Mac, for a pair Vision cannot match and for a motion no camera makes.
fn vision_motion(previous: &GrayFrame, current: &GrayFrame) -> Option<CameraMotion> {
    if (previous.width, previous.height) != (current.width, current.height) {
        return None;
    }
    let (p, c) = (gray8(previous), gray8(current));
    let frame = |pixels| sq_platform_vision::Gray8 { width: current.width, height: current.height, pixels };
    sq_platform_vision::registered_motion(frame(&p), frame(&c))
}

/// Measures `count` frames like the Mac pass: tracked features first (robust to moving subjects), the photometric
/// registration for frames the tracker calls weak, and always as the check, the rolling-shutter sample and the cut scores.
/// `picture(i)` gives frame i as a gray picture and its time. Pairs that cannot be registered restart the path (a cut); a
/// flat picture keeps the identity with confidence 0, so the plan borrows its neighbors.
#[cfg(test)]
pub fn analyze_frames(
    count: usize,
    picture: &mut dyn FnMut(usize) -> Option<(Time, GrayFrame)>,
    picture_size: (i64, i64),
    progress: Progress<'_>,
    cancel: &CancelToken,
) -> Result<StabilizationAnalysis, StabilizationError> {
    analyze_frames_turned(count, picture, picture_size, 0, progress, cancel)
}

/// [`analyze_frames`] for pictures already turned upright by `quarter_turns` (Swift `pass.quarterTurns`): the rolling
/// shutter scans along x for an odd count, and the analysis keeps the count for the plan.
pub fn analyze_frames_turned(
    count: usize,
    picture: &mut dyn FnMut(usize) -> Option<(Time, GrayFrame)>,
    picture_size: (i64, i64),
    quarter_turns: i64,
    progress: Progress<'_>,
    cancel: &CancelToken,
) -> Result<StabilizationAnalysis, StabilizationError> {
    let scans_along_x = quarter_turns.rem_euclid(4) % 2 != 0;
    let mut times = Vec::with_capacity(count);
    let mut motions = Vec::with_capacity(count);
    let mut confidence = Vec::with_capacity(count);
    let mut checks: Vec<Option<CameraMotion>> = Vec::with_capacity(count);
    let mut rolling: Vec<Option<RollingShutterSample>> = Vec::with_capacity(count);
    let mut perspective: Vec<PerspectiveResidual> = Vec::with_capacity(count);
    let mut histogram_jumps = Vec::with_capacity(count);
    let mut residuals = Vec::with_capacity(count);
    let mut cuts = Vec::new();
    let mut previous: Option<(GrayFrame, FeaturePyramid, Vec<f32>)> = None;
    for i in 0..count {
        cancel.check().map_err(|Cancelled| StabilizationError::Cancelled)?;
        let (t, g) = picture(i).ok_or(StabilizationError::Unreadable)?;
        times.push(t);
        let pyramid = FeaturePyramid::new(g.clone());
        let hist = g.quadrant_histograms();
        let (fx, fy) = (picture_size.0 as f64 / g.width as f64, picture_size.1 as f64 / g.height as f64);
        let mut residual = PerspectiveResidual::ZERO;
        let motion = match &previous {
            None => {
                checks.push(None);
                rolling.push(None);
                residuals.push(0.0);
                histogram_jumps.push(0.0);
                confidence.push(1.0);
                CameraMotion::IDENTITY
            }
            Some((pg, pp, ph)) => {
                let step = PhotometricRegistration::register(pg, &g, LEVELS);
                let usable = step.filter(|m| m.converged && m.texture >= PhotometricRegistration::MIN_TEXTURE);
                let in_source = usable.map(|m| Registration::scaled_xy(&m.motion, fx, fy));
                checks.push(in_source);
                // Always measured, so switching Rolling Shutter on later needs no second analysis.
                rolling
                    .push(usable.and_then(|u| RollingShutterMeasure::sample(pg, &g, &u.motion, scans_along_x, fx, fy)));
                residuals.push(step.map_or(f64::NAN, |m| m.residual));
                histogram_jumps.push(GrayFrame::histogram_distance(ph, &hist));
                if let Some(fm) = FeatureTracker::register(pp, &pyramid) {
                    confidence.push(fm.confidence());
                    residual = fm.residual.map_or(PerspectiveResidual::ZERO, |r| r.scaled(fx, fy));
                    Registration::scaled_xy(&fm.motion, fx, fy)
                } else {
                    match step {
                        // Nothing registered: Vision may still match the pair (not a cut then), else it is one.
                        None => match vision_motion(pg, &g) {
                            Some(m) => {
                                confidence.push(VISION_CONFIDENCE);
                                Registration::scaled_xy(&m, fx, fy)
                            }
                            None => {
                                cuts.push(i);
                                confidence.push(0.0);
                                CameraMotion::IDENTITY
                            }
                        },
                        Some(m) if m.residual > CUT_RESIDUAL => {
                            cuts.push(i);
                            confidence.push(0.0);
                            CameraMotion::IDENTITY
                        }
                        Some(m) if !m.converged || m.texture < PhotometricRegistration::MIN_TEXTURE => {
                            match vision_motion(pg, &g) {
                                Some(v) => {
                                    confidence.push(VISION_CONFIDENCE);
                                    Registration::scaled_xy(&v, fx, fy)
                                }
                                None => {
                                    confidence.push(0.0);
                                    CameraMotion::IDENTITY
                                }
                            }
                        }
                        Some(m) => {
                            confidence.push(m.coherence.clamp(0.0, 1.0));
                            Registration::scaled_xy(&m.motion, fx, fy)
                        }
                    }
                }
            }
        };
        motions.push(motion);
        perspective.push(residual);
        previous = Some((g, pyramid, hist));
        if let Some(report) = progress {
            report((i + 1) as f64 / count as f64);
        }
    }
    // Cuts: "no match" plus the change scores (a registration also "matches" across many cuts).
    let detected = StabilizationCuts::detect(&motions, &histogram_jumps, &residuals, &checks, &confidence);
    cuts.extend(detected);
    cuts.sort_unstable();
    cuts.dedup();
    let mut out = StabilizationAnalysis::new(picture_size.0, picture_size.1, times, motions);
    out.cuts = cuts;
    out.confidence = confidence;
    out.checks = checks;
    out.rolling = rolling;
    out.rolling_scan = quarter_turns.rem_euclid(4);
    if perspective.iter().any(|p| !p.is_zero()) {
        out.perspective = perspective;
    }
    Ok(out)
}

/// [`StabilizationAnalyzing`] over a video file.
pub struct FfmpegStabilizationAnalyzer {
    path: PathBuf,
}

impl FfmpegStabilizationAnalyzer {
    /// An analyzer for the media file at `path`.
    pub fn new(path: &Path) -> FfmpegStabilizationAnalyzer {
        FfmpegStabilizationAnalyzer { path: path.to_path_buf() }
    }
}

impl StabilizationAnalyzing for FfmpegStabilizationAnalyzer {
    fn analyze(
        &self,
        source_range: TimeRange,
        picture_width: i64,
        picture_height: i64,
        progress: Progress<'_>,
        cancel: &CancelToken,
    ) -> Result<StabilizationAnalysis, StabilizationError> {
        let reader = FfmpegFrameReader::open(&self.path).map_err(|_| StabilizationError::Unreadable)?;
        let first = reader.index_at(source_range.start).unwrap_or(0);
        let last = reader
            .index_at(source_range.end() - Time::new(1, 1_000_000))
            .unwrap_or(reader.count().saturating_sub(1))
            .max(first);
        if reader.count() == 0 {
            return Err(StabilizationError::NoVideoTrack);
        }
        // `picture_width/height` are the upright size (display size); a clip stored sideways is turned upright first, as
        // Swift does with the track's preferred transform, so x and y motion are the picture's.
        let turns = reader.rotation().div_euclid(90).rem_euclid(4);
        let mut read =
            |i: usize| reader.picture(first + i, MEASURE_SIDE).map(|p| (p.pts, rotate_gray(&gray(&p), turns)));
        analyze_frames_turned(last - first + 1, &mut read, (picture_width, picture_height), turns, progress, cancel)
    }
}

/// The key a result is stored under: the file, its size and its modification time.
pub fn cache_name(path: &Path) -> Option<String> {
    let meta = std::fs::metadata(path).ok()?;
    let modified = meta.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();
    let mut h: u64 = 0xcbf29ce484222325;
    for b in path.to_string_lossy().bytes().chain(meta.len().to_le_bytes()).chain(modified.to_le_bytes()) {
        h = (h ^ u64::from(b)).wrapping_mul(0x100000001b3);
    }
    Some(format!("{h:016x}.json"))
}

/// The disk cache holds at most this much (Swift `StabilizationCache.limitBytes`).
pub const CACHE_LIMIT_BYTES: i64 = 200 << 20;

/// Deletes the least recently used `.json` files of `dir` until the folder fits `limit` bytes (Swift
/// `StabilizationCache.prune`: last use is the modification time, which a read refreshes).
pub(crate) fn prune_cache(dir: &Path, limit: i64) {
    use sq_core_project::cache_disk_policy::{CacheDiskPolicy, CacheEntry};
    let Ok(files) = std::fs::read_dir(dir) else { return };
    let entries: Vec<CacheEntry> = files
        .flatten()
        .filter(|f| f.path().extension().is_some_and(|e| e == "json"))
        .filter_map(|f| {
            let meta = f.metadata().ok()?;
            let used = meta.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64();
            Some(CacheEntry {
                id: f.file_name().to_string_lossy().into_owned(),
                bytes: i64::try_from(meta.len()).unwrap_or(i64::MAX),
                last_use: sq_core_time::Timestamp::from_unix_seconds(used),
            })
        })
        .collect();
    for id in CacheDiskPolicy::eviction_plan(&entries, limit, &std::collections::BTreeSet::new()) {
        let _ = std::fs::remove_file(dir.join(id));
    }
}

/// A read marks the file as just used, so the next prune keeps it.
fn touch(file: &Path) {
    if let Ok(f) = std::fs::OpenOptions::new().write(true).open(file) {
        let _ = f.set_modified(std::time::SystemTime::now());
    }
}

fn save_analysis(file: &Path, range: TimeRange, a: &StabilizationAnalysis) -> Option<()> {
    use serde_json::json;
    let pair = |t: Time| json!([t.value(), t.timescale()]);
    let body = json!({
        "version": a.version, "width": a.picture_width, "height": a.picture_height,
        "start": pair(range.start), "duration": pair(range.duration),
        "times": a.frame_times.iter().map(|t| pair(*t)).collect::<Vec<_>>(),
        "motions": a.motions.iter().map(|m| json!([m.dx, m.dy, m.rotation, m.scale])).collect::<Vec<_>>(),
        "cuts": a.cuts, "confidence": a.confidence,
        "checks": a.checks.iter().map(|c| c.map(|m| json!([m.dx, m.dy, m.rotation, m.scale]))).collect::<Vec<_>>(),
        "rolling": a.rolling.iter().map(|r| r.map(|r| json!([r.shift_x, r.shift_y, r.slope_x, r.slope_y]))).collect::<Vec<_>>(),
        "perspective": a.perspective.iter().map(|p| json!(p.values)).collect::<Vec<_>>(),
    });
    std::fs::create_dir_all(file.parent()?).ok()?;
    std::fs::write(file, body.to_string()).ok()
}

pub(crate) fn load_analysis(file: &Path) -> Option<(TimeRange, StabilizationAnalysis)> {
    let loaded = read_analysis(file)?;
    touch(file);
    Some(loaded)
}

fn read_analysis(file: &Path) -> Option<(TimeRange, StabilizationAnalysis)> {
    let v: serde_json::Value = serde_json::from_slice(&std::fs::read(file).ok()?).ok()?;
    let time = |v: &serde_json::Value| Some(Time::new(v.get(0)?.as_i64()?, v.get(1)?.as_i64().filter(|d| *d > 0)?));
    if v.get("version")?.as_i64()? != StabilizationAnalysis::CURRENT_VERSION {
        return None;
    }
    let range = TimeRange::new(time(v.get("start")?)?, time(v.get("duration")?)?);
    let times = v.get("times")?.as_array()?.iter().map(time).collect::<Option<Vec<_>>>()?;
    let motions = v
        .get("motions")?
        .as_array()?
        .iter()
        .map(|m| {
            Some(CameraMotion::new(m.get(0)?.as_f64()?, m.get(1)?.as_f64()?, m.get(2)?.as_f64()?, m.get(3)?.as_f64()?))
        })
        .collect::<Option<Vec<_>>>()?;
    if times.len() != motions.len() {
        return None;
    }
    let mut a = StabilizationAnalysis::new(v.get("width")?.as_i64()?, v.get("height")?.as_i64()?, times, motions);
    a.cuts = v.get("cuts")?.as_array()?.iter().filter_map(|c| c.as_u64().map(|c| c as usize)).collect();
    a.confidence = v.get("confidence")?.as_array()?.iter().filter_map(serde_json::Value::as_f64).collect();
    // Results saved before the second measurement have no `rolling` key: they are measured again.
    let numbers =
        |v: &serde_json::Value| -> Option<Vec<f64>> { v.as_array()?.iter().map(serde_json::Value::as_f64).collect() };
    a.checks = v
        .get("checks")?
        .as_array()?
        .iter()
        .map(|c| {
            if c.is_null() {
                Some(None)
            } else {
                numbers(c).filter(|n| n.len() == 4).map(|n| Some(CameraMotion::new(n[0], n[1], n[2], n[3])))
            }
        })
        .collect::<Option<Vec<_>>>()?;
    a.rolling = v
        .get("rolling")?
        .as_array()?
        .iter()
        .map(|r| {
            if r.is_null() {
                return Some(None);
            }
            let n = numbers(r).filter(|n| n.len() == 4)?;
            Some(Some(RollingShutterSample { shift_x: n[0], shift_y: n[1], slope_x: n[2], slope_y: n[3] }))
        })
        .collect::<Option<Vec<_>>>()?;
    a.perspective = v
        .get("perspective")?
        .as_array()?
        .iter()
        .map(|p| numbers(p).map(|n| PerspectiveResidual::new(&n)))
        .collect::<Option<Vec<_>>>()?;
    Some((range, a))
}

/// What a finished analysis run tells the UI thread.
#[derive(Clone, Debug, PartialEq)]
pub enum StabilizationMessage {
    /// 0...1.
    Progress(f64),
    /// The run ended: `Ok(frames)` or the status line to show.
    Done(Result<usize, String>),
}

/// What to measure: a source range of a media file, in a picture of `size` px.
#[derive(Clone, Debug)]
pub struct StabilizationRequest {
    /// The media file.
    pub path: PathBuf,
    /// The source range.
    pub range: TimeRange,
    /// Upright picture width and height.
    pub size: (i64, i64),
}

/// Measures the request into `store`, reusing the store and then the disk cache (`cache_dir`) first.
pub fn analyze_into_store(
    analyzer: &dyn StabilizationAnalyzing,
    request: &StabilizationRequest,
    store: &StabilizationStore,
    cache_dir: Option<&Path>,
    progress: Progress<'_>,
    cancel: &CancelToken,
) -> Result<usize, String> {
    let StabilizationRequest { path, range, size } = request;
    let (range, size) = (*range, *size);
    let key = path.to_string_lossy();
    if let Some(a) = store.get(&key, range, size.0, size.1) {
        return Ok(a.frame_times.len());
    }
    let file = cache_dir.zip(cache_name(path)).map(|(d, n)| d.join(n));
    if let Some((stored, a)) = file.as_deref().and_then(load_analysis)
        && stored.start <= range.start
        && stored.end() >= range.end()
        && (a.picture_width, a.picture_height) == size
    {
        let n = a.frame_times.len();
        store.put(&key, stored, a);
        return Ok(n);
    }
    let a = analyzer
        .analyze(range, size.0, size.1, progress, cancel)
        .map_err(|e| format!("Stabilizer analysis failed: {e}"))?;
    let n = a.frame_times.len();
    if let Some(f) = &file {
        // A full disk only costs the next launch a new measurement.
        if save_analysis(f, range, &a).is_some()
            && let Some(dir) = f.parent()
        {
            prune_cache(dir, CACHE_LIMIT_BYTES);
        }
    }
    store.put(&key, range, a);
    Ok(n)
}

/// An analysis on its own thread.
pub struct StabilizationJob {
    inbox: Receiver<StabilizationMessage>,
    cancel: CancelToken,
}

impl StabilizationJob {
    /// Starts the run; `analyzer` is built on the job's thread by the caller's closure (opening a file takes a moment).
    pub fn spawn(
        analyzer: Box<dyn StabilizationAnalyzing + Send>,
        request: StabilizationRequest,
        store: StabilizationStore,
        cache_dir: Option<PathBuf>,
        wake: WakeFn,
    ) -> StabilizationJob {
        let (tx, inbox) = channel();
        let cancel = CancelToken::new();
        let token = cancel.clone();
        std::thread::spawn(move || {
            let (tell, tell_wake) = (tx.clone(), Arc::clone(&wake));
            let report = move |p: f64| {
                // The receiver is gone when the app quits; nothing is left to tell.
                let _ = tell.send(StabilizationMessage::Progress(p));
                tell_wake();
            };
            // A panic in the analysis ends the run with a status line; the runner would otherwise wait for `Done` forever.
            let done = sq_core_time::caught_panic::catching(|| {
                analyze_into_store(&*analyzer, &request, &store, cache_dir.as_deref(), Some(&report), &token)
            })
            .unwrap_or_else(|_| Err("The Stabilizer analysis stopped unexpectedly.".to_string()));
            let _ = tx.send(StabilizationMessage::Done(done));
            wake();
        });
        StabilizationJob { inbox, cancel }
    }

    /// Asks the run to stop.
    pub fn stop(&self) {
        self.cancel.cancel();
    }

    /// Everything that arrived since the last call.
    pub fn poll(&self) -> Vec<StabilizationMessage> {
        self.inbox.try_iter().collect()
    }
}

#[cfg(test)]
mod tests;
