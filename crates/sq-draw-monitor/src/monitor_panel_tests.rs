//! Panel tests: MonitorPanelTests, MonitorPickAndPointTests, MonitorTipTests, MonitorHeaderTipsTests, SourceDragTests,
//! MonitorTextToolTests, MonitorFormatSwitcherTests of the Swift package.

use crate::monitor_panel::{HeaderControl, MonitorPanel, PanelEvent, PanelWiring};
use crate::monitor_panel_model::{MonitorEvent, MonitorPanelModel};
use crate::monitor_panel_source_drag::MonitorDragPhase;
use crate::safe_zone_choice::SafeZoneChoice;
use crate::test_support::{Rig, draw, draw_with_text, drawn, mid, panel};
use sq_core_edit::timeline_source_edit::SourceStreams;
use sq_core_edit::viewer_zoom::ViewerZoom;
use sq_core_time::{Id, Time, Vec2};
use sq_draw::monitor::audio_meter::{AudioMeter, MeterChannelLabel, MeterReading};
use sq_draw::monitor::monitor_modes::{MonitorAction, MonitorMode, MonitorZoom};
use sq_draw::scroll::{GestureKind, ScrollGesture};
use sq_draw::theme::spacing;
use sq_draw::{Color, InputKey, InputModifiers};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use std::cell::Cell;
use std::rc::Rc;

fn menus(p: &mut MonitorPanel) -> Vec<(Vec<String>, CGRect, Option<CGPoint>)> {
    p.take_events()
        .into_iter()
        .filter_map(|e| match e {
            PanelEvent::Menu { items, anchor, pointer } => {
                Some((items.iter().map(|i| i.title.clone()).collect(), anchor, pointer))
            }
            _ => None,
        })
        .collect()
}

#[test]
fn fit_picture_sits_inside_the_twelve_point_margin() {
    let p = panel(MonitorMode::Program);
    assert_eq!(p.slot().min_x(), 12.0);
    assert!((p.canvas_rect().width / p.canvas_rect().height - 16.0 / 9.0).abs() < 0.01);
    let inner = p.canvas_rect().inset_by(1.0, 1.0);
    assert!(p.slot().contains(CGPoint::new(inner.min_x(), inner.min_y())));
    assert!(p.slot().contains(CGPoint::new(inner.max_x() - 0.01, inner.max_y() - 0.01)));
}

#[test]
fn an_engine_failure_shows_the_card_with_its_reason_and_offline_media_keeps_its_own() {
    let mut p = panel(MonitorMode::Program);
    assert!(p.offline_card_rect(80.0, 160.0).is_none());
    p.model.engine_failure = Some("compositor: no adapter".to_string());
    assert_eq!(p.model.offline_card_title(), "Preview unavailable");
    assert_eq!(p.model.offline_card_detail().as_deref(), Some("compositor: no adapter"));
    assert!(p.offline_card_rect(80.0, 160.0).is_some());
    p.model.offline_file_name = Some("A001.mov".to_string());
    assert_eq!(p.model.offline_card_title(), "Media offline");
    assert_eq!(p.model.offline_card_detail().as_deref(), Some("A001.mov was moved or renamed"));
}

#[test]
fn the_offline_card_fits_its_picture_and_keeps_the_tail_of_a_long_name() {
    let mut p = panel(MonitorMode::Program);
    p.model.offline_file_name = Some(format!("{} final take.mov", "Interview_Take ".repeat(14)));
    // 8 pt per character stands in for the font; the real measure is the canvas.
    let measure = |t: &str| t.chars().count() as f64 * 5.0;
    for width in [120.0, 174.0, 400.0] {
        let shown = p.model.offline_card_detail_fitted(width, measure);
        assert!(measure(&shown) <= width, "{width}: {shown}");
        assert!(shown.ends_with(" was moved or renamed"), "{width}: tail kept in {shown}");
        assert!(shown.contains('\u{2026}'), "{width}: ellipsis in {shown}");
    }
    p.model.offline_file_name = Some("A001.mov".to_string());
    assert_eq!(p.model.offline_card_detail_fitted(1000.0, measure), "A001.mov was moved or renamed");
    // The card never outgrows a narrow picture inside a wider slot.
    p.canvas_rect = CGRect::new(p.slot().min_x() + 40.0, p.slot().min_y(), 180.0, 100.0);
    let r = p.offline_card_rect(80.0, 5000.0).unwrap_or_default();
    assert!(r.width <= 180.0 - 16.0 + 0.5, "card {} wide for a 180 picture", r.width);
}

#[test]
fn offline_card_centers_on_the_slot_while_a_file_is_offline() {
    let mut p = panel(MonitorMode::Program);
    assert!(p.offline_card_rect(80.0, 160.0).is_none());
    p.model.offline_file_name = Some("A001.mov".to_string());
    assert_eq!(p.model.offline_card_detail().as_deref(), Some("A001.mov was moved or renamed"));
    let r = p.offline_card_rect(80.0, 160.0);
    assert_eq!(r.map(|r| r.width), Some(192.0));
    assert_eq!(r.map(|r| r.height), Some(44.0));
    let r = r.unwrap_or_default();
    assert!((r.mid_x() - p.slot().mid_x()).abs() <= 0.5);
    assert!((r.mid_y() - p.slot().mid_y()).abs() <= 0.5);
    let wide = p.offline_card_rect(80.0, 5000.0);
    // Capped by the picture and the slot less 16 pt a side, never below the readable minimum.
    let ww = wide.map_or(0.0, |r| r.width);
    assert!(ww <= p.slot().width - 32.0 + 0.5 && ww <= p.canvas_rect().width.max(120.0) + 0.5, "{ww}");
    assert!(ww >= 120.0_f64.min(p.slot().width - 32.0) - 0.5, "{ww}");
    // No black frame under the card (the Mac monitor's gray backdrop shows).
    let c = draw(&mut p);
    let frame = c.px(p.canvas_rect());
    assert!(!c.list.quads().iter().any(|q| {
        q.color.r == 0.0
            && q.color.g == 0.0
            && q.color.b == 0.0
            && q.color.a == 1.0
            && q.rect.x == frame.x
            && q.rect.w == frame.w
    }));
}

#[test]
fn zoom_popup_value_reaches_the_picture() {
    let mut p = panel(MonitorMode::Program);
    p.model.set_zoom(MonitorZoom::Percent(100));
    p.layout_px(sq_draw::Rect::new(0.0, 0.0, 800.0, 500.0), 1.0);
    assert_eq!(p.viewer_zoom(), ViewerZoom::Percent(100));
    assert_eq!(p.canvas_rect().width, 1920.0);
    assert_eq!(p.slot().min_x(), 0.0);
}

#[test]
fn ctrl_wheel_zooms_about_the_pointer_and_shows_the_value() {
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    let at = mid(p.slot());
    // AppKit sign: the wheel away from the user (positive deltaY) zooms in, as ProgramSurfaceView.
    rig.scroll(&mut p, at, 0.0, 40.0, InputModifiers::COMMAND, None);
    let ViewerZoom::View { scale, .. } = p.viewer_zoom() else { panic!("no view zoom") };
    assert!(scale > p.mapping().fit_scale() * 0.99);
    assert_eq!(p.model.zoom(), MonitorZoom::Custom((scale * 100.0).round() as i64));
}

#[test]
fn pinch_zooms_and_trackpad_points_pan_one_to_one_as_the_mac_surface() {
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    let at = mid(p.slot());
    let fit = p.mapping().scale();
    let pinch = ScrollGesture { kind: GestureKind::Magnify(0.5), precise: true, ..ScrollGesture::default() };
    rig.scroll(&mut p, at, 0.0, 0.0, InputModifiers::NONE, Some(pinch));
    assert!((p.mapping().scale() / fit - 1.5).abs() < 1e-6);
    // Trackpad: 10 pt of fingers move the picture 10 pt (the host's 20 px at 2x do not count).
    let c0 = p.canvas_rect().min_x();
    let pan = ScrollGesture { delta_x: 10.0, precise: true, ..ScrollGesture::default() };
    rig.scroll(&mut p, at, 20.0, 0.0, InputModifiers::NONE, Some(pan));
    assert!((p.canvas_rect().min_x() - c0 - 10.0).abs() < 0.5);
    // Mouse wheel: a line moves 8 pt.
    let c1 = p.canvas_rect().min_x();
    let wheel = ScrollGesture { delta_x: 1.0, ..ScrollGesture::default() };
    rig.scroll(&mut p, at, 0.0, 0.0, InputModifiers::NONE, Some(wheel));
    assert!((p.canvas_rect().min_x() - c1 - 8.0).abs() < 0.5);
}

#[test]
fn tabs_replace_the_title_and_a_click_switches() {
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    p.tabs = vec!["Program".into(), "Source".into()];
    draw(&mut p);
    assert_eq!(p.tab_rects.len(), 2);
    let (program, source) = (p.tab_rects[0], p.tab_rects[1]);
    rig.down(&mut p, program.mid_x(), program.mid_y(), InputModifiers::NONE);
    assert!(p.take_events().iter().all(|e| !matches!(e, PanelEvent::SelectTab(_)))); // the shown tab: nothing to switch
    assert!(rig.down(&mut p, source.max_x() - 0.5, source.mid_y(), InputModifiers::NONE));
    assert!(p.take_events().iter().any(|e| matches!(e, PanelEvent::SelectTab(1))));
}

/// The header tabs lay out like the dock's tab strip (10 pt padding, 2 pt apart, first tab `sm - 2` in).
#[test]
fn tabs_follow_the_dock_strip_layout() {
    let mut p = panel(MonitorMode::Program);
    p.tabs = vec!["Program".into(), "Source".into()];
    draw(&mut p);
    assert_eq!(p.tab_rects.len(), 2);
    assert_eq!(p.tab_rects[0].min_x(), p.header_rect().min_x() + spacing::SM as f64 - 2.0);
    assert_eq!(p.tab_rects[1].min_x(), p.tab_rects[0].max_x() + 2.0);
    assert!(p.tab_rects[0].width >= 20.0);
}

/// With tabs the header is as tall as the dock's strip, so the labels sit on the line of the other panels' tabs.
#[test]
fn tabs_header_is_as_tall_as_the_dock_strip() {
    let mut p = panel(MonitorMode::Program);
    draw(&mut p);
    let titled = p.header_rect().height;
    p.tabs = vec!["Program".into(), "Source".into()];
    p.layout_frame(CGRect::new(0.0, 0.0, 600.0, 400.0));
    draw(&mut p);
    assert_eq!(p.header_rect().height, f64::from(sq_uikit::redesign_tokens::size::PANEL_HEADER));
    assert!(p.header_rect().height < titled);
}

#[test]
fn empty_program_offers_new_sequence_and_the_click_calls_it() {
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    p.model.has_sequence = false;
    p.model.wired.new_sequence = true;
    draw(&mut p);
    let r = p.new_sequence_rect();
    assert!(r.width > 0.0);
    rig.click(&mut p, mid(r));
    let calls = p.model.take_events().iter().filter(|e| **e == MonitorEvent::NewSequence).count();
    assert_eq!(calls, 1);
    p.model.has_sequence = true;
    draw(&mut p);
    assert_eq!(p.new_sequence_rect(), CGRect::default());
}

#[test]
fn empty_program_stacks_pip_hint_and_button_and_only_with_a_host() {
    let mut p = panel(MonitorMode::Program);
    p.model.has_sequence = false;
    p.model.wired.new_sequence = true;
    draw(&mut p);
    assert_eq!(p.empty_mascot_rect(), CGRect::default()); // no mascot closure: the text stack as before
    let drawn_rects: Rc<std::cell::RefCell<Vec<CGRect>>> = Rc::default();
    let sink = Rc::clone(&drawn_rects);
    p.empty_mascot = Some(Box::new(move |_, r| sink.borrow_mut().push(r)));
    draw(&mut p);
    let pip = p.empty_mascot_rect();
    assert_eq!(*drawn_rects.borrow(), [pip]);
    assert!(pip.width == MonitorPanel::EMPTY_MASCOT_SIDE && pip.height == MonitorPanel::EMPTY_MASCOT_SIDE);
    assert!((pip.mid_x() - p.slot().mid_x()).abs() <= 0.5);
    assert!(pip.max_y() + 14.0 <= p.new_sequence_rect().min_y()); // Pip above the hint, the button below it
    let slot = p.slot();
    let inside = |r: CGRect| {
        r.min_x() >= slot.min_x() && r.max_x() <= slot.max_x() && r.min_y() >= slot.min_y() && r.max_y() <= slot.max_y()
    };
    assert!(inside(pip) && inside(p.new_sequence_rect()));
    p.model.has_sequence = true;
    p.model.timeline_is_empty = true;
    draw(&mut p);
    assert!(p.empty_mascot_rect().width > 0.0); // an empty timeline keeps Pip and the hint (no button)
    p.model.timeline_is_empty = false;
    draw(&mut p);
    assert_eq!(p.empty_mascot_rect(), CGRect::default());
}

#[test]
fn source_empty_state_has_no_pip() {
    let mut p = panel(MonitorMode::Source);
    let drawn_pip = Rc::new(Cell::new(false));
    let flag = Rc::clone(&drawn_pip);
    p.empty_mascot = Some(Box::new(move |_, _| flag.set(true)));
    draw(&mut p);
    assert!(!drawn_pip.get(), "Source draws no Pip");
    assert_eq!(p.empty_mascot_rect(), CGRect::default());
}

#[test]
fn header_line_is_accent_only_while_focused_and_sits_at_the_header_bottom() {
    let mut p = panel(MonitorMode::Program);
    let r = MonitorPanel::active_line_rect(p.header_rect());
    assert!(r.max_y() == p.header_rect().max_y() && r.height == 2.0);
    assert_eq!(r.min_x(), p.header_rect().min_x() + spacing::SM as f64);
    let line_colors = |p: &mut MonitorPanel| -> Vec<Color> {
        let c = draw(p);
        let want = c.px(r);
        [p.theme.accent(), p.theme.label3()]
            .into_iter()
            .filter(|col| {
                c.list.quads().iter().any(|q| {
                    q.rect.w == want.w
                        && q.rect.h == want.h
                        && q.color.r == col.r
                        && q.color.g == col.g
                        && q.color.b == col.b
                })
            })
            .collect()
    };
    p.is_focused = true;
    let accent = p.theme.accent();
    assert!(line_colors(&mut p).contains(&accent));
    p.is_focused = false;
    assert!(!line_colors(&mut p).contains(&accent));
}

#[test]
fn drop_highlight_paints_the_card_and_the_half_zone() {
    let mut p = panel(MonitorMode::Program);
    let plain = draw(&mut p).list.quads().len();
    p.drop_highlight = true;
    assert!(draw(&mut p).list.quads().len() > plain);
}

#[test]
fn wheel_at_fit_does_not_pan() {
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    rig.scroll(&mut p, CGPoint::new(400.0, 200.0), 0.0, 40.0, InputModifiers::NONE, None);
    assert_eq!(p.viewer_zoom(), ViewerZoom::Fit);
}

#[test]
fn header_offers_zoom_quality_and_the_monitor_menu() {
    let p = drawn(MonitorMode::Program);
    let ctls: Vec<HeaderControl> = p.header_controls().iter().map(|c| c.0).collect();
    assert!(ctls.contains(&HeaderControl::Options));
    assert!(ctls.contains(&HeaderControl::Zoom));
    assert!(ctls.contains(&HeaderControl::Quality));
    assert!(p.header_items(HeaderControl::Zoom).iter().any(|i| i.title == "Fit"));
    assert!(p.header_items(HeaderControl::Options).iter().any(|i| i.title == "Safe Margins"));
}

#[test]
fn content_popup_sits_right_beside_zoom_not_after_the_tabs() {
    let mut p = panel(MonitorMode::Program);
    p.model.has_sequence = true;
    p.model.sequence_name = "Main".to_string();
    draw(&mut p);
    let find = |k: HeaderControl| p.header_controls().iter().find(|c| c.0 == k).map(|c| c.1);
    let (Some(content), Some(zoom)) = (find(HeaderControl::Content), find(HeaderControl::Zoom)) else {
        panic!("popups")
    };
    assert!(content.max_x() <= zoom.min_x());
    assert!(zoom.min_x() - content.max_x() < 8.0);
}

#[test]
fn zone_control_shows_only_while_a_zone_is_on() {
    let mut p = panel(MonitorMode::Program);
    p.model.set_safe_zone(SafeZoneChoice::Off);
    draw(&mut p);
    assert!(!p.header_controls().iter().any(|c| c.0 == HeaderControl::Zone));
    p.model.set_safe_zone(SafeZoneChoice::Tiktok);
    draw(&mut p);
    assert!(p.header_controls().iter().any(|c| c.0 == HeaderControl::Zone));
}

#[test]
fn click_on_a_popup_opens_its_rows_below_it() {
    let mut p = drawn(MonitorMode::Program);
    let mut rig = Rig::new();
    let zoom = p.header_controls().iter().find(|c| c.0 == HeaderControl::Zoom).map(|c| c.1).unwrap_or_default();
    rig.down(&mut p, zoom.mid_x(), zoom.mid_y(), InputModifiers::NONE);
    let opened = menus(&mut p);
    assert_eq!(opened.len(), 1);
    assert_eq!(opened[0].1, zoom);
    assert_eq!(opened[0].0.first().map(String::as_str), Some("Fit"));
}

#[test]
fn right_click_on_the_scrub_strip_opens_the_mark_menu() {
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    let s = p.footer().scrub_rect();
    rig.down(&mut p, s.mid_x(), s.mid_y(), InputModifiers::SECONDARY);
    let opened = menus(&mut p);
    let titles = &opened[0].0;
    assert!(titles.contains(&"Remove In".to_string()));
    assert!(titles.contains(&"Go to Out".to_string()));
}

#[test]
fn transport_button_runs_the_model_action() {
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    let play = p.footer().buttons().iter().find(|b| b.0 == MonitorAction::PlayPause).map(|b| b.1).unwrap_or_default();
    rig.click(&mut p, mid(play));
    let got: Vec<MonitorAction> = p
        .model
        .take_events()
        .into_iter()
        .filter_map(|e| if let MonitorEvent::Action(a) = e { Some(a) } else { None })
        .collect();
    assert_eq!(got, [MonitorAction::PlayPause]);
}

#[test]
fn ruler_drag_pulls_out_a_guide_and_dropping_it_back_removes_it() {
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    p.model.set_shows_rulers(true);
    let r = p.canvas_rect();
    rig.down(&mut p, r.mid_x(), r.min_y() + 5.0, InputModifiers::NONE);
    rig.drag(&mut p, r.mid_x(), r.mid_y());
    rig.up(&mut p, r.mid_x(), r.mid_y());
    assert_eq!(p.model.guides.horizontal().len(), 1);
    let y = r.min_y() + p.model.guides.horizontal()[0] * r.height;
    rig.down(&mut p, r.mid_x(), y, InputModifiers::NONE);
    rig.up(&mut p, r.mid_x(), r.min_y() + 1.0);
    assert!(p.model.guides.is_empty());
}

#[test]
fn dashed_edge_and_band_draw_without_even_odd_fill() {
    let mut c = sq_draw::canvas::Canvas::with_size(100.0, 100.0, None, 1.0);
    let before = c.list.quads().len();
    crate::monitor_panel_overlays::fill_band(
        &mut c,
        CGRect::new(0.0, 0.0, 100.0, 100.0),
        CGRect::new(10.0, 10.0, 80.0, 80.0),
        Color::WHITE,
    );
    assert_eq!(c.list.quads().len() - before, 4);
}

/// Go to Timecode (the Mac `focusTimecodeField` + `commitTimecode`): typed keys go to the field, Return seeks, a rejected
/// text keeps the time and gives the hint.
#[test]
fn go_to_timecode_opens_the_footer_field_and_return_seeks() {
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    p.focus_timecode_field();
    assert!(p.is_editing_timecode());
    draw(&mut p);
    for ch in "+10".chars() {
        assert!(rig.key(&mut p, InputKey::Character(ch)));
    }
    assert!(rig.key(&mut p, InputKey::Enter));
    let seeks: Vec<Time> = p
        .model
        .take_events()
        .into_iter()
        .filter_map(|e| if let MonitorEvent::Seek(t) = e { Some(t) } else { None })
        .collect();
    assert_eq!(seeks, [Time::new(10, 25)]);
    assert!(!p.is_editing_timecode());
    p.focus_timecode_field();
    for ch in "soon".chars() {
        rig.key(&mut p, InputKey::Character(ch));
    }
    rig.key(&mut p, InputKey::Enter);
    assert!(p.model.take_events().iter().all(|e| !matches!(e, MonitorEvent::Seek(_))));
    let hint = MonitorPanelModel::timecode_hint("soon");
    assert!(
        rig.events.iter().any(|e| *e == sq_app_shell::AppEvent::Status(sq_uikit::localization::SQL10n::string(&hint)))
    );
    p.focus_timecode_field();
    p.end_timecode_edit();
    assert!(!p.is_editing_timecode());
}

// MonitorPickAndPointTests

#[test]
fn click_on_the_picture_reports_its_sequence_position() {
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    let r = p.canvas_rect();
    rig.click(&mut p, mid(r));
    let picked: Vec<Vec2> = p
        .take_events()
        .into_iter()
        .filter_map(|e| if let PanelEvent::PickClip(v) = e { Some(v) } else { None })
        .collect();
    assert_eq!(picked.len(), 1);
    assert!(picked[0].x.abs() < 2.0 && picked[0].y.abs() < 2.0);
    // A quarter of the way in from the top left is a quarter of the frame from the center.
    rig.down(&mut p, r.min_x() + r.width / 4.0, r.min_y() + r.height / 4.0, InputModifiers::NONE);
    let picked: Vec<Vec2> = p
        .take_events()
        .into_iter()
        .filter_map(|e| if let PanelEvent::PickClip(v) = e { Some(v) } else { None })
        .collect();
    assert_eq!(picked.len(), 1);
    assert!((picked[0].x + 480.0).abs() < 4.0 && (picked[0].y + 270.0).abs() < 4.0);
}

#[test]
fn click_on_the_transform_box_does_not_pick() {
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    p.overlay.is_shown = true;
    p.overlay.media_pixel_size = Some(CGSize::new(1920.0, 1080.0));
    let r = p.canvas_rect();
    rig.click(&mut p, CGPoint::new(r.mid_x() + 30.0, r.mid_y() + 30.0));
    assert!(p.take_events().iter().all(|e| !matches!(e, PanelEvent::PickClip(_))));
}

// MonitorTipTests / MonitorHeaderTipsTests

fn tip_over(p: &mut MonitorPanel, rig: &mut Rig, r: CGRect) -> Option<String> {
    rig.moved(p, r.mid_x(), r.mid_y());
    rig.ui.hover.tooltip.text.clone()
}

#[test]
fn transport_buttons_offer_the_mac_tips() {
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    let btn = |p: &MonitorPanel, a: MonitorAction| {
        p.footer().buttons().iter().find(|b| b.0 == a).map(|b| b.1).unwrap_or_default()
    };
    let play = btn(&p, MonitorAction::PlayPause);
    assert!(tip_over(&mut p, &mut rig, play).is_some_and(|t| t.starts_with("Play")));
    p.model.is_playing = true;
    let mark = btn(&p, MonitorAction::MarkIn);
    let want =
        crate::shortcut_tips::keyboard_tip("Mark In", sq_uikit::editor_command::EditorCommand::MarkIn, &p.key_map);
    assert_eq!(tip_over(&mut p, &mut rig, mark), Some(want));
}

#[test]
fn header_popups_carry_the_mac_tips() {
    let p = drawn(MonitorMode::Program);
    assert_eq!(p.header_tip(HeaderControl::Zone), "Platform Safe Zone");
    assert_eq!(p.header_tip(HeaderControl::Zoom), "Zoom: Fit, or 10 to 800 %");
    assert_eq!(p.header_tip(HeaderControl::Quality), "Playback Quality");
    assert_eq!(p.header_tip(HeaderControl::Options), "More");
    assert_eq!(p.header_tip(HeaderControl::Content), "Open Sequences");
    assert_eq!(drawn(MonitorMode::Source).header_tip(HeaderControl::Content), "Source Clips");
}

#[test]
fn moving_over_the_options_button_offers_its_tip() {
    let mut p = drawn(MonitorMode::Program);
    let mut rig = Rig::new();
    let r = p.header_controls().iter().find(|c| c.0 == HeaderControl::Options).map(|c| c.1).unwrap_or_default();
    assert_eq!(p.header_tip_at(mid(r)).as_deref(), Some("More"));
    assert_eq!(p.header_tip_at(CGPoint::new(-5.0, -5.0)), None);
    rig.ui.now = 1.0;
    assert_eq!(tip_over(&mut p, &mut rig, r).as_deref(), Some("More"));
}

// SourceDragTests

fn source(waveform: bool) -> MonitorPanel {
    let mut m = MonitorPanelModel::new(Time::new(1, 25), MonitorMode::Source);
    m.duration = Time::new(250, 25);
    m.source_items = vec![crate::monitor_panel_model::SourceItem { id: Id::from_u128(1), name: "clip.mov".into() }];
    if waveform {
        m.viewer_mode = crate::monitor_drop_indicator::SourceViewerMode::Waveform;
    }
    let mut p = MonitorPanel::new(m, None);
    p.layout_px(sq_draw::Rect::new(0.0, 0.0, 800.0, 500.0), 1.0);
    draw(&mut p);
    p
}

fn drag_log(p: &mut MonitorPanel) -> Vec<(SourceStreams, MonitorDragPhase)> {
    p.take_events()
        .into_iter()
        .filter_map(
            |e| if let PanelEvent::SourceDrag { streams, phase, .. } = e { Some((streams, phase)) } else { None },
        )
        .collect()
}

#[test]
fn picture_drags_both_streams_after_four_points() {
    let mut p = source(false);
    let mut rig = Rig::new();
    p.wiring = PanelWiring::all();
    let c = p.canvas_rect();
    rig.down(&mut p, c.mid_x(), c.mid_y(), InputModifiers::NONE);
    rig.drag(&mut p, c.mid_x() + 2.0, c.mid_y());
    assert!(drag_log(&mut p).is_empty()); // under the threshold
    assert_eq!(p.active_source_drag(), None);
    rig.drag(&mut p, c.mid_x() + 30.0, c.mid_y() + 400.0);
    assert_eq!(p.active_source_drag(), Some(SourceStreams::Both));
    rig.up(&mut p, c.mid_x() + 30.0, c.mid_y() + 400.0);
    let log = drag_log(&mut p);
    assert_eq!(log.iter().map(|l| l.0).collect::<Vec<_>>(), [SourceStreams::Both, SourceStreams::Both]);
    assert_eq!(log.iter().map(|l| l.1).collect::<Vec<_>>(), [MonitorDragPhase::Moved, MonitorDragPhase::Ended]);
    assert_eq!(p.model.take_events().iter().filter(|e| **e == MonitorEvent::DragEnded).count(), 1);
    assert!(!p.is_dragging());
}

#[test]
fn a_click_without_movement_is_no_drag() {
    let mut p = source(false);
    let mut rig = Rig::new();
    p.wiring = PanelWiring::all();
    let c = p.canvas_rect();
    rig.click(&mut p, mid(c));
    assert!(drag_log(&mut p).is_empty());
}

#[test]
fn footer_handles_drag_one_stream_and_esc_cancels() {
    let mut p = source(false);
    let mut rig = Rig::new();
    p.wiring = PanelWiring::all();
    assert_eq!(
        p.footer().stream_handles().iter().map(|h| h.0).collect::<Vec<_>>(),
        [SourceStreams::VideoOnly, SourceStreams::AudioOnly]
    );
    let audio = p.footer().stream_handles()[1].1;
    rig.down(&mut p, audio.mid_x(), audio.mid_y(), InputModifiers::NONE);
    rig.drag(&mut p, audio.mid_x() - 40.0, audio.mid_y() + 60.0);
    assert!(rig.key(&mut p, InputKey::Escape));
    let log = drag_log(&mut p);
    assert_eq!(log.iter().map(|l| l.0).collect::<Vec<_>>(), [SourceStreams::AudioOnly, SourceStreams::AudioOnly]);
    assert_eq!(log.iter().map(|l| l.1).collect::<Vec<_>>(), [MonitorDragPhase::Moved, MonitorDragPhase::Canceled]);
    assert_eq!(p.active_source_drag(), None);
}

#[test]
fn program_has_no_stream_handles_and_a_narrow_footer_drops_them_first() {
    assert!(panel(MonitorMode::Program).footer().stream_handles().is_empty());
    let m = MonitorPanelModel::new(Time::new(1, 25), MonitorMode::Source);
    let mut p = MonitorPanel::new(m, None);
    p.layout_px(sq_draw::Rect::new(0.0, 0.0, 330.0, 300.0), 1.0);
    assert!(p.footer().stream_handles().is_empty());
}

#[test]
fn waveform_meter_takes_its_column_and_follows_the_feed() {
    let mut p = source(true);
    assert_eq!(p.wave_meter_rect(), CGRect::default()); // no feed: the waveform spans the slot
    let full = p.wave_math().width;
    p.has_wave_meter = true;
    p.wave_meter_reading = Some(MeterReading { source: 1, sequence: 1, peaks: vec![0.5, 0.25] });
    assert_eq!(p.wave_meter_rect().width, AudioMeter::WIDTH);
    assert!(p.wave_math().width < full);
    p.poll_wave_meter(1.0);
    assert_ne!(p.wave_meter.meter.readout(), "dB"); // a level shows
    p.has_wave_meter = false;
    assert_eq!(p.wave_meter_rect(), CGRect::default());
}

#[test]
fn waveform_meter_label_solos_and_alt_mutes() {
    let mut p = source(true);
    let mut rig = Rig::new();
    p.has_wave_meter = true;
    let r = p.wave_meter_rect();
    let left = CGPoint::new(r.min_x() + 10.0, r.max_y() - 8.0); // the "L" label row
    rig.down(&mut p, left.x, left.y, InputModifiers::NONE);
    assert!(p.wave_meter.channel_monitor().is_soloed(0));
    assert_eq!(p.wave_meter.labels().first(), Some(&MeterChannelLabel::Soloed));
    rig.down(&mut p, left.x, left.y, InputModifiers::OPTION);
    assert!(p.wave_meter.channel_monitor().is_muted(0));
    let changes = p.take_events().iter().filter(|e| matches!(e, PanelEvent::WaveChannelMonitorChange(_))).count();
    assert_eq!(changes, 2);
}

// MonitorTextToolTests (the Type tool presses; the field itself is tested beside it)

fn program() -> MonitorPanel {
    let mut p = panel(MonitorMode::Program);
    p.wiring = PanelWiring::all();
    p.has_picture = true;
    p.set_sequence_size(CGSize::new(1920.0, 1080.0));
    draw(&mut p);
    p
}

fn press(p: &mut MonitorPanel, rig: &mut Rig, a: CGPoint, to: Option<CGPoint>) {
    rig.down(p, a.x, a.y, InputModifiers::NONE);
    if let Some(b) = to {
        rig.drag(p, b.x, b.y);
    }
    let e = to.unwrap_or(a);
    rig.up(p, e.x, e.y);
}

#[test]
fn type_tool_click_places_point_text_at_the_canvas_center() {
    let mut p = program();
    let mut rig = Rig::new();
    p.type_tool_on = true;
    let c = p.canvas_rect();
    press(&mut p, &mut rig, mid(c), None);
    let ev = p.take_events();
    let clicks: Vec<Vec2> =
        ev.iter().filter_map(|e| if let PanelEvent::TypeClick(v) = e { Some(*v) } else { None }).collect();
    assert_eq!(clicks.len(), 1);
    assert!(clicks[0].x.abs() < 2.0 && clicks[0].y.abs() < 2.0);
    assert!(ev.iter().all(|e| !matches!(e, PanelEvent::PickClip(_)))); // the Type tool does not pick
    assert!(!p.is_dragging());
}

#[test]
fn type_tool_drag_draws_a_box_in_sequence_pixels() {
    let mut p = program();
    let mut rig = Rig::new();
    p.type_tool_on = true;
    let c = p.canvas_rect();
    let a = CGPoint::new(c.min_x() + c.width * 0.25, c.min_y() + c.height * 0.25);
    let b = CGPoint::new(c.min_x() + c.width * 0.75, c.min_y() + c.height * 0.75);
    rig.down(&mut p, a.x, a.y, InputModifiers::NONE);
    rig.drag(&mut p, b.x, b.y);
    assert!(p.type_drag_rect().is_some());
    rig.up(&mut p, b.x, b.y);
    let ev = p.take_events();
    assert!(ev.iter().all(|e| !matches!(e, PanelEvent::TypeClick(_))));
    let boxes: Vec<(Vec2, Vec2)> = ev
        .iter()
        .filter_map(|e| if let PanelEvent::TypeBox { center, size } = e { Some((*center, *size)) } else { None })
        .collect();
    assert_eq!(boxes.len(), 1);
    assert!(boxes[0].0.x.abs() < 2.0 && boxes[0].0.y.abs() < 2.0); // centered
    assert!((boxes[0].1.x - 960.0).abs() < 4.0 && (boxes[0].1.y - 540.0).abs() < 4.0); // half the sequence
}

#[test]
fn esc_cancels_the_type_press() {
    let mut p = program();
    let mut rig = Rig::new();
    p.type_tool_on = true;
    let c = p.canvas_rect();
    rig.down(&mut p, c.mid_x(), c.mid_y(), InputModifiers::NONE);
    assert!(rig.key(&mut p, InputKey::Escape));
    rig.up(&mut p, c.mid_x(), c.mid_y());
    assert!(p.take_events().iter().all(|e| !matches!(e, PanelEvent::TypeClick(_))));
}

#[test]
fn double_click_on_the_picture_asks_for_text_editing() {
    let mut p = program();
    let mut rig = Rig::new();
    let c = p.canvas_rect();
    rig.ui.now = 10.0;
    press(&mut p, &mut rig, mid(c), None);
    rig.ui.now += 0.2;
    press(&mut p, &mut rig, CGPoint::new(c.mid_x() + 1.0, c.mid_y()), None);
    let count =
        |p: &mut MonitorPanel| p.take_events().iter().filter(|e| matches!(e, PanelEvent::TextDoubleClick(_))).count();
    assert_eq!(count(&mut p), 1);
    rig.ui.now += 1.0; // slow second press: no double-click
    press(&mut p, &mut rig, mid(c), None);
    rig.ui.now += 1.0;
    press(&mut p, &mut rig, mid(c), None);
    assert_eq!(count(&mut p), 0);
}

#[test]
fn press_uses_the_caret_map_scaled_to_the_view() {
    use crate::monitor_text_field::{Caret, CaretLine, Carets};
    let mut p = program();
    let mut rig = Rig::new();
    p.text_field.sequence_size = CGSize::new(1920.0, 1080.0);
    p.text_field.caret_source = Some(Box::new(|text| {
        (text == "abc").then(|| Carets {
            lines: vec![CaretLine { top: 0.0, height: 100.0 }],
            carets: (0..=3).map(|i| Caret { line: 0, x: 10.0 + f64::from(i) * 50.0 }).collect(),
        })
    }));
    p.text_field.begin("abc", crate::monitor_text_field::tests_target(200.0, 100.0), false, None);
    draw(&mut p);
    let q = p.text_field.quad(p.canvas_rect());
    let k = (q[1].x - q[0].x) / 200.0; // view points per layer px
    let at = CGPoint::new(q[0].x + 112.0 * k, q[0].y + 50.0 * k); // layer x 112: caret 2 (x 110)
    rig.click(&mut p, at);
    assert_eq!(p.text_field.edit().map(|e| e.caret()), Some(2));
}

#[test]
fn press_inside_moves_the_caret_outside_ends() {
    let mut p = program();
    let mut rig = Rig::new();
    p.text_field.sequence_size = CGSize::new(1920.0, 1080.0);
    p.text_field.begin("Hello", crate::monitor_text_field::tests_target(800.0, 200.0), true, None);
    draw(&mut p);
    let q = p.text_field.quad(p.canvas_rect());
    assert_eq!(q.len(), 4);
    let m = CGPoint::new((q[0].x + q[2].x) / 2.0, (q[0].y + q[2].y) / 2.0);
    rig.click(&mut p, m);
    assert!(p.text_field.is_editing());
    assert!(p.text_field.edit().is_some_and(|e| e.selection().is_empty())); // the press placed the caret
    let out = CGPoint::new(p.canvas_rect().min_x() + 4.0, p.canvas_rect().min_y() + 4.0);
    rig.down(&mut p, out.x, out.y, InputModifiers::NONE);
    assert!(!p.text_field.is_editing());
    let ended =
        p.text_field.events.iter().filter(|e| matches!(e, crate::monitor_text_field::TextFieldEvent::Ended(_))).count();
    assert_eq!(ended, 1);
}

// MonitorFormatSwitcherTests

#[test]
fn sync_connects_the_switcher_to_the_session() {
    let mut rig = Rig::new();
    let mut m = MonitorPanelModel::new(Time::new(1, 25), MonitorMode::Program);
    m.sync_formats(&rig.session);
    m.emit(MonitorEvent::AddFormat(sq_core_effects::sequence_conform::SequenceConform::ASPECT_PRESETS[0]));
    m.apply_format_events(&mut rig.session);
    m.sync_formats(&rig.session);
    assert_eq!(m.format_items.len(), 1);
    assert_eq!(m.format_current, Some(m.format_items[0].id)); // adding shows the new format
    m.emit(MonitorEvent::PickFormat(None));
    m.apply_format_events(&mut rig.session);
    m.sync_formats(&rig.session);
    assert_eq!(m.format_current, None);
    let first = m.format_items[0].id;
    m.emit(MonitorEvent::PickFormat(Some(first)));
    m.apply_format_events(&mut rig.session);
    assert_eq!(rig.session.active_variant_id(), Some(first));
    m.emit(MonitorEvent::RemoveFormat(first));
    m.apply_format_events(&mut rig.session);
    m.sync_formats(&rig.session);
    assert!(m.format_items.is_empty());
}

#[test]
fn program_transport_follows_the_playhead() {
    let mut rig = Rig::new();
    let mut m = MonitorPanelModel::new(Time::new(1, 25), MonitorMode::Program);
    rig.session.seek(Time::seconds(2));
    m.sync_transport(&rig.session);
    assert_ne!(rig.session.playhead(), Time::ZERO, "the seek moved the playhead");
    assert_eq!(m.current_time, rig.session.playhead());
}

#[test]
fn monitor_panel_routes_presses_to_the_overlay_and_esc_cancels() {
    use crate::transform_overlay::{OverlayEvent, Phase};
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    p.overlay.is_shown = true;
    p.overlay.media_pixel_size = Some(CGSize::new(1920.0, 1080.0));
    let c = p.canvas_rect();
    rig.down(&mut p, c.mid_x() + 40.0, c.mid_y() + 20.0, InputModifiers::NONE);
    assert!(p.is_dragging());
    rig.drag(&mut p, c.mid_x() + 60.0, c.mid_y() + 20.0);
    let ev = p.overlay.take_events();
    assert!(matches!(ev.last(), Some(OverlayEvent::Transform(Phase::Changed, _))));
    assert!(rig.key(&mut p, InputKey::Escape));
    assert!(p.overlay.take_events().contains(&OverlayEvent::DragCanceled));
    assert!(!p.is_dragging());
}

#[test]
fn full_screen_is_offered_in_both_modes_once_wired() {
    for mode in [MonitorMode::Program, MonitorMode::Source] {
        let mut p = panel(mode);
        let titles = |p: &MonitorPanel| -> Vec<String> {
            p.model.option_items(Vec::new()).into_iter().map(|i| i.title).collect()
        };
        assert!(!titles(&p).contains(&"Full Screen".to_string()), "{mode:?} unwired");
        p.model.wired.full_screen = true;
        assert!(titles(&p).contains(&"Full Screen".to_string()), "{mode:?} wired");
        let row = p.model.option_items(Vec::new()).into_iter().find(|i| i.title == "Full Screen");
        assert!(row.is_some_and(|r| r.action.is_some()));
    }
}

/// Windows check at 640x400: the Program | Source tabs and the header popups (Main, Fit, Auto) printed over each other.
/// At every width the header pieces stay apart and inside the header; the popups fold into the "..." menu first.
#[test]
fn header_pieces_never_overlap_at_any_width() {
    for width in (200..=900).step_by(10) {
        let mut p = panel(MonitorMode::Program);
        p.tabs = vec!["Program".into(), "Source".into()];
        p.model.has_sequence = true;
        p.layout_frame(CGRect::new(0.0, 0.0, f64::from(width), 400.0));
        draw_with_text(&mut p);
        let head = p.header_rect();
        let mut boxes: Vec<(String, CGRect)> =
            p.tab_rects.iter().enumerate().map(|(i, r)| (format!("tab{i}"), *r)).collect();
        boxes.extend(p.header_controls().iter().map(|(c, r)| (format!("{c:?}"), *r)));
        for (i, (na, a)) in boxes.iter().enumerate() {
            assert!(
                a.min_x() >= head.min_x() - 0.5 && a.max_x() <= head.max_x() + 0.5,
                "{na} outside at {width}: {a:?}"
            );
            for (nb, b) in &boxes[i + 1..] {
                assert!(a.max_x() <= b.min_x() + 0.5 || b.max_x() <= a.min_x() + 0.5, "{na} overlaps {nb} at {width}");
            }
        }
        assert!(p.header_controls().iter().any(|c| c.0 == HeaderControl::Options), "the menu stays at {width}");
    }
}

/// What folded out of the header is still one click away in the "..." menu.
#[test]
fn a_narrow_header_keeps_zoom_and_quality_in_the_menu() {
    let mut p = panel(MonitorMode::Program);
    p.tabs = vec!["Program".into(), "Source".into()];
    p.model.has_sequence = true;
    p.layout_frame(CGRect::new(0.0, 0.0, 450.0, 400.0));
    draw_with_text(&mut p);
    let items = p.header_items(HeaderControl::Options);
    assert!(items.iter().any(|i| i.title == "Zoom") && items.iter().any(|i| i.title == "Playback Quality"));
}
