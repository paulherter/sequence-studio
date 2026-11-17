// Swift: FXBadge.swift
//! The effects marker at the top right of a clip: drawn only once an effect is applied (the "none" state draws nothing).
//! V1 Quiet (DESIGN-SPEC §2): a 5 pt white dot at 85 %, 4 pt in from the top right corner; no "fx" text.

use sq_core_model::{BlendMode, Clip, ClipAnimation, ClipFootageColor, TrackKind};
use sq_uikit::keyframe_graph_geometry::{Rect, Size};

/// Whether the badge is drawn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FXBadgeState {
    /// Nothing applied.
    None,
    /// Something is applied.
    Applied,
}

/// The effects badge.
pub struct FXBadge;

impl FXBadge {
    /// Smallest clip width that has room for the badge.
    pub const MIN_CLIP_WIDTH: f64 = 16.0;
    /// Dot size.
    pub const SIZE: Size = Size::new(5.0, 5.0);
    /// Distance from the corner.
    pub const INSET: f64 = 4.0;

    /// Pure draw decision. Applied = any effect in the list, a changed fixed effect (Motion, Opacity, blend mode), a color
    /// correction, or a frame hold.
    pub fn state(clip: &Clip) -> FXBadgeState {
        if clip.kind != TrackKind::Video {
            return FXBadgeState::None;
        }
        let fresh = ClipAnimation::default();
        let a = &clip.animation;
        let motion_changed = a.position != fresh.position
            || a.scale != fresh.scale
            || a.rotation != fresh.rotation
            || a.anchor != fresh.anchor;
        let opacity_changed = a.opacity != fresh.opacity || clip.blend_mode != BlendMode::Normal;
        if !clip.effects.is_empty()
            || motion_changed
            || opacity_changed
            || clip.footage_color != ClipFootageColor::default()
            || clip.hold_frame.is_some()
        {
            return FXBadgeState::Applied;
        }
        FXBadgeState::None
    }

    /// Where the badge sits: the top right corner of the clip, kept in view while the right end is scrolled out.
    pub fn frame(clip_rect: &Rect, visible: &Rect) -> Option<Rect> {
        if clip_rect.width < Self::MIN_CLIP_WIDTH {
            return None;
        }
        let right = clip_rect.max_x().min(visible.max_x()) - Self::INSET;
        let r =
            Rect::new(right - Self::SIZE.width, clip_rect.min_y() + Self::INSET, Self::SIZE.width, Self::SIZE.height);
        if r.min_x() >= clip_rect.min_x() + Self::INSET { Some(r) } else { None }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::*;

    #[test]
    fn plain_clip_has_no_badge_and_a_hold_or_blend_mode_has() {
        let mut c = mkv(0, 24);
        assert_eq!(FXBadge::state(&c), FXBadgeState::None);
        c.hold_frame = Some(sq_core_time::Time::ZERO);
        assert_eq!(FXBadge::state(&c), FXBadgeState::Applied);
        let mut d = mkv(0, 24);
        d.blend_mode = BlendMode::Multiply;
        assert_eq!(FXBadge::state(&d), FXBadgeState::Applied);
        let audio = mk(0, 24, TrackKind::Audio, None);
        assert_eq!(FXBadge::state(&audio), FXBadgeState::None);
    }

    #[test]
    fn badge_sits_in_the_top_right_corner_and_stays_in_view() {
        let clip = Rect::new(100.0, 50.0, 200.0, 30.0);
        let visible = Rect::new(0.0, 0.0, 250.0, 300.0);
        let f = FXBadge::frame(&clip, &visible).unwrap();
        assert_eq!((f.max_x(), f.min_y()), (246.0, 54.0));
        assert!(FXBadge::frame(&Rect::new(0.0, 0.0, 10.0, 30.0), &visible).is_none());
    }
}
