// Swift: MonitorHost+PictureTools.swift (`captionHit`, `beginCaptionDrag`, `moveCaptionDrag`)
//! Captions on the Program picture (Select tool): a press selects one, a drag moves it as one undo step, a double-click
//! (handled by the text work) edits it.
// shortcut: the drag snaps to the center lines and the safe areas, not to the platform UI zone (the zone rect of the
// card's Safe Zone choice is not passed in); upgrade when the zone should attract captions.

use sq_core_model::CaptionPosition;
use sq_core_time::{Id, Vec2};
use sq_draw_monitor::monitor_panel::PictureToolsHost;
use sq_editor_session::{CaptionMonitorHit, EditorSession, SnapResult};
use sq_text::caption_presets::CaptionLookRegistry;
use sq_timeline_ui::caption_drag::CaptionDrag;
use sq_uikit::keyframe_graph_geometry::{Rect, Size};
use std::collections::BTreeSet;

/// A caption drag in progress: the caption, its position and drawn text block at the press, and whether a step was written.
struct Drag {
    id: Id,
    start: CaptionPosition,
    text_rect: Rect,
    started: bool,
}

/// The Program card's caption picks.
#[derive(Default)]
pub struct CaptionPicks {
    drag: Option<Drag>,
}

fn hit(s: &EditorSession, p: Vec2) -> Option<Id> {
    if !s.engine().shows_captions() {
        return None;
    }
    let tl = s.display_timeline()?;
    let library = CaptionLookRegistry::shared().library_for_project(s.project());
    CaptionMonitorHit::caption(p, &tl, s.playhead(), &library)
}

impl PictureToolsHost for CaptionPicks {
    fn caption_hit_test(&self, s: &EditorSession, p: Vec2) -> bool {
        hit(s, p).is_some()
    }

    fn caption_drag_began(&mut self, s: &mut EditorSession, p: Vec2) -> bool {
        let (Some(id), Some(tl)) = (hit(s, p), s.display_timeline()) else { return false };
        let Some(item) = s.caption_item(id) else { return false };
        s.select(BTreeSet::new(), BTreeSet::from([id]));
        let library = CaptionLookRegistry::shared().library_for_project(s.project());
        self.drag = Some(Drag {
            id,
            start: s.effective_caption_position(&item),
            text_rect: CaptionMonitorHit::text_rect(&item, &tl.format, &library),
            started: false,
        });
        true
    }

    /// One drag = one undo step; snaps to the center and the safe areas.
    fn caption_drag_moved(&mut self, s: &mut EditorSession, delta: Vec2, snap: f64) -> SnapResult {
        let (Some(d), Some(tl)) = (self.drag.as_mut(), s.display_timeline()) else { return SnapResult::default() };
        let canvas = Size::new(tl.format.display_width() as f64, tl.format.height as f64);
        let (position, guides) = CaptionDrag::moved(d.start, d.text_rect, delta, canvas, snap, None);
        let (id, started) = (d.id, d.started);
        d.started = true;
        s.stop_playback();
        s.set_caption_item_position(&BTreeSet::from([id]), position, started);
        guides
    }

    fn caption_drag_ended(&mut self, _s: &mut EditorSession) {
        self.drag = None;
    }
}
