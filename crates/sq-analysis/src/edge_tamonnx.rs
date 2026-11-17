// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EdgeTAMOnnx.swift
//! EdgeTAM on ONNX Runtime (the Windows backend of the subject mask; the Mac runs the same five parts as Core ML in
//! EdgeTAM.swift, not ported). Same parts, same inputs and outputs, same memory bookkeeping; plain float arrays and an RGBA8
//! picture. Model files: docs/THIRD_PARTY.md.
// Same as Swift (EdgeTAMOnnx.swift:8): the session keeps the Mac session's logic by copy (memory packing, candidate choice), no look-ahead encoder
// thread and no prediction deadline; upgrade by moving the shared bookkeeping out of EdgeTAM.swift into one portable type.
// Speed only, not visible: `OnnxModel::run` takes owned tensors, so the encoder features are cloned for every call (Swift copies on write);
// upgrade when sq-onnx takes borrowed inputs.
use sq_core_masks::subject_mask::SubjectMatte;
use sq_core_masks::subject_track_rules::{SubjectMemoryGate, SubjectTrackBox, SubjectTrackRules};
use sq_core_time::Vec2;
use sq_onnx::onnx_model::{OnnxError, OnnxModel, OnnxTensor};
use std::collections::{BTreeMap, HashMap};
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Instant;

/// An RGBA8 picture, rows tightly packed, origin top left.
#[derive(Clone, Debug, PartialEq)]
pub struct SubjectFrame {
    /// Width in px.
    pub width: usize,
    /// Height in px.
    pub height: usize,
    /// Four bytes per px.
    pub rgba: Vec<u8>,
}

impl SubjectFrame {
    /// A picture; `rgba` must hold `width * height * 4` bytes (Swift traps otherwise).
    pub fn new(width: usize, height: usize, rgba: Vec<u8>) -> SubjectFrame {
        assert_eq!(rgba.len(), width * height * 4, "SubjectFrame size mismatch");
        SubjectFrame { width, height, rgba }
    }

    /// The picture turned clockwise by `degrees` (a multiple of 90, the file's rotation tag) so that it is upright, as the
    /// Mac analysis frames are: a pick point is a fraction of the upright picture and the mattes are stored upright.
    pub fn upright(&self, degrees: i64) -> SubjectFrame {
        let q = ((degrees / 90) % 4 + 4) % 4;
        if q == 0 {
            return self.clone();
        }
        let (w, h) = (self.width, self.height);
        let (nw, nh) = if q == 2 { (w, h) } else { (h, w) };
        let mut out = vec![0_u8; self.rgba.len()];
        for y in 0..h {
            for x in 0..w {
                // Clockwise: (x, y) of the source lands at (h-1-y, x); twice: (w-1-x, h-1-y); counter-clockwise: (y, w-1-x).
                let (dx, dy) = match q {
                    1 => (h - 1 - y, x),
                    2 => (w - 1 - x, h - 1 - y),
                    _ => (y, w - 1 - x),
                };
                let s = (y * w + x) * 4;
                let d = (dy * nw + dx) * 4;
                out[d..d + 4].copy_from_slice(&self.rgba[s..s + 4]);
            }
        }
        SubjectFrame { width: nw, height: nh, rgba: out }
    }
}

/// What the tracking model said about one frame.
#[derive(Clone, Debug, PartialEq)]
pub struct EdgeTAMAnswer {
    /// `SubjectTrackRules::LOGIT_SIZE` squared logits over the whole (stretched) frame.
    pub logits: Vec<f32>,
    /// > 0: the object is on this frame.
    pub score: f32,
}

/// Why the model gave no answer.
#[derive(Clone, Debug, PartialEq)]
pub enum EdgeTAMOnnxError {
    /// A model file is missing.
    Missing(String),
    /// A track step without a click.
    NotConditioned,
    /// The model answered wrongly.
    BadAnswer(String),
    /// ONNX Runtime failed (Swift lets its `OnnxError` through).
    Onnx(OnnxError),
}

impl fmt::Display for EdgeTAMOnnxError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EdgeTAMOnnxError::Missing(s) => write!(f, "EdgeTAM model: {s}"),
            EdgeTAMOnnxError::NotConditioned => f.write_str("the session has no click yet"),
            EdgeTAMOnnxError::BadAnswer(s) => write!(f, "EdgeTAM answered wrongly: {s}"),
            EdgeTAMOnnxError::Onnx(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for EdgeTAMOnnxError {}

impl From<OnnxError> for EdgeTAMOnnxError {
    fn from(e: OnnxError) -> Self {
        EdgeTAMOnnxError::Onnx(e)
    }
}

type Result<T> = std::result::Result<T, EdgeTAMOnnxError>;

/// The process environment as `EdgeTAMOnnxLocation` reads it.
pub fn process_environment() -> HashMap<String, String> {
    std::env::vars().collect()
}

/// Where the five ONNX parts are: `SQ_SUBJECT_MASK_MODELS`, a `SubjectMask` folder next to the exe, the app bundle's
/// `Contents/Resources/SubjectMask` (macOS), then `%LOCALAPPDATA%\Sequence Studio\SubjectMask`.
pub struct EdgeTAMOnnxLocation;

impl EdgeTAMOnnxLocation {
    /// The part names.
    pub const NAMES: [&'static str; 5] = ["encoder", "decoder", "decoder_box", "mem_encoder", "mem_attention"];

    /// The file of part `name` in `dir`.
    pub fn file(name: &str, dir: &Path) -> PathBuf {
        dir.join(format!("edgetam_{name}.onnx"))
    }

    /// Whether all five parts are in `dir`.
    pub fn complete(dir: &Path) -> bool {
        Self::NAMES.iter().all(|n| Self::file(n, dir).exists())
    }

    /// The folders to look in, best first.
    pub fn candidates(environment: &HashMap<String, String>) -> Vec<PathBuf> {
        let mut out = Vec::new();
        if let Some(env) = environment.get("SQ_SUBJECT_MASK_MODELS").filter(|e| !e.is_empty()) {
            out.push(PathBuf::from(env));
        }
        if let Some(dir) = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf)) {
            out.push(dir.join("SubjectMask"));
            out.push(dir.join("../Resources/SubjectMask"));
        }
        if let Some(local) = environment.get("LOCALAPPDATA").filter(|e| !e.is_empty()) {
            out.push(sq_os::app_folders::app_subfolder(Path::new(local), "SubjectMask"));
        }
        out
    }

    /// The first complete folder.
    pub fn find(environment: &HashMap<String, String>) -> Option<PathBuf> {
        Self::candidates(environment).into_iter().find(|d| Self::complete(d))
    }
}

/// Seconds and calls of one part.
type Timing = (f64, u64);

/// The loaded parts. Predictions of all sessions run one at a time.
pub struct EdgeTAMOnnxModel {
    encoder: OnnxModel,
    decoder: OnnxModel,
    decoder_box: OnnxModel,
    memory_encoder: OnnxModel,
    memory_attention: OnnxModel,
    run_lock: Mutex<()>,
    /// Seconds spent in each part since the last `take_timings`, by name (for the bench and the log).
    timings: Mutex<BTreeMap<String, Timing>>,
}

const MEMORY_SLOTS: usize = 7;
const MEMORY_TOKENS: usize = 512;
const MEMORY_DIM: usize = 64;
const POINTER_SLOTS: usize = 16;
const POINTER_DIM: usize = 256;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl EdgeTAMOnnxModel {
    /// Loads all parts (`accelerate`: the platform accelerator, see `sq_onnx::onnx_model::Provider::choose`; false = CPU).
    pub fn new(directory: &Path, accelerate: bool, device: Option<i32>) -> Result<EdgeTAMOnnxModel> {
        Self::with_provider(directory, sq_onnx::onnx_model::Provider::choose(accelerate), device)
    }

    /// Loads all parts on the named provider (the CPU when the accelerator refuses a part).
    pub fn with_provider(
        directory: &Path,
        provider: sq_onnx::onnx_model::Provider,
        device: Option<i32>,
    ) -> Result<EdgeTAMOnnxModel> {
        let load = |name: &str| -> Result<OnnxModel> {
            let file = EdgeTAMOnnxLocation::file(name, directory);
            if !file.exists() {
                return Err(EdgeTAMOnnxError::Missing(file.display().to_string()));
            }
            Ok(OnnxModel::with_provider(&file.to_string_lossy(), provider, device, 0)?)
        };
        Ok(EdgeTAMOnnxModel {
            encoder: load("encoder")?,
            decoder: load("decoder")?,
            decoder_box: load("decoder_box")?,
            memory_encoder: load("mem_encoder")?,
            memory_attention: load("mem_attention")?,
            run_lock: Mutex::new(()),
            timings: Mutex::new(BTreeMap::new()),
        })
    }

    /// A tracking session over this model.
    pub fn make_session(self: &Arc<Self>) -> EdgeTAMOnnxSession {
        EdgeTAMOnnxSession::new(Arc::clone(self))
    }

    fn run(
        &self,
        name: &str,
        model: &OnnxModel,
        inputs: &HashMap<String, OnnxTensor>,
    ) -> Result<HashMap<String, OnnxTensor>> {
        let _one_at_a_time = lock(&self.run_lock);
        let began = Instant::now();
        let out = model.run(inputs)?;
        let seconds = began.elapsed().as_secs_f64();
        let mut t = lock(&self.timings);
        let old = t.get(name).copied().unwrap_or((0.0, 0));
        t.insert(name.to_string(), (old.0 + seconds, old.1 + 1));
        Ok(model.output_names.iter().cloned().zip(out).collect())
    }

    /// Per part: total seconds and calls since the last call.
    pub fn take_timings(&self) -> BTreeMap<String, (f64, u64)> {
        std::mem::take(&mut *lock(&self.timings))
    }

    /// The frame stretched onto the model's square, RGB 0...1, planar (1, 3, side, side). `crop`: frame fractions.
    pub fn input(frame: &SubjectFrame, crop: Option<&SubjectTrackBox>) -> OnnxTensor {
        let side = SubjectTrackRules::MODEL_SIZE;
        let (mut cx, mut cy, mut cw, mut ch) = (0_usize, 0_usize, frame.width, frame.height);
        if let Some(crop) = crop {
            let clamp = |v: f64, hi: usize| (v.round() as i64).clamp(0, hi as i64) as usize;
            cx = clamp(crop.x0 * frame.width as f64, frame.width - 1);
            cy = clamp(crop.y0 * frame.height as f64, frame.height - 1);
            let x1 = (crop.x1 * frame.width as f64).round() as i64;
            let y1 = (crop.y1 * frame.height as f64).round() as i64;
            cw = 1.max((x1 - cx as i64).min((frame.width - cx) as i64)) as usize;
            ch = 1.max((y1 - cy as i64).min((frame.height - cy) as i64)) as usize;
        }
        let mut data = vec![0.0_f32; 3 * side * side];
        // Bilinear on pixel centers; a shrink by more than 2 averages a 2 x 2 block per tap so the picture is not aliased.
        let sx = cw as f64 / side as f64;
        let sy = ch as f64 / side as f64;
        let wide = sx.max(sy) > 2.0;
        let plane = side * side;
        let px = &frame.rgba;
        // Column taps once.
        let mut x0s = vec![0_usize; side];
        let mut x1s = vec![0_usize; side];
        let mut fxs = vec![0.0_f32; side];
        for x in 0..side {
            let fx = (x as f64 + 0.5) * sx - 0.5;
            let i = fx.floor() as i64;
            x0s[x] = i.clamp(0, cw as i64 - 1) as usize;
            x1s[x] = (i + 1).clamp(0, cw as i64 - 1) as usize;
            fxs[x] = (fx - i as f64).clamp(0.0, 1.0) as f32;
        }
        for y in 0..side {
            let fy = (y as f64 + 0.5) * sy - 0.5;
            let j = fy.floor() as i64;
            let y0 = j.clamp(0, ch as i64 - 1) as usize;
            let y1 = (j + 1).clamp(0, ch as i64 - 1) as usize;
            let ty = (fy - j as f64).clamp(0.0, 1.0) as f32;
            for x in 0..side {
                let tx = fxs[x];
                for c in 0..3 {
                    let at = |xx: usize, yy: usize| f32::from(px[((cy + yy) * frame.width + cx + xx) * 4 + c]);
                    let (mut a, mut b, mut d, mut e) = (at(x0s[x], y0), at(x1s[x], y0), at(x0s[x], y1), at(x1s[x], y1));
                    if wide {
                        // The neighbors one source pixel further out, for the box average.
                        let (xa, xb) = ((x0s[x] + 1).min(cw - 1), (x1s[x] + 1).min(cw - 1));
                        let (ya, yb) = ((y0 + 1).min(ch - 1), (y1 + 1).min(ch - 1));
                        a = (a + at(xa, y0) + at(x0s[x], ya) + at(xa, ya)) / 4.0;
                        b = (b + at(xb, y0) + at(x1s[x], ya) + at(xb, ya)) / 4.0;
                        d = (d + at(xa, y1) + at(x0s[x], yb) + at(xa, yb)) / 4.0;
                        e = (e + at(xb, y1) + at(x1s[x], yb) + at(xb, yb)) / 4.0;
                    }
                    let top = a + (b - a) * tx;
                    let bottom = d + (e - d) * tx;
                    data[c * plane + y * side + x] = (top + (bottom - top) * ty) / 255.0;
                }
            }
        }
        OnnxTensor::new(vec![1, 3, side as i64, side as i64], data)
    }
}

/// The encoder's answer for one frame.
struct Features {
    vision: OnnxTensor,
    no_memory: OnnxTensor,
    high0: OnnxTensor,
    high1: OnnxTensor,
}

/// A remembered frame: its memory and object pointer.
struct Entry {
    memory: Vec<f32>,
    pointer: Vec<f32>,
}

struct Decoded {
    logits: Vec<f32>,
    score: f32,
    ious: Vec<f32>,
    low: OnnxTensor,
    pointer: Vec<f32>,
    all: Vec<f32>,
}

/// What `track` answered and `commit` may remember.
struct Pending {
    features: Arc<Features>,
    low: OnnxTensor,
    pointer: Vec<f32>,
    logits: Vec<f32>,
}

/// The memory bookkeeping of the reference tracker for one object and one conditioning frame (see EdgeTAMSession).
pub struct EdgeTAMOnnxSession {
    model: Arc<EdgeTAMOnnxModel>,
    encoded: Option<(SubjectFrame, Arc<Features>)>,
    conditioning: Option<Entry>,
    /// Newest last.
    recent: Vec<Entry>,
    pending: Option<Pending>,
    gate: SubjectMemoryGate,
}

impl EdgeTAMOnnxSession {
    fn new(model: Arc<EdgeTAMOnnxModel>) -> EdgeTAMOnnxSession {
        EdgeTAMOnnxSession {
            model,
            encoded: None,
            conditioning: None,
            recent: Vec::new(),
            pending: None,
            gate: SubjectMemoryGate::tracker(),
        }
    }

    fn encode(&mut self, frame: &SubjectFrame, crop: Option<&SubjectTrackBox>) -> Result<Arc<Features>> {
        if crop.is_none()
            && let Some((f, features)) = &self.encoded
            && f == frame
        {
            return Ok(Arc::clone(features));
        }
        let mut out = self.model.run(
            "encoder",
            &self.model.encoder,
            &HashMap::from([("image".to_string(), EdgeTAMOnnxModel::input(frame, crop))]),
        )?;
        let mut part =
            |n: &str| out.remove(n).ok_or_else(|| EdgeTAMOnnxError::BadAnswer(format!("encoder has no {n}")));
        let features = Arc::new(Features {
            vision: part("vision_feat")?,
            no_memory: part("feat_no_mem")?,
            high0: part("high_res_0")?,
            high1: part("high_res_1")?,
        });
        if crop.is_none() {
            self.encoded = Some((frame.clone(), Arc::clone(&features)));
        }
        Ok(features)
    }

    /// `points`: (x, y, label) in model pixels; none = tracked frame, one = click, three = box corners + click.
    fn decode(
        &self,
        pix_feat: &OnnxTensor,
        features: &Features,
        points: &[(f64, f64, f32)],
        choice: Option<usize>,
    ) -> Result<Decoded> {
        let slots = if points.len() == 3 { 3 } else { 1 };
        let mut coords = OnnxTensor::zeros(vec![1, slots as i64, 2]);
        let mut labels = OnnxTensor::zeros(vec![1, slots as i64]);
        labels.data[0] = -1.0;
        for (i, p) in points.iter().enumerate() {
            coords.data[i * 2] = p.0 as f32;
            coords.data[i * 2 + 1] = p.1 as f32;
            labels.data[i] = p.2;
        }
        let mut pick = OnnxTensor::zeros(vec![1, 4]);
        if let Some(choice) = choice {
            pick.data[choice] = 1.0;
        }
        let (name, part) =
            if slots == 3 { ("decoder_box", &self.model.decoder_box) } else { ("decoder", &self.model.decoder) };
        let mut out = self.model.run(
            name,
            part,
            &HashMap::from([
                ("pix_feat".to_string(), pix_feat.clone()),
                ("high_res_0".to_string(), features.high0.clone()),
                ("high_res_1".to_string(), features.high1.clone()),
                ("point_coords".to_string(), coords),
                ("point_labels".to_string(), labels),
                ("choice".to_string(), pick),
            ]),
        )?;
        let (Some(low), Some(ptr), Some(score), Some(ious), Some(all)) = (
            out.remove("low_res_mask"),
            out.remove("obj_ptr"),
            out.remove("object_score"),
            out.remove("ious"),
            out.remove("all_masks"),
        ) else {
            return Err(EdgeTAMOnnxError::BadAnswer("the decoder lacks an output".to_string()));
        };
        if low.data.len() != SubjectTrackRules::LOGIT_SIZE * SubjectTrackRules::LOGIT_SIZE {
            return Err(EdgeTAMOnnxError::BadAnswer(format!("mask of {} values", low.data.len())));
        }
        Ok(Decoded {
            logits: low.data.clone(),
            score: score.data.first().copied().unwrap_or(0.0),
            ious: ious.data,
            low,
            pointer: ptr.data,
            all: all.data,
        })
    }

    fn remember(&self, features: &Features, low: &OnnxTensor, is_click: bool) -> Result<Vec<f32>> {
        let mut out = self.model.run(
            "mem_encoder",
            &self.model.memory_encoder,
            &HashMap::from([
                ("vision_feat".to_string(), features.vision.clone()),
                ("low_res_mask".to_string(), low.clone()),
                ("is_click".to_string(), OnnxTensor::new(vec![1], vec![if is_click { 1.0 } else { 0.0 }])),
            ]),
        )?;
        out.remove("memory").map(|m| m.data).ok_or_else(|| EdgeTAMOnnxError::BadAnswer("no memory".to_string()))
    }

    /// Starts a new conditioning: the click's memory, nothing recent.
    fn condition_on(&mut self, memory: Vec<f32>, pointer: Vec<f32>) {
        self.conditioning = Some(Entry { memory, pointer });
        self.recent = Vec::new();
        self.pending = None;
        self.gate.reset();
    }

    /// Conditions on a click (frame fractions), with a box around the subject when one is known. Without a box the largest
    /// candidate the model trusts is kept.
    pub fn click(
        &mut self,
        frame: &SubjectFrame,
        point: Vec2,
        box_: Option<&SubjectTrackBox>,
    ) -> Result<EdgeTAMAnswer> {
        let features = self.encode(frame, None)?;
        let p = SubjectTrackRules::model_point(point);
        let decoded = if let Some(box_) = box_ {
            let b = SubjectTrackRules::model_box(box_);
            self.decode(&features.no_memory, &features, &[(b.0, b.1, 2.0), (b.2, b.3, 3.0), (p.0, p.1, 1.0)], Some(0))?
        } else {
            let mut decoded = self.decode(&features.no_memory, &features, &[(p.0, p.1, 1.0)], None)?;
            let n = SubjectTrackRules::LOGIT_SIZE * SubjectTrackRules::LOGIT_SIZE;
            if decoded.all.len() == 4 * n && decoded.ious.len() == 4 {
                let areas: Vec<f64> = (0..4)
                    .map(|t| decoded.all[t * n..(t + 1) * n].iter().filter(|v| **v > 0.0).count() as f64 / n as f64)
                    .collect();
                let largest = SubjectTrackRules::largest_candidate(&areas, &decoded.ious, 0.6);
                // Swift's `max(by:)` keeps the first of equal maxima.
                let best = (2..=3).fold(1, |best, i| if decoded.ious[best] < decoded.ious[i] { i } else { best });
                if largest != best {
                    decoded = self.decode(&features.no_memory, &features, &[(p.0, p.1, 1.0)], Some(largest))?;
                }
            }
            decoded
        };
        let memory = self.remember(&features, &decoded.low, true)?;
        self.condition_on(memory, decoded.pointer);
        Ok(EdgeTAMAnswer { logits: decoded.logits, score: decoded.score })
    }

    /// Conditions on a Magic pick: the clicks of one frame (frame fractions, `subtract` = take the area out). One adding click
    /// is `click`; more (or a removing one) go through the three-slot decoder with the last three, as the Mac corrections do,
    /// and keep the model's best candidate.
    pub fn pick(&mut self, frame: &SubjectFrame, points: &[(Vec2, bool)]) -> Result<EdgeTAMAnswer> {
        let Some(first) = points.first() else {
            return Err(EdgeTAMOnnxError::BadAnswer("no point".to_string()));
        };
        if points.len() == 1 && !first.1 {
            return self.click(frame, first.0, None);
        }
        let features = self.encode(frame, None)?;
        let mut asked: Vec<(f64, f64, f32)> = points[points.len().saturating_sub(3)..]
            .iter()
            .map(|(point, subtract)| {
                let m = SubjectTrackRules::model_point(*point);
                (m.0, m.1, if *subtract { 0.0 } else { 1.0 })
            })
            .collect();
        if asked.len() == 2 {
            asked.push((0.0, 0.0, -1.0));
        }
        let decoded = self.decode(&features.no_memory, &features, &asked, None)?;
        let memory = self.remember(&features, &decoded.low, true)?;
        self.condition_on(memory, decoded.pointer);
        Ok(EdgeTAMAnswer { logits: decoded.logits, score: decoded.score })
    }

    /// Conditions on a matte of this frame (a corrected or earlier tracked one).
    pub fn condition(&mut self, frame: &SubjectFrame, matte: &SubjectMatte) -> Result<()> {
        let (Some(box_), Some(inside)) = (SubjectTrackRules::box_of(matte), SubjectTrackRules::interior_point(matte))
        else {
            return Err(EdgeTAMOnnxError::BadAnswer("empty matte".to_string()));
        };
        let features = self.encode(frame, None)?;
        let b = SubjectTrackRules::model_box(&box_);
        let p = SubjectTrackRules::model_point(inside);
        let decoded =
            self.decode(&features.no_memory, &features, &[(b.0, b.1, 2.0), (b.2, b.3, 3.0), (p.0, p.1, 1.0)], Some(0))?;
        let given = SubjectTrackRules::logits_from(matte, SubjectTrackRules::LOGIT_SIZE);
        let mut low = decoded.low;
        let n = low.data.len().min(given.len());
        low.data[..n].copy_from_slice(&given[..n]);
        let memory = self.remember(&features, &low, true)?;
        self.condition_on(memory, decoded.pointer);
        Ok(())
    }

    /// The subject on the next frame. Not remembered until `commit`.
    pub fn track(&mut self, frame: &SubjectFrame) -> Result<EdgeTAMAnswer> {
        let features = self.encode(frame, None)?;
        let Some(conditioning) = &self.conditioning else {
            return Err(EdgeTAMOnnxError::NotConditioned);
        };
        let slot_size = MEMORY_TOKENS * MEMORY_DIM;
        let dim = POINTER_DIM;
        if conditioning.memory.len() != slot_size || conditioning.pointer.len() != dim {
            return Err(EdgeTAMOnnxError::BadAnswer("memory of another shape".to_string()));
        }
        let recent_memory: Vec<&Entry> = {
            let ok: Vec<&Entry> = self.recent.iter().filter(|e| e.memory.len() == slot_size).collect();
            ok[ok.len().saturating_sub(MEMORY_SLOTS - 1)..].iter().rev().copied().collect()
        };
        let recent_pointers: Vec<&Entry> = {
            let ok: Vec<&Entry> = self.recent.iter().filter(|e| e.pointer.len() == dim).collect();
            ok[ok.len().saturating_sub(POINTER_SLOTS - 1)..].iter().rev().copied().collect()
        };
        let mut memory = OnnxTensor::zeros(vec![1, MEMORY_SLOTS as i64, MEMORY_TOKENS as i64, MEMORY_DIM as i64]);
        memory.data[..slot_size].copy_from_slice(&conditioning.memory);
        for (back, entry) in recent_memory.iter().enumerate() {
            let slot = MEMORY_SLOTS - 1 - back; // nearest frame -> last slot
            memory.data[slot * slot_size..(slot + 1) * slot_size].copy_from_slice(&entry.memory);
        }
        let mut memory_valid = OnnxTensor::zeros(vec![1, MEMORY_SLOTS as i64]);
        memory_valid.data[0] = 1.0;
        for back in 0..recent_memory.len() {
            memory_valid.data[MEMORY_SLOTS - 1 - back] = 1.0;
        }
        let mut pointer_array = OnnxTensor::zeros(vec![1, POINTER_SLOTS as i64, dim as i64]);
        pointer_array.data[..dim].copy_from_slice(&conditioning.pointer);
        for (index, entry) in recent_pointers.iter().enumerate() {
            pointer_array.data[(index + 1) * dim..(index + 2) * dim].copy_from_slice(&entry.pointer);
        }
        let mut pointer_valid = OnnxTensor::zeros(vec![1, POINTER_SLOTS as i64]);
        for index in 0..=recent_pointers.len() {
            pointer_valid.data[index] = 1.0;
        }
        let mut attended = self.model.run(
            "mem_attention",
            &self.model.memory_attention,
            &HashMap::from([
                ("vision_feat".to_string(), features.vision.clone()),
                ("memory".to_string(), memory),
                ("memory_valid".to_string(), memory_valid),
                ("obj_ptrs".to_string(), pointer_array),
                ("ptr_valid".to_string(), pointer_valid),
            ]),
        )?;
        let pix = attended.remove("pix_feat").ok_or_else(|| EdgeTAMOnnxError::BadAnswer("no pix_feat".to_string()))?;
        let decoded = self.decode(&pix, &features, &[], None)?;
        let answer = EdgeTAMAnswer { logits: decoded.logits.clone(), score: decoded.score };
        self.pending = Some(Pending { features, low: decoded.low, pointer: decoded.pointer, logits: decoded.logits });
        Ok(answer)
    }

    /// Adds the frame `track` just answered to the memory of recent frames (when the gate admits it).
    pub fn commit(&mut self) -> Result<()> {
        let Some(p) = self.pending.take() else { return Ok(()) };
        if !self.gate.admit(&p.logits) {
            return Ok(());
        }
        let memory = self.remember(&p.features, &p.low, false)?;
        self.recent.push(Entry { memory, pointer: p.pointer });
        let keep = POINTER_SLOTS - 1;
        if self.recent.len() > keep {
            self.recent.drain(..self.recent.len() - keep);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Left half red, right half blue, 40 x 20.
    fn red_blue() -> SubjectFrame {
        let mut rgba = vec![255_u8; 40 * 20 * 4];
        for y in 0..20 {
            for x in 0..40 {
                let i = (y * 40 + x) * 4;
                rgba[i] = if x < 20 { 255 } else { 0 };
                rgba[i + 1] = 0;
                rgba[i + 2] = if x < 20 { 0 } else { 255 };
            }
        }
        SubjectFrame::new(40, 20, rgba)
    }

    #[test]
    fn the_model_square_is_planar_rgb_in_zero_to_one() {
        let t = EdgeTAMOnnxModel::input(&red_blue(), None);
        let side = SubjectTrackRules::MODEL_SIZE;
        let plane = side * side;
        assert_eq!(t.shape, [1, 3, side as i64, side as i64]);
        let left_middle = (side / 2) * side + 10;
        let right_middle = (side / 2) * side + side - 10;
        assert!((t.data[left_middle] - 1.0).abs() < 0.01); // R of the left half
        assert!(t.data[plane + left_middle].abs() < 0.01); // G
        assert!((t.data[2 * plane + right_middle] - 1.0).abs() < 0.01); // B of the right half
        assert!(t.data[right_middle].abs() < 0.01);
    }

    #[test]
    fn a_crop_takes_only_that_part_of_the_frame() {
        let t = EdgeTAMOnnxModel::input(&red_blue(), Some(&SubjectTrackBox::new(0.5, 0.0, 1.0, 1.0)));
        let plane = SubjectTrackRules::MODEL_SIZE * SubjectTrackRules::MODEL_SIZE;
        assert!(t.data[plane * 2 + 5000] > 0.99 && t.data[5000] < 0.01); // all blue
    }

    #[test]
    fn models_are_found_by_the_environment_folder_only_when_complete() {
        let dir = std::env::temp_dir().join(format!("sq-edgetam-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let env = HashMap::from([("SQ_SUBJECT_MASK_MODELS".to_string(), dir.display().to_string())]);
        assert_eq!(EdgeTAMOnnxLocation::find(&env), None);
        for name in EdgeTAMOnnxLocation::NAMES {
            std::fs::write(EdgeTAMOnnxLocation::file(name, &dir), b"").expect("file");
        }
        assert_eq!(EdgeTAMOnnxLocation::find(&env), Some(dir.clone()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    // 3 x 2: row 0 = A B C, row 1 = D E F (the red channel holds the letter's index).
    fn letters() -> SubjectFrame {
        SubjectFrame::new(3, 2, (0..6_u8).flat_map(|i| [i, 0, 0, 255]).collect())
    }

    fn reds(f: &SubjectFrame) -> Vec<u8> {
        (0..f.rgba.len() / 4).map(|i| f.rgba[i * 4]).collect()
    }

    #[test]
    fn clockwise_quarter_turn_puts_the_left_column_on_top() {
        let r = letters().upright(90);
        assert_eq!((r.width, r.height), (2, 3));
        assert_eq!(reds(&r), [3, 0, 4, 1, 5, 2]);
    }

    #[test]
    fn half_and_three_quarter_turns() {
        assert_eq!(reds(&letters().upright(180)), [5, 4, 3, 2, 1, 0]);
        let r = letters().upright(270);
        assert_eq!((r.width, r.height), (2, 3));
        assert_eq!(reds(&r), [2, 5, 1, 4, 0, 3]);
        assert_eq!(reds(&letters().upright(0)), [0, 1, 2, 3, 4, 5]);
        assert_eq!(reds(&letters().upright(-90)), reds(&r));
    }

    /// Runs the real models when `SQ_SUBJECT_MASK_MODELS` points at them (the PC: ONNX Runtime + DirectML, `SQ_ONNX_RUNTIME` =
    /// the dll); otherwise it skips with a note.
    #[test]
    fn a_disc_follows_the_click_and_moves() {
        let Some(dir) = EdgeTAMOnnxLocation::find(&process_environment()) else {
            eprintln!("skipped: no EdgeTAM models (set SQ_SUBJECT_MASK_MODELS)");
            return;
        };
        // The runtime next to the exe or on PATH is found by default; `SQ_ONNX_RUNTIME` names a newer onnxruntime.dll.
        if let Ok(dll) = std::env::var("SQ_ONNX_RUNTIME") {
            let _ = OnnxModel::load_runtime(Some(&dll));
        }
        let frame = |cx: i64| {
            let (w, h) = (640_usize, 360_usize);
            let mut rgba = vec![255_u8; w * h * 4];
            for y in 0..h {
                for x in 0..w {
                    let i = (y * w + x) * 4;
                    let (dx, dy) = (x as i64 - cx, y as i64 - 180);
                    let inside = dx * dx + dy * dy < 80 * 80;
                    rgba[i] = if inside { 220 } else { 40 };
                    rgba[i + 1] = if inside { 60 } else { 90 };
                    rgba[i + 2] = if inside { 40 } else { 120 };
                }
            }
            SubjectFrame::new(w, h, rgba)
        };
        // One pass per provider: the platform accelerator (or the one SQ_ONNX_PROVIDER names), then the CPU. The masks must agree
        // (IoU >= 0.95 per frame) and the per-frame times go to stderr.
        use sq_onnx::onnx_model::Provider;
        let pass = |provider: Provider| -> Vec<Vec<bool>> {
            let model = match EdgeTAMOnnxModel::with_provider(&dir, provider, None) {
                Ok(m) => Arc::new(m),
                Err(e) => panic!("models did not load: {e}"),
            };
            let mut session = model.make_session();
            let a = session.click(&frame(200), Vec2::new(200.0 / 640.0, 0.5), None).expect("click");
            let area = a.logits.iter().filter(|v| **v > 0.0).count();
            eprintln!("onnx smoke {provider:?}: click area {area} of {}", a.logits.len());
            assert!(area > 500);
            let mut masks = vec![a.logits.iter().map(|v| *v > 0.0).collect::<Vec<_>>()];
            let started = Instant::now();
            for k in 1..=6 {
                let r = session.track(&frame(200 + k * 20)).expect("track");
                session.commit().expect("commit");
                eprintln!(
                    "onnx smoke {provider:?}: track {k} area {} score {}",
                    r.logits.iter().filter(|v| **v > 0.0).count(),
                    r.score
                );
                masks.push(r.logits.iter().map(|v| *v > 0.0).collect());
            }
            eprintln!(
                "onnx smoke {provider:?}: {:.0} ms per tracked frame",
                started.elapsed().as_secs_f64() * 1000.0 / 6.0
            );
            for (name, (seconds, calls)) in model.take_timings() {
                eprintln!("onnx smoke {provider:?}: {name} {calls}x avg {:.1} ms", seconds / calls as f64 * 1000.0);
            }
            masks
        };
        let fast = pass(Provider::choose(true));
        let cpu = pass(Provider::Cpu);
        for (i, (f, c)) in fast.iter().zip(&cpu).enumerate() {
            let both = f.iter().zip(c).filter(|(a, b)| **a && **b).count() as f64;
            let either = f.iter().zip(c).filter(|(a, b)| **a || **b).count() as f64;
            let iou = if either == 0.0 { 1.0 } else { both / either };
            eprintln!("onnx smoke: frame {i} IoU accelerator vs CPU {iou:.4}");
            assert!(iou >= 0.95, "frame {i}: IoU {iou}");
        }
    }
}
