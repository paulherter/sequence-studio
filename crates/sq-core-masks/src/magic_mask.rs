// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MagicMask.swift
//! Magic masks (pure part): which segmented objects a click picks, and which objects of the next frame continue the
//! picked subject while tracking. The segmentation itself (Vision instance masks) runs in SQAnalysis.

use crate::subject_mask::SubjectMatte;
use sq_core_model::{MagicPoint, MagicSelection};
use sq_core_time::Id;
use sq_core_time::Vec2;
use std::collections::BTreeSet;

/// Logic Swift keeps on `MagicSelection`.
pub trait MagicSelectionExt {
    /// The frame the pick was made on (the first point's), `None` before the first click.
    fn anchor_time(&self) -> Option<sq_core_time::Time>;
    /// Stable across launches (FNV-1a over the media id and the points), hex. Never depends on `part`: this key holds the
    /// followed objects as they are (the whole person), in every build.
    fn cache_key(&self, media: Id) -> String;
}

impl MagicSelectionExt for MagicSelection {
    fn anchor_time(&self) -> Option<sq_core_time::Time> {
        self.points.first().map(|p| p.source_time)
    }

    fn cache_key(&self, media: Id) -> String {
        let mut h: u64 = 0xcbf29ce484222325;
        let mut mix = |bytes: &[u8]| {
            for b in bytes {
                h ^= u64::from(*b);
                h = h.wrapping_mul(0x100000001b3);
            }
        };
        mix(&media.as_u128().to_be_bytes());
        for p in &self.points {
            mix(&p.position.x.to_bits().to_le_bytes());
            mix(&p.position.y.to_bits().to_le_bytes());
            mix(&[u8::from(p.subtract)]);
            mix(&p.source_time.value().to_le_bytes());
            mix(&p.source_time.timescale().to_le_bytes());
        }
        format!("{h:x}")
    }
}

/// Object labels of one frame: 0 = background, 1...n = one segmented object each (numbers are per frame, not stable).
/// Row 0 at the top; covers the whole upright frame.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstanceLabels {
    width: usize,
    height: usize,
    /// The labels.
    pub labels: Vec<u8>,
}

impl InstanceLabels {
    /// Labels of `width` x `height`; `labels.len()` must be `width * height` (Swift traps otherwise).
    pub fn new(width: usize, height: usize, labels: Vec<u8>) -> InstanceLabels {
        assert!(width > 0 && height > 0 && labels.len() == width * height, "InstanceLabels size mismatch");
        InstanceLabels { width, height, labels }
    }

    /// Width in texels.
    pub fn width(&self) -> usize {
        self.width
    }

    /// Height in texels.
    pub fn height(&self) -> usize {
        self.height
    }

    /// The label at frame fractions `p` (nearest texel; outside the frame: background).
    pub fn label_at(&self, p: Vec2) -> u8 {
        if !(p.x >= 0.0 && p.x <= 1.0 && p.y >= 0.0 && p.y <= 1.0) {
            return 0;
        }
        let x = ((p.x * self.width as f64) as usize).min(self.width - 1);
        let y = ((p.y * self.height as f64) as usize).min(self.height - 1);
        self.labels[y * self.width + x]
    }

    /// A hard matte of the objects in `selected`.
    pub fn matte_of(&self, selected: &BTreeSet<u8>) -> SubjectMatte {
        let mut lut = [0.0_f32; 256];
        for l in selected {
            if *l != 0 {
                lut[usize::from(*l)] = 1.0;
            }
        }
        SubjectMatte::new(self.width, self.height, self.labels.iter().map(|l| lut[usize::from(*l)]).collect())
    }
}

/// Objects picked by clicks, and which objects continue a subject.
pub struct MagicPick;

/// What a pick on one frame found: the objects and the remove points that cut inside a kept object.
#[derive(Clone, Debug, PartialEq)]
pub struct MagicSelected {
    /// The picked objects.
    pub selected: BTreeSet<u8>,
    /// Remove points on the subject's own object.
    pub cuts: Vec<Vec2>,
}

/// The objects of the next frame that continue a subject, and how well.
#[derive(Clone, Debug, PartialEq)]
pub struct MagicFollowed {
    /// The continuing objects.
    pub selected: BTreeSet<u8>,
    /// IoU of the new pick with the previous matte (0...1).
    pub confidence: f64,
}

impl MagicPick {
    /// A remove point on an object holding at least this share of the last matte cuts it instead of dropping it.
    pub const PROTECTED_SHARE: f64 = 0.3;
    /// Below this share of an object lying inside the last matte it is not part of the subject.
    pub const KEEP_SHARE: f64 = 0.5;
    /// A part of the subject the segmenter split off (an arm, a leg, a hand with a cup) moves faster than the body and
    /// lies less inside the last matte than the body does: an object at most `LIMB_SIZE` of the last matte's area stays
    /// from this share on. A whole second object (another person stepping in) is larger and still needs `KEEP_SHARE`.
    pub const LIMB_SHARE: f64 = 0.25;
    /// See `LIMB_SHARE`.
    pub const LIMB_SIZE: f64 = 0.35;
    /// Tracking stops (the subject counts as lost) when the new pick and the last matte agree less than this (IoU).
    pub const MIN_CONFIDENCE: f64 = 0.3;

    /// Objects picked by `points` on one frame: every object under an add point, minus every object under a subtract
    /// point. Points on the background pick nothing.
    pub fn select(points: &[MagicPoint], l: &InstanceLabels) -> BTreeSet<u8> {
        Self::selection(points, l).selected
    }

    /// `select` plus the remove points that cut inside a kept object: a remove point on the object of the first click
    /// (the subject) never drops it, it cuts that part away along color edges (`MagicCorrection`).
    pub fn selection(points: &[MagicPoint], l: &InstanceLabels) -> MagicSelected {
        let (mut add, mut sub, mut cuts) = (BTreeSet::new(), BTreeSet::new(), Vec::new());
        let subject = points.iter().find(|p| !p.subtract).map(|p| l.label_at(p.position)).unwrap_or(0);
        for p in points {
            let x = l.label_at(p.position);
            if x == 0 {
                continue;
            }
            if !p.subtract {
                add.insert(x);
            } else if x == subject {
                cuts.push(p.position);
            } else {
                sub.insert(x);
            }
        }
        MagicSelected { selected: add.difference(&sub).copied().collect(), cuts }
    }

    /// Share of `previous` (any size) lying on object `x` (0...1).
    pub fn share(x: u8, previous: &SubjectMatte, l: &InstanceLabels) -> f64 {
        let resampled;
        let prev = if previous.width() == l.width() && previous.height() == l.height() {
            previous
        } else {
            resampled = previous.resampled(l.width(), l.height());
            &resampled
        };
        let (mut on, mut all) = (0.0_f64, 0.0_f64);
        for i in 0..l.labels.len() {
            let v = f64::from(prev.values[i]);
            all += v;
            if l.labels[i] == x {
                on += v;
            }
        }
        if all > 0.0 { on / all } else { 0.0 }
    }

    /// The soft matte of `selected` when it is usable (not blank, at the labels' size or at the analyzed frame's size
    /// `frame_width` x `frame_height`), else the hard matte of the labels: a soft mask Vision returns empty or at another
    /// size must never turn a pick into nothing.
    pub fn usable_soft(
        soft: Option<&SubjectMatte>,
        l: &InstanceLabels,
        selected: &BTreeSet<u8>,
        frame_width: usize,
        frame_height: usize,
    ) -> SubjectMatte {
        if let Some(soft) = soft
            && !soft.is_blank()
            && ((soft.width() == l.width() && soft.height() == l.height())
                || (soft.width() == frame_width && soft.height() == frame_height))
        {
            return soft.clone();
        }
        l.matte_of(selected)
    }

    /// The objects of the next frame that continue the subject of `previous` (the last frame's matte, any size): every
    /// object lying at least `KEEP_SHARE` inside it (a small one: `LIMB_SHARE`), or else the one overlapping it most.
    /// `confidence` = IoU of the new pick with the previous matte (0...1). `None` when nothing overlaps (subject gone or
    /// hidden).
    pub fn follow(previous: &SubjectMatte, l: &InstanceLabels) -> Option<MagicFollowed> {
        let resampled;
        let prev = if previous.width() == l.width() && previous.height() == l.height() {
            previous
        } else {
            resampled = previous.resampled(l.width(), l.height());
            &resampled
        };
        let (mut inside, mut area) = ([0.0_f64; 256], [0.0_f64; 256]);
        let mut prev_area = 0.0_f64;
        for i in 0..l.labels.len() {
            let v = f64::from(prev.values[i]);
            prev_area += v;
            let x = usize::from(l.labels[i]);
            if x == 0 {
                continue;
            }
            area[x] += 1.0;
            inside[x] += v;
        }
        let mut selected = BTreeSet::new();
        let mut best: Option<(u8, f64)> = None;
        for x in 1..256 {
            if area[x] <= 0.0 {
                continue;
            }
            if inside[x] / area[x] >= Self::KEEP_SHARE {
                selected.insert(x as u8);
            }
            if inside[x] > best.map_or(0.0, |b| b.1) {
                best = Some((x as u8, inside[x]));
            }
        }
        // Split limbs: only next to a body that was followed (never the only thing kept, never on an empty last matte).
        if !selected.is_empty() && prev_area > 0.0 {
            for x in 1..256 {
                if area[x] > 0.0 && area[x] <= Self::LIMB_SIZE * prev_area && inside[x] / area[x] >= Self::LIMB_SHARE {
                    selected.insert(x as u8);
                }
            }
        }
        if selected.is_empty()
            && let Some(b) = best
            && b.1 > 0.0
        {
            selected = BTreeSet::from([b.0]);
        }
        if selected.is_empty() || prev_area <= 0.0 {
            return None;
        }
        let (mut inter, mut new_area) = (0.0_f64, 0.0_f64);
        for x in &selected {
            inter += inside[usize::from(*x)];
            new_area += area[usize::from(*x)];
        }
        let union = new_area + prev_area - inter;
        Some(MagicFollowed { selected, confidence: if union > 0.0 { (inter / union).clamp(0.0, 1.0) } else { 0.0 } })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::MagicSelection;
    use sq_core_time::Time;

    fn matte(w: usize, h: usize, f: impl Fn(usize, usize) -> f32) -> SubjectMatte {
        let mut v = vec![0.0_f32; w * h];
        for y in 0..h {
            for x in 0..w {
                v[y * w + x] = f(x, y);
            }
        }
        SubjectMatte::new(w, h, v)
    }

    #[test]
    fn soft_matte_falls_back_to_the_hard_labels() {
        let mut l = vec![0_u8; 100];
        for y in 2..6 {
            for x in 2..6 {
                l[y * 10 + x] = 3;
            }
        }
        let labels = InstanceLabels::new(10, 10, l);
        let sel = BTreeSet::from([3_u8]);
        let hard = labels.matte_of(&sel);
        let good = matte(10, 10, |x, y| if (2..6).contains(&x) && (2..6).contains(&y) { 0.9 } else { 0.0 });
        assert_eq!(MagicPick::usable_soft(Some(&good), &labels, &sel, 0, 0), good);
        assert_eq!(MagicPick::usable_soft(Some(&matte(10, 10, |_, _| 0.0)), &labels, &sel, 0, 0), hard);
        assert_eq!(MagicPick::usable_soft(Some(&matte(5, 5, |_, _| 1.0)), &labels, &sel, 0, 0), hard);
        assert_eq!(MagicPick::usable_soft(None, &labels, &sel, 0, 0), hard);
        let fine = matte(32, 18, |x, y| if (6..20).contains(&x) && (4..11).contains(&y) { 1.0 } else { 0.0 });
        assert_eq!(MagicPick::usable_soft(Some(&fine), &labels, &sel, 32, 18), fine);
        assert_eq!(MagicPick::usable_soft(Some(&fine), &labels, &sel, 40, 18), hard);
        assert_eq!(MagicPick::usable_soft(Some(&matte(32, 18, |_, _| 0.0)), &labels, &sel, 32, 18), hard);
    }

    #[test]
    fn cache_key_is_stable_and_ignores_part() {
        let media = Id::from_u128(7);
        let p = MagicPoint { position: Vec2::new(0.25, 0.5), subtract: false, source_time: Time::new(3, 600) };
        let a = MagicSelection { points: vec![p], part: None };
        let b = MagicSelection { points: vec![p], part: Some(sq_core_model::AnonymizeTarget::Face) };
        assert_eq!(a.cache_key(media), b.cache_key(media));
        assert_ne!(a.cache_key(media), a.cache_key(Id::from_u128(8)));
        assert_eq!(a.anchor_time(), Some(Time::new(3, 600)));
        assert_eq!(MagicSelection::default().anchor_time(), None);
    }

    /// 8 x 4 labels: instance 1 on the left half, instance 2 on the right half of rows 1...2.
    fn four_by_eight() -> InstanceLabels {
        let mut l = vec![0_u8; 32];
        for y in 1..=2 {
            for x in 0..4 {
                l[y * 8 + x] = 1;
            }
            for x in 4..8 {
                l[y * 8 + x] = 2;
            }
        }
        InstanceLabels::new(8, 4, l)
    }

    fn point(x: f64, y: f64, subtract: bool) -> MagicPoint {
        MagicPoint { position: Vec2::new(x, y), subtract, source_time: Time::ZERO }
    }

    #[test]
    fn pick_adds_and_subtracts_instances() {
        let l = four_by_eight();
        assert_eq!(l.label_at(Vec2::new(0.1, 0.5)), 1);
        assert_eq!(l.label_at(Vec2::new(0.1, 0.05)), 0);
        assert_eq!(MagicPick::select(&[point(0.1, 0.5, false)], &l), BTreeSet::from([1]));
        let both = [point(0.1, 0.5, false), point(0.9, 0.5, false)];
        assert_eq!(MagicPick::select(&both, &l), BTreeSet::from([1, 2]));
        let minus = [both[0], both[1], point(0.8, 0.4, true)];
        assert_eq!(MagicPick::select(&minus, &l), BTreeSet::from([1]));
        assert!(MagicPick::select(&[point(0.1, 0.05, false)], &l).is_empty());
        let matte = l.matte_of(&BTreeSet::from([1]));
        assert_eq!(matte.area(), 8.0);
        assert!(matte.at(0, 1) == 1.0 && matte.at(5, 1) == 0.0);
    }

    #[test]
    fn follow_keeps_the_instance_that_overlaps_the_last_matte() {
        let l = four_by_eight();
        let prev = l.matte_of(&BTreeSet::from([2]));
        let swapped = InstanceLabels::new(
            8,
            4,
            l.labels
                .iter()
                .map(|x| {
                    if *x == 1 {
                        2
                    } else if *x == 2 {
                        1
                    } else {
                        0
                    }
                })
                .collect(),
        );
        let f = MagicPick::follow(&prev, &swapped);
        assert_eq!(f.as_ref().map(|f| f.selected.clone()), Some(BTreeSet::from([1])));
        assert!(f.is_some_and(|f| f.confidence > 0.99));
        assert!(MagicPick::follow(&prev, &InstanceLabels::new(8, 4, vec![0; 32])).is_none());
    }

    #[test]
    fn follow_keeps_a_split_limb_but_not_another_person() {
        let (w, h) = (40, 20);
        let mut prev = vec![0.0_f32; w * h];
        for y in 0..h {
            for x in 10..20 {
                prev[y * w + x] = 1.0;
            }
        }
        let last = SubjectMatte::new(w, h, prev);
        let frame = |from: usize, to: usize, rows: usize| {
            let mut l = vec![0_u8; w * h];
            for y in 0..h {
                for x in 10..20 {
                    l[y * w + x] = 1;
                }
            }
            for y in 0..rows {
                for x in from..to {
                    l[y * w + x] = 2;
                }
            }
            InstanceLabels::new(w, h, l)
        };
        let sel = |f: &InstanceLabels| MagicPick::follow(&last, f).map(|f| f.selected).unwrap_or_default();
        assert_eq!(sel(&frame(17, 27, 4)), BTreeSet::from([1, 2]));
        assert_eq!(sel(&frame(19, 29, 4)), BTreeSet::from([1]));
        assert_eq!(sel(&frame(17, 27, 20)), BTreeSet::from([1]));
        assert!(sel(&frame(14, 24, 20)).contains(&2));
    }

    #[test]
    fn follow_works_across_matte_sizes() {
        let l = four_by_eight();
        let prev = l.matte_of(&BTreeSet::from([1])).resampled(16, 8);
        assert_eq!(MagicPick::follow(&prev, &l).map(|f| f.selected), Some(BTreeSet::from([1])));
    }

    #[test]
    fn cache_key_follows_media_and_points() {
        let media = Id::from_u128(5);
        let a = MagicSelection { points: vec![point(0.5, 0.5, false)], part: None };
        let mut b = a.clone();
        assert_eq!(a.cache_key(media), b.cache_key(media));
        b.points[0].position = Vec2::new(0.6, 0.5);
        assert_ne!(a.cache_key(media), b.cache_key(media));
        assert_ne!(a.cache_key(media), a.cache_key(Id::from_u128(6)));
    }
}
