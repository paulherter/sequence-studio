// Swift: AngleTile.swift
//! The tiles of the multi-angle Source view and where they lie.

use sq_uikit::controls_grid::{CGPoint, CGRect};

/// The frame as a draw-list image (canvas monitor): image slot and its source rect (u0, v0, u1, v1) in that slot.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AngleTilePicture {
    /// Image slot.
    pub slot: usize,
    /// Left of the source rect.
    pub u0: f32,
    /// Top of the source rect.
    pub v0: f32,
    /// Right of the source rect.
    pub u1: f32,
    /// Bottom of the source rect.
    pub v1: f32,
}

impl AngleTilePicture {
    /// The whole slot.
    pub fn new(slot: usize) -> AngleTilePicture {
        AngleTilePicture { slot, u0: 0.0, v0: 0.0, u1: 1.0, v1: 1.0 }
    }
}

/// One angle in the multi-angle view: its name, the frame it shows now (`None` while loading) and whether it is the one
/// that plays. The Mac `image: AnyObject?` (a `CGImage`) is not ported: only the draw-list picture exists here.
#[derive(Clone, Debug, PartialEq)]
pub struct AngleTile {
    /// The angle's name.
    pub name: String,
    /// The frame on the canvas monitor; `None` while loading.
    pub picture: Option<AngleTilePicture>,
    /// The angle that plays.
    pub is_active: bool,
}

impl AngleTile {
    /// A tile.
    pub fn new(name: &str, picture: Option<AngleTilePicture>, is_active: bool) -> AngleTile {
        AngleTile { name: name.to_string(), picture, is_active }
    }
}

/// Where the tiles of the multi-angle view lie: as many columns as give the largest pictures of `aspect` (width / height).
pub enum AnglesGridLayout {}

impl AnglesGridLayout {
    /// The tile rects.
    pub fn cells(count: usize, bounds: CGRect, aspect: f64, gap: f64) -> Vec<CGRect> {
        if count == 0 || bounds.width <= 0.0 || bounds.height <= 0.0 || aspect <= 0.0 {
            return Vec::new();
        }
        let (mut best_columns, mut best_width) = (1usize, 0.0f64);
        for columns in 1..=count {
            let rows = count.div_ceil(columns);
            let w = (bounds.width - gap * (columns - 1) as f64) / columns as f64;
            let h = (bounds.height - gap * (rows - 1) as f64) / rows as f64;
            let fit = (w.min(h * aspect)).max(0.0);
            if fit > best_width {
                best_columns = columns;
                best_width = fit;
            }
        }
        let rows = count.div_ceil(best_columns);
        let w = best_width;
        let h = w / aspect;
        let used_w = w * best_columns as f64 + gap * (best_columns - 1) as f64;
        let used_h = h * rows as f64 + gap * (rows - 1) as f64;
        let origin = CGPoint::new(
            bounds.min_x() + (bounds.width - used_w) / 2.0,
            bounds.min_y() + (bounds.height - used_h) / 2.0,
        );
        (0..count)
            .map(|i| {
                let r = i / best_columns;
                let c = i % best_columns;
                // The last row is centered when it is not full.
                let in_row = if r == rows - 1 { count - r * best_columns } else { best_columns };
                let shift = (best_columns - in_row) as f64 * (w + gap) / 2.0;
                CGRect::new(origin.x + shift + c as f64 * (w + gap), origin.y + r as f64 * (h + gap), w, h)
            })
            .collect()
    }

    /// The tile under `point`, if any.
    pub fn index(point: CGPoint, cells: &[CGRect]) -> Option<usize> {
        cells.iter().position(|c| c.contains(point))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn four_tiles_fill_a_two_by_two_grid() {
        let cells = AnglesGridLayout::cells(4, CGRect::new(0.0, 0.0, 400.0, 225.0), 16.0 / 9.0, 0.0);
        assert_eq!(cells.len(), 4);
        assert_eq!(AnglesGridLayout::index(CGPoint::new(10.0, 10.0), &cells), Some(0));
        assert_eq!(AnglesGridLayout::index(CGPoint::new(900.0, 900.0), &cells), None);
    }

    #[test]
    fn the_last_row_is_centered_when_not_full() {
        let cells = AnglesGridLayout::cells(3, CGRect::new(0.0, 0.0, 400.0, 400.0), 1.0, 0.0);
        assert_eq!(cells.len(), 3);
        assert!(cells[2].x > cells[0].x);
    }
}
