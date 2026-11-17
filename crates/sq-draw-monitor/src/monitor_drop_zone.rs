// Swift: MonitorDropZone.swift
//! Where project items dropped on the Program monitor go.

use sq_uikit::controls_grid::{CGRect, CGSize};

/// Where project items dropped on the Program monitor go: the left half inserts at the playhead (later clips move
/// right), the right half overwrites. Pure so the split is testable; the panel shows the zone under the pointer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MonitorDropZone {
    /// Left half.
    Insert,
    /// Right half.
    Overwrite,
}

impl MonitorDropZone {
    /// Every zone.
    pub const ALL: [MonitorDropZone; 2] = [MonitorDropZone::Insert, MonitorDropZone::Overwrite];

    /// The zone at horizontal position `x` of a panel `width` wide.
    pub fn zone(x: f64, width: f64) -> MonitorDropZone {
        if width <= 0.0 {
            return MonitorDropZone::Overwrite;
        }
        if x < width / 2.0 { MonitorDropZone::Insert } else { MonitorDropZone::Overwrite }
    }

    /// The zone's action name.
    pub fn title(self) -> &'static str {
        if self == MonitorDropZone::Insert { "Insert" } else { "Overwrite" }
    }

    /// The half of a panel of `size` this zone covers (origin at the left).
    pub fn rect(self, size: CGSize) -> CGRect {
        let half = size.width / 2.0;
        CGRect::new(if self == MonitorDropZone::Insert { 0.0 } else { half }, 0.0, half, size.height)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn left_half_inserts_right_half_overwrites() {
        assert_eq!(MonitorDropZone::zone(10.0, 100.0), MonitorDropZone::Insert);
        assert_eq!(MonitorDropZone::zone(50.0, 100.0), MonitorDropZone::Overwrite);
        assert_eq!(MonitorDropZone::zone(10.0, 0.0), MonitorDropZone::Overwrite);
        let r = MonitorDropZone::Overwrite.rect(CGSize::new(100.0, 40.0));
        assert_eq!((r.x, r.width, r.height), (50.0, 50.0, 40.0));
    }
}
