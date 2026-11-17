// Swift: TextHitTest.swift
//! Type tool: which text layer lies under a click in the Program monitor.

use sq_core_graphics::graphics_make_graphic::TEXT_KIND;
use sq_core_model::{Clip, Project, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, Vec2};
use sq_editor_session::es02_timeline_ops::{LayerBounds, OverlayTarget};
use sq_uikit::controls_grid::CGPoint;

/// Which layer lies under a click in the Program monitor. Pure (no session, no undo step): a click on existing text edits
/// it instead of making a second text.
pub enum TextHitTest {}

impl TextHitTest {
    /// Topmost visible text clip under `time` whose drawn rectangle contains `p` (sequence px from the canvas center);
    /// the last video track is the topmost, hidden tracks never hit.
    pub fn topmost_text_clip(p: Vec2, timeline: &Timeline, project: &Project, time: Time) -> Option<Id> {
        for track in timeline.tracks.iter().filter(|t| t.kind == TrackKind::Video && t.is_visible).rev() {
            for c in track.clips() {
                let Some(r) = &c.generator else { continue };
                if r.kind != TEXT_KIND {
                    continue;
                }
                let Some(o) = OverlayTarget::make(c, project, timeline, time, None) else { continue };
                if LayerBounds::rect(o.size, &o.display_transform()).contains(CGPoint::new(p.x, p.y)) {
                    return Some(c.id);
                }
            }
        }
        None
    }

    /// Topmost visible picture or text clip under `time` whose drawn rectangle contains `p` (a click in the Program
    /// monitor selects it). Audio and hidden tracks never hit; the last video track is the topmost. `accepting` narrows
    /// the clips that count (Magic: video from a file, so a title above the picture does not catch the click).
    pub fn topmost_visual_clip(
        p: Vec2,
        timeline: &Timeline,
        project: &Project,
        time: Time,
        variant: Option<Id>,
        accepting: &dyn Fn(&Clip) -> bool,
    ) -> Option<Id> {
        // Any video track can be hit, not only the targeted one; a hit on a targeted track wins over a higher untargeted one.
        let mut fallback: Option<Id> = None;
        for track in timeline.tracks.iter().filter(|t| t.kind == TrackKind::Video && t.is_visible).rev() {
            // A graphics clip is picked through its layers (Graphics overlay), not as a canvas-sized box.
            for c in track.clips().iter().filter(|c| c.is_enabled && !c.is_graphics() && accepting(c)) {
                let Some(o) = OverlayTarget::make(c, project, timeline, time, variant) else { continue };
                if LayerBounds::rect(o.size, &o.display_transform()).contains(CGPoint::new(p.x, p.y)) {
                    if track.is_targeted {
                        return Some(c.id);
                    }
                    if fallback.is_none() {
                        fallback = Some(c.id);
                    }
                    break;
                }
            }
        }
        fallback
    }

    /// Whether a hit on track `hit` beats the one already picked on track `picked` (indexes into `tracks`; `None`: nothing
    /// picked yet): a targeted track wins over an untargeted one, otherwise the higher track.
    pub fn hit_wins(hit: usize, picked: Option<usize>, tracks: &[Track]) -> bool {
        let Some(picked) = picked else { return true };
        let ht = tracks[hit].is_targeted;
        let pt = tracks[picked].is_targeted;
        if ht != pt { ht } else { hit >= picked }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::Track;

    fn track(targeted: bool) -> Track {
        let mut t = Track::new(Id::from_u128(1), TrackKind::Video);
        t.is_targeted = targeted;
        t
    }

    #[test]
    fn a_targeted_track_beats_an_untargeted_one_and_then_the_higher_track_wins() {
        let tracks = [track(false), track(true), track(false)];
        assert!(TextHitTest::hit_wins(0, None, &tracks));
        assert!(TextHitTest::hit_wins(1, Some(2), &tracks));
        assert!(!TextHitTest::hit_wins(2, Some(1), &tracks));
        let plain = [track(false), track(false)];
        assert!(TextHitTest::hit_wins(1, Some(0), &plain));
        assert!(!TextHitTest::hit_wins(0, Some(1), &plain));
    }
}
