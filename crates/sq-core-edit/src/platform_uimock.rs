// Swift: PlatformUIMock.swift (the `SafeZoneChoice` extension waits for safe_zone_choice.rs)
//! Geometry of the light platform UI mock the Program monitor can draw over the dimmed zone (right action column, account
//! name and caption lines, progress bar). Pure fractions of the frame (origin top-left), derived from the clear (safe)
//! rectangle, so it scales with any frame and matches whatever the zone popup chose. Preview only: never exported.

use crate::cut_check::NormRect;

/// What an element of the mock stands for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PlatformUIMockKind {
    /// Profile picture.
    Avatar,
    /// Like button.
    Like,
    /// Comment button.
    Comment,
    /// Share button.
    Share,
    /// Save button.
    Save,
    /// Account name line.
    AccountName,
    /// One caption line.
    CaptionLine,
    /// Progress bar at the bottom edge.
    ProgressBar,
}

/// One drawn element.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlatformUIMockElement {
    /// What it is.
    pub kind: PlatformUIMockKind,
    /// Frame fractions. The round buttons are square in pixels at the frame aspect.
    pub rect: NormRect,
}

impl PlatformUIMockElement {
    /// True for the five round buttons.
    pub fn is_round_button(&self) -> bool {
        use PlatformUIMockKind::*;
        matches!(self.kind, Avatar | Like | Comment | Share | Save)
    }
}

/// `enum PlatformUIMock`.
pub enum PlatformUIMock {}

impl PlatformUIMock {
    /// The elements for a clear rectangle `zone` in a frame of `frame_aspect` (width / height). Empty when the zone leaves
    /// no room outside it (a full-frame zone).
    pub fn elements(z: NormRect, frame_aspect: f64) -> Vec<PlatformUIMockElement> {
        use PlatformUIMockKind::*;
        let aspect = frame_aspect.max(0.01);
        let right_band = 1.0 - (z.x + z.width);
        let bottom_band = 1.0 - (z.y + z.height);
        let mut out = Vec::new();
        let el = |kind, x, y, width, height| PlatformUIMockElement { kind, rect: NormRect { x, y, width, height } };
        if right_band > 0.01 {
            // the stack always fits above the zone's bottom
            let dh = ((right_band * 0.62).min(0.11) * aspect).min((z.y + z.height) / 7.6);
            let dw = dh / aspect;
            let cx = (z.x + z.width) + right_band / 2.0;
            let step = dh * 1.55;
            let mut cy = z.y + z.height - dh * 0.7;
            for k in [Save, Share, Comment, Like, Avatar] {
                // bottom to top
                out.push(el(k, cx - dw / 2.0, cy - dh / 2.0, dw, dh));
                cy -= step;
            }
        }
        if bottom_band > 0.02 {
            let top = z.y + z.height;
            let w = z.width;
            out.push(el(AccountName, z.x, top + bottom_band * 0.12, (0.30_f64).min(w * 0.45), bottom_band * 0.07));
            out.push(el(CaptionLine, z.x, top + bottom_band * 0.28, w * 0.85, bottom_band * 0.06));
            out.push(el(CaptionLine, z.x, top + bottom_band * 0.40, w * 0.60, bottom_band * 0.06));
            out.push(el(ProgressBar, 0.0, 1.0 - 0.004, 1.0, 0.004));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FULL: NormRect = NormRect { x: 0.0, y: 0.0, width: 1.0, height: 1.0 };

    #[test]
    fn a_full_frame_zone_leaves_nothing_to_draw() {
        assert!(PlatformUIMock::elements(FULL, 9.0 / 16.0).is_empty());
    }

    #[test]
    fn elements_stay_inside_the_frame_outside_the_zone_and_round_buttons_are_round() {
        use crate::cut_check::{CutCheckPlatform, SafeZone};
        for p in CutCheckPlatform::ALL {
            for aspect in [9.0 / 16.0, 1.0, 16.0 / 9.0] {
                let zone = SafeZone::rect_for(p, aspect);
                let els = PlatformUIMock::elements(zone, aspect);
                for e in &els {
                    assert!(FULL.contains(&e.rect), "{p:?} {aspect} {:?} leaves the frame", e.kind);
                    if e.kind != PlatformUIMockKind::ProgressBar {
                        let overlaps = e.rect.x < zone.x + zone.width - 0.001
                            && e.rect.x + e.rect.width > zone.x + 0.001
                            && e.rect.y < zone.y + zone.height - 0.001
                            && e.rect.y + e.rect.height > zone.y + 0.001;
                        assert!(!overlaps, "{p:?} {aspect} {:?} covers the clear zone", e.kind);
                    }
                    if e.is_round_button() {
                        assert!((e.rect.height - e.rect.width * aspect).abs() < 1e-9);
                    }
                }
                assert_eq!(els.iter().filter(|e| e.is_round_button()).count(), 5);
            }
        }
    }
}
