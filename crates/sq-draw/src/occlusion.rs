//! Skips quads that a later opaque rectangle fully covers. A UI frame stacks full-window and panel backgrounds on top of
//! each other (about 4.6 screens of shape area at 3456x2038 on the Color page); the quad shader runs for every covered pixel,
//! so the overdraw cost 4.5 ms of GPU time per present, and the UI is presented at every refresh during playback.
//! The result is pixel-identical: only quads whose every drawn pixel is overwritten by an opaque quad drawn later are dropped.

use crate::draw_list::{DrawQuad, QuadKind};

/// Opaque rects smaller than this (in px) are not worth testing against: the test costs per quad.
const MIN_OCCLUDER_AREA: f32 = 64.0 * 64.0;
/// Occluders tested per quad; the test is linear in it.
const MAX_OCCLUDERS: usize = 48;

/// Whole pixels `[x0, y0, x1, y1]` that an opaque filled rect (`rect` clipped to its clip) certainly overwrites.
fn solid_pixels(q: &DrawQuad) -> Option<[f32; 4]> {
    if q.kind != QuadKind::Shape || q.color.a < 1.0 || q.radius > 0.0 || q.stroke > 0.0 {
        return None;
    }
    let b = bounds(q);
    // A pixel is drawn fully opaque only when it lies wholly inside the rect: round the box inward.
    let s = [b[0].ceil(), b[1].ceil(), b[2].floor(), b[3].floor()];
    ((s[2] - s[0]) * (s[3] - s[1]) >= MIN_OCCLUDER_AREA).then_some(s)
}

/// The box (`rect` clipped) outside which the quad draws nothing.
pub(crate) fn bounds(q: &DrawQuad) -> [f32; 4] {
    [q.rect.x.max(q.clip[0]), q.rect.y.max(q.clip[1]), q.rect.max_x().min(q.clip[2]), q.rect.max_y().min(q.clip[3])]
}

/// For every quad: whether it still shows (`false` = a later opaque rect hides all of it). Only valid for a 1:1 target
/// (the reduced view supersamples and covers pixel edges differently).
pub fn visible(quads: &[DrawQuad]) -> Vec<bool> {
    let mut shown = vec![true; quads.len()];
    let mut occluders: Vec<[f32; 4]> = Vec::new();
    for (i, q) in quads.iter().enumerate().rev() {
        let b = bounds(q);
        if occluders.iter().any(|o| o[0] <= b[0] && o[1] <= b[1] && o[2] >= b[2] && o[3] >= b[3]) {
            shown[i] = false;
            continue;
        }
        if occluders.len() < MAX_OCCLUDERS
            && let Some(s) = solid_pixels(q)
        {
            occluders.push(s);
        }
    }
    shown
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::draw_list::{Color, DrawList, Rect};

    fn shown(list: &DrawList) -> Vec<bool> {
        visible(list.quads())
    }

    #[test]
    fn a_later_opaque_rect_hides_what_it_covers() {
        let mut l = DrawList::new(1000.0, 1000.0);
        l.fill(Rect::new(0.0, 0.0, 1000.0, 1000.0), Color::hex(0x101010, 1.0), 0.0); // old background
        l.fill(Rect::new(0.0, 0.0, 1000.0, 1000.0), Color::hex(0x181818, 1.0), 0.0); // window background
        l.fill(Rect::new(100.0, 100.0, 300.0, 300.0), Color::hex(0x202020, 1.0), 0.0); // panel
        l.fill(Rect::new(150.0, 150.0, 20.0, 20.0), Color::hex(0xFFFFFF, 1.0), 0.0); // child on the panel
        assert_eq!(shown(&l), vec![false, true, true, true]);
    }

    #[test]
    fn what_is_drawn_after_stays_and_partial_cover_stays() {
        let mut l = DrawList::new(1000.0, 1000.0);
        l.fill(Rect::new(0.0, 0.0, 200.0, 200.0), Color::hex(0x202020, 1.0), 0.0);
        l.fill(Rect::new(150.0, 150.0, 200.0, 200.0), Color::hex(0x303030, 1.0), 0.0); // overlaps only a corner
        assert_eq!(shown(&l), vec![true, true]);
    }

    #[test]
    fn translucent_rounded_stroked_and_small_rects_hide_nothing() {
        for (a, radius, stroke, size) in
            [(0.5, 0.0, 0.0, 300.0), (1.0, 8.0, 0.0, 300.0), (1.0, 0.0, 2.0, 300.0), (1.0, 0.0, 0.0, 40.0)]
        {
            let mut l = DrawList::new(1000.0, 1000.0);
            l.fill(Rect::new(110.0, 110.0, 10.0, 10.0), Color::hex(0x202020, 1.0), 0.0);
            let r = Rect::new(100.0, 100.0, size, size);
            if stroke > 0.0 {
                l.stroke(r, Color::hex(0xFFFFFF, a), stroke, radius);
            } else {
                l.fill(r, Color::hex(0xFFFFFF, a), radius);
            }
            assert_eq!(shown(&l), vec![true, true], "alpha {a} radius {radius} stroke {stroke} size {size}");
        }
    }

    #[test]
    fn an_edge_pixel_only_partly_covered_is_not_hidden() {
        let mut l = DrawList::new(1000.0, 1000.0);
        l.fill(Rect::new(100.0, 100.0, 200.0, 100.0), Color::hex(0x202020, 1.0), 0.0);
        // Covers x 100.5..300: pixel 100 is half covered, so the quad under it still shows there.
        l.fill(Rect::new(100.5, 100.0, 199.5, 100.0), Color::hex(0x303030, 1.0), 0.0);
        assert_eq!(shown(&l), vec![true, true]);
        // Covers x 99.5..300.5: the whole pixels 100..300 are covered.
        l.fill(Rect::new(99.5, 99.5, 201.0, 101.0), Color::hex(0x404040, 1.0), 0.0);
        assert_eq!(shown(&l), vec![false, false, true]);
    }

    #[test]
    fn a_clip_limits_both_the_hider_and_the_hidden() {
        let mut l = DrawList::new(1000.0, 1000.0);
        l.fill(Rect::new(0.0, 0.0, 1000.0, 1000.0), Color::hex(0x101010, 1.0), 0.0);
        l.push_clip(Rect::new(100.0, 100.0, 200.0, 200.0));
        l.fill(Rect::new(0.0, 0.0, 1000.0, 1000.0), Color::hex(0x202020, 1.0), 0.0); // visible part: the clip
        l.pop_clip();
        // The big background is only partly under the clipped fill: it stays.
        assert_eq!(shown(&l), vec![true, true]);
        let mut l = DrawList::new(1000.0, 1000.0);
        l.push_clip(Rect::new(100.0, 100.0, 200.0, 200.0));
        l.fill(Rect::new(0.0, 0.0, 1000.0, 1000.0), Color::hex(0x101010, 1.0), 0.0);
        l.fill(Rect::new(120.0, 120.0, 100.0, 100.0), Color::hex(0x202020, 1.0), 0.0);
        l.fill(Rect::new(0.0, 0.0, 1000.0, 1000.0), Color::hex(0x303030, 1.0), 0.0); // covers the whole clip box
        l.pop_clip();
        assert_eq!(shown(&l), vec![false, false, true]);
    }
}
