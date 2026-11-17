// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SubjectCropPass.swift
//! The second look at a tracked subject: the tracking model answers on the whole frame stretched onto its square, which
//! leaves a person of 5 % of the frame a few dozen mask texels wide. A crop around the first answer, stretched onto the
//! same square, gives the model several times the detail; its answer replaces the first one inside the crop when the two
//! agree. Also the search band that keeps a new mask near where the subject was.
//!
//! Principles from the research notes: crop around the last mask with a margin, never track a different object far
//! away. No third-party code.

use crate::subject_mask::SubjectMatte;
use crate::subject_track_rules::{SubjectTrackBox, SubjectTrackRules};

/// The crop pass and the search band.
pub struct SubjectCropPass;

impl SubjectCropPass {
    /// The crop's width / height in pixels stays inside `MIN_ASPECT ... 1 / MIN_ASPECT`: a strip stretched to a square
    /// would distort the person more than the whole frame does.
    pub const MIN_ASPECT: f64 = 0.6;
    /// Share of the box's longer side added on each side.
    pub const MARGIN: f64 = 0.1;
    /// A crop of more than this share of the frame is no gain over the frame itself.
    pub const LARGEST_CROP: f64 = 0.65;
    /// The crop's answer must overlap the frame's answer by this much to be used.
    pub const AGREEMENT: f64 = 0.6;
    /// Every frame the subject was lost widens the band by this share of the frame on each side, so one that comes back
    /// far from where it left is found again (the whole frame after about 8 lost frames).
    pub const LOST_GROWTH: f64 = 0.1;

    /// The crop (frame fractions) for a subject in `box_`; `None` when the subject is too large for it to help.
    /// `aspect`: the frame's width / height.
    pub fn crop(box_: &SubjectTrackBox, aspect: f64) -> Option<SubjectTrackBox> {
        if !(box_.width() > 0.0 && box_.height() > 0.0 && aspect > 0.0) {
            return None;
        }
        let pad = (Self::MARGIN * box_.width().max(box_.height())).max(0.02);
        let mut w = box_.width() + 2.0 * pad;
        let mut h = box_.height() + 2.0 * pad;
        // Pixel aspect = w * aspect / h, kept in range by widening the shorter side.
        let pixel = w * aspect / h;
        if pixel < Self::MIN_ASPECT {
            w = Self::MIN_ASPECT * h / aspect;
        } else if pixel > 1.0 / Self::MIN_ASPECT {
            h = w * aspect * Self::MIN_ASPECT;
        }
        // Clamped to the frame, the other side comes down so the aspect bound still holds.
        if h > 1.0 {
            h = 1.0;
            w = w.min(1.0 / (aspect * Self::MIN_ASPECT));
        }
        if w > 1.0 {
            w = 1.0;
            h = h.min(aspect / Self::MIN_ASPECT);
        }
        if !(w >= box_.width() - 1e-9 && h >= box_.height() - 1e-9) {
            return None;
        }
        if w * h > Self::LARGEST_CROP {
            return None;
        }
        let cx = (box_.x0 + box_.x1) / 2.0;
        let cy = (box_.y0 + box_.y1) / 2.0;
        let x0 = (cx - w / 2.0).max(0.0).min(1.0 - w);
        let y0 = (cy - h / 2.0).max(0.0).min(1.0 - h);
        Some(SubjectTrackBox::new(x0, y0, x0 + w, y0 + h))
    }

    /// Whether the crop's answer (on the frame's logit grid) is the same subject as the frame's answer.
    pub fn accepts(crop: &[f32], frame: &[f32]) -> bool {
        if !crop.iter().any(|v| *v > 0.0) {
            return false;
        }
        SubjectTrackRules::iou(crop, frame) >= Self::AGREEMENT
    }

    /// `size` x `size` logits of the crop laid onto the frame's grid (`side` x `side`): inside the crop the crop's
    /// answer, outside the frame's own.
    pub fn merged(frame: &[f32], side: usize, crop_logits: &[f32], size: usize, crop: &SubjectTrackBox) -> Vec<f32> {
        let mut out = frame.to_vec();
        Self::place(crop_logits, size, crop, side, side, |x, y, v| out[y * side + x] = v);
        out
    }

    /// The matte of the frame with the crop's answer (bilinear, then sigmoid) inside the crop.
    // shortcut: still the sigmoid, not `SubjectTrackRules::edge_alpha` (the crop pass is off unless
    // `SQ_SUBJECT_MASK_CROP=1`); upgrade to the edge-distance alpha when the crop pass is switched on by default.
    pub fn compose(base: &SubjectMatte, crop_logits: &[f32], size: usize, crop: &SubjectTrackBox) -> SubjectMatte {
        let mut values = base.values.clone();
        let w = base.width();
        Self::place(crop_logits, size, crop, base.width(), base.height(), |x, y, v| {
            values[y * w + x] = if v <= -9.0 {
                0.0
            } else if v >= 9.0 {
                1.0
            } else {
                1.0 / (1.0 + (-f64::from(v)).exp() as f32)
            };
        });
        SubjectMatte::new(base.width(), base.height(), values)
    }

    /// Calls `write` for every cell of a `width` x `height` grid that lies inside `crop`, with the crop logits sampled
    /// there.
    fn place(
        logits: &[f32],
        size: usize,
        crop: &SubjectTrackBox,
        width: usize,
        height: usize,
        mut write: impl FnMut(usize, usize, f32),
    ) {
        assert!(logits.len() == size * size && size > 1, "crop logits size mismatch");
        let xa = ((crop.x0 * width as f64).ceil() as i64).max(0);
        let xb = ((crop.x1 * width as f64).floor() as i64).min(width as i64);
        let ya = ((crop.y0 * height as f64).ceil() as i64).max(0);
        let yb = ((crop.y1 * height as f64).floor() as i64).min(height as i64);
        if !(xa < xb && ya < yb && crop.width() > 0.0 && crop.height() > 0.0) {
            return;
        }
        let sz = size as f64;
        for y in ya as usize..yb as usize {
            let fy = (((y as f64 + 0.5) / height as f64 - crop.y0) / crop.height() * sz - 0.5).clamp(0.0, sz - 1.0);
            let r0 = fy as usize * size;
            let r1 = (fy as usize + 1).min(size - 1) * size;
            let ty = (fy - (fy as usize) as f64) as f32;
            for x in xa as usize..xb as usize {
                let fx = (((x as f64 + 0.5) / width as f64 - crop.x0) / crop.width() * sz - 0.5).clamp(0.0, sz - 1.0);
                let c0 = fx as usize;
                let c1 = (c0 + 1).min(size - 1);
                let tx = (fx - c0 as f64) as f32;
                let top = logits[r0 + c0] + (logits[r0 + c1] - logits[r0 + c0]) * tx;
                let bottom = logits[r1 + c0] + (logits[r1 + c1] - logits[r1 + c0]) * tx;
                write(x, y, top + (bottom - top) * ty);
            }
        }
    }

    /// Where the subject may be on the next frame: the previous box grown by a quarter of its diagonal plus a fixed
    /// margin, and by `LOST_GROWTH` for every frame the subject was lost.
    pub fn band(box_: &SubjectTrackBox, lost_frames: usize) -> SubjectTrackBox {
        let diagonal = (box_.width() * box_.width() + box_.height() * box_.height()).sqrt();
        let grow = 0.25 * diagonal + 0.05 + Self::LOST_GROWTH * lost_frames as f64;
        box_.grown(grow, grow)
    }

    /// `logits` (size x size) with everything outside `band` set to background.
    pub fn constrain(logits: &[f32], size: usize, band: &SubjectTrackBox) -> Vec<f32> {
        let mut out = logits.to_vec();
        for y in 0..size {
            let v = (y as f64 + 0.5) / size as f64;
            for x in 0..size {
                let u = (x as f64 + 0.5) / size as f64;
                if !(u >= band.x0 && u <= band.x1 && v >= band.y0 && v <= band.y1) {
                    out[y * size + x] = -SubjectTrackRules::MATTE_LOGIT;
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::subject_track_rules::SubjectLostRule;

    fn bx(x0: f64, y0: f64, x1: f64, y1: f64) -> SubjectTrackBox {
        SubjectTrackBox::new(x0, y0, x1, y1)
    }

    fn logits64(b: &SubjectTrackBox) -> Vec<f32> {
        let size = 64;
        let mut out = vec![-8.0_f32; size * size];
        for y in 0..size {
            for x in 0..size {
                let u = (x as f64 + 0.5) / size as f64;
                let v = (y as f64 + 0.5) / size as f64;
                if u >= b.x0 && u <= b.x1 && v >= b.y0 && v <= b.y1 {
                    out[y * size + x] = 8.0;
                }
            }
        }
        out
    }

    const WIDE: f64 = 16.0 / 9.0;

    #[test]
    fn a_small_subject_gets_a_crop_around_it_with_margin() {
        let crop = SubjectCropPass::crop(&bx(0.4, 0.3, 0.5, 0.6), WIDE).unwrap_or(bx(9.0, 9.0, 9.0, 9.0));
        assert!(crop.x0 < 0.4 && crop.x1 > 0.5 && crop.y0 < 0.3 && crop.y1 > 0.6);
        assert!(crop.x0 >= 0.0 && crop.y0 >= 0.0 && crop.x1 <= 1.0 && crop.y1 <= 1.0);
    }

    #[test]
    fn a_tall_narrow_subject_is_widened_to_a_crop_that_is_not_a_strip() {
        let crop = SubjectCropPass::crop(&bx(0.45, 0.1, 0.55, 0.8), WIDE).unwrap_or(bx(9.0, 9.0, 9.0, 9.0));
        let pixel_aspect = crop.width() * 16.0 / 9.0 / crop.height();
        assert!(pixel_aspect >= SubjectCropPass::MIN_ASPECT - 1e-9);
        assert!(crop.x0 < 0.45 && crop.x1 > 0.55);
    }

    #[test]
    fn a_subject_that_fills_the_frame_needs_no_crop() {
        assert!(SubjectCropPass::crop(&bx(0.1, 0.05, 0.9, 0.95), WIDE).is_none());
    }

    #[test]
    fn a_crop_near_the_edge_shifts_inside_the_frame() {
        let crop = SubjectCropPass::crop(&bx(0.0, 0.2, 0.08, 0.5), WIDE).unwrap_or(bx(9.0, 9.0, 9.0, 9.0));
        assert!(crop.x0 >= 0.0 && crop.x1 <= 1.0 && crop.x0 == 0.0);
        assert!(crop.x1 > 0.08);
    }

    #[test]
    fn the_crops_logits_replace_the_frame_inside_the_crop_only() {
        let size = 8;
        let crop = bx(0.25, 0.25, 0.75, 0.75);
        let base = SubjectMatte::new(16, 16, vec![0.2; 256]);
        let inside = vec![10.0_f32; size * size];
        let out = SubjectCropPass::compose(&base, &inside, size, &crop);
        let on_grid = SubjectCropPass::merged(&vec![-8.0; 16 * 16], 16, &inside, size, &crop);
        assert!(on_grid[8 * 16 + 8] == 10.0 && on_grid[0] == -8.0);
        assert!(out.at(8, 8) > 0.99);
        assert_eq!(out.at(0, 0), 0.2);
        assert_eq!(out.at(15, 15), 0.2);
    }

    #[test]
    fn a_crop_answer_agrees_with_the_frame_answer_or_is_not_used() {
        let a = logits64(&bx(0.3, 0.3, 0.6, 0.9));
        let b = logits64(&bx(0.31, 0.3, 0.6, 0.9));
        let c = logits64(&bx(0.0, 0.0, 0.2, 0.2));
        assert!(SubjectCropPass::accepts(&b, &a));
        assert!(!SubjectCropPass::accepts(&c, &a));
        assert!(!SubjectCropPass::accepts(&vec![-8.0; a.len()], &a));
    }

    #[test]
    fn logits_far_from_the_previous_box_are_cut_off_near_ones_stay() {
        let size = 64;
        let mut logits = vec![-8.0_f32; size * size];
        logits[32 * size + 32] = 8.0;
        logits[4 * size + 60] = 8.0;
        let cut = SubjectCropPass::constrain(&logits, size, &bx(0.4, 0.4, 0.6, 0.6));
        assert_eq!(cut[32 * size + 32], 8.0);
        assert_eq!(cut[4 * size + 60], -SubjectTrackRules::MATTE_LOGIT);
    }

    #[test]
    fn the_band_grows_with_the_box_diagonal() {
        let (a, b) = (bx(0.45, 0.45, 0.5, 0.5), bx(0.2, 0.2, 0.8, 0.8));
        let (small, big) = (SubjectCropPass::band(&a, 0), SubjectCropPass::band(&b, 0));
        assert!(small.x0 < a.x0 && big.x0 < b.x0);
        assert!(b.x0 - big.x0 > a.x0 - small.x0);
    }

    #[test]
    fn the_band_widens_with_every_lost_frame_until_it_covers_the_frame() {
        let a = bx(0.1, 0.5, 0.2, 0.6);
        assert!(SubjectCropPass::band(&a, 3).x1 > SubjectCropPass::band(&a, 0).x1);
        let far = SubjectCropPass::band(&a, 10);
        assert!(far.x0 <= 0.0 && far.x1 >= 1.0 && far.y0 <= 0.0 && far.y1 >= 1.0);
    }

    #[test]
    fn a_mask_under_49_logit_pixels_is_lost_whatever_its_usual_area() {
        let mut rule = SubjectLostRule::default();
        assert!(rule.is_lost(40.0 / 65536.0, Some(bx(0.5, 0.5, 0.51, 0.51))));
        let mut small = SubjectLostRule::default();
        for _ in 0..6 {
            assert!(!small.is_lost(100.0 / 65536.0, Some(bx(0.48, 0.48, 0.52, 0.52))));
        }
    }

    #[test]
    fn a_subject_that_leaves_through_the_edge_keeps_its_shrinking_mask() {
        let mut rule = SubjectLostRule::default();
        for _ in 0..5 {
            assert!(!rule.is_lost(0.1, Some(bx(0.7, 0.2, 1.0, 1.0))));
        }
        assert!(!rule.is_lost(0.04, Some(bx(0.85, 0.2, 1.0, 1.0))));
        assert!(!rule.is_lost(0.01, Some(bx(0.95, 0.2, 1.0, 1.0))));
    }

    #[test]
    fn a_collapse_in_the_middle_of_the_frame_is_still_lost() {
        let mut rule = SubjectLostRule::default();
        for _ in 0..5 {
            assert!(!rule.is_lost(0.1, Some(bx(0.35, 0.35, 0.65, 0.65))));
        }
        assert!(rule.is_lost(0.01, Some(bx(0.45, 0.45, 0.55, 0.55))));
    }

    #[test]
    fn a_subject_at_the_edge_that_only_collapses_in_place_is_lost() {
        let mut rule = SubjectLostRule::default();
        for _ in 0..5 {
            assert!(!rule.is_lost(0.1, Some(bx(0.7, 0.2, 1.0, 1.0))));
        }
        assert!(rule.is_lost(0.01, Some(bx(0.7, 0.2, 1.0, 0.3))));
    }

    #[test]
    fn a_tiny_mask_is_lost_even_at_the_edge_and_after_no_history() {
        let mut rule = SubjectLostRule::default();
        assert!(rule.is_lost(10.0 / 65536.0, Some(bx(0.99, 0.5, 1.0, 0.51))));
    }

    #[test]
    fn the_crop_keeps_its_aspect_bound_when_the_frame_clamps_it() {
        if let Some(c) = SubjectCropPass::crop(&bx(0.0, 0.45, 1.0, 0.55), 1.78) {
            let a = c.width() * 1.78 / c.height();
            assert!((SubjectCropPass::MIN_ASPECT - 1e-9..=1.0 / SubjectCropPass::MIN_ASPECT + 1e-9).contains(&a));
        }
    }
}
