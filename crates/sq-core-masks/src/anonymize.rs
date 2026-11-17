// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Anonymize.swift (pure part; `Clip.addAnonymize` waits on the effects crate, see NOTES.md)
//! Anonymize (pure part). The command covers a person with a Mosaic or a blur: every person is one Magic mask (the
//! existing tracker follows the person), the cover is one effect that takes those masks as its input. Face and Skin
//! narrow the person's matte per frame (`AnonymizeRefiner`); frames where that was a guess are listed for a manual check
//! (`AnonymizeCheck`). Detection (Vision) sits in SQAnalysis.

use crate::magic_follow::MagicGuide;
use crate::magic_mask::{InstanceLabels, MagicSelectionExt};
use crate::subject_mask::SubjectMatte;
use sq_core_model::{AnonymizeTarget, MagicSelection};
use sq_core_time::{Id, Vec2};
use std::collections::BTreeMap;
use std::ops::Range;

/// Logic Swift keeps on `AnonymizeTarget`.
pub trait AnonymizeTargetExt {
    /// Display name.
    fn title(self) -> &'static str;
    /// Name of the masks a run makes ("Face 1", "Person 2").
    fn mask_name(self) -> &'static str;
    /// The stored raw value.
    fn raw_value(self) -> &'static str;
}

impl AnonymizeTargetExt for AnonymizeTarget {
    fn title(self) -> &'static str {
        match self {
            AnonymizeTarget::Face => "Face",
            AnonymizeTarget::Person => "Whole Person",
            AnonymizeTarget::Skin => "Skin",
        }
    }

    fn mask_name(self) -> &'static str {
        match self {
            AnonymizeTarget::Face => "Face",
            AnonymizeTarget::Person => "Person",
            AnonymizeTarget::Skin => "Skin",
        }
    }

    fn raw_value(self) -> &'static str {
        match self {
            AnonymizeTarget::Face => "face",
            AnonymizeTarget::Person => "person",
            AnonymizeTarget::Skin => "skin",
        }
    }
}

/// What covers it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AnonymizeCover {
    /// Blocks.
    Mosaic,
    /// Gaussian blur.
    Blur,
}

impl AnonymizeCover {
    /// Display name.
    pub fn title(self) -> &'static str {
        if self == AnonymizeCover::Mosaic { "Mosaic" } else { "Blur" }
    }
}

/// A box in fractions of the upright frame, origin top left, y down.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnonymizeBox {
    /// Left.
    pub x: f64,
    /// Top.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

impl AnonymizeBox {
    /// The middle point.
    pub fn center(&self) -> Vec2 {
        Vec2::new(self.x + self.width / 2.0, self.y + self.height / 2.0)
    }

    /// The middle of the box: `share` of its width and height.
    pub fn inner(&self, share: f64) -> AnonymizeBox {
        AnonymizeBox {
            x: self.x + self.width * (1.0 - share) / 2.0,
            y: self.y + self.height * (1.0 - share) / 2.0,
            width: self.width * share,
            height: self.height * share,
        }
    }

    /// Texel range of the box in a `w` x `h` grid (at least one texel, inside the grid); `None` when it lies outside.
    pub fn texels(&self, w: usize, h: usize) -> Option<(Range<usize>, Range<usize>)> {
        let x0 = ((self.x * w as f64).floor() as i64).max(0);
        let y0 = ((self.y * h as f64).floor() as i64).max(0);
        let x1 = ((((self.x + self.width) * w as f64).ceil()) as i64).min(w as i64);
        let y1 = ((((self.y + self.height) * h as f64).ceil()) as i64).min(h as i64);
        if !(x0 < w as i64 && y0 < h as i64 && x1 > 0 && y1 > 0) {
            return None;
        }
        Some((x0 as usize..x1.max(x0 + 1) as usize, y0 as usize..y1.max(y0 + 1) as usize))
    }
}

/// A detected face: its box and the detector's confidence 0...1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnonymizeFace {
    /// The box.
    pub box_: AnonymizeBox,
    /// 0...1.
    pub confidence: f64,
}

/// A person found on a frame: the segmented object, a point on it (a Magic pick there selects it), its extent and its
/// face when one was detected.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnonymizePerson {
    /// The object label.
    pub label: u8,
    /// A point on the object.
    pub point: Vec2,
    /// Its extent.
    pub box_: AnonymizeBox,
    /// Its face.
    pub face: Option<AnonymizeFace>,
}

/// Finding the people of a segmented frame.
pub struct AnonymizePeople;

impl AnonymizePeople {
    /// A detected box belongs to the object that fills at least this share of it.
    const MIN_SHARE: f64 = 0.15;

    /// The segmented objects that are people: those under a detected face or body box. Left to right. Objects no
    /// detection points at (things, animals) are left out.
    pub fn find(labels: &InstanceLabels, bodies: &[AnonymizeBox], faces: &[AnonymizeFace]) -> Vec<AnonymizePerson> {
        let mut found: Vec<u8> = Vec::new();
        let mut face_of: BTreeMap<u8, AnonymizeFace> = BTreeMap::new();
        let mut by_confidence = faces.to_vec();
        by_confidence.sort_by(|a, b| b.confidence.total_cmp(&a.confidence));
        for f in &by_confidence {
            let Some(l) = Self::dominant(labels, &f.box_.inner(0.5)) else { continue };
            if face_of.contains_key(&l) {
                continue;
            }
            face_of.insert(l, *f);
            found.push(l);
        }
        for b in bodies {
            let Some(l) = Self::dominant(labels, b) else { continue };
            if found.contains(&l) {
                continue;
            }
            found.push(l);
        }
        let mut people: Vec<AnonymizePerson> = found
            .iter()
            .filter_map(|&l| {
                let box_ = Self::extent(l, labels)?;
                let face = face_of.get(&l).copied();
                let p = Self::point(l, labels, face.map_or(box_.center(), |f| f.box_.center()))?;
                Some(AnonymizePerson { label: l, point: p, box_, face })
            })
            .collect();
        people.sort_by(|a, b| a.box_.center().x.total_cmp(&b.box_.center().x));
        people
    }

    /// The object that fills most of `box_` (at least `MIN_SHARE` of it), `None` when that is the background.
    fn dominant(l: &InstanceLabels, box_: &AnonymizeBox) -> Option<u8> {
        let r = box_.texels(l.width(), l.height())?;
        let mut count = [0_usize; 256];
        for y in r.1.clone() {
            for x in r.0.clone() {
                count[usize::from(l.labels[y * l.width() + x])] += 1;
            }
        }
        let mut best = 0;
        for i in 1..256 {
            if count[i] > count[best] || (best == 0 && count[i] > 0) {
                best = i;
            }
        }
        if best == 0 || (count[best] as f64) < Self::MIN_SHARE * (r.0.len() * r.1.len()) as f64 {
            return None;
        }
        Some(best as u8)
    }

    fn extent(label: u8, l: &InstanceLabels) -> Option<AnonymizeBox> {
        let (mut x0, mut x1, mut y0, mut y1) = (l.width() as i64, -1_i64, l.height() as i64, -1_i64);
        for y in 0..l.height() {
            for x in 0..l.width() {
                if l.labels[y * l.width() + x] == label {
                    let (xi, yi) = (x as i64, y as i64);
                    x0 = x0.min(xi);
                    x1 = x1.max(xi);
                    y0 = y0.min(yi);
                    y1 = y1.max(yi);
                }
            }
        }
        if x1 < 0 {
            return None;
        }
        let (w, h) = (l.width() as f64, l.height() as f64);
        Some(AnonymizeBox {
            x: x0 as f64 / w,
            y: y0 as f64 / h,
            width: (x1 - x0 + 1) as f64 / w,
            height: (y1 - y0 + 1) as f64 / h,
        })
    }

    /// The texel center of `label` nearest `p` (frame fractions).
    fn point(label: u8, l: &InstanceLabels, p: Vec2) -> Option<Vec2> {
        let mut best: Option<Vec2> = None;
        let mut best_d = f64::INFINITY;
        let (w, h) = (l.width() as f64, l.height() as f64);
        for y in 0..l.height() {
            for x in 0..l.width() {
                if l.labels[y * l.width() + x] != label {
                    continue;
                }
                let q = Vec2::new((x as f64 + 0.5) / w, (y as f64 + 0.5) / h);
                let (dx, dy) = ((q.x - p.x) * w, (q.y - p.y) * h);
                let d = dx * dx + dy * dy;
                if d < best_d {
                    best_d = d;
                    best = Some(q);
                }
            }
        }
        best
    }
}

/// Why a stretch of frames is listed for a manual check.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AnonymizeReason {
    /// The tracker lost the person: from here to the clip's edge the cover is the last followed matte, enlarged
    /// (`AnonymizeFallback`), so the person may be outside it.
    Lost,
    /// No face was detected: the cover sits where the face was last seen on the person (or at the head end).
    NoFace,
    /// A face was detected with low confidence.
    LowConfidence,
    /// Skin could not be told apart: the whole person is covered.
    WholePerson,
}

impl AnonymizeReason {
    /// The explanation shown in the list.
    pub fn text(self) -> &'static str {
        match self {
            AnonymizeReason::Lost => "Person not followed: the cover stays where they were last seen, enlarged",
            AnonymizeReason::NoFace => "No face detected: the cover is placed by estimate",
            AnonymizeReason::LowConfidence => "Face detected with low confidence",
            AnonymizeReason::WholePerson => "Skin not told apart: the whole person is covered",
        }
    }

    /// The person may be visible on these frames: listed first and never cut from the list.
    pub fn is_critical(self) -> bool {
        self == AnonymizeReason::Lost
    }
}

/// One entry of the list for a manual check: on these frames the cover of a person is a guess or missing.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnonymizeCheck {
    /// Index of the person in the run (0 = first).
    pub person: usize,
    /// Why.
    pub reason: AnonymizeReason,
    /// Source seconds of the first frame.
    pub from: f64,
    /// Source seconds of the last frame.
    pub to: f64,
}

/// Flagged frames as a list of checks.
pub struct AnonymizeReport;

impl AnonymizeReport {
    /// Flagged frames as ranges: frames with the same reason that follow each other (at most `gap` seconds apart, with
    /// half a gap of slack) are one entry. In time order.
    pub fn ranges(person: usize, flags: &[(f64, AnonymizeReason)], gap: f64) -> Vec<AnonymizeCheck> {
        let mut out: Vec<AnonymizeCheck> = Vec::new();
        let mut sorted = flags.to_vec();
        sorted.sort_by(|a, b| a.0.total_cmp(&b.0));
        for f in sorted {
            if let Some(i) = out.iter().rposition(|c| c.reason == f.1).filter(|&i| f.0 - out[i].to <= gap * 1.5 + 1e-6)
            {
                out[i].to = f.0;
            } else {
                out.push(AnonymizeCheck { person, reason: f.1, from: f.0, to: f.0 });
            }
        }
        out.sort_by(|a, b| a.from.total_cmp(&b.from));
        out
    }
}

/// A skin tone as chroma (Cb, Cr around 0) and how far from it still counts.
#[derive(Clone, Copy, Debug, PartialEq)]
struct SkinTone {
    cb: f64,
    cr: f64,
    radius: f64,
}

impl SkinTone {
    /// A wide middle of human skin chroma, used until a face was seen.
    const GENERIC: SkinTone = SkinTone { cb: -0.10, cr: 0.10, radius: 0.09 };

    fn matches(&self, c: (f64, f64)) -> bool {
        let a = c.0 - self.cb;
        let b = c.1 - self.cr;
        a * a + b * b <= self.radius * self.radius
    }
}

/// Narrows a person's matte to the face or to the skin, frame by frame in tracking order. It errs toward covering more:
/// a frame without a usable detection keeps the last known place (Face) or tone (Skin), or the whole person, and is
/// flagged for the check list.
#[derive(Clone, Debug)]
pub struct AnonymizeRefiner {
    part: AnonymizeTarget,
    /// The last face box relative to the person's extent (fractions of it).
    last_face: Option<AnonymizeBox>,
    tone: Option<SkinTone>,
}

impl AnonymizeRefiner {
    /// Faces below this confidence are still used, and flagged.
    pub const MIN_FACE_CONFIDENCE: f64 = 0.5;
    /// A face belongs to the person when the person's matte fills at least this much of the face box's middle.
    const MIN_FACE_COVER: f64 = 0.3;

    /// A refiner for one part.
    pub fn new(part: AnonymizeTarget) -> AnonymizeRefiner {
        AnonymizeRefiner { part, last_face: None, tone: None }
    }

    /// The part this refiner narrows to.
    pub fn part(&self) -> AnonymizeTarget {
        self.part
    }

    /// Continues from mattes stored before (Track from a frame in the middle of a clip, or a correction click): where
    /// the face was on `person` is read from the stored face matte `narrowed` of the same frame, so a first frame
    /// without a detected face is placed there and not at the head end. Skin learns its tone from the next detected face.
    pub fn seed(&mut self, person: &SubjectMatte, narrowed: &SubjectMatte) {
        if self.part != AnonymizeTarget::Face {
            return;
        }
        let (Some(body), Some(e)) = (Self::extent(person), Self::extent(narrowed)) else { return };
        // The stored ellipse is wider than the face box it was made from (`ellipse`); undone here, so guesses do not
        // grow with every Track.
        let w = e.width / (2.0 * 0.95 * 0.94);
        let h = e.height / (2.0 * 1.05 * 0.94);
        let box_ =
            AnonymizeBox { x: e.center().x - w / 2.0, y: e.center().y + 0.08 * h - h / 2.0, width: w, height: h };
        self.last_face = Some(AnonymizeBox {
            x: (box_.x - body.x) / body.width,
            y: (box_.y - body.y) / body.height,
            width: box_.width / body.width,
            height: box_.height / body.height,
        });
    }

    /// The narrowed matte of one frame and why it is a guess, if it is.
    pub fn refine(
        &mut self,
        person: &SubjectMatte,
        faces: &[AnonymizeFace],
        guide: Option<&MagicGuide>,
    ) -> (SubjectMatte, Option<AnonymizeReason>) {
        match self.part {
            AnonymizeTarget::Person => (person.clone(), None),
            AnonymizeTarget::Face => self.face(person, faces),
            AnonymizeTarget::Skin => self.skin(person, faces, guide),
        }
    }

    fn face(&mut self, person: &SubjectMatte, faces: &[AnonymizeFace]) -> (SubjectMatte, Option<AnonymizeReason>) {
        let Some(body) = Self::extent(person) else { return (person.clone(), Some(AnonymizeReason::WholePerson)) };
        if let Some(f) = Self::face_of(person, faces) {
            self.last_face = Some(AnonymizeBox {
                x: (f.box_.x - body.x) / body.width,
                y: (f.box_.y - body.y) / body.height,
                width: f.box_.width / body.width,
                height: f.box_.height / body.height,
            });
            let flag =
                if f.confidence < Self::MIN_FACE_CONFIDENCE { Some(AnonymizeReason::LowConfidence) } else { None };
            return (Self::ellipse(&f.box_, person.width(), person.height()), flag);
        }
        let guess = if let Some(r) = self.last_face {
            AnonymizeBox {
                x: body.x + r.x * body.width,
                y: body.y + r.y * body.height,
                width: r.width * body.width,
                height: r.height * body.height,
            }
        } else {
            // Never seen: the head end of the person (generous for a close-up, where the person is as wide as tall).
            let bw = body.width * person.width() as f64;
            let bh = body.height * person.height() as f64;
            let h = bh.min((bh / 5.0).max(bw * 0.9));
            AnonymizeBox { x: body.x, y: body.y, width: body.width, height: h / person.height() as f64 }
        };
        (Self::ellipse(&guess, person.width(), person.height()), Some(AnonymizeReason::NoFace))
    }

    /// The face on this person: the one whose middle the matte fills most.
    fn face_of(person: &SubjectMatte, faces: &[AnonymizeFace]) -> Option<AnonymizeFace> {
        let mut best: Option<(AnonymizeFace, f64)> = None;
        for f in faces {
            let Some(r) = f.box_.inner(0.5).texels(person.width(), person.height()) else { continue };
            let mut s = 0.0_f64;
            for y in r.1.clone() {
                for x in r.0.clone() {
                    s += f64::from(person.at(x, y));
                }
            }
            let cover = s / (r.0.len() * r.1.len()) as f64;
            if cover >= Self::MIN_FACE_COVER && cover > best.map_or(0.0, |b| b.1) {
                best = Some((*f, cover));
            }
        }
        best.map(|b| b.0)
    }

    /// Extent of the matte (values from one half) in frame fractions.
    fn extent(m: &SubjectMatte) -> Option<AnonymizeBox> {
        let (mut x0, mut x1, mut y0, mut y1) = (m.width() as i64, -1_i64, m.height() as i64, -1_i64);
        for y in 0..m.height() {
            for x in 0..m.width() {
                if m.values[y * m.width() + x] >= 0.5 {
                    let (xi, yi) = (x as i64, y as i64);
                    x0 = x0.min(xi);
                    x1 = x1.max(xi);
                    y0 = y0.min(yi);
                    y1 = y1.max(yi);
                }
            }
        }
        if x1 < 0 {
            return None;
        }
        let (w, h) = (m.width() as f64, m.height() as f64);
        Some(AnonymizeBox {
            x: x0 as f64 / w,
            y: y0 as f64 / h,
            width: (x1 - x0 + 1) as f64 / w,
            height: (y1 - y0 + 1) as f64 / h,
        })
    }

    /// A soft ellipse around `box_`: the whole box is covered, with room for hair, ears and chin (a detector's face box
    /// ends at the brow and the chin).
    fn ellipse(box_: &AnonymizeBox, w: usize, h: usize) -> SubjectMatte {
        let cx = box_.center().x * w as f64;
        let cy = (box_.center().y - box_.height * 0.08) * h as f64;
        let rx = (box_.width * w as f64 * 0.95).max(1.5);
        let ry = (box_.height * h as f64 * 1.05).max(1.5);
        let mut v = vec![0.0_f32; w * h];
        let y0 = (((cy - ry) as i64) - 1).max(0);
        let y1 = (((cy + ry) as i64) + 2).min(h as i64);
        let x0 = (((cx - rx) as i64) - 1).max(0);
        let x1 = (((cx + rx) as i64) + 2).min(w as i64);
        if !(y0 < y1 && x0 < x1) {
            return SubjectMatte::new(w, h, v);
        }
        for y in y0 as usize..y1 as usize {
            for x in x0 as usize..x1 as usize {
                let dx = (x as f64 + 0.5 - cx) / rx;
                let dy = (y as f64 + 0.5 - cy) / ry;
                let d = (dx * dx + dy * dy).sqrt();
                v[y * w + x] = ((1.0 - d) / 0.12).clamp(0.0, 1.0) as f32;
            }
        }
        SubjectMatte::new(w, h, v)
    }

    fn chroma(g: &MagicGuide, x: usize, y: usize) -> (f64, f64) {
        let i = (y * g.width() + x) * 3;
        let r = f64::from(g.rgb[i]);
        let gr = f64::from(g.rgb[i + 1]);
        let b = f64::from(g.rgb[i + 2]);
        (-0.169 * r - 0.331 * gr + 0.5 * b, 0.5 * r - 0.419 * gr - 0.081 * b)
    }

    /// The tone of the face: the middle of its box, where the person's matte is.
    fn tone_of(face: &AnonymizeBox, person: &SubjectMatte, g: &MagicGuide) -> Option<SkinTone> {
        let r = face.inner(0.5).texels(g.width(), g.height())?;
        let (mut n, mut sb, mut sr, mut sbb, mut srr) = (0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64);
        for y in r.1.clone() {
            for x in r.0.clone() {
                if person.sample((x as f64 + 0.5) / g.width() as f64, (y as f64 + 0.5) / g.height() as f64) < 0.5 {
                    continue;
                }
                let c = Self::chroma(g, x, y);
                n += 1.0;
                sb += c.0;
                sr += c.1;
                sbb += c.0 * c.0;
                srr += c.1 * c.1;
            }
        }
        if n < 4.0 {
            return None;
        }
        let (mb, mr) = (sb / n, sr / n);
        let spread = ((sbb / n - mb * mb).max(0.0) + (srr / n - mr * mr).max(0.0)).sqrt();
        Some(SkinTone { cb: mb, cr: mr, radius: (2.5 * spread).clamp(0.05, 0.12) })
    }

    fn skin(
        &mut self,
        person: &SubjectMatte,
        faces: &[AnonymizeFace],
        guide: Option<&MagicGuide>,
    ) -> (SubjectMatte, Option<AnonymizeReason>) {
        let Some(g) = guide else { return (person.clone(), Some(AnonymizeReason::WholePerson)) };
        let (w, h) = (person.width(), person.height());
        let face = Self::face_of(person, faces);
        let mut flag = Some(AnonymizeReason::NoFace);
        if let Some(f) = &face
            && let Some(t) = Self::tone_of(&f.box_, person, g)
        {
            self.tone = Some(t);
            flag = if f.confidence < Self::MIN_FACE_CONFIDENCE { Some(AnonymizeReason::LowConfidence) } else { None };
        }
        let t = self.tone.unwrap_or(SkinTone::GENERIC);
        let mut on = vec![false; w * h];
        let mut any = false;
        for y in 0..h {
            let gy = (((y as f64 + 0.5) / h as f64 * g.height() as f64) as usize).min(g.height() - 1);
            for x in 0..w {
                if person.values[y * w + x] < 0.5 {
                    continue;
                }
                let gx = (((x as f64 + 0.5) / w as f64 * g.width() as f64) as usize).min(g.width() - 1);
                if t.matches(Self::chroma(g, gx, gy)) {
                    on[y * w + x] = true;
                    any = true;
                }
            }
        }
        // The face itself counts as skin whatever its color (eyes, beard, glasses, make-up).
        if let Some(f) = &face
            && let Some(r) = f.box_.texels(w, h)
        {
            for y in r.1.clone() {
                for x in r.0.clone() {
                    if person.values[y * w + x] >= 0.5 {
                        on[y * w + x] = true;
                        any = true;
                    }
                }
            }
        }
        if !any {
            return (person.clone(), Some(AnonymizeReason::WholePerson));
        }
        // Close holes inside skin (tattoos, jewelry, shadows), then one texel of room; never outside the person.
        let r = 2.max(w.max(h) / 24);
        let closed = Self::grow(&Self::grow(&Self::grow(&on, w, h, r, true), w, h, r, false), w, h, 1, true);
        let mut v = vec![0.0_f32; w * h];
        for i in 0..w * h {
            if closed[i] {
                v[i] = person.values[i];
            }
        }
        let out = SubjectMatte::new(w, h, v);
        if out.is_blank() { (person.clone(), Some(AnonymizeReason::WholePerson)) } else { (out, flag) }
    }

    /// Grows the `to` texels by `r` (a square): `to` true = dilate, false = erode. Outside the grid counts as not `to`.
    fn grow(m: &[bool], w: usize, h: usize, r: usize, to: bool) -> Vec<bool> {
        let r = r as i64;
        let mut a = m.to_vec();
        for y in 0..h {
            let row = y * w;
            let mut last = i64::MIN / 2;
            for x in 0..w {
                if m[row + x] == to {
                    last = x as i64;
                }
                if x as i64 - last <= r {
                    a[row + x] = to;
                }
            }
            last = i64::MAX / 2;
            for x in (0..w).rev() {
                if m[row + x] == to {
                    last = x as i64;
                }
                if last - x as i64 <= r {
                    a[row + x] = to;
                }
            }
        }
        let mut b = a.clone();
        for x in 0..w {
            let mut last = i64::MIN / 2;
            for y in 0..h {
                if a[y * w + x] == to {
                    last = y as i64;
                }
                if y as i64 - last <= r {
                    b[y * w + x] = to;
                }
            }
            last = i64::MAX / 2;
            for y in (0..h).rev() {
                if a[y * w + x] == to {
                    last = y as i64;
                }
                if last - y as i64 <= r {
                    b[y * w + x] = to;
                }
            }
        }
        b
    }
}

/// Logic Swift keeps on `MagicSelection` in `Anonymize.swift`.
pub trait MagicSelectionAnonymizeExt {
    /// Matte cache key of the narrowed matte of a Face / Skin mask (derived from `cache_key`, which holds the followed
    /// person). `None` for a whole person or an ordinary pick. A build that does not know `part` reads `cache_key` and
    /// so covers the whole person.
    fn part_key(&self, media: Id) -> Option<String>;
    /// The key of the matte the mask draws.
    fn matte_key(&self, media: Id) -> String;
    /// Every matte key the mask needs (the followed person first): all are kept while the mask exists.
    fn matte_keys(&self, media: Id) -> Vec<String>;
    /// Made by Anonymize: a frame without a matte is covered by estimate (`AnonymizeFallback`), never left open.
    fn must_cover(&self) -> bool;
}

impl MagicSelectionAnonymizeExt for MagicSelection {
    fn part_key(&self, media: Id) -> Option<String> {
        let part = self.part.filter(|p| *p != AnonymizeTarget::Person)?;
        Some(format!("{}-{}", self.cache_key(media), part.raw_value()))
    }

    fn matte_key(&self, media: Id) -> String {
        self.part_key(media).unwrap_or_else(|| self.cache_key(media))
    }

    fn matte_keys(&self, media: Id) -> Vec<String> {
        let mut out = vec![self.cache_key(media)];
        out.extend(self.part_key(media));
        out
    }

    fn must_cover(&self) -> bool {
        self.part.is_some()
    }
}

/// What a mask that must cover (Anonymize) draws on a frame without a tracked matte: the person was lost, the frame was
/// revealed by a trim or a slip after the run, or the matte file is gone. When in doubt the cover is larger, never missing.
pub struct AnonymizeFallback;

impl AnonymizeFallback {
    /// The three steps of `growth`.
    pub const GROWTHS: [f64; 3] = [0.06, 0.10, 0.16];

    /// How far the nearest tracked matte is grown, as a share of the frame width, when it is `gap` seconds away. Three
    /// steps (not a ramp), so the grown matte of one tracked frame is made once per step and reused.
    pub fn growth(gap: f64) -> f64 {
        if gap < 0.5 {
            Self::GROWTHS[0]
        } else if gap < 1.5 {
            Self::GROWTHS[1]
        } else {
            Self::GROWTHS[2]
        }
    }

    /// No tracked matte at all (or the picture is warped after tracking): the whole frame.
    pub fn whole_frame() -> SubjectMatte {
        SubjectMatte::new(8, 8, vec![1.0; 64])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::MagicPoint;
    use sq_core_time::Time;

    /// Labels of a w x h frame; each object fills columns x0..<x1 of rows y0..<y1.
    fn labels(w: usize, h: usize, objects: &[(u8, usize, usize, usize, usize)]) -> InstanceLabels {
        let mut l = vec![0_u8; w * h];
        for (id, x0, x1, y0, y1) in objects {
            for y in *y0..*y1 {
                for x in *x0..*x1 {
                    l[y * w + x] = *id;
                }
            }
        }
        InstanceLabels::new(w, h, l)
    }

    fn box_(x: f64, y: f64, w: f64, h: f64) -> AnonymizeBox {
        AnonymizeBox { x, y, width: w, height: h }
    }

    /// A person matte: columns x0..<x1, rows y0..<y1 of a w x h matte.
    fn matte(w: usize, h: usize, x0: usize, x1: usize, y0: usize, y1: usize) -> SubjectMatte {
        let mut v = vec![0.0_f32; w * h];
        for y in y0..y1 {
            for x in x0..x1 {
                v[y * w + x] = 1.0;
            }
        }
        SubjectMatte::new(w, h, v)
    }

    fn face(b: AnonymizeBox, confidence: f64) -> AnonymizeFace {
        AnonymizeFace { box_: b, confidence }
    }

    #[test]
    fn people_are_the_objects_under_a_face_or_body_left_to_right() {
        let l = labels(40, 20, &[(1, 26, 34, 4, 20), (2, 4, 12, 2, 20), (3, 18, 22, 0, 6)]);
        let f = face(box_(0.125, 0.1, 0.15, 0.2), 0.9);
        let people = AnonymizePeople::find(&l, &[box_(0.65, 0.2, 0.2, 0.8)], &[f]);
        assert_eq!(people.iter().map(|p| p.label).collect::<Vec<_>>(), vec![2, 1]);
        assert!(people[0].face == Some(f) && people[1].face.is_none());
        for p in &people {
            assert_eq!(l.label_at(p.point), p.label);
        }
        assert!((people[0].box_.x - 0.1).abs() < 1e-9 && (people[0].box_.width - 0.2).abs() < 1e-9);
    }

    #[test]
    fn a_box_over_background_or_the_same_person_twice_gives_no_extra_person() {
        let l = labels(40, 20, &[(1, 10, 20, 2, 20)]);
        let f = face(box_(0.3, 0.1, 0.15, 0.25), 0.8);
        let people = AnonymizePeople::find(&l, &[box_(0.25, 0.1, 0.25, 0.9), box_(0.7, 0.1, 0.2, 0.8)], &[f]);
        assert_eq!(people.len(), 1);
        assert_eq!(people[0].face, Some(f));
    }

    #[test]
    fn face_target_covers_the_face_and_leaves_the_body() {
        let person = matte(80, 60, 30, 50, 5, 60);
        let mut r = AnonymizeRefiner::new(AnonymizeTarget::Face);
        let (m, flag) = r.refine(&person, &[face(box_(0.4, 0.1, 0.2, 0.25), 0.9)], None);
        assert_eq!(flag, None);
        for (x, y) in [(32, 6), (47, 6), (32, 20), (47, 20), (40, 13)] {
            assert_eq!(m.at(x, y), 1.0, "{x},{y}");
        }
        assert_eq!(m.at(40, 45), 0.0);
        assert_eq!(m.at(5, 13), 0.0);
    }

    #[test]
    fn a_face_of_somebody_else_is_not_used() {
        let person = matte(80, 60, 30, 50, 5, 60);
        let mut r = AnonymizeRefiner::new(AnonymizeTarget::Face);
        let (m, flag) = r.refine(&person, &[face(box_(0.05, 0.1, 0.15, 0.25), 0.95)], None);
        assert_eq!(flag, Some(AnonymizeReason::NoFace));
        assert_eq!(m.at(40, 10), 1.0);
        assert_eq!(m.at(8, 12), 0.0);
    }

    #[test]
    fn a_frame_without_a_face_keeps_the_last_face_place_on_the_person_and_is_flagged() {
        let mut r = AnonymizeRefiner::new(AnonymizeTarget::Face);
        r.refine(&matte(80, 60, 30, 50, 5, 60), &[face(box_(0.4, 0.1, 0.2, 0.25), 0.9)], None);
        let (m, flag) = r.refine(&matte(80, 60, 50, 70, 5, 60), &[], None);
        assert_eq!(flag, Some(AnonymizeReason::NoFace));
        assert_eq!(m.at(60, 13), 1.0);
        assert!(m.at(40, 13) < 1.0);
        assert_eq!(m.at(60, 50), 0.0);
    }

    #[test]
    fn an_unsure_face_is_used_and_flagged() {
        let mut r = AnonymizeRefiner::new(AnonymizeTarget::Face);
        let (m, flag) = r.refine(&matte(80, 60, 30, 50, 5, 60), &[face(box_(0.4, 0.1, 0.2, 0.25), 0.3)], None);
        assert_eq!(flag, Some(AnonymizeReason::LowConfidence));
        assert_eq!(m.at(40, 13), 1.0);
    }

    #[test]
    fn whole_person_is_the_person_matte_unchanged() {
        let person = matte(80, 60, 30, 50, 5, 60);
        let mut r = AnonymizeRefiner::new(AnonymizeTarget::Person);
        let (m, flag) = r.refine(&person, &[], None);
        assert!(m == person && flag.is_none());
    }

    /// A picture at the matte's size: skin tone on the face rows (5..<20) and an arm (rows 30..<40), blue shirt elsewhere
    /// on the person, gray background; `tattoo`: a dark patch in the middle of the arm.
    fn picture(w: usize, h: usize, tattoo: bool) -> MagicGuide {
        let mut rgb = vec![0.5_f32; w * h * 3];
        for y in 0..h {
            for x in 30..50 {
                let skin = (5..20).contains(&y) || (30..40).contains(&y);
                let mut c: (f32, f32, f32) = if skin { (0.85, 0.62, 0.5) } else { (0.1, 0.2, 0.7) };
                if tattoo && (33..37).contains(&y) && (37..43).contains(&x) {
                    c = (0.1, 0.12, 0.12);
                }
                let i = (y * w + x) * 3;
                rgb[i] = c.0;
                rgb[i + 1] = c.1;
                rgb[i + 2] = c.2;
            }
        }
        MagicGuide::new(w, h, rgb)
    }

    #[test]
    fn skin_target_covers_skin_and_leaves_clothes() {
        let person = matte(80, 60, 30, 50, 5, 60);
        let mut r = AnonymizeRefiner::new(AnonymizeTarget::Skin);
        let f = face(box_(0.4, 0.1, 0.2, 0.2), 0.9);
        let (m, flag) = r.refine(&person, &[f], Some(&picture(80, 60, false)));
        assert_eq!(flag, None);
        assert_eq!(m.at(40, 12), 1.0);
        assert_eq!(m.at(40, 35), 1.0);
        assert_eq!(m.at(40, 25), 0.0);
        assert_eq!(m.at(40, 52), 0.0);
        assert_eq!(m.at(10, 12), 0.0);
    }

    #[test]
    fn a_tattoo_inside_skin_is_covered_too() {
        let person = matte(80, 60, 30, 50, 5, 60);
        let mut r = AnonymizeRefiner::new(AnonymizeTarget::Skin);
        let f = face(box_(0.4, 0.1, 0.2, 0.2), 0.9);
        let (m, _) = r.refine(&person, &[f], Some(&picture(80, 60, true)));
        for x in 37..43 {
            assert_eq!(m.at(x, 35), 1.0, "x {x}");
        }
        assert_eq!(m.at(40, 52), 0.0);
    }

    #[test]
    fn skin_without_a_face_uses_the_tone_learned_before_and_is_flagged() {
        let person = matte(80, 60, 30, 50, 5, 60);
        let mut r = AnonymizeRefiner::new(AnonymizeTarget::Skin);
        let pic = picture(80, 60, false);
        r.refine(&person, &[face(box_(0.4, 0.1, 0.2, 0.2), 0.9)], Some(&pic));
        let (m, flag) = r.refine(&person, &[], Some(&pic));
        assert_eq!(flag, Some(AnonymizeReason::NoFace));
        assert!(m.at(40, 35) == 1.0 && m.at(40, 52) == 0.0);
    }

    #[test]
    fn skin_that_cannot_be_found_covers_the_whole_person() {
        let person = matte(80, 60, 30, 50, 5, 60);
        let mut a = AnonymizeRefiner::new(AnonymizeTarget::Skin);
        let (m, flag) = a.refine(&person, &[], None);
        assert!(m == person && flag == Some(AnonymizeReason::WholePerson));
        let mut b = AnonymizeRefiner::new(AnonymizeTarget::Skin);
        let blue = MagicGuide::new(80, 60, (0..80 * 60 * 3).map(|i| if i % 3 == 2 { 0.8 } else { 0.1 }).collect());
        let (m, flag) = b.refine(&person, &[], Some(&blue));
        assert!(m == person && flag == Some(AnonymizeReason::WholePerson));
    }

    #[test]
    fn flagged_frames_collapse_into_ranges_per_reason() {
        let fd = 1.0 / 25.0;
        let mut flags = Vec::new();
        for i in 10..20 {
            flags.push((f64::from(i) * fd, AnonymizeReason::NoFace));
        }
        for i in 40..43 {
            flags.push((f64::from(i) * fd, AnonymizeReason::NoFace));
        }
        flags.push((30.0 * fd, AnonymizeReason::LowConfidence));
        let r = AnonymizeReport::ranges(2, &flags, fd);
        assert_eq!(r.len(), 3);
        assert_eq!(
            r.iter().map(|c| c.reason).collect::<Vec<_>>(),
            vec![AnonymizeReason::NoFace, AnonymizeReason::LowConfidence, AnonymizeReason::NoFace]
        );
        assert!((r[0].from - 10.0 * fd).abs() < 1e-9 && (r[0].to - 19.0 * fd).abs() < 1e-9);
        assert!((r[1].from - 30.0 * fd).abs() < 1e-9 && r[1].from == r[1].to);
        assert!(r.iter().all(|c| c.person == 2));
        assert!(AnonymizeReport::ranges(0, &[], fd).is_empty());
    }

    #[test]
    fn no_check_text_claims_certainty() {
        for r in [
            AnonymizeReason::Lost,
            AnonymizeReason::NoFace,
            AnonymizeReason::LowConfidence,
            AnonymizeReason::WholePerson,
        ] {
            let t = r.text().to_lowercase();
            assert!(!t.is_empty());
            for word in ["guarantee", "certain", "always", "fully", "safe"] {
                assert!(!t.contains(word), "{r:?}: {t}");
            }
        }
    }

    fn pick(x: f64, part: Option<AnonymizeTarget>) -> MagicSelection {
        MagicSelection {
            points: vec![MagicPoint { position: Vec2::new(x, 0.5), subtract: false, source_time: Time::new(1, 2) }],
            part,
        }
    }

    #[test]
    fn the_part_of_a_pick_never_changes_the_person_key() {
        let plain = pick(0.3, None);
        let (face_, skin, person) = (
            pick(0.3, Some(AnonymizeTarget::Face)),
            pick(0.3, Some(AnonymizeTarget::Skin)),
            pick(0.3, Some(AnonymizeTarget::Person)),
        );
        let media = Id::from_u128(77);
        let base = plain.cache_key(media);
        assert!([&face_, &skin, &person].iter().all(|s| s.cache_key(media) == base));
        let fk = face_.part_key(media).unwrap_or_default();
        let sk = skin.part_key(media).unwrap_or_default();
        assert!(fk != sk && fk.starts_with(&base) && sk.starts_with(&base) && fk != base && !fk.is_empty());
        assert!(plain.part_key(media).is_none() && person.part_key(media).is_none());
        assert!(face_.matte_key(media) == fk && person.matte_key(media) == base && plain.matte_key(media) == base);
        assert!(face_.matte_keys(media) == vec![base.clone(), fk] && plain.matte_keys(media) == vec![base]);
        assert!(face_.must_cover() && skin.must_cover() && person.must_cover() && !plain.must_cover());
    }

    #[test]
    fn the_fallback_grows_with_the_distance_to_the_nearest_tracked_frame() {
        assert!(AnonymizeFallback::growth(0.04) >= 0.05);
        assert!(AnonymizeFallback::growth(1.0) > AnonymizeFallback::growth(0.04));
        assert!(AnonymizeFallback::growth(10.0) > AnonymizeFallback::growth(1.0));
        assert!(AnonymizeFallback::whole_frame().values.iter().all(|v| *v == 1.0));
        assert!(AnonymizeReason::Lost.is_critical() && !AnonymizeReason::NoFace.is_critical());
    }

    /// Track on a Face mask from the middle of a clip: the refiner starts with the face place of the stored mattes, so a
    /// first frame without a detected face is covered there, not at the head end of the person.
    #[test]
    fn a_seeded_refiner_places_the_face_where_the_stored_matte_had_it() {
        let person = matte(100, 100, 30, 70, 10, 100);
        let stored = face(box_(0.55, 0.40, 0.10, 0.10), 0.9);
        let mut first = AnonymizeRefiner::new(AnonymizeTarget::Face);
        let narrowed = first.refine(&person, &[stored], None).0;
        let mut seeded = AnonymizeRefiner::new(AnonymizeTarget::Face);
        seeded.seed(&person, &narrowed);
        let got = seeded.refine(&person, &[], None);
        assert_eq!(got.1, Some(AnonymizeReason::NoFace));
        let e = AnonymizeRefiner::extent(&got.0).unwrap_or(box_(9.0, 9.0, 9.0, 9.0));
        let want = AnonymizeRefiner::extent(&narrowed).unwrap_or(box_(0.0, 0.0, 0.0, 0.0));
        assert!((e.center().x - want.center().x).abs() < 0.03 && (e.center().y - want.center().y).abs() < 0.03);
        assert!((e.width - want.width).abs() < 0.04 && (e.height - want.height).abs() < 0.04);
        let mut blind = AnonymizeRefiner::new(AnonymizeTarget::Face);
        let head = AnonymizeRefiner::extent(&blind.refine(&person, &[], None).0).unwrap_or(box_(9.0, 9.0, 9.0, 9.0));
        assert!((head.center().y - want.center().y).abs() > 0.1);
    }
}
