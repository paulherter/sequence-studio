//! View tools that reach the monitor and the timeline through the real root: the Hand tool on the Program picture and
//! Fit Sequence on the timeline.

use super::tests::{root, session};
use super::*;
use sq_core_time::{Id, SequentialIds, Time, TimeRange};
use sq_draw::InputEvent;
use sq_draw::InputModifiers;
use sq_editor_session::TimelineTool;
use sq_uikit::editor_command::EditorCommand as C;

/// A root laid out in `width` x 800 whose first video track holds one clip of `seconds`.
fn rig_with_clip(width: f64, seconds: i64) -> (AppRoot, crate::test_rig::Rig) {
    let mut s = session();
    s.perform("Setup", None, |p| {
        let mut ids = SequentialIds::default();
        let t = &mut p.timelines[0];
        t.format.frame_duration = Time::new(1, 30);
        let c = sq_core_model::Clip::new(
            Id::from_u128(1),
            "clip",
            Id::from_u128(101),
            sq_core_model::TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::seconds(seconds)),
            Time::ZERO,
        );
        assert!(t.tracks[0].insert(c, &mut ids).is_ok());
    });
    s.take_changes();
    let mut rig = crate::test_rig::Rig::new(s);
    let mut r = root();
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, width, 800.0), &mut rig.cx());
    (r, rig)
}

/// Runs frames (layout ticks the zoom glide) with the panel clock advanced by 16 ms each, until it lands.
fn run_frames(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, now: &std::rc::Rc<std::cell::Cell<f64>>, width: f64) {
    for _ in 0..200 {
        if !r.timeline.inner().panel.is_zooming() {
            return;
        }
        now.set(now.get() + 0.016);
        r.layout(CGRect::new(0.0, 0.0, width, 800.0), &mut rig.cx());
    }
}

/// Fit Sequence from the header menu or `\` (the same command): on the first press the view lands where a freshly
/// opened sequence is fitted (the whole sequence across the track width with the 16 pt margins), from any start.
#[test]
fn fit_sequence_fills_the_track_width_on_the_first_press_from_any_view() {
    for width in [900.0, 1400.0, 1920.0] {
        for secs in [4, 18, 120] {
            let (mut r, mut rig) = rig_with_clip(width, secs);
            let now = std::rc::Rc::new(std::cell::Cell::new(100.0));
            let c = std::rc::Rc::clone(&now);
            r.timeline.inner().panel.clock = Box::new(move || c.get());
            let fit = r.timeline.inner().panel.geometry.points_per_second;
            // The track width is the same for every length: the sequence's pixels grow with its seconds.
            let filled = fit * secs as f64;
            for start in [fit * 0.5, fit * 1.7, fit * 6.0, fit * 40.0] {
                r.timeline.inner().panel.set_zoom(start, None);
                r.timeline.inner().panel.geometry.scroll_x = 37.0;
                r.timeline.inner().host.run(C::ZoomFit);
                r.answer(&mut rig.cx());
                run_frames(&mut r, &mut rig, &now, width);
                let p = &mut r.timeline.inner().panel;
                let ok = (p.geometry.points_per_second - fit).abs() < 1e-6 && p.geometry.scroll_x == 0.0;
                assert!(
                    ok,
                    "w={width} secs={secs} start={start}: pps {} scroll {}",
                    p.geometry.points_per_second, p.geometry.scroll_x
                );
                assert!((p.geometry.x(Time::seconds(secs)) - p.geometry.x(Time::ZERO) - filled).abs() < 1e-6);
            }
        }
    }
}

/// A sequence opened in a window of one width, then fitted after the window grew: the fit follows the new width.
#[test]
fn fit_sequence_follows_a_resized_window() {
    let (mut r, mut rig) = rig_with_clip(900.0, 18);
    let now = std::rc::Rc::new(std::cell::Cell::new(100.0));
    let c = std::rc::Rc::clone(&now);
    r.timeline.inner().panel.clock = Box::new(move || c.get());
    let small = r.timeline.inner().panel.geometry.points_per_second;
    r.layout(CGRect::new(0.0, 0.0, 1920.0, 800.0), &mut rig.cx());
    r.timeline.inner().host.run(C::ZoomFit);
    r.answer(&mut rig.cx());
    run_frames(&mut r, &mut rig, &now, 1920.0);
    let (_, fresh) = {
        let (mut r2, rig2) = rig_with_clip(1920.0, 18);
        (rig2, r2.timeline.inner().panel.geometry.points_per_second)
    };
    let got = r.timeline.inner().panel.geometry.points_per_second;
    assert!(got > small * 1.5 && (got - fresh).abs() < 1e-6, "small {small}, fitted {got}, fresh {fresh}");
}

/// A root laid out in `width` x 800 whose first video track holds back-to-back clips of `frames` frames at 30 fps (the
/// shape of the checker's fixture: three clips, 12.03 s).
fn rig_with_clips(width: f64, frames: &[i64]) -> (AppRoot, crate::test_rig::Rig) {
    let mut s = session();
    s.perform("Setup", None, |p| {
        let mut ids = SequentialIds::default();
        let t = &mut p.timelines[0];
        t.format.frame_duration = Time::new(1, 30);
        let mut at = 0;
        for (i, n) in frames.iter().enumerate() {
            let c = sq_core_model::Clip::new(
                Id::from_u128(1 + i as u128),
                "clip",
                Id::from_u128(101 + i as u128),
                sq_core_model::TrackKind::Video,
                TimeRange::new(Time::new(at, 30), Time::new(*n, 30)),
                Time::ZERO,
            );
            assert!(t.tracks[0].insert(c, &mut ids).is_ok());
            at += n;
        }
    });
    s.take_changes();
    let mut rig = crate::test_rig::Rig::new(s);
    let mut r = root();
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, width, 800.0), &mut rig.cx());
    (r, rig)
}

/// The whole 12.03 s sequence is in view after Fit Sequence: its end lies inside the window and uses most of the track
/// width (a view of only ~4 s would put the end at three window widths), from a fresh open, after zooming in or out, and
/// when the button is pressed again (restore) and once more.
#[test]
fn fit_sequence_shows_the_whole_twelve_second_sequence() {
    for width in [1100.0, 1400.0, 1920.0] {
        let (mut r, mut rig) = rig_with_clips(width, &[120, 120, 121]);
        let now = std::rc::Rc::new(std::cell::Cell::new(100.0));
        let c = std::rc::Rc::clone(&now);
        r.timeline.inner().panel.clock = Box::new(move || c.get());
        let end = Time::new(361, 30);
        let shows_all = |r: &mut AppRoot, what: &str| {
            let g = &r.timeline.inner().panel.geometry;
            let x = g.x(end);
            assert!(x <= width && x >= width * 0.5 && g.x(Time::ZERO) >= 0.0, "w={width} {what}: end at x={x}");
        };
        shows_all(&mut r, "fresh open");
        let fit = r.timeline.inner().panel.geometry.points_per_second;
        for (what, start) in [("zoomed in", fit * 8.0), ("zoomed out", fit * 0.6)] {
            r.timeline.inner().panel.set_zoom(start, None);
            r.timeline.inner().panel.geometry.scroll_x = 37.0;
            r.timeline.inner().host.run(C::ZoomFit);
            r.answer(&mut rig.cx());
            run_frames(&mut r, &mut rig, &now, width);
            shows_all(&mut r, what);
        }
        for press in 0..3 {
            r.timeline.inner().host.run(C::ZoomFit);
            r.answer(&mut rig.cx());
            run_frames(&mut r, &mut rig, &now, width);
            // Press 0 is the restore of the toggle (back to the zoomed-out view), press 1 fits again, press 2 restores.
            if press == 1 {
                shows_all(&mut r, "fitted again");
            }
        }
        for _ in 0..2 {
            r.timeline.inner().host.run(C::ZoomOut);
            r.answer(&mut rig.cx());
            run_frames(&mut r, &mut rig, &now, width);
        }
        r.timeline.inner().host.run(C::ZoomFit);
        r.answer(&mut rig.cx());
        run_frames(&mut r, &mut rig, &now, width);
        shows_all(&mut r, "after two zoom-outs");
    }
}

/// A root with a sequence, the monitor laid out, and the timeline tool `tool`.
fn with_tool(tool: TimelineTool) -> (AppRoot, crate::test_rig::Rig) {
    let mut s = session();
    s.add_sequence(None, None, None);
    let mut rig = crate::test_rig::Rig::new(s);
    let mut r = root().with_graphics(crate::GraphicsHost::new());
    r.timeline.inner().panel.tool_state_mut().tool = tool;
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    r.sync(&rig.session);
    (r, rig)
}

/// The center of the Program picture, then a press, a drag by `dx` and a release.
fn drag_picture(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, dx: f32) {
    let c = r.monitor.panel.canvas_rect();
    let (x, y) = (c.mid_x() as f32, c.mid_y() as f32);
    let none = InputModifiers::NONE;
    r.handle(&InputEvent::MouseDown { x, y, modifiers: none }, &mut rig.cx());
    r.handle(&InputEvent::MouseDragged { x: x + dx, y, modifiers: none }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x: x + dx, y }, &mut rig.cx());
    r.pump(&mut rig.cx());
}

#[test]
fn the_hand_tool_pans_a_zoomed_program_picture_and_a_double_click_fits_it() {
    use sq_core_edit::viewer_zoom::ViewerZoom;
    let (mut r, mut rig) = with_tool(TimelineTool::Hand);
    assert!(r.monitor.panel.hand_tool_on, "the timeline's Hand tool reaches the monitor");
    r.monitor.panel.zoom_gesture(ViewerZoom::Percent(200));
    drag_picture(&mut r, &mut rig, -100.0);
    let ViewerZoom::View { scale, center_x, .. } = r.monitor.panel.viewer_zoom() else { panic!("not panned") };
    assert!(center_x > 0.0 && (scale - 2.0).abs() < 1e-9, "dragging left shows what lies right: {center_x}");
    // two presses in a row on the picture
    let c = r.monitor.panel.canvas_rect();
    let (x, y) = (c.mid_x() as f32, c.mid_y() as f32);
    for _ in 0..2 {
        r.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx());
        r.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
    }
    assert!(r.monitor.panel.viewer_zoom().is_fit(), "the double-click fits the picture");
}

#[test]
fn another_tool_leaves_the_zoomed_program_picture_alone() {
    use sq_core_edit::viewer_zoom::ViewerZoom;
    let (mut r, mut rig) = with_tool(TimelineTool::Hand);
    r.timeline.inner().panel.tool_state_mut().tool = TimelineTool::Selection;
    r.sync(&rig.session);
    assert!(!r.monitor.panel.hand_tool_on);
    r.monitor.panel.zoom_gesture(ViewerZoom::Percent(200));
    drag_picture(&mut r, &mut rig, -100.0);
    assert_eq!(r.monitor.panel.viewer_zoom(), ViewerZoom::Percent(200));
}
