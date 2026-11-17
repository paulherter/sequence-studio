// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SubjectLogitMath.swift
//! `SubjectTrackRules::stats` and `SubjectCropPass::constrain` for the per-frame path: the same loops, kept here because the
//! Swift target is optimized in a Debug build. The sq-core-masks versions stay the reference (the tests below).
use sq_core_masks::subject_track_rules::{SubjectTrackBox, SubjectTrackRules};

/// The per-frame loops over a square of logits.
pub struct SubjectLogitMath;

impl SubjectLogitMath {
    /// Share of the frame the logits call subject, and the box around it.
    pub fn stats(logits: &[f32], size: usize) -> (f64, Option<SubjectTrackBox>) {
        assert!(logits.len() >= size * size, "logits size mismatch");
        let (mut n, mut min_x, mut min_y, mut max_x, mut max_y) = (0_usize, size, size, -1_i64, -1_i64);
        for y in 0..size {
            let row = y * size;
            let (mut row_n, mut first, mut last) = (0_usize, size, -1_i64);
            for x in 0..size {
                if logits[row + x] > 0.0 {
                    row_n += 1;
                    if first == size {
                        first = x;
                    }
                    last = x as i64;
                }
            }
            if row_n == 0 {
                continue;
            }
            n += row_n;
            min_x = min_x.min(first);
            max_x = max_x.max(last);
            if min_y == size {
                min_y = y;
            }
            max_y = y as i64;
        }
        if n == 0 {
            return (0.0, None);
        }
        let s = size as f64;
        (
            n as f64 / (s * s),
            Some(SubjectTrackBox::new(
                min_x as f64 / s,
                min_y as f64 / s,
                (max_x + 1) as f64 / s,
                (max_y + 1) as f64 / s,
            )),
        )
    }

    /// `logits` (size x size) with everything outside `band` set to background.
    pub fn constrain(logits: &[f32], size: usize, band: &SubjectTrackBox) -> Vec<f32> {
        let outside = -SubjectTrackRules::MATTE_LOGIT;
        // Which columns lie inside the band, once (the same test per pixel as the reference).
        let columns: Vec<bool> = (0..size)
            .map(|x| {
                let u = (x as f64 + 0.5) / size as f64;
                u >= band.x0 && u <= band.x1
            })
            .collect();
        let mut out = logits.to_vec();
        for y in 0..size {
            let v = (y as f64 + 0.5) / size as f64;
            let row = y * size;
            if !(v >= band.y0 && v <= band.y1) {
                out[row..row + size].fill(outside);
                continue;
            }
            for x in 0..size {
                if !columns[x] {
                    out[row + x] = outside;
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_masks::subject_crop_pass::SubjectCropPass;

    /// A disc of logits with a little deterministic noise (a fixed generator keeps the test repeatable).
    fn logits(size: usize, center: (i64, i64), radius: f32) -> Vec<f32> {
        let mut state: u32 = 0x1234_5678;
        let mut v = vec![0.0_f32; size * size];
        for y in 0..size {
            for x in 0..size {
                state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                let noise = (state >> 8) as f32 / (1_u32 << 24) as f32 * 0.4 - 0.2;
                let dx = (x as i64 - center.0) as f32;
                let dy = (y as i64 - center.1) as f32;
                v[y * size + x] = (radius - (dx * dx + dy * dy).sqrt()) * 0.7 + noise;
            }
        }
        v
    }

    #[test]
    fn stats_match_the_reference() {
        for (cx, cy, r) in [(128, 128, 40.0), (10, 240, 30.0), (250, 5, 12.0), (128, 128, -5.0)] {
            let l = logits(256, (cx, cy), r);
            let a = SubjectTrackRules::stats(&l, 256);
            let (area, box_) = SubjectLogitMath::stats(&l, 256);
            assert!(a.area == area && a.box_ == box_, "blob {cx} {cy} {r}");
        }
    }

    #[test]
    fn stats_of_an_empty_and_a_full_frame() {
        assert_eq!(SubjectLogitMath::stats(&[-1.0; 64], 8).1, None);
        let (area, box_) = SubjectLogitMath::stats(&[1.0; 64], 8);
        assert!(area == 1.0 && box_ == Some(SubjectTrackBox::new(0.0, 0.0, 1.0, 1.0)));
    }

    #[test]
    fn constrain_matches_the_reference() {
        let l = logits(256, (128, 128), 60.0);
        for (x0, y0, x1, y1) in [
            (0.2, 0.3, 0.6, 0.9),
            (-0.2, -0.1, 0.4, 0.5),
            (0.0, 0.0, 1.0, 1.0),
            (0.5, 0.5, 0.5, 0.5),
            (0.7, 0.1, 1.3, 0.2),
        ] {
            let band = SubjectTrackBox::new(x0, y0, x1, y1);
            assert_eq!(SubjectLogitMath::constrain(&l, 256, &band), SubjectCropPass::constrain(&l, 256, &band));
        }
    }
}
