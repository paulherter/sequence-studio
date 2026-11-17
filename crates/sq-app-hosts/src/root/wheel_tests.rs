//! D9: the mouse wheel over the Controls panel, through the whole root, in the shape the Windows window sends it
//! (`WM_MOUSEWHEEL` -> winit `LineDelta` -> `WinScroll`: a gesture on the UI context and 40 px per notch in the event).

use super::menu_click_tests::{new_root, send};
use super::*;
use sq_draw::scroll::WinScroll;

/// One Windows wheel notch of `lines` at the point (window points, scale 1).
fn notch(root: &mut AppRoot, rig: &mut crate::test_rig::Rig, at: CGPoint, lines: i32) -> bool {
    let mut w = WinScroll::default();
    let g = w.wheel(lines * WinScroll::WHEEL_DELTA, false, false, 0.0);
    let (dx, dy) = WinScroll::pixels(&g, 1.0);
    let (x, y) = (at.x as f32, at.y as f32);
    send(root, rig, InputEvent::MouseMoved { x, y });
    rig.ui.gesture = Some(g);
    let taken = send(root, rig, InputEvent::Scroll { x, y, dx, dy, modifiers: InputModifiers::NONE });
    rig.ui.gesture = None;
    taken
}

#[test]
fn a_wheel_notch_over_the_controls_panel_scrolls_it_through_the_root() {
    for track_kind in [sq_core_model::TrackKind::Audio, sq_core_model::TrackKind::Video] {
        let (mut root, mut rig) = new_root();
        let clip = rig
            .session
            .active_timeline()
            .and_then(|t| t.tracks.iter().find(|k| k.kind == track_kind).and_then(|k| k.clips().first().map(|c| c.id)))
            .expect("a clip");
        rig.session.select(std::iter::once(clip).collect(), Default::default());
        send(&mut root, &mut rig, InputEvent::MouseMoved { x: 5.0, y: 5.0 });
        let frame = root.dock.content_frame(PanelID::EffectControls).expect("the Controls panel is docked");
        let at = CGPoint::new(frame.mid_x(), frame.mid_y());
        for _ in 0..4 {
            notch(&mut root, &mut rig, at, -1);
        }
        let moved = root.inspector.scrolled_by();
        assert!(moved > 0.0, "{track_kind:?}: four wheel notches at {at:?} moved the Controls panel by {moved}");
    }
}
