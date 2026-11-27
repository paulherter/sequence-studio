//! What of the window changed since the last presented frame. The UI is drawn into a retained layer, and a frame that
//! changed little (playback: the picture, the playhead, the meters) redraws only those pixels, then the layer is copied to
//! the drawable. The result is pixel-identical to a full draw: the damaged pixels are cleared and redrawn from the whole
//! list in the same order, every other pixel is the retained one.

use crate::draw_list::{DrawQuad, QuadKind};
use crate::occlusion::bounds;

/// Most separate rects a frame redraws; more merge into one box.
const MAX_REGIONS: usize = 6;
/// Safety margin around a changed quad (anti-aliased edges).
const PAD: f32 = 2.0;

/// The one answer to "what must this frame draw".
#[derive(Clone, Debug, PartialEq)]
pub enum Damage {
    /// Nothing changed: the retained layer is presented as it is.
    None,
    /// Only these target pixel boxes `[x0, y0, x1, y1]` (disjoint) changed.
    Regions(Vec<[u32; 4]>),
    /// Everything: first frame, resize, a different quad count, or a change too big to patch.
    Full,
}

/// Sources of change that the quads themselves do not show: new pixels in the picture or in an image slot.
#[derive(Clone, Copy, Debug, Default)]
pub struct Dirty {
    /// Anything that can alter every quad (atlas rebuilt, layer lost).
    pub all: bool,
    /// A new video picture.
    pub video: bool,
    /// Image slots with new pixels.
    pub images: [bool; 6],
}

fn merge(regions: &mut Vec<[f32; 4]>) {
    loop {
        let mut merged = false;
        'scan: for i in 0..regions.len() {
            for j in i + 1..regions.len() {
                let (a, b) = (regions[i], regions[j]);
                if a[0] <= b[2] && b[0] <= a[2] && a[1] <= b[3] && b[1] <= a[3] {
                    regions[i] = [a[0].min(b[0]), a[1].min(b[1]), a[2].max(b[2]), a[3].max(b[3])];
                    regions.swap_remove(j);
                    merged = true;
                    break 'scan;
                }
            }
        }
        if !merged {
            break;
        }
    }
}

/// The damage between the last drawn list (`prev`) and `next` on a `width` x `height` target.
pub fn damage(prev: &[DrawQuad], next: &[DrawQuad], dirty: &Dirty, width: u32, height: u32) -> Damage {
    if dirty.all || prev.len() != next.len() {
        return Damage::Full;
    }
    let mut regions: Vec<[f32; 4]> = Vec::new();
    for (a, b) in prev.iter().zip(next) {
        let stale = a != b
            || (b.kind == QuadKind::Video && dirty.video)
            || (b.kind == QuadKind::Image && dirty.images.get(b.slot as usize).copied().unwrap_or(true));
        if !stale {
            continue;
        }
        for q in [a, b] {
            let r = bounds(q);
            if r[2] > r[0] && r[3] > r[1] {
                regions.push([r[0] - PAD, r[1] - PAD, r[2] + PAD, r[3] + PAD]);
            }
        }
    }
    if regions.is_empty() {
        return Damage::None;
    }
    merge(&mut regions);
    if regions.len() > MAX_REGIONS {
        let all = regions.iter().fold([f32::MAX, f32::MAX, f32::MIN, f32::MIN], |u, r| {
            [u[0].min(r[0]), u[1].min(r[1]), u[2].max(r[2]), u[3].max(r[3])]
        });
        regions = vec![all];
    }
    let (w, h) = (width as f32, height as f32);
    let boxes: Vec<[u32; 4]> = regions
        .iter()
        .map(|r| {
            [
                r[0].floor().clamp(0.0, w) as u32,
                r[1].floor().clamp(0.0, h) as u32,
                r[2].ceil().clamp(0.0, w) as u32,
                r[3].ceil().clamp(0.0, h) as u32,
            ]
        })
        .filter(|b| b[2] > b[0] && b[3] > b[1])
        .collect();
    let area: u64 = boxes.iter().map(|b| u64::from(b[2] - b[0]) * u64::from(b[3] - b[1])).sum();
    if boxes.is_empty() {
        Damage::None
    } else if area * 10 >= u64::from(width) * u64::from(height) * 7 {
        Damage::Full
    } else {
        Damage::Regions(boxes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::draw_list::{Color, Rect};

    fn quad(x: f32, kind: QuadKind) -> DrawQuad {
        DrawQuad {
            rect: Rect::new(x, 10.0, 20.0, 20.0),
            uv: [0.0; 4],
            color: Color { r: 1.0, g: 1.0, b: 1.0, a: 1.0 },
            radius: 0.0,
            stroke: 0.0,
            kind,
            slot: 0.0,
            clip: [0.0, 0.0, 1000.0, 1000.0],
        }
    }

    #[test]
    fn an_identical_list_has_no_damage() {
        let l = vec![quad(0.0, QuadKind::Shape), quad(100.0, QuadKind::Glyph)];
        assert_eq!(damage(&l, &l, &Dirty::default(), 1000, 1000), Damage::None);
    }

    #[test]
    fn a_moved_quad_damages_old_and_new_place_separately() {
        let a = vec![quad(0.0, QuadKind::Shape), quad(300.0, QuadKind::Shape)];
        let mut b = a.clone();
        b[1].rect.x = 600.0;
        let Damage::Regions(r) = damage(&a, &b, &Dirty::default(), 1000, 1000) else { panic!() };
        assert_eq!(r.len(), 2);
        assert!(r.iter().any(|b| b[0] <= 300 && b[2] >= 320));
        assert!(r.iter().any(|b| b[0] <= 600 && b[2] >= 620));
    }

    #[test]
    fn a_new_picture_damages_only_the_video_quad() {
        let l = vec![quad(0.0, QuadKind::Shape), quad(400.0, QuadKind::Video)];
        let dirty = Dirty { video: true, ..Dirty::default() };
        let Damage::Regions(r) = damage(&l, &l, &dirty, 1000, 1000) else { panic!() };
        assert_eq!(r, vec![[398, 8, 422, 32]]);
    }

    #[test]
    fn a_new_image_damages_only_quads_of_that_slot() {
        let mut img = quad(50.0, QuadKind::Image);
        img.slot = 3.0;
        let l = vec![img, quad(400.0, QuadKind::Image)];
        let mut dirty = Dirty::default();
        dirty.images[3] = true;
        let Damage::Regions(r) = damage(&l, &l, &dirty, 1000, 1000) else { panic!() };
        assert_eq!(r.len(), 1);
        assert!(r[0][0] <= 50 && r[0][2] >= 70);
    }

    #[test]
    fn a_different_count_or_a_big_change_is_a_full_draw() {
        let a = vec![quad(0.0, QuadKind::Shape)];
        assert_eq!(damage(&a, &[], &Dirty::default(), 1000, 1000), Damage::Full);
        let mut b = a.clone();
        b[0].rect = Rect::new(0.0, 0.0, 900.0, 900.0);
        assert_eq!(damage(&a, &b, &Dirty::default(), 1000, 1000), Damage::Full);
        assert_eq!(damage(&a, &a, &Dirty { all: true, ..Dirty::default() }, 1000, 1000), Damage::Full);
    }

    #[test]
    fn overlapping_changes_merge_and_many_regions_collapse() {
        let a: Vec<DrawQuad> = (0..10).map(|i| quad(i as f32 * 50.0, QuadKind::Shape)).collect();
        let mut b = a.clone();
        for q in &mut b {
            q.color.a = 0.5;
        }
        let Damage::Regions(r) = damage(&a, &b, &Dirty::default(), 1000, 1000) else { panic!() };
        assert_eq!(r.len(), 1, "touching boxes become one");
        let a: Vec<DrawQuad> = (0..10).map(|i| quad(i as f32 * 90.0, QuadKind::Shape)).collect();
        let mut b = a.clone();
        for q in b.iter_mut().step_by(2) {
            q.color.a = 0.5;
        }
        let Damage::Regions(r) = damage(&a, &b, &Dirty::default(), 1000, 1000) else { panic!() };
        assert!(r.len() <= MAX_REGIONS);
    }
}
