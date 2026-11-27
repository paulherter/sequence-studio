// Swift: Anonymize.swift (SQAnalysis `Anonymizer`, `AnonymizeFrameRefiner`), AnonymizeSearch.swift (`findEveryone`)
//! The Anonymize analysis: finds everyone across a clip (sampled frames, sightings linked into one entry per person) and
//! follows each chosen person over the clip with the Magic mask tracker, storing the whole-person matte and, for Face and
//! Skin, the narrowed matte under staged keys until the masks are written.
//!
//! Portable counterpart of the Mac's Vision path. Decision: Vision gives per-object labels (`AnonymizePeople::find`); the
//! ONNX path has no instance segmenter, so a person is a body box (YOLOX) with the face (YuNet) inside it, picked at the
//! face (or the upper body), and EdgeTAM (the Magic Mask tracker of this app) segments and follows them from that point.
//! The tracker is the same one Swift uses for Anonymize (`MagicMaskTracker`), here on EdgeTAM.

use super::magic_job::{TrackFrames, Tracker};
use sq_analysis::analysis_turn::CancelToken;
use sq_analysis::anonymize_search::{AnonymizeSearch, AnonymizeSighting};
use sq_analysis::edge_tamonnx::SubjectFrame;
use sq_analysis::frame_matte_store::FrameMatteStore;
use sq_core_masks::anonymize::{
    AnonymizeBox, AnonymizeCheck, AnonymizeFace, AnonymizePerson, AnonymizeReason, AnonymizeRefiner, AnonymizeReport,
    MagicSelectionAnonymizeExt,
};
use sq_core_masks::magic_correction::GRID_MAX;
use sq_core_masks::magic_follow::MagicGuide;
use sq_core_masks::magic_mask::MagicSelectionExt;
use sq_core_masks::subject_mask::SubjectMatte;
use sq_core_model::{AnonymizeTarget, MagicPoint, MagicSelection};
use sq_core_time::{Id, Time, Vec2};

/// How a person on one frame is told from the person on the next (frame fractions), as the Swift default.
const LINK_REACH: f64 = 0.2;
/// Matte keys of a run start with this until the masks are written (`MagicMatteStore.stagedPrefix`).
pub const STAGED_PREFIX: &str = "staged-";

/// Why a run did not finish.
#[derive(Clone, Debug, PartialEq)]
pub enum AnonymizeError {
    /// The user canceled.
    Canceled,
    /// A frame, the detector or the tracker failed.
    Failed(String),
}

/// Where the frames, the detectors and the tracker come from (the system: FFmpeg frames, ONNX models; tests: fakes).
pub trait AnonymizeSources: Send + Sync {
    /// The frame shown at `seconds` (upright) and its source time; `None` = no frame there.
    fn shown(&self, seconds: f64) -> Result<Option<(f64, SubjectFrame)>, String>;
    /// The frames of a run from `from` to `to` (source seconds, `to` before `from` runs backward), the pick frame first.
    fn frames(&self, from: f64, to: f64) -> Result<Box<dyn TrackFrames>, String>;
    /// A new tracker session (the model is loaded once and shared).
    fn tracker(&self) -> Result<Box<dyn Tracker>, String>;
    /// Face and body boxes of an upright frame; `bodies` false = faces only.
    fn detect(&self, frame: &SubjectFrame, bodies: bool) -> Result<(Vec<AnonymizeBox>, Vec<AnonymizeFace>), String>;
}

/// Mattes of a run, stored under a staged key until the result is taken over.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Staged {
    /// The staged key.
    pub temp: String,
    /// The key under which the masks read them.
    pub key: String,
}

/// What a run found.
#[derive(Clone, Debug, PartialEq)]
pub struct Outcome {
    /// Frames to look at by hand, in time order per person.
    pub checks: Vec<AnonymizeCheck>,
    /// Frames stored over all people.
    pub frames: usize,
    /// Where the mattes are: `commit` moves them under the masks' keys, `discard` forgets them.
    pub staged: Vec<Staged>,
}

/// The people of one frame from the detectors: every body box is one person (with the best face inside it); a face no body
/// holds is a person of its own, with an estimated body. Left to right.
pub fn people_in(bodies: &[AnonymizeBox], faces: &[AnonymizeFace]) -> Vec<AnonymizePerson> {
    let bodies = &distinct(bodies)[..];
    let mut by_confidence = faces.to_vec();
    by_confidence.sort_by(|a, b| b.confidence.total_cmp(&a.confidence));
    let mut face_of: Vec<Option<AnonymizeFace>> = vec![None; bodies.len()];
    let mut alone: Vec<AnonymizeFace> = Vec::new();
    for f in by_confidence {
        let c = f.box_.center();
        let inside = |b: &AnonymizeBox| c.x >= b.x && c.x <= b.x + b.width && c.y >= b.y && c.y <= b.y + b.height;
        // The smallest body around the face that has no face yet.
        let home = (0..bodies.len())
            .filter(|&i| face_of[i].is_none() && inside(&bodies[i]))
            .min_by(|&a, &b| (bodies[a].width * bodies[a].height).total_cmp(&(bodies[b].width * bodies[b].height)));
        match home {
            Some(i) => face_of[i] = Some(f),
            None => alone.push(f),
        }
    }
    let mut people: Vec<AnonymizePerson> = bodies
        .iter()
        .zip(face_of)
        .map(|(b, face)| AnonymizePerson {
            label: 0,
            point: face.map_or(Vec2::new(b.x + b.width / 2.0, b.y + b.height * 0.25), |f| f.box_.center()),
            box_: *b,
            face,
        })
        .collect();
    for f in alone {
        let (w, h) = ((f.box_.width * 2.5).min(1.0), (f.box_.height * 5.0).min(1.0));
        let x = (f.box_.center().x - w / 2.0).clamp(0.0, 1.0 - w);
        let y = (f.box_.y - f.box_.height * 0.2).clamp(0.0, 1.0 - h);
        people.push(AnonymizePerson {
            label: 0,
            point: f.box_.center(),
            box_: AnonymizeBox { x, y, width: w, height: h },
            face: Some(f),
        });
    }
    people.sort_by(|a, b| a.box_.center().x.total_cmp(&b.box_.center().x));
    for (i, p) in people.iter_mut().enumerate() {
        p.label = (i + 1).min(255) as u8;
    }
    people
}

/// The boxes without the ones that sit inside another (the detector may box one person twice, the whole body and the
/// upper part): a box that lies at least 80 % inside a larger one is the same person.
fn distinct(boxes: &[AnonymizeBox]) -> Vec<AnonymizeBox> {
    let area = |b: &AnonymizeBox| b.width * b.height;
    let inside = |a: &AnonymizeBox, b: &AnonymizeBox| {
        let (w, h) =
            ((a.x + a.width).min(b.x + b.width) - a.x.max(b.x), (a.y + a.height).min(b.y + b.height) - a.y.max(b.y));
        w > 0.0 && h > 0.0 && w * h >= 0.8 * area(a)
    };
    let mut order: Vec<usize> = (0..boxes.len()).collect();
    order.sort_by(|&a, &b| area(&boxes[b]).total_cmp(&area(&boxes[a])));
    let mut kept: Vec<usize> = Vec::new();
    for i in order {
        if !kept.iter().any(|&k| inside(&boxes[i], &boxes[k])) {
            kept.push(i);
        }
    }
    kept.sort_unstable();
    kept.into_iter().map(|i| boxes[i]).collect()
}

/// Everyone who shows up on the sampled frames of the clip (`AnonymizeSearch::default_sample_times`), linked into one
/// entry per person. `Ok(None)` = no frame could be read at all. `progress` 0...1 over the frames.
pub fn find_everyone(
    src: &dyn AnonymizeSources,
    first: f64,
    last: f64,
    anchor: f64,
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
    hold: &mut dyn FnMut(bool),
) -> Result<Option<Vec<AnonymizeSighting>>, AnonymizeError> {
    let times = AnonymizeSearch::default_sample_times(first, last, anchor);
    let mut samples: Vec<(f64, Vec<AnonymizePerson>)> = Vec::new();
    for (i, t) in times.iter().enumerate() {
        super::pacing::yield_shared(cancel, hold);
        if cancel.is_cancelled() {
            return Err(AnonymizeError::Canceled);
        }
        if let Some((pts, frame)) = src.shown(*t).map_err(AnonymizeError::Failed)? {
            let (bodies, faces) = src.detect(&frame, true).map_err(AnonymizeError::Failed)?;
            samples.push((pts, people_in(&bodies, &faces)));
        }
        progress((i + 1) as f64 / times.len() as f64);
    }
    let Some(nearest) = samples.iter().map(|s| s.0).min_by(|a, b| (a - anchor).abs().total_cmp(&(b - anchor).abs()))
    else {
        return Ok(None);
    };
    Ok(Some(AnonymizeSearch::link(&samples, nearest, LINK_REACH)))
}

/// The pick that follows `person` found on the frame at `pts`.
pub fn selection(person: &AnonymizePerson, pts: f64, target: AnonymizeTarget) -> MagicSelection {
    let t = Time::new((pts * 90_000.0).round() as i64, 90_000);
    MagicSelection {
        points: vec![MagicPoint { position: person.point, subtract: false, source_time: t }],
        part: Some(target),
    }
}

/// Takes a run's mattes over under the masks' own keys (after the masks were written into the clip). Mattes of an earlier
/// run at other times stay.
pub fn commit(staged: &[Staged], store: &FrameMatteStore) {
    for s in staged {
        store.copy_frames(&s.temp, &s.key, |_| true);
        store.remove(&s.temp);
        store.save_later(&s.key);
    }
}

/// Forgets a run's mattes; mattes a mask already draws are not touched.
pub fn discard(staged: &[Staged], store: &FrameMatteStore) {
    for s in staged {
        store.remove(&s.temp);
    }
}

/// The color guide of the Skin refinement: the frame at most `GRID_MAX` px a side.
fn guide_of(frame: &SubjectFrame) -> Option<MagicGuide> {
    let (w, h) = (frame.width, frame.height);
    if w == 0 || h == 0 || frame.rgba.len() < w * h * 4 {
        return None;
    }
    let s = (GRID_MAX as f64 / w.max(h) as f64).min(1.0);
    let (gw, gh) = (((w as f64 * s).round() as usize).max(1), ((h as f64 * s).round() as usize).max(1));
    let mut rgb = Vec::with_capacity(gw * gh * 3);
    for y in 0..gh {
        for x in 0..gw {
            let (sx, sy) = ((x * w / gw).min(w - 1), (y * h / gh).min(h - 1));
            let i = (sy * w + sx) * 4;
            rgb.extend(frame.rgba[i..i + 3].iter().map(|v| f32::from(*v) / 255.0));
        }
    }
    Some(MagicGuide::new(gw, gh, rgb))
}

/// One direction of one person: frames stored, flagged frames and where the person was lost (source seconds).
struct Direction {
    frames: usize,
    flags: Vec<(f64, AnonymizeReason)>,
    lost_at: Option<f64>,
}

#[allow(clippy::too_many_arguments)]
fn follow_direction(
    src: &dyn AnonymizeSources,
    pick: &MagicSelection,
    keys: (&str, Option<&str>),
    from: f64,
    to: f64,
    store: &FrameMatteStore,
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
    hold: &mut dyn FnMut(bool),
) -> Result<Direction, AnonymizeError> {
    let fail = AnonymizeError::Failed;
    let mut frames = src.frames(from, to).map_err(fail)?;
    let mut tracker = src.tracker().map_err(AnonymizeError::Failed)?;
    let part = pick.part.unwrap_or(AnonymizeTarget::Person);
    // One refiner per direction: both start at the pick's frame, where the person was found.
    let mut refiner = keys.1.map(|_| AnonymizeRefiner::new(part));
    let points: Vec<(Vec2, bool)> = pick.points.iter().map(|p| (p.position, p.subtract)).collect();
    let total = frames.count();
    let mut out = Direction { frames: 0, flags: Vec::new(), lost_at: None };
    for i in 0..total {
        super::pacing::yield_shared(cancel, hold);
        if cancel.is_cancelled() {
            return Err(AnonymizeError::Canceled);
        }
        let Some((pts, frame)) = frames.frame(i) else {
            return Err(AnonymizeError::Failed("a frame could not be read".to_string()));
        };
        let matte: Option<SubjectMatte> = if i == 0 {
            Some(tracker.start(&frame, &points).map_err(AnonymizeError::Failed)?)
        } else {
            tracker.next(&frame).map_err(AnonymizeError::Failed)?
        };
        let Some(matte) = matte else {
            out.lost_at = Some(pts);
            break;
        };
        if let (Some(r), Some(part_key)) = (refiner.as_mut(), keys.1) {
            // A detector that fails on a frame is a frame without a face: covered by estimate and listed, never skipped.
            let faces = src.detect(&frame, false).map(|d| d.1).unwrap_or_default();
            let guide = if part == AnonymizeTarget::Skin { guide_of(&frame) } else { None };
            let (narrowed, flag) = r.refine(&matte, &faces, guide.as_ref());
            store.put(part_key, pts, narrowed);
            out.flags.extend(flag.map(|f| (pts, f)));
        }
        store.put(keys.0, pts, matte);
        out.frames += 1;
        progress((i + 1) as f64 / total.max(1) as f64);
    }
    Ok(out)
}

/// Follows every pick from its own frame to `last` and back to `first` (source seconds of the clip's edge frames).
/// `frame_gap`: seconds between two frames (joins flagged frames into ranges). The mattes are stored under staged keys
/// (`Outcome::staged`), never under a mask's key: a pick on the same frame as an applied mask has that mask's key, so a run
/// that is canceled, fails or is refused must leave it alone. A run that fails has removed its staged mattes.
#[allow(clippy::too_many_arguments)]
pub fn run(
    src: &dyn AnonymizeSources,
    picks: &[MagicSelection],
    media: Id,
    first: f64,
    last: f64,
    frame_gap: f64,
    store: &FrameMatteStore,
    stage_id: &str,
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
    hold: &mut dyn FnMut(bool),
) -> Result<Outcome, AnonymizeError> {
    let prefix = format!("{STAGED_PREFIX}{stage_id}-");
    let mut out = Outcome { checks: Vec::new(), frames: 0, staged: Vec::new() };
    for pick in picks {
        for k in pick.matte_keys(media) {
            if !out.staged.iter().any(|s| s.key == k) {
                out.staged.push(Staged { temp: format!("{prefix}{k}"), key: k });
            }
        }
    }
    match follow(src, picks, media, (first, last, frame_gap), store, &prefix, cancel, progress, hold, &mut out) {
        Ok(()) => {
            progress(1.0);
            Ok(out)
        }
        Err(e) => {
            discard(&out.staged, store);
            Err(e)
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn follow(
    src: &dyn AnonymizeSources,
    picks: &[MagicSelection],
    media: Id,
    span: (f64, f64, f64),
    store: &FrameMatteStore,
    prefix: &str,
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
    hold: &mut dyn FnMut(bool),
    out: &mut Outcome,
) -> Result<(), AnonymizeError> {
    let (first, last, frame_gap) = span;
    let total = picks.len().max(1) as f64;
    for (i, pick) in picks.iter().enumerate() {
        let Some(t) = pick.anchor_time() else { continue };
        let anchor = t.value() as f64 / t.timescale().max(1) as f64;
        let key = format!("{prefix}{}", pick.cache_key(media));
        let part_key = pick.part_key(media).map(|k| format!("{prefix}{k}"));
        let extent = (last - first).max(1e-3);
        let forward_share = ((last - anchor) / extent).clamp(0.0, 1.0);
        let mut flags: Vec<(f64, AnonymizeReason)> = Vec::new();
        let mut lost: Vec<AnonymizeCheck> = Vec::new();
        for forward in [true, false] {
            let to = if forward { last } else { first };
            if !forward && anchor - first <= 1e-4 {
                continue;
            }
            let mut report = |p: f64| {
                let done = if forward { p * forward_share } else { forward_share + p * (1.0 - forward_share) };
                progress((i as f64 + done) / total);
            };
            let d =
                follow_direction(src, pick, (&key, part_key.as_deref()), anchor, to, store, cancel, &mut report, hold)?;
            out.frames += d.frames;
            flags.extend(d.flags);
            if d.frames == 0 {
                // Nothing to follow from the pick's frame: the whole direction is unchecked.
                lost.push(AnonymizeCheck {
                    person: i,
                    reason: AnonymizeReason::Lost,
                    from: anchor.min(to),
                    to: anchor.max(to),
                });
            } else if let Some(at) = d.lost_at {
                // From the frame the person was lost to the clip's edge the cover is the enlarged last place.
                lost.push(AnonymizeCheck {
                    person: i,
                    reason: AnonymizeReason::Lost,
                    from: at.min(to),
                    to: at.max(to),
                });
            }
        }
        let mut checks = AnonymizeReport::ranges(i, &flags, frame_gap);
        checks.extend(lost);
        checks.sort_by(|a, b| a.from.total_cmp(&b.from));
        out.checks.extend(checks);
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests;
