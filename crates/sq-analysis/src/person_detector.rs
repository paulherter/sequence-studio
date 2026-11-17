// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: VisionSubjectDetector.swift (`detect(with:)`), Anonymize.swift (`PersonDetecting`, `VisionPersonDetector`)
//! Faces, bodies and saliency on ONNX Runtime, for the systems without Apple's Vision framework (Windows, Linux).
//!
//! Faces: YuNet (OpenCV Zoo, MIT). Bodies: YOLOX-Tiny, class "person" only (Megvii, Apache-2.0). Saliency: the spectral
//! residual of Hou and Zhang (no model, a small FFT). The outputs are the Swift ones: `SubjectBox` lists for Auto-Reframe
//! (`SubjectDetecting`), `AnonymizeBox` / `AnonymizeFace` for Anonymize (`PersonDetecting`), boxes in fractions of the
//! upright frame with the origin top left. The models download once into the model folder (sha256 pinned).

use crate::edge_tamonnx::SubjectFrame;
use crate::reframe::{NormalizedRect, SubjectBox, SubjectDetecting, SubjectKind};
use sq_core_masks::anonymize::{AnonymizeBox, AnonymizeFace};
use sq_core_time::Time;
use sq_core_time::sha256_digest::Sha256;
use sq_onnx::onnx_model::{OnnxModel, TensorData, TypedTensor};
use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Face and body boxes of one upright frame (Swift `PersonDetecting`).
pub trait PersonDetecting: Sync {
    /// `bodies` false: faces only (what the per-frame refinement needs).
    fn detect(&self, frame: &SubjectFrame, bodies: bool) -> Result<(Vec<AnonymizeBox>, Vec<AnonymizeFace>), String>;
}

/// A pinned model file: name, URL, size, sha256.
pub struct PinnedModel {
    /// File name in the model folder.
    pub file: &'static str,
    /// Download address (commit or tag pinned).
    pub url: &'static str,
    /// Exact size.
    pub size: u64,
    /// Lowercase hex sha256.
    pub sha256: &'static str,
}

/// YuNet 2023mar (MIT, github.com/opencv/opencv_zoo, commit f12e127).
pub const YUNET: PinnedModel = PinnedModel {
    file: "face_detection_yunet_2023mar.onnx",
    url: "https://github.com/opencv/opencv_zoo/raw/f12e12798e8314f7c074a6656816c048dcc95b7a/models/face_detection_yunet/face_detection_yunet_2023mar.onnx",
    size: 232_589,
    sha256: "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4",
};

/// YOLOX-Tiny 416 (Apache-2.0, github.com/Megvii-BaseDetection/YOLOX, release 0.1.1rc0).
pub const YOLOX_TINY: PinnedModel = PinnedModel {
    file: "yolox_tiny.onnx",
    url: "https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_tiny.onnx",
    size: 20_219_662,
    sha256: "427cc366d34e27ff7a03e2899b5e3671425c262ea2291f88bb942bc1cc70b0f7",
};

/// The model folder: `SQ_PERSON_MODELS`, else `%LOCALAPPDATA%\Sequence Studio\People`, else `~/Library/Application Support/Sequence Studio/People`.
pub fn default_folder(env: impl Fn(&str) -> Option<String>) -> PathBuf {
    sq_os::app_folders::data_subfolder(env, "SQ_PERSON_MODELS", "People")
}

fn file_hex(path: &Path) -> std::io::Result<String> {
    let mut f = fs::File::open(path)?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            return Ok(h.finalize_hex());
        }
        h.update(&buf[..n]);
    }
}

/// Makes sure `model` is in `folder`: downloads it with the system `curl` into a `.part`, checks size and sha256, moves it
/// into place. Returns the file's path.
pub fn ensure_model(folder: &Path, model: &PinnedModel) -> Result<PathBuf, String> {
    let target = folder.join(model.file);
    if fs::metadata(&target).is_ok_and(|m| m.len() == model.size) {
        return Ok(target);
    }
    fs::create_dir_all(folder).map_err(|e| e.to_string())?;
    let part = folder.join(format!("{}.part", model.file));
    fs::remove_file(&part).ok();
    let mut cmd = Command::new("curl");
    cmd.args(["-fsSL", "--retry", "2", "-o"]).arg(&part).arg(model.url).stdout(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let status = cmd.status().map_err(|e| format!("cannot start curl: {e}"))?;
    let checked = if !status.success() {
        Err(format!("the download of {} failed ({status})", model.file))
    } else if fs::metadata(&part).map_or(0, |m| m.len()) != model.size {
        Err(format!("{} has the wrong size", model.file))
    } else if file_hex(&part).map_err(|e| e.to_string())? != model.sha256 {
        Err(format!("{} does not match its checksum", model.file))
    } else {
        Ok(())
    };
    if let Err(e) = checked {
        fs::remove_file(&part).ok();
        return Err(e);
    }
    fs::rename(&part, &target).map_err(|e| e.to_string())?;
    Ok(target)
}

/// A candidate box in the pixels of the network input.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Cand {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    score: f32,
}

fn iou(a: &Cand, b: &Cand) -> f32 {
    let w = (a.x2.min(b.x2) - a.x1.max(b.x1)).max(0.0);
    let h = (a.y2.min(b.y2) - a.y1.max(b.y1)).max(0.0);
    let inter = w * h;
    let union = (a.x2 - a.x1) * (a.y2 - a.y1) + (b.x2 - b.x1) * (b.y2 - b.y1) - inter;
    if union <= 0.0 { 0.0 } else { inter / union }
}

/// Greedy non-maximum suppression: best first, a box that overlaps a kept one by more than `max_iou` is dropped.
fn nms(mut c: Vec<Cand>, max_iou: f32) -> Vec<Cand> {
    c.sort_by(|a, b| b.score.total_cmp(&a.score));
    let mut kept: Vec<Cand> = Vec::new();
    for x in c {
        if kept.iter().all(|k| iou(k, &x) <= max_iou) {
            kept.push(x);
        }
    }
    kept
}

/// The frame fitted into a `side` x `side` square (aspect kept, `pad` around), as float planes B, G, R in 0...255.
struct Letterbox {
    data: Vec<f32>,
    scale: f32,
    pad_x: f32,
    pad_y: f32,
}

fn letterbox(frame: &SubjectFrame, side: usize, pad: f32) -> Letterbox {
    let (w, h) = (frame.width.max(1), frame.height.max(1));
    let scale = (side as f32 / w as f32).min(side as f32 / h as f32);
    let (nw, nh) =
        (((w as f32 * scale).round() as usize).clamp(1, side), ((h as f32 * scale).round() as usize).clamp(1, side));
    let (pad_x, pad_y) = (((side - nw) / 2) as f32, ((side - nh) / 2) as f32);
    let plane = side * side;
    let mut data = vec![pad; 3 * plane];
    for y in 0..nh {
        // Bilinear, pixel centers aligned.
        let sy = ((y as f32 + 0.5) * h as f32 / nh as f32 - 0.5).clamp(0.0, h as f32 - 1.0);
        let (y0, fy) = (sy.floor() as usize, sy.fract());
        let y1 = (y0 + 1).min(h - 1);
        for x in 0..nw {
            let sx = ((x as f32 + 0.5) * w as f32 / nw as f32 - 0.5).clamp(0.0, w as f32 - 1.0);
            let (x0, fx) = (sx.floor() as usize, sx.fract());
            let x1 = (x0 + 1).min(w - 1);
            let at = |xx: usize, yy: usize, c: usize| f32::from(frame.rgba[(yy * w + xx) * 4 + c]);
            let dst = (y + pad_y as usize) * side + x + pad_x as usize;
            for (plane_i, c) in [(0, 2), (1, 1), (2, 0)] {
                let top = at(x0, y0, c) * (1.0 - fx) + at(x1, y0, c) * fx;
                let bottom = at(x0, y1, c) * (1.0 - fx) + at(x1, y1, c) * fx;
                data[plane_i * plane + dst] = top * (1.0 - fy) + bottom * fy;
            }
        }
    }
    Letterbox { data, scale, pad_x, pad_y }
}

/// YuNet's three scales: `cls`, `obj` (one value per cell) and `bbox` (four) for strides 8, 16, 32 over a `side` input.
/// Score = sqrt(cls * obj); the box is anchor-free (cell + offset, exp size).
fn decode_yunet(cls: [&[f32]; 3], obj: [&[f32]; 3], bbox: [&[f32]; 3], side: usize, min_score: f32) -> Vec<Cand> {
    let mut out = Vec::new();
    for (i, stride) in [8usize, 16, 32].into_iter().enumerate() {
        let cols = side / stride;
        for cell in 0..cols * cols {
            let score = (cls[i][cell].clamp(0.0, 1.0) * obj[i][cell].clamp(0.0, 1.0)).sqrt();
            if score < min_score {
                continue;
            }
            let b = &bbox[i][cell * 4..cell * 4 + 4];
            let s = stride as f32;
            let (cx, cy) = (((cell % cols) as f32 + b[0]) * s, ((cell / cols) as f32 + b[1]) * s);
            let (w, h) = (b[2].exp() * s, b[3].exp() * s);
            out.push(Cand { x1: cx - w / 2.0, y1: cy - h / 2.0, x2: cx + w / 2.0, y2: cy + h / 2.0, score });
        }
    }
    out
}

/// YOLOX's raw output (rows of x, y, w, h, objectness and 80 class scores over the grids of strides 8, 16, 32); the person
/// class is index 0.
fn decode_yolox(rows: &[f32], side: usize, min_score: f32) -> Vec<Cand> {
    let mut out = Vec::new();
    let mut row = 0usize;
    for stride in [8usize, 16, 32] {
        let cols = side / stride;
        for cell in 0..cols * cols {
            let r = &rows[row * 85..row * 85 + 85];
            row += 1;
            let score = r[4] * r[5];
            if score < min_score {
                continue;
            }
            let s = stride as f32;
            let (cx, cy) = ((r[0] + (cell % cols) as f32) * s, (r[1] + (cell / cols) as f32) * s);
            let (w, h) = (r[2].exp() * s, r[3].exp() * s);
            out.push(Cand { x1: cx - w / 2.0, y1: cy - h / 2.0, x2: cx + w / 2.0, y2: cy + h / 2.0, score });
        }
    }
    out
}

/// A candidate in network pixels as a box in fractions of the frame.
fn to_box(c: &Cand, lb: &Letterbox, frame: &SubjectFrame) -> AnonymizeBox {
    let (w, h) = (frame.width.max(1) as f32, frame.height.max(1) as f32);
    let x1 = ((c.x1 - lb.pad_x) / lb.scale / w).clamp(0.0, 1.0);
    let y1 = ((c.y1 - lb.pad_y) / lb.scale / h).clamp(0.0, 1.0);
    let x2 = ((c.x2 - lb.pad_x) / lb.scale / w).clamp(0.0, 1.0);
    let y2 = ((c.y2 - lb.pad_y) / lb.scale / h).clamp(0.0, 1.0);
    AnonymizeBox { x: f64::from(x1), y: f64::from(y1), width: f64::from(x2 - x1), height: f64::from(y2 - y1) }
}

const YUNET_SIDE: usize = 640;
const YOLOX_SIDE: usize = 416;

fn f32_input(side: usize, data: Vec<f32>) -> TypedTensor {
    TypedTensor::new(vec![1, 3, side as i64, side as i64], TensorData::F32(data))
}

fn floats(t: Option<TypedTensor>, what: &str) -> Result<Vec<f32>, String> {
    match t.map(|t| t.data) {
        Some(TensorData::F32(v)) => Ok(v),
        _ => Err(format!("the model returned no {what}")),
    }
}

/// Face and person detectors on ONNX Runtime.
pub struct OnnxPeopleDetector {
    yunet: OnnxModel,
    yolox: OnnxModel,
}

impl OnnxPeopleDetector {
    /// Opens the models of `folder`, downloading what is missing.
    pub fn open(folder: &Path) -> Result<OnnxPeopleDetector, String> {
        let open = |m: &PinnedModel| -> Result<OnnxModel, String> {
            let path = ensure_model(folder, m)?;
            let path = path.to_str().ok_or("a model path is not UTF-8")?;
            OnnxModel::new(path, true, None, 0).map_err(|e| e.to_string())
        };
        Ok(OnnxPeopleDetector { yunet: open(&YUNET)?, yolox: open(&YOLOX_TINY)? })
    }

    /// Faces of `frame` with confidence 0...1.
    pub fn faces(&self, frame: &SubjectFrame) -> Result<Vec<AnonymizeFace>, String> {
        let lb = letterbox(frame, YUNET_SIDE, 0.0);
        let mut inputs = HashMap::new();
        inputs.insert("input".to_string(), f32_input(YUNET_SIDE, lb.data.clone()));
        let names: Vec<String> =
            ["cls_8", "cls_16", "cls_32", "obj_8", "obj_16", "obj_32", "bbox_8", "bbox_16", "bbox_32"]
                .map(String::from)
                .to_vec();
        let wanted: Vec<&str> = names.iter().map(String::as_str).collect();
        let mut out = self
            .yunet
            .run_typed(&inputs, &wanted)
            .map_err(|e| format!("{e} (outputs: {:?})", self.yunet.output_names))?
            .into_iter();
        let mut next = |what: &str| floats(out.next(), what);
        let (c8, c16, c32) = (next("cls_8")?, next("cls_16")?, next("cls_32")?);
        let (o8, o16, o32) = (next("obj_8")?, next("obj_16")?, next("obj_32")?);
        let (b8, b16, b32) = (next("bbox_8")?, next("bbox_16")?, next("bbox_32")?);
        let found = decode_yunet([&c8, &c16, &c32], [&o8, &o16, &o32], [&b8, &b16, &b32], YUNET_SIDE, 0.6);
        Ok(nms(found, 0.3)
            .iter()
            .map(|c| AnonymizeFace { box_: to_box(c, &lb, frame), confidence: f64::from(c.score.min(1.0)) })
            .collect())
    }

    /// Whole-person boxes of `frame`.
    pub fn bodies(&self, frame: &SubjectFrame) -> Result<Vec<(AnonymizeBox, f64)>, String> {
        let lb = letterbox(frame, YOLOX_SIDE, 114.0);
        let mut inputs = HashMap::new();
        inputs.insert("images".to_string(), f32_input(YOLOX_SIDE, lb.data.clone()));
        let out = self.yolox.run_typed(&inputs, &[self.yolox.output_names.first().map_or("output", String::as_str)]);
        let rows = floats(out.map_err(|e| e.to_string())?.into_iter().next(), "detections")?;
        if rows.len() < 3549 * 85 {
            return Err("the person model returned an unexpected shape".into());
        }
        let found = decode_yolox(&rows, YOLOX_SIDE, 0.35);
        Ok(nms(found, 0.45).iter().map(|c| (to_box(c, &lb, frame), f64::from(c.score.min(1.0)))).collect())
    }
}

impl PersonDetecting for OnnxPeopleDetector {
    fn detect(&self, frame: &SubjectFrame, bodies: bool) -> Result<(Vec<AnonymizeBox>, Vec<AnonymizeFace>), String> {
        let faces = self.faces(frame)?;
        let bodies = if bodies { self.bodies(frame)?.into_iter().map(|b| b.0).collect() } else { Vec::new() };
        Ok((bodies, faces))
    }
}

fn rect(b: &AnonymizeBox) -> NormalizedRect {
    NormalizedRect { x: b.x, y: b.y, width: b.width, height: b.height }
}

/// Everything the Swift `VisionSubjectDetector.detect` returns for one frame: faces, bodies, saliency.
pub fn subjects_of(people: &OnnxPeopleDetector, frame: &SubjectFrame) -> Result<Vec<SubjectBox>, String> {
    let mut out = Vec::new();
    for f in people.faces(frame)? {
        out.push(SubjectBox { kind: SubjectKind::Face, rect: rect(&f.box_), confidence: f.confidence });
    }
    for (b, confidence) in people.bodies(frame)? {
        out.push(SubjectBox { kind: SubjectKind::Body, rect: rect(&b), confidence });
    }
    for b in crate::saliency::salient_boxes(frame) {
        out.push(SubjectBox { kind: SubjectKind::Saliency, rect: rect(&b), confidence: 0.5 });
    }
    Ok(out)
}

/// A frame source: the upright frame at a source time, small (long side about 640 px); `None` = no frame there.
pub type FrameAt = Box<dyn Fn(Time) -> Result<Option<SubjectFrame>, String> + Send + Sync>;

/// `SubjectDetecting` for Auto-Reframe: the frames come from `frames`, the boxes from the ONNX detectors.
pub struct OnnxSubjectDetector {
    people: OnnxPeopleDetector,
    frames: FrameAt,
}

impl OnnxSubjectDetector {
    /// A detector over `frames`; the models are opened from `folder`.
    pub fn new(folder: &Path, frames: FrameAt) -> Result<OnnxSubjectDetector, String> {
        Ok(OnnxSubjectDetector { people: OnnxPeopleDetector::open(folder)?, frames })
    }
}

impl SubjectDetecting for OnnxSubjectDetector {
    type Error = String;

    fn subjects(&self, source_time: Time) -> Result<Vec<SubjectBox>, String> {
        match (self.frames)(source_time)? {
            Some(frame) => subjects_of(&self.people, &frame),
            None => Ok(Vec::new()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(w: usize, h: usize) -> SubjectFrame {
        SubjectFrame::new(w, h, vec![200; w * h * 4])
    }

    #[test]
    fn nms_keeps_the_best_of_overlapping_boxes() {
        let c = |x: f32, s: f32| Cand { x1: x, y1: 0.0, x2: x + 10.0, y2: 10.0, score: s };
        let kept = nms(vec![c(0.0, 0.5), c(1.0, 0.9), c(50.0, 0.4)], 0.3);
        assert_eq!(kept.iter().map(|k| k.score).collect::<Vec<_>>(), [0.9, 0.4]);
    }

    #[test]
    fn letterbox_fits_the_longer_side_and_maps_boxes_back() {
        let f = frame(200, 100);
        let lb = letterbox(&f, 100, 0.0);
        assert_eq!((lb.scale, lb.pad_x, lb.pad_y), (0.5, 0.0, 25.0));
        // The picture sits in rows 25..75 of the square; the rest is padding (B plane first, value 200 inside).
        assert_eq!(lb.data[10 * 100 + 10], 0.0);
        assert_eq!(lb.data[50 * 100 + 10], 200.0);
        // A box over the right half of the picture: network x 50..100, y 25..75.
        let b = to_box(&Cand { x1: 50.0, y1: 25.0, x2: 100.0, y2: 75.0, score: 1.0 }, &lb, &f);
        assert_eq!((b.x, b.y, b.width, b.height), (0.5, 0.0, 0.5, 1.0));
    }

    #[test]
    fn yunet_cells_become_boxes_with_the_geometric_mean_score() {
        let side = 640;
        let n = |stride: usize| (side / stride) * (side / stride);
        let mut cls = [vec![0.0; n(8)], vec![0.0; n(16)], vec![0.0; n(32)]];
        let mut obj = [vec![0.0; n(8)], vec![0.0; n(16)], vec![0.0; n(32)]];
        let mut bbox = [vec![0.0; n(8) * 4], vec![0.0; n(16) * 4], vec![0.0; n(32) * 4]];
        // Stride 16, cell (row 3, col 5): center at (5 + 0.5, 3 + 0.5) * 16, size e^0 * 16 = 16.
        let cell = 3 * 40 + 5;
        cls[1][cell] = 0.81;
        obj[1][cell] = 1.0;
        bbox[1][cell * 4] = 0.5;
        bbox[1][cell * 4 + 1] = 0.5;
        let found = decode_yunet(
            [&cls[0], &cls[1], &cls[2]],
            [&obj[0], &obj[1], &obj[2]],
            [&bbox[0], &bbox[1], &bbox[2]],
            side,
            0.6,
        );
        assert_eq!(found.len(), 1);
        let f = found[0];
        assert!((f.score - 0.9).abs() < 1e-6);
        assert_eq!((f.x1, f.y1, f.x2, f.y2), (80.0, 48.0, 96.0, 64.0));
    }

    #[test]
    fn yolox_rows_decode_the_person_score_and_grid_position() {
        let side = 416;
        let total = 52 * 52 + 26 * 26 + 13 * 13;
        let mut rows = vec![0f32; total * 85];
        // Stride 32, cell (row 2, col 4) = row index 52*52 + 26*26 + 2*13 + 4.
        let i = 52 * 52 + 26 * 26 + 2 * 13 + 4;
        rows[i * 85..i * 85 + 6].copy_from_slice(&[0.5, 0.5, 1.0_f32.ln(), 2.0_f32.ln(), 0.8, 0.9]);
        let found = decode_yolox(&rows, side, 0.35);
        assert_eq!(found.len(), 1);
        let f = found[0];
        assert!((f.score - 0.72).abs() < 1e-6);
        assert!((f.x1 - 128.0).abs() < 1e-3 && (f.x2 - 160.0).abs() < 1e-3, "{f:?}");
        assert!((f.y2 - f.y1 - 64.0).abs() < 1e-3);
    }

    #[test]
    fn the_model_folder_follows_the_environment() {
        let env = |k: &str| match k {
            "SQ_PERSON_MODELS" => Some("/p".to_string()),
            "LOCALAPPDATA" => Some("/l".to_string()),
            _ => None,
        };
        assert_eq!(default_folder(env), PathBuf::from("/p"));
        assert_eq!(
            default_folder(|k| (k == "LOCALAPPDATA").then(|| "/l".to_string())),
            PathBuf::from("/l/Sequence Studio/People")
        );
        assert_eq!(YUNET.sha256.len(), 64);
        assert_eq!(YOLOX_TINY.sha256.len(), 64);
    }

    /// Reads a binary PPM (P6) into a frame.
    fn read_ppm(path: &str) -> Option<SubjectFrame> {
        let b = fs::read(path).ok()?;
        let mut parts = Vec::new();
        let mut at = 0;
        while parts.len() < 4 {
            while b.get(at)?.is_ascii_whitespace() {
                at += 1;
            }
            let start = at;
            while !b.get(at)?.is_ascii_whitespace() {
                at += 1;
            }
            parts.push(String::from_utf8_lossy(&b[start..at]).into_owned());
        }
        let (w, h): (usize, usize) = (parts[1].parse().ok()?, parts[2].parse().ok()?);
        let rgb = &b[at + 1..];
        let rgba = rgb.as_chunks::<3>().0.iter().flat_map(|p| [p[0], p[1], p[2], 255]).collect();
        Some(SubjectFrame::new(w, h, rgba))
    }

    /// YuNet and YOLOX on the CPU and on the platform accelerator: the same boxes (IoU >= 0.9) and the time per picture.
    #[test]
    fn the_accelerator_and_the_cpu_find_the_same_boxes() {
        use sq_onnx::onnx_model::Provider;
        let (Ok(face_path), Ok(body_path)) =
            (std::env::var("SQ_PEOPLE_FACE_PPM"), std::env::var("SQ_PEOPLE_BODIES_PPM"))
        else {
            eprintln!("skipped: SQ_PEOPLE_FACE_PPM / SQ_PEOPLE_BODIES_PPM are not set");
            return;
        };
        let folder = std::env::var("SQ_PERSON_MODELS")
            .map_or_else(|_| std::env::temp_dir().join("sq-people-test-models"), PathBuf::from);
        let (Some(face_frame), Some(body_frame)) = (read_ppm(&face_path), read_ppm(&body_path)) else {
            panic!("cannot read the test pictures");
        };
        let mut found = Vec::new();
        for provider in [Provider::Cpu, Provider::platform_default()] {
            Provider::force(Some(provider));
            let det = match OnnxPeopleDetector::open(&folder) {
                Ok(d) => d,
                Err(e) => {
                    Provider::force(None);
                    eprintln!("skipped: {e}");
                    return;
                }
            };
            let _ = det.detect(&body_frame, true);
            let n = 10;
            let start = std::time::Instant::now();
            let mut last = None;
            for _ in 0..n {
                last = Some((
                    det.faces(&face_frame).unwrap_or_default(),
                    det.detect(&body_frame, true).unwrap_or_default().0,
                ));
            }
            let per = start.elapsed().as_secs_f64() * 1000.0 / n as f64;
            eprintln!("people {provider:?}: {per:.1} ms for YuNet on the portrait + YOLOX on the people picture");
            found.push(last.unwrap_or_default());
        }
        Provider::force(None);
        let iou = |a: &AnonymizeBox, b: &AnonymizeBox| -> f64 {
            let w = (a.x + a.width).min(b.x + b.width) - a.x.max(b.x);
            let h = (a.y + a.height).min(b.y + b.height) - a.y.max(b.y);
            let inter = w.max(0.0) * h.max(0.0);
            inter / (a.width * a.height + b.width * b.height - inter).max(1e-12)
        };
        assert_eq!(found[0].0.len(), found[1].0.len(), "face counts differ");
        assert_eq!(found[0].1.len(), found[1].1.len(), "body counts differ");
        for (c, f) in found[0].0.iter().zip(&found[1].0) {
            assert!(iou(&c.box_, &f.box_) >= 0.9, "face boxes differ: {c:?} {f:?}");
        }
        for (c, f) in found[0].1.iter().zip(&found[1].1) {
            assert!(iou(c, f) >= 0.9, "body boxes differ: {c:?} {f:?}");
        }
    }

    /// Real models on real pictures. `SQ_PEOPLE_FACE_PPM` is a portrait (a face), `SQ_PEOPLE_BODIES_PPM` a picture of full-body
    /// people; the models download into `SQ_PERSON_MODELS` or a temp folder (needs the ONNX Runtime on PATH).
    #[test]
    fn real_faces_and_bodies_are_found_on_real_pictures() {
        let (Ok(face_path), Ok(body_path)) =
            (std::env::var("SQ_PEOPLE_FACE_PPM"), std::env::var("SQ_PEOPLE_BODIES_PPM"))
        else {
            eprintln!("skipped: SQ_PEOPLE_FACE_PPM / SQ_PEOPLE_BODIES_PPM are not set");
            return;
        };
        let folder = std::env::var("SQ_PERSON_MODELS")
            .map_or_else(|_| std::env::temp_dir().join("sq-people-test-models"), PathBuf::from);
        let det = match OnnxPeopleDetector::open(&folder) {
            Ok(d) => d,
            Err(e) => {
                eprintln!("skipped: {e}");
                return;
            }
        };
        let (Some(face_frame), Some(body_frame)) = (read_ppm(&face_path), read_ppm(&body_path)) else {
            panic!("cannot read the test pictures");
        };
        let subjects = subjects_of(&det, &face_frame).unwrap_or_else(|e| panic!("{e}"));
        eprintln!("portrait: {subjects:?}");
        let faces: Vec<_> = subjects.iter().filter(|s| s.kind == SubjectKind::Face).collect();
        assert_eq!(faces.len(), 1, "one face expected");
        let r = faces[0].rect;
        // The face is in the upper middle of the picture and of plausible size.
        assert!(r.x > 0.2 && r.x + r.width < 0.95 && r.y < 0.5 && r.width > 0.15 && r.width < 0.7, "{r:?}");
        assert!(faces[0].confidence > 0.6);

        let (bodies, faces) = det.detect(&body_frame, true).unwrap_or_else(|e| panic!("{e}"));
        eprintln!("people picture: {} bodies {bodies:?}, {} faces", bodies.len(), faces.len());
        assert!(!bodies.is_empty(), "at least one person");
        assert!(bodies.iter().all(|b| b.width > 0.01 && b.height > 0.05 && b.x + b.width <= 1.0 + 1e-9));
        // The Reframe path: the frame source feeds `subjects`, and the focus lands on the face.
        let frame = face_frame.clone();
        let reframe = OnnxSubjectDetector::new(&folder, Box::new(move |_| Ok(Some(frame.clone()))))
            .unwrap_or_else(|e| panic!("{e}"));
        let boxes = reframe.subjects(Time::new(0, 1)).unwrap_or_else(|e| panic!("{e}"));
        let focus = crate::reframe::ReframeFocus::focus(&boxes, 0.5).unwrap_or_else(|| panic!("no focus"));
        assert!(
            (focus.x - (r.x + r.width / 2.0)).abs() < 1e-9 && (focus.y - (r.y + r.height / 2.0)).abs() < 1e-9,
            "{focus:?}"
        );
        // Faces only: the second return is empty.
        assert!(det.detect(&body_frame, false).is_ok_and(|(b, _)| b.is_empty()));
    }
}
