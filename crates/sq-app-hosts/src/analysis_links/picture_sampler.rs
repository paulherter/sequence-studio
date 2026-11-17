//! The Program picture read back as working-linear samples (Swift `ProgramFrameSampling`, answered from the monitor's
//! newest composite). A request waits for a newer picture than the one shown when it was made, so a solo view set just
//! before it is not read stale; after `SETTLE` it takes whatever is shown (a second capture of an unchanged frame).

use crate::{LinearImage, MonitorPicture};
use sq_editor_session::ProgramFrameSampling;
use std::cell::RefCell;
use std::rc::Rc;
use std::time::{Duration, Instant};

/// How long a request waits for a newer picture before it reads the shown one.
const SETTLE: Duration = Duration::from_millis(150);

/// What a request reads from the picture.
#[derive(Clone, Copy)]
enum Read {
    /// The whole picture scaled to about this many columns.
    Scaled(usize),
    /// The mean of a square patch around a frame fraction.
    Patch([f64; 2], i64),
}

struct Request {
    key: String,
    read: Read,
    generation: i64,
    since: Instant,
}

/// A sampler over the monitor picture; clones share the pending requests (one sits in the flows, one is polled).
#[derive(Clone)]
pub struct PictureSampler {
    picture: MonitorPicture,
    pending: Rc<RefCell<Vec<Request>>>,
}

impl PictureSampler {
    pub fn new(picture: MonitorPicture) -> PictureSampler {
        PictureSampler { picture, pending: Rc::default() }
    }

    /// The answer of the request under `key` once its picture is there: `Some(None)` = no picture to read.
    pub fn take_ready(&self, key: &str) -> Option<Option<Vec<[f32; 3]>>> {
        let ready = {
            let mut pending = self.pending.borrow_mut();
            let i = pending.iter().position(|r| {
                r.key == key && (self.picture.generation() != r.generation || r.since.elapsed() >= SETTLE)
            })?;
            pending.remove(i)
        };
        Some(self.picture.linear().and_then(|image| match ready.read {
            Read::Scaled(width) => downsample(&image, width),
            Read::Patch(at, radius) => patch_mean(&image, at, radius).map(|rgb| vec![rgb]),
        }))
    }

    /// True while a request under `key` waits.
    pub fn is_waiting(&self, key: &str) -> bool {
        self.pending.borrow().iter().any(|r| r.key == key)
    }

    /// Drops the request under `key` (a run that timed out).
    pub fn cancel(&self, key: &str) {
        self.pending.borrow_mut().retain(|r| r.key != key);
    }
}

impl ProgramFrameSampling for PictureSampler {
    fn sample_linear(&mut self, width: i64, key: &str) {
        let mut pending = self.pending.borrow_mut();
        pending.retain(|r| r.key != key);
        pending.push(Request {
            key: key.to_string(),
            read: Read::Scaled(usize::try_from(width).unwrap_or(1).max(1)),
            generation: self.picture.generation(),
            since: Instant::now(),
        });
    }

    fn sample_patch(&mut self, position: [f64; 2], radius: i64, key: &str) {
        let mut pending = self.pending.borrow_mut();
        pending.retain(|r| r.key != key);
        pending.push(Request {
            key: key.to_string(),
            read: Read::Patch(position, radius),
            generation: self.picture.generation(),
            since: Instant::now(),
        });
    }
}

/// The patch rectangle around a 0...1 position, clamped to the picture (Swift `FrameSampler.patch`): x, y, width, height.
pub(crate) fn patch(width: usize, height: usize, at: [f64; 2], radius: i64) -> Option<(usize, usize, usize, usize)> {
    if width == 0 || height == 0 || !at[0].is_finite() || !at[1].is_finite() {
        return None;
    }
    let (w, h) = (i64::try_from(width).ok()?, i64::try_from(height).ok()?);
    // `Int(p * size)` truncates toward zero, then the clamp
    let cx = ((at[0] * w as f64) as i64).clamp(0, w - 1);
    let cy = ((at[1] * h as f64) as i64).clamp(0, h - 1);
    let (x0, y0) = ((cx - radius).max(0), (cy - radius).max(0));
    let (x1, y1) = ((cx + radius).min(w - 1), (cy + radius).min(h - 1));
    Some((x0 as usize, y0 as usize, (x1 - x0 + 1) as usize, (y1 - y0 + 1) as usize))
}

fn half_at(image: &LinearImage, i: usize) -> f32 {
    f32::from(exr::prelude::f16::from_bits(u16::from_le_bytes([image.bytes[i * 2], image.bytes[i * 2 + 1]])))
}

/// Mean linear RGB of the (2 * radius + 1) squared patch around `at` (Swift `ProgramLinearFrame.average` /
/// `FrameSampler.sampleColor`): a position outside the picture reads the nearest edge patch; `None` for an empty picture.
pub fn patch_mean(image: &LinearImage, at: [f64; 2], radius: i64) -> Option<[f32; 3]> {
    let (w, h) = (image.width, image.height);
    if w == 0 || h == 0 || image.bytes.len() != w * h * 8 {
        return None;
    }
    let (x0, y0, pw, ph) = patch(w, h, at, radius)?;
    let mut sum = [0.0_f32; 3];
    for y in y0..y0 + ph {
        for x in x0..x0 + pw {
            let i = (y * w + x) * 4;
            (0..3).for_each(|c| sum[c] += half_at(image, i + c));
        }
    }
    let n = (pw * ph) as f32;
    Some(sum.map(|s| s / n))
}

/// Box average of the composite down to about `width` columns, rows top down, linear RGB (alpha dropped).
fn downsample(image: &LinearImage, width: usize) -> Option<Vec<[f32; 3]>> {
    let (w, h) = (image.width, image.height);
    if w == 0 || h == 0 || image.bytes.len() != w * h * 8 {
        return None;
    }
    let out_w = width.min(w);
    let out_h = (h * out_w / w).max(1);
    let half = |i: usize| half_at(image, i);
    let mut out = Vec::with_capacity(out_w * out_h);
    for oy in 0..out_h {
        let (y0, y1) = (oy * h / out_h, ((oy + 1) * h / out_h).max(oy * h / out_h + 1));
        for ox in 0..out_w {
            let (x0, x1) = (ox * w / out_w, ((ox + 1) * w / out_w).max(ox * w / out_w + 1));
            let mut sum = [0.0_f32; 3];
            for y in y0..y1 {
                for x in x0..x1 {
                    let i = (y * w + x) * 4;
                    (0..3).for_each(|c| sum[c] += half(i + c));
                }
            }
            let n = ((y1 - y0) * (x1 - x0)) as f32;
            out.push(sum.map(|s| s / n));
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(w: usize, h: usize, rgb: [f32; 3]) -> LinearImage {
        let mut bytes = Vec::new();
        for _ in 0..w * h {
            for v in [rgb[0], rgb[1], rgb[2], 1.0] {
                bytes.extend(exr::prelude::f16::from_f32(v).to_bits().to_le_bytes());
            }
        }
        LinearImage { width: w, height: h, bytes }
    }

    #[test]
    fn downsample_keeps_the_aspect_and_the_mean() {
        let samples = downsample(&image(200, 100, [0.5, 0.25, 0.0]), 96).expect("samples");
        assert_eq!(samples.len(), 96 * 48);
        assert!(samples.iter().all(|p| (p[0] - 0.5).abs() < 1e-3 && (p[1] - 0.25).abs() < 1e-3 && p[2] == 0.0));
    }

    #[test]
    fn a_request_waits_for_a_newer_picture() {
        let picture = MonitorPicture::default();
        let mut sampler = PictureSampler::new(picture.clone());
        sampler.sample_linear(96, "k");
        assert!(sampler.is_waiting("k"));
        assert!(sampler.take_ready("k").is_none(), "same picture, not settled");
        picture.set(None);
        assert_eq!(sampler.take_ready("k"), Some(None), "a newer picture without linear data answers none");
        assert!(!sampler.is_waiting("k"));
    }

    #[test]
    fn a_patch_request_answers_the_mean_of_the_five_by_five_patch_clamped_at_the_edge() {
        let mut bytes = Vec::new();
        for i in 0..10 * 10 {
            let v = if i == 0 { 1.0 } else { 0.0 };
            for c in [v, 0.0, 0.0, 1.0] {
                bytes.extend(exr::prelude::f16::from_f32(c).to_bits().to_le_bytes());
            }
        }
        let frame = || LinearImage { width: 10, height: 10, bytes: bytes.clone() };
        // the corner patch is cut to 3 x 3 cells, one of them red
        let corner = patch_mean(&frame(), [0.0, 0.0], 2).expect("patch");
        assert!((corner[0] - 1.0 / 9.0).abs() < 1e-3 && corner[1] == 0.0);
        // far inside: the whole patch is black
        assert_eq!(patch_mean(&frame(), [0.5, 0.5], 2), Some([0.0; 3]));
        assert!(patch_mean(&frame(), [f64::NAN, 0.5], 2).is_none());

        let picture = MonitorPicture::default();
        let mut sampler = PictureSampler::new(picture.clone());
        sampler.sample_patch([0.0, 0.0], 2, "color.pick");
        assert!(sampler.is_waiting("color.pick"));
        // a newer picture arrives with its linear copy
        picture.set(None);
        let reader = move || Some(LinearImage { width: 10, height: 10, bytes: bytes.clone() });
        picture.set_linear(Some(std::sync::Arc::new(reader)));
        let answer = sampler.take_ready("color.pick").expect("a newer picture is there").expect("one sample");
        assert_eq!(answer.len(), 1, "a patch answers one color");
        assert!((answer[0][0] - 1.0 / 9.0).abs() < 1e-3);
    }
}
