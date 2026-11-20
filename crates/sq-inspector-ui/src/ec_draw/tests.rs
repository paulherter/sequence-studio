//! Ported from the SQInspectorUI tests: EasingPopoverDrawTests, GraphEditorDrawTests, InlineSpeedGraphDrawTests,
//! EffectKeyframeLanesDrawTests, EffectControlsDrawPanelTests and EffectControlsDrawRowsTests. The Swift `onEdit` closure that
//! fed the clip back is not needed: the model stores what it commits, the tests only drain the events.

use std::collections::BTreeSet;

use sq_core_model::keyframes_editing::SummaryMember;
use sq_core_model::{BlendMode, Clip, ClipEffect, EaseReading, EasingCurveShape, TrackKind};
use sq_core_time::{EasingCurve, Id, Keyframe, KeyframeTrack, SequentialIds, Time, TimeRange, Vec2};
use sq_draw::draw_list::Color;
use sq_draw::{Canvas, DrawTheme, InputKey, InputModifiers, SoftwareRenderer, Sources, UiCx};
use sq_editor_session::EffectSection;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize, ControlsGrid};
use sq_uikit::keyframe_graph_geometry::GraphMode;
use sq_uikit::keyframe_viewport::EffectControlsSplit;
use sq_uikit::sqmenu_model::SQMenuItemKind;

use super::easing_popover_draw::{EasingChipItem, EasingPopoverDraw, EasingPopoverEvent};
use super::effect_controls_draw_panel::{EffectControlsDrawPanel, FieldId, PanelEvent, RowRef, Target};
use super::effect_controls_draw_rows::WidgetKind;
use super::effect_controls_draw_view::{EffectControlsDrawView, Part, ViewEvent};
use crate::ec::controls_metrics::{ControlsMetrics, Portable};
use crate::ec::effect_controls_model::core::{EffectControlsEvent, EffectControlsModel};
use crate::ec::effect_controls_model::layout::{EffectControlsLayout, EffectRowKind, EffectRowsRequest};
use crate::ec::effect_controls_model::property::{EffectComponent, EffectProperty};
use crate::ec::prelude::*;
use crate::keyframes::graph_editor_shortcuts::GraphEditorShortcut;
use sq_core_model::keyframes_premiere::KeyInterpolationChoice;

fn s(n: i64) -> Time {
    Time::new(n, 1)
}

fn clip_of(kind: TrackKind, seconds: i64, start: i64) -> Clip {
    Clip::new(Id::from_u128(1000), "c", Id::from_u128(1001), kind, TimeRange::new(Time::ZERO, s(seconds)), s(start))
}

fn model_with(c: Clip) -> EffectControlsModel {
    let mut m = EffectControlsModel::new(Box::new(SequentialIds::default()));
    m.set_clip(Some(c), None, Vec::new(), None);
    m
}

/// The edits (name, coalescing) among the events since the last call.
fn edits(m: &mut EffectControlsModel) -> Vec<(String, bool)> {
    m.take_events()
        .into_iter()
        .filter_map(|e| match e {
            EffectControlsEvent::Edit { name, coalescing, .. } => Some((name, coalescing)),
            _ => None,
        })
        .collect()
}

fn mid(r: CGRect) -> CGPoint {
    CGPoint::new(r.mid_x(), r.mid_y())
}

fn canvas(w: f32, h: f32) -> Canvas<'static> {
    Canvas::with_size(w, h, None, 1.0)
}

fn view_of(m: EffectControlsModel, w: f64, h: f64) -> EffectControlsDrawView {
    let mut v = EffectControlsDrawView::new(m, 0.0);
    v.set_size(CGSize::new(w, h));
    v.relayout();
    v
}

fn panel_of(m: &EffectControlsModel, w: f64, h: f64) -> EffectControlsDrawPanel {
    let mut p = EffectControlsDrawPanel::new();
    p.size = CGSize::new(w, h);
    p.relayout(m);
    p
}

fn click(p: &mut EffectControlsDrawPanel, m: &mut EffectControlsModel, cx: &mut UiCx, at: CGPoint) {
    p.mouse_down(m, cx, at, 1, InputModifiers::NONE);
    p.mouse_up(m, cx, at);
}

fn row_center(p: &EffectControlsDrawPanel, kind: &EffectRowKind, x: f64) -> Option<CGPoint> {
    let r = p.rows().iter().find(|r| &r.kind == kind)?;
    Some(CGPoint::new(x, r.y + r.height / 2.0))
}

// MARK: EasingPopoverDrawTests

/// Position with two keys, both selected.
fn easing_model() -> EffectControlsModel {
    let mut c = clip_of(TrackKind::Video, 10, 0);
    c.animation.position.track = KeyframeTrack::with_keys(vec![
        Keyframe::new(Id::from_u128(21), Time::ZERO, Vec2::new(0.0, 0.0)),
        Keyframe::new(Id::from_u128(22), s(2), Vec2::new(100.0, 0.0)),
    ]);
    let mut m = model_with(c);
    for id in [Id::from_u128(21), Id::from_u128(22)] {
        m.select_key(&EffectProperty::Position, id, true);
    }
    m
}

#[test]
fn a_chip_applies_its_curve_and_lights_up() {
    let mut m = easing_model();
    let mut pop = EasingPopoverDraw::new(&m);
    let i =
        pop.chips().iter().position(|c| *c == EasingChipItem::Curve(EasingCurve::ease_out())).expect("ease out chip");
    let at = CGPoint::new(8.0 + i as f64 * 44.0 + 20.0, 145.0);
    // scroll the strip to the chip first when it is out of view
    let at = if at.x > 130.0 {
        // the Custom chip is pinned at the right end of the strip: scroll the chip to the left part
        pop.scroll(CGPoint::new(100.0, 140.0), -(at.x - 60.0), 0.0);
        CGPoint::new(at.x - pop.chip_scroll(), at.y)
    } else {
        at
    };
    pop.mouse_down(&mut m, at);
    pop.mouse_up(&mut m, at);
    let EaseReading::Common(shape) = EffectControlsModel::ease_reading(&m).expect("reading") else {
        panic!("not common")
    };
    assert!(shape.is_approximately_equal(&EasingCurve::ease_out().shape()));
    // Springs bake keys: offered for keyframes.
    assert!(pop.chips().iter().any(|c| matches!(c, EasingChipItem::Spring(_))));
    let mut c = canvas(260.0, 200.0);
    let mut cx = UiCx::new();
    pop.draw(&m, &mut c, &DrawTheme::default(), &mut cx);
    assert!(!c.list.quads().is_empty());
}

#[test]
fn dragging_a_handle_is_one_gesture_on_the_source() {
    let mut m = easing_model();
    m.take_events();
    let mut pop = EasingPopoverDraw::new(&m);
    let e = pop.editor();
    let seg = e.segment().expect("segment");
    let knob = e.geometry().handle_end(&seg, sq_core_time::EaseSide::Out);
    let at = CGPoint::new(knob.x, e.geometry().key(&seg, sq_core_time::EaseSide::Out).y);
    assert_eq!(e.handle_at(at), Some(sq_core_time::EaseSide::Out));
    pop.mouse_down(&mut m, at);
    pop.mouse_dragged(&mut m, CGPoint::new(at.x + 40.0, at.y), InputModifiers::NONE);
    pop.mouse_dragged(&mut m, CGPoint::new(at.x + 60.0, at.y), InputModifiers::NONE);
    pop.mouse_up(&mut m, CGPoint::new(at.x + 60.0, at.y));
    let names = edits(&mut m);
    assert!(names.len() == 2 && !names[0].1 && names[1].1, "{names:?}");
    let EaseReading::Common(shape) = EffectControlsModel::ease_reading(&m).expect("reading") else {
        panic!("not common")
    };
    assert!(shape.out.dx > sq_core_model::EaseShape::LINEAR.out.dx);
}

#[test]
fn save_hands_the_shape_and_typed_name() {
    let mut m = easing_model();
    let mut pop = EasingPopoverDraw::new(&m);
    let mut cx = UiCx::new();
    pop.mouse_down(&mut m, CGPoint::new(8.0 + 10.0, 167.0 + 10.0));
    for ch in "Snap".chars() {
        pop.key(&m, InputKey::Character(ch), InputModifiers::NONE, &mut cx);
    }
    pop.key(&m, InputKey::Enter, InputModifiers::NONE, &mut cx);
    let got = pop.take_events();
    assert_eq!(got, vec![EasingPopoverEvent::Save(sq_core_model::EaseShape::LINEAR, "Snap".to_string())]);
    assert!(pop.name().text.is_empty());
}

#[test]
fn motion_curve_row_has_the_edit_curve_button() {
    let mut c = clip_of(TrackKind::Video, 4, 0);
    let fx = ClipEffect::new(Id::from_u128(77), ClipEffect::MOVE_KIND);
    c.effects = vec![fx];
    let mut m = model_with(c);
    m.set_collapsed_sections(Default::default());
    let mut p = panel_of(&m, 420.0, 3000.0);
    let row = p
        .rows()
        .iter()
        .find(|r| matches!(&r.kind, EffectRowKind::Property(EffectProperty::Fx { key, .. }) if key == ClipEffect::MOTION_CURVE_KEY))
        .cloned()
        .expect("curve row");
    let EffectRowKind::Property(prop) = row.kind.clone() else { return };
    let g = ControlsGrid::new(420.0);
    let popup_w = (g.value_max_x() - ControlsGrid::RESET_WIDTH - ControlsGrid::GAP - ControlsGrid::VALUE_X)
        .min(Portable::POPUP_WIDTH);
    let x = ControlsGrid::VALUE_X + popup_w + ControlsGrid::GAP + ControlsGrid::RESET_WIDTH / 2.0;
    let at = CGPoint::new(x, row.y + row.height / 2.0);
    assert_eq!(p.target_at(&m, at), Target::Curve(prop));
    let mut cx = UiCx::new();
    click(&mut p, &mut m, &mut cx, at);
    let events = p.take_events();
    assert!(matches!(
        events.first(),
        Some(PanelEvent::EaseCurve { target: super::effect_controls_draw_panel::EaseCurveTarget::Motion(_), .. })
    ));
}

// MARK: GraphEditorDrawTests

const O0: u128 = 31;
const O1: u128 = 32;

fn editor_view() -> EffectControlsDrawView {
    let mut clip = clip_of(TrackKind::Video, 10, 0);
    clip.animation.opacity.track = KeyframeTrack::with_keys(vec![
        Keyframe::new(Id::from_u128(O0), s(0), 0.0),
        Keyframe::new(Id::from_u128(O1), s(4), 1.0),
    ]);
    let mut m = model_with(clip);
    m.graph_show_all = true;
    m.graph_snap = false;
    if !m.graph_editor {
        m.toggle_graph_editor();
    }
    view_of(m, 900.0, 400.0)
}

fn to_panel(v: &EffectControlsDrawView, p: CGPoint) -> CGPoint {
    CGPoint::new(p.x + v.lane_x(), p.y + v.top())
}

#[test]
fn editor_replaces_the_lanes_and_draws() {
    let mut v = editor_view();
    assert_eq!(v.part_at(CGPoint::new(v.lane_x() + 100.0, v.top() + 50.0)), Part::GraphEditor);
    assert_eq!(v.graph_editor.size, v.lanes_size());
    let mut c = canvas(900.0, 400.0);
    v.draw(&mut c, &mut UiCx::new());
    assert!(!c.list.quads().is_empty());
    let g = v.graph_editor.geometry(&v.model);
    assert!(g.curve(&EffectProperty::Opacity.id()).is_some());
}

#[test]
fn key_drag_moves_the_key_in_one_step() {
    let mut v = editor_view();
    let g = v.graph_editor.geometry(&v.model);
    let c = g.curve(&EffectProperty::Opacity.id()).expect("curve").clone();
    let start = to_panel(&v, g.key_point(&c, &c.curve.keys[1]));
    let one = g.lane.points_per_second();
    let mut cx = UiCx::new();
    v.model.take_events();
    v.mouse_down(&mut cx, start, 1, InputModifiers::NONE);
    for i in 1..=10 {
        v.mouse_dragged(&mut cx, CGPoint::new(start.x - one * i as f64 / 10.0, start.y), None);
    }
    v.mouse_up(&mut cx, CGPoint::new(start.x - one, start.y));
    let key = v.model.clip().and_then(|c| c.animation.opacity.track.key(Id::from_u128(O1)).map(|k| k.time));
    assert_eq!(key, Some(s(3)));
    let names: BTreeSet<String> = edits(&mut v.model).into_iter().map(|e| e.0).collect();
    assert_eq!(names.len(), 1);
}

#[test]
fn a_graph_drag_is_one_undo_step() {
    let mut v = editor_view();
    let g = v.graph_editor.geometry(&v.model);
    let c = g.curve(&EffectProperty::Opacity.id()).expect("curve").clone();
    let start = to_panel(&v, g.key_point(&c, &c.curve.keys[1]));
    let one = g.lane.points_per_second();
    let mut cx = UiCx::new();
    v.model.take_events();
    v.mouse_down(&mut cx, start, 1, InputModifiers::NONE);
    for i in 1..=10 {
        v.mouse_dragged(&mut cx, CGPoint::new(start.x - one * i as f64 / 10.0, start.y), None);
    }
    v.mouse_up(&mut cx, CGPoint::new(start.x - one, start.y));
    let events = v.model.take_events();
    let ends = events.iter().filter(|e| matches!(e, EffectControlsEvent::GestureEnded)).count();
    let edits: Vec<bool> = events
        .iter()
        .filter_map(|e| match e {
            EffectControlsEvent::Edit { coalescing, .. } => Some(*coalescing),
            _ => None,
        })
        .collect();
    assert_eq!(ends, 1, "one gesture end closes the whole drag");
    assert_eq!(edits.len(), 1, "ten drag events reach the host as one edit: {edits:?}");
}

#[test]
fn escape_during_a_marquee_restores_the_selection() {
    let mut v = editor_view();
    let g = v.graph_editor.geometry(&v.model);
    let c = g.curve(&EffectProperty::Opacity.id()).expect("curve").clone();
    let k0 = g.key_point(&c, &c.curve.keys[0]);
    let k1 = g.key_point(&c, &c.curve.keys[1]);
    let before = BTreeSet::from([SummaryMember::new(EffectProperty::Opacity.id(), Id::from_u128(O0))]);
    v.model.select(&before.iter().cloned().collect::<Vec<_>>(), false);
    let origin = to_panel(&v, CGPoint::new(k1.x + 30.0, k0.y.min(k1.y) - 20.0));
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, origin, 1, InputModifiers::NONE);
    v.mouse_dragged(&mut cx, to_panel(&v, CGPoint::new(k1.x - 20.0, k0.y.max(k1.y) + 20.0)), None);
    assert!(v.model.selection().contains(&SummaryMember::new(EffectProperty::Opacity.id(), Id::from_u128(O1))));
    assert!(v.key(&mut cx, InputKey::Escape, InputModifiers::NONE));
    v.mouse_up(&mut cx, origin);
    assert_eq!(v.model.selection(), &before);
}

#[test]
fn toolbar_snap_toggles_and_shortcuts_run() {
    let mut v = editor_view();
    let frames = v.graph_editor.toolbar_frames();
    assert_eq!(frames.len(), 8);
    let snap = to_panel(&v, mid(frames[1]));
    assert_eq!(v.help(snap).as_deref(), Some("Snap"));
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, snap, 1, InputModifiers::NONE);
    v.mouse_up(&mut cx, snap);
    assert!(v.model.graph_snap);
    let empty = to_panel(&v, CGPoint::new(100.0, 50.0));
    v.mouse_down(&mut cx, empty, 1, InputModifiers::NONE);
    v.mouse_up(&mut cx, empty);
    assert!(v.key(&mut cx, InputKey::Character('a'), InputModifiers::COMMAND));
    assert_eq!(v.model.selection().len(), 2);
    assert_eq!(
        GraphEditorShortcut::resolve(InputKey::Function(9), InputModifiers::SHIFT),
        Some(GraphEditorShortcut::Ease(KeyInterpolationChoice::EaseIn))
    );
}

#[test]
fn right_click_offers_the_key_menu() {
    let mut v = editor_view();
    let g = v.graph_editor.geometry(&v.model);
    let c = g.curve(&EffectProperty::Opacity.id()).expect("curve").clone();
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, to_panel(&v, g.key_point(&c, &c.curve.keys[0])), 1, InputModifiers::SECONDARY);
    let shown = menu_titles(&mut v);
    assert!(shown.contains(&"Delete".to_string()), "{shown:?}");
}

/// The titles of the first menu the view asked for.
fn menu_titles(v: &mut EffectControlsDrawView) -> Vec<String> {
    v.take_events()
        .into_iter()
        .find_map(|e| match e {
            ViewEvent::Menu { menu, .. } => Some(menu.items().into_iter().map(|i| i.title).collect()),
            _ => None,
        })
        .unwrap_or_default()
}

// MARK: InlineSpeedGraphDrawTests

/// Opacity keyed at 0 s and 2 s of a 10 s clip, its row opened, in a 900 pt panel.
fn inline_view() -> (EffectControlsDrawView, CGRect) {
    let mut m = model_with(clip_of(TrackKind::Video, 10, 5));
    m.set_playhead(s(5));
    m.toggle_stopwatch(&EffectProperty::Opacity, false);
    m.set_playhead(s(7));
    m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.5);
    m.toggle_open(&EffectProperty::Opacity);
    let v = view_of(m, 900.0, 1200.0);
    let r = v
        .rows_panel
        .rows()
        .iter()
        .find(|r| r.kind == EffectRowKind::Graph(EffectProperty::Opacity))
        .expect("graph row")
        .clone();
    let f = CGRect::new(v.lane_x(), v.top() + r.y, 900.0 - v.lane_x(), r.height);
    (v, f)
}

#[test]
fn opened_row_shows_the_curve_over_the_lanes() {
    let (mut v, f) = inline_view();
    assert_eq!(v.part_at(mid(f)), Part::Graph(EffectProperty::Opacity));
    assert_eq!(v.part_at(CGPoint::new(f.mid_x(), f.min_y() - 4.0)), Part::Lanes);
    let mut c = canvas(900.0, 1200.0);
    v.draw(&mut c, &mut UiCx::new());
    let img = SoftwareRenderer::render(&c.list, 900, 1200, Color::BLACK, &Sources::default());
    assert_eq!(img.pixels[((f.mid_y() as usize) * 900 + f.mid_x() as usize) * 4 + 3], 255);
}

#[test]
fn right_click_offers_the_curve_presets_and_the_key_items() {
    let (mut v, f) = inline_view();
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, CGPoint::new(f.max_x() - 4.0, f.mid_y()), 1, InputModifiers::SECONDARY);
    let ev = v.take_events().into_iter().find_map(|e| match e {
        ViewEvent::Menu { menu, .. } => Some(menu),
        _ => None,
    });
    let menu = ev.expect("menu");
    let titles: Vec<String> = menu.items().into_iter().map(|i| i.title).collect();
    assert_eq!(&titles[..5], ["Linear", "Ease In & Out", "Ease In", "Ease Out", "Hold"]);
    assert!(titles.contains(&"Delete".to_string()));
    let ids: BTreeSet<Id> = v.model.track_of(&EffectProperty::Opacity).expect("track").key_ids().into_iter().collect();
    v.model.set_selection_for(&EffectProperty::Opacity, &ids);
    let smooth = titles.iter().position(|t| t == "Ease In & Out").expect("smooth");
    v.run_menu(&menu, &[smooth]);
    assert_eq!(v.model.speed_chip(&EffectProperty::Opacity), Some(crate::ec::speed_graph::SpeedCurveChip::Smooth));
}

#[test]
fn handle_drag_is_one_gesture_and_sets_the_reach() {
    let (mut v, f) = inline_view();
    v.model.apply_speed_chip(crate::ec::speed_graph::SpeedCurveChip::Smooth, &EffectProperty::Opacity);
    let seg = v.model.speed_segments(&EffectProperty::Opacity)[0].clone();
    let model = &v.model;
    let end = {
        let mut probe = super::inline_speed_graph_draw::InlineSpeedGraphDraw::new(EffectProperty::Opacity);
        probe.size = CGSize::new(f.width, f.height);
        probe.geometry(model).handle_end(&seg, sq_core_time::EaseSide::Out)
    };
    v.model.take_events();
    let start = CGPoint::new(f.min_x() + end.x, f.min_y() + end.y);
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, start, 1, InputModifiers::NONE);
    v.mouse_dragged(&mut cx, CGPoint::new(start.x + 15.0, start.y), None);
    v.mouse_dragged(&mut cx, CGPoint::new(start.x + 30.0, start.y), None);
    v.mouse_up(&mut cx, CGPoint::new(start.x + 30.0, start.y));
    let values = v.model.speed_values(&EffectProperty::Opacity).expect("values");
    assert!(values.reach_out > 1.0 / 3.0);
    assert!(!edits(&mut v.model).is_empty());
}

#[test]
fn marquee_from_the_curve_selects_the_keys() {
    let (mut v, f) = inline_view();
    v.model.clear_selection();
    let from = CGPoint::new(f.min_x() + 5.0, f.min_y() + 2.0);
    let to = CGPoint::new(f.max_x() - 1.0, f.max_y() - 2.0);
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, from, 1, InputModifiers::NONE);
    v.mouse_dragged(&mut cx, mid(f), None);
    v.mouse_dragged(&mut cx, to, None);
    assert_eq!(v.model.selected_key_ids(&EffectProperty::Opacity).len(), 2);
    v.mouse_up(&mut cx, to);
    assert!(v.lanes.marquee().is_none());
}

// MARK: Value mode (SpeedGraphRow's KeyframeGraphView per component)

#[test]
fn value_mode_draws_the_value_graph_and_its_menu_switches_back() {
    let (mut v, f) = inline_view();
    v.model.set_graph_mode_for(GraphMode::Value, &EffectProperty::Opacity);
    let mut c = canvas(900.0, 1200.0);
    v.draw(&mut c, &mut UiCx::new());
    let (width, keys) = {
        let g = &v.value_graphs(&EffectProperty::Opacity)[0].1;
        (g.size.width, g.track().keys.len())
    };
    assert!(width == f.width && keys == 2);
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, mid(f), 1, InputModifiers::SECONDARY);
    let menu = v
        .take_events()
        .into_iter()
        .find_map(|e| match e {
            ViewEvent::Menu { menu, .. } => Some(menu),
            _ => None,
        })
        .expect("menu");
    let titles: Vec<String> = menu.items().into_iter().map(|i| i.title).collect();
    assert_eq!(&titles[..2], ["Speed", "Value"]);
    v.run_menu(&menu, &[0]);
    assert_eq!(v.model.graph_mode_for(&EffectProperty::Opacity), GraphMode::Speed);
}

#[test]
fn value_mode_key_drag_is_one_edit() {
    let (mut v, f) = inline_view();
    v.model.set_graph_mode_for(GraphMode::Value, &EffectProperty::Opacity);
    let mut c = canvas(900.0, 1200.0);
    v.draw(&mut c, &mut UiCx::new());
    let key = {
        let g = &v.value_graphs(&EffectProperty::Opacity)[0].1;
        g.geometry().key_point(g.track(), 1)
    };
    v.model.take_events();
    let start = CGPoint::new(f.min_x() + key.x, f.min_y() + key.y);
    let before = v.model.graph_track(&EffectProperty::Opacity, EffectComponent::All).keys[1].value;
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, start, 1, InputModifiers::NONE);
    v.mouse_dragged(&mut cx, CGPoint::new(start.x, start.y + 10.0), None);
    v.mouse_dragged(&mut cx, CGPoint::new(start.x, start.y + 20.0), None);
    v.mouse_up(&mut cx, CGPoint::new(start.x, start.y + 20.0));
    assert_eq!(edits(&mut v.model).len(), 1);
    assert!(v.model.graph_track(&EffectProperty::Opacity, EffectComponent::All).keys[1].value < before);
}

// MARK: EffectKeyframeLanesDrawTests

fn lanes_view() -> EffectControlsDrawView {
    view_of(model_with(clip_of(TrackKind::Video, 4, 0)), 900.0, 1200.0)
}

/// Animates Opacity with the row's ring (one key at the playhead) and returns the key's point in panel coordinates.
fn animate_opacity(v: &mut EffectControlsDrawView) -> CGPoint {
    let r = v
        .rows_panel
        .rows()
        .iter()
        .find(|r| r.kind == EffectRowKind::Property(EffectProperty::Opacity))
        .expect("row")
        .clone();
    let ring = CGPoint::new(ControlsGrid::TOGGLE_MID_X, v.top() + r.y + r.height / 2.0);
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, ring, 1, InputModifiers::NONE);
    v.mouse_up(&mut cx, ring);
    assert_eq!(v.model.keys(&EffectProperty::Opacity).len(), 1);
    v.relayout();
    let x = v.model.lane_geometry(v.lanes.size.width).x(v.model.local_playhead());
    CGPoint::new(v.lane_x() + x, v.top() + r.y + r.height / 2.0)
}

#[test]
fn layout_is_the_mac_split() {
    let v = lanes_view();
    assert_eq!(v.lane_x(), EffectControlsSplit::clamp(v.label_width(), 900.0));
    assert_eq!(v.rows_panel.size.width, v.lane_x());
    assert_eq!(v.lanes.size.width, 900.0 - v.lane_x());
    assert_eq!(v.lanes.rows, v.rows_panel.rows());
    assert_eq!(v.part_at(CGPoint::new(v.lane_x() + 50.0, ControlsMetrics::CLIP_LINE + 4.0)), Part::Ruler);
    assert_eq!(v.part_at(CGPoint::new(v.lane_x(), 400.0)), Part::Divider);
}

#[test]
fn click_selects_a_key_and_drag_moves_it_as_one_step() {
    let mut v = lanes_view();
    let key = animate_opacity(&mut v);
    v.model.take_events();
    assert!(v.model.selection().is_empty());
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, key, 1, InputModifiers::NONE);
    assert_eq!(v.model.selected_key_ids(&EffectProperty::Opacity).len(), 1);
    let to = CGPoint::new(key.x + 60.0, key.y);
    v.mouse_dragged(&mut cx, CGPoint::new(key.x + 30.0, key.y), None);
    v.mouse_dragged(&mut cx, to, None);
    v.mouse_up(&mut cx, to);
    let moved = v.model.keys(&EffectProperty::Opacity)[0].1;
    assert!(moved > v.model.clip().map_or(Time::ZERO, |c| c.start));
    let names: BTreeSet<String> = edits(&mut v.model).into_iter().map(|e| e.0).collect();
    assert_eq!(names.len(), 1);
}

#[test]
fn marquee_on_empty_lane_selects_the_keys_under_it() {
    let mut v = lanes_view();
    let key = animate_opacity(&mut v);
    v.model.clear_selection();
    let from = CGPoint::new(key.x + 30.0, key.y - 8.0);
    let to = CGPoint::new(v.lane_x() + 1.0, key.y + 8.0);
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, from, 1, InputModifiers::NONE);
    assert!(v.model.selection().is_empty());
    v.mouse_dragged(&mut cx, CGPoint::new(key.x + 10.0, key.y), None);
    v.mouse_dragged(&mut cx, to, None);
    assert!(v.lanes.marquee().is_some());
    assert_eq!(v.model.selected_key_ids(&EffectProperty::Opacity).len(), 1);
    v.mouse_up(&mut cx, to);
    assert!(v.lanes.marquee().is_none());
}

#[test]
fn right_click_on_a_key_offers_the_mac_menu_and_delete_removes_it() {
    let mut v = lanes_view();
    let key = animate_opacity(&mut v);
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, key, 1, InputModifiers::SECONDARY);
    v.mouse_up(&mut cx, key);
    let titles = menu_titles(&mut v);
    assert!(
        titles.contains(&"Temporal Interpolation".to_string())
            && titles.contains(&"Delete".to_string())
            && titles.contains(&"Copy".to_string())
    );
    assert!(!titles.contains(&"Scale Time\u{2026}".to_string())); // no prompt host: the dialog tools stay out
    v.set_has_prompt(true);
    v.mouse_down(&mut cx, key, 1, InputModifiers::SECONDARY);
    v.mouse_up(&mut cx, key);
    assert!(menu_titles(&mut v).contains(&"Scale Time\u{2026}".to_string()));
    assert!(v.key(&mut cx, InputKey::Delete, InputModifiers::NONE));
    assert!(v.model.keys(&EffectProperty::Opacity).is_empty());
}

#[test]
fn ruler_press_scrubs_the_playhead() {
    let mut v = lanes_view();
    v.model.take_events();
    let p = CGPoint::new(v.lane_x() + v.lanes.size.width / 2.0, ControlsMetrics::CLIP_LINE + 6.0);
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, p, 1, InputModifiers::NONE);
    v.mouse_dragged(&mut cx, CGPoint::new(p.x + 40.0, p.y), None);
    v.mouse_up(&mut cx, CGPoint::new(p.x + 40.0, p.y));
    let events = v.model.take_events();
    let began = events.iter().filter(|e| matches!(e, EffectControlsEvent::ScrubBegan)).count();
    let ended = events.iter().filter(|e| matches!(e, EffectControlsEvent::ScrubEnded)).count();
    let moved =
        events.iter().filter(|e| matches!(e, EffectControlsEvent::Scrub(_) | EffectControlsEvent::Seek(_))).count();
    assert!(began == 1 && ended == 1 && moved > 0);
}

#[test]
fn divider_drag_moves_the_split() {
    let mut v = lanes_view();
    let x0 = v.lane_x();
    let mut cx = UiCx::new();
    v.mouse_down(&mut cx, CGPoint::new(x0, 300.0), 1, InputModifiers::NONE);
    v.mouse_dragged(&mut cx, CGPoint::new(x0 + 40.0, 300.0), None);
    v.mouse_up(&mut cx, CGPoint::new(x0 + 40.0, 300.0));
    assert_eq!(v.lane_x(), EffectControlsSplit::clamp(x0 + 40.0, 900.0));
    assert_eq!(v.rows_panel.size.width, v.lane_x());
    assert!(v.take_events().iter().any(|e| matches!(e, ViewEvent::PersistLabelWidth(_))));
}

#[test]
fn draws_header_rows_ruler_and_lanes() {
    let mut v = lanes_view();
    animate_opacity(&mut v);
    let mut c = canvas(900.0, 1200.0);
    v.draw(&mut c, &mut UiCx::new());
    let img = SoftwareRenderer::render(&c.list, 900, 400, Color::BLACK, &Sources::default());
    assert_eq!(img.pixels[(100 * 900 + v.lane_x() as usize + 100) * 4 + 3], 255); // the lanes fill
}

// MARK: EffectControlsDrawPanelTests

fn panel_model() -> EffectControlsModel {
    model_with(clip_of(TrackKind::Video, 4, 0))
}

#[test]
fn empty_state_shows_only_without_a_clip() {
    let mut m = panel_model();
    let mut p = panel_of(&m, 420.0, 2000.0);
    assert!(!p.shows_empty_state(&m));
    m.set_clip(None, None, Vec::new(), None);
    assert!(p.shows_empty_state(&m));
    let mut c = canvas(420.0, 600.0);
    p.draw(&m, &mut c, &mut UiCx::new());
}

#[test]
fn rows_are_the_mac_layout() {
    let m = panel_model();
    let p = panel_of(&m, 420.0, 2000.0);
    let mut req = EffectRowsRequest::new(m.visible_sections());
    req.collapsed = m.collapsed_sections().clone();
    req.expanded = m.expanded().clone();
    req.blend_mode_row = true;
    req.group_headers = true;
    req.first_group_header = false;
    req.open_color_groups = m.open_color_groups.clone();
    req.subject_masks = m.subject_mask_ids();
    req.picture_masks = m.picture_mask_ids();
    req.magic_masks = m.magic_mask_ids();
    req.magic_notice = sq_draw::experimental::prefs().shows_notice(sq_draw::experimental::Feature::MagicMask);
    req.color_range_masks = m.color_range_mask_ids();
    req.grade_ranges = m.grade_range_effects();
    req.stabilizers = m.stabilizer_methods();
    req.transform_crop = m.transform_crop_properties();
    assert_eq!(p.rows(), EffectControlsLayout::rows(&req).as_slice());
    assert!(p.rows().iter().any(|r| r.kind == EffectRowKind::BlendMode));
}

#[test]
fn dragging_the_opacity_field_is_one_gesture_on_the_model() {
    let mut m = panel_model();
    let mut p = panel_of(&m, 420.0, 2000.0);
    let mut cx = UiCx::new();
    let at = row_center(&p, &EffectRowKind::Property(EffectProperty::Opacity), ControlsGrid::value_column(0) + 10.0)
        .expect("row");
    assert_eq!(
        p.target_at(&m, at),
        Target::Field(FieldId { row: RowRef::Property(EffectProperty::Opacity), component: EffectComponent::All })
    );
    let before = m.scalar_value(&EffectProperty::Opacity);
    p.mouse_down(&mut m, &mut cx, at, 1, InputModifiers::NONE);
    p.mouse_dragged(&mut m, &mut cx, CGPoint::new(at.x - 30.0, at.y), None);
    p.mouse_up(&mut m, &mut cx, CGPoint::new(at.x - 30.0, at.y));
    assert!(m.scalar_value(&EffectProperty::Opacity) < before);
    let names: BTreeSet<String> = edits(&mut m).into_iter().map(|e| e.0).collect();
    assert_eq!(names.len(), 1);
}

#[test]
fn click_types_a_value_and_enter_commits() {
    let mut m = panel_model();
    let mut p = panel_of(&m, 420.0, 2000.0);
    let mut cx = UiCx::new();
    let at = row_center(&p, &EffectRowKind::Property(EffectProperty::Opacity), ControlsGrid::value_column(0) + 10.0)
        .expect("row");
    click(&mut p, &mut m, &mut cx, at);
    let id = FieldId { row: RowRef::Property(EffectProperty::Opacity), component: EffectComponent::All };
    assert!(p.focused_field() == Some(&id) && p.fields().get(&id).is_some_and(|f| f.is_editing()));
    for ch in "40".chars() {
        p.key(&mut m, &mut cx, InputKey::Character(ch), InputModifiers::NONE);
    }
    p.key(&mut m, &mut cx, InputKey::Enter, InputModifiers::NONE);
    let want = EffectProperty::Opacity.native_from_display(40.0, EffectComponent::All, None);
    assert!((m.scalar_value(&EffectProperty::Opacity) - want).abs() < 1e-9);
    assert!(p.focused_field().is_none());
}

#[test]
fn command_z_leaves_an_open_field_and_goes_on_to_the_app() {
    let mut m = panel_model();
    let mut p = panel_of(&m, 420.0, 2000.0);
    let mut cx = UiCx::new();
    let at = row_center(&p, &EffectRowKind::Property(EffectProperty::Opacity), ControlsGrid::value_column(0) + 10.0)
        .expect("row");
    click(&mut p, &mut m, &mut cx, at);
    assert!(p.focused_field().is_some());
    assert!(!p.key(&mut m, &mut cx, InputKey::Character('z'), InputModifiers::COMMAND));
    assert!(p.focused_field().is_none());
    assert!(!p.key(&mut m, &mut cx, InputKey::Character('z'), InputModifiers::COMMAND | InputModifiers::SHIFT));
}

#[test]
fn double_click_on_a_field_types_and_the_reset_arrow_resets_the_row() {
    let mut m = panel_model();
    let mut p = panel_of(&m, 420.0, 2000.0);
    let mut cx = UiCx::new();
    m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.25);
    p.sync_fields(&m);
    let at = row_center(&p, &EffectRowKind::Property(EffectProperty::Opacity), ControlsGrid::value_column(0) + 10.0)
        .expect("row");
    click(&mut p, &mut m, &mut cx, at);
    p.mouse_down(&mut m, &mut cx, at, 2, InputModifiers::NONE);
    p.mouse_up(&mut m, &mut cx, at);
    assert!(!m.is_default(&EffectProperty::Opacity), "double-click does not reset");
    assert!(p.fields().values().any(|f| f.is_editing()), "it types, the whole value selected");
    let _ = m.reset(&EffectProperty::Opacity);
    assert!(m.is_default(&EffectProperty::Opacity), "the row's reset stays");
}

#[test]
fn blur_commits_the_typed_value_and_clears_the_focus() {
    let mut m = panel_model();
    let mut p = panel_of(&m, 420.0, 2000.0);
    let mut cx = UiCx::new();
    let at = row_center(&p, &EffectRowKind::Property(EffectProperty::Opacity), ControlsGrid::value_column(0) + 10.0)
        .expect("row");
    click(&mut p, &mut m, &mut cx, at);
    cx.typed_text = Some("5".into());
    p.key(&mut m, &mut cx, InputKey::Character('5'), InputModifiers::NONE);
    cx.typed_text = None;
    assert!(p.has_keyboard_focus());
    p.blur(&mut m, &mut cx);
    assert!(!p.has_keyboard_focus());
    assert!(p.fields().values().all(|f| !f.is_editing()));
    let want = EffectProperty::Opacity.native_from_display(5.0, EffectComponent::All, None);
    assert!((m.scalar_value(&EffectProperty::Opacity) - want).abs() < 1e-9);
}

#[test]
fn ring_starts_animation_and_the_chevron_collapses() {
    let mut m = panel_model();
    let mut p = panel_of(&m, 420.0, 2000.0);
    let mut cx = UiCx::new();
    let ring_at =
        row_center(&p, &EffectRowKind::Property(EffectProperty::Opacity), ControlsGrid::TOGGLE_MID_X).expect("row");
    click(&mut p, &mut m, &mut cx, ring_at);
    assert!(m.keyframe_control_state(&EffectProperty::Opacity).shows_navigation);
    let section = p.rows().iter().find(|r| matches!(r.kind, EffectRowKind::Section(_))).cloned().expect("section");
    let EffectRowKind::Section(sec) = section.kind.clone() else { return };
    let chevron = CGPoint::new(ControlsGrid::HEADER_TOGGLE_MID_X, section.y + section.height / 2.0);
    assert_eq!(p.target_at(&m, chevron), Target::Chevron(sec.clone()));
    click(&mut p, &mut m, &mut cx, chevron);
    assert!(m.collapsed_sections().contains(&sec));
    let mut open = EffectRowsRequest::new(m.visible_sections());
    open.blend_mode_row = true;
    open.group_headers = true;
    open.first_group_header = false;
    assert!(p.rows().len() < EffectControlsLayout::rows(&open).len());
}

#[test]
fn blend_popup_offers_the_mac_sections_and_picks() {
    let mut m = panel_model();
    let mut p = panel_of(&m, 420.0, 2000.0);
    let mut cx = UiCx::new();
    let at = row_center(&p, &EffectRowKind::BlendMode, ControlsGrid::VALUE_X + 20.0).expect("row");
    assert!(at.x < ControlsGrid::new(420.0).value_max_x());
    click(&mut p, &mut m, &mut cx, at);
    let Some(PanelEvent::Menu { menu, .. }) = p.take_events().into_iter().next() else { panic!("no menu") };
    let items = menu.items();
    let modes: Vec<usize> =
        items.iter().enumerate().filter(|(_, i)| i.kind == SQMenuItemKind::Action).map(|(n, _)| n).collect();
    assert_eq!(modes.len(), BlendMode::menu_sections().concat().len());
    assert_eq!(
        items.iter().filter(|i| i.kind == SQMenuItemKind::Separator).count(),
        BlendMode::menu_sections().len() - 1
    );
    assert_eq!(
        items.iter().find(|i| i.is_checked).map(|i| i.title.clone()),
        Some(BlendMode::Normal.title().to_string())
    );
    let multiply = items.iter().position(|i| i.title == BlendMode::Multiply.title()).expect("multiply");
    menu.run(&[multiply], &mut m);
    assert_eq!(m.blend_mode(), BlendMode::Multiply);
}

#[test]
fn section_context_menu_is_the_mac_one() {
    let mut m = panel_model();
    let mut p = panel_of(&m, 420.0, 2000.0);
    let at =
        row_center(&p, &EffectRowKind::Property(EffectProperty::Opacity), ControlsGrid::LABEL_X + 4.0).expect("row");
    p.context_menu(&mut m, at);
    let Some(PanelEvent::Menu { menu, .. }) = p.take_events().into_iter().next() else { panic!("no menu") };
    assert!(menu.items().iter().any(|i| i.title == "Reset"));
    let section = p.rows().iter().find(|r| matches!(r.kind, EffectRowKind::Section(_))).cloned().expect("section");
    p.context_menu(&mut m, CGPoint::new(100.0, section.y + 4.0));
    let Some(PanelEvent::Menu { menu, .. }) = p.take_events().into_iter().next() else { panic!("no menu") };
    assert!(menu.items().iter().any(|i| i.title.starts_with("Reset")));
}

#[test]
fn section_menu_wording_has_no_mac_keys_off_the_mac() {
    let mut c = clip_of(TrackKind::Video, 4, 0);
    c.add_effect(ClipEffect::ULTRA_KEY_KIND, None, &mut SequentialIds::default()).expect("effect");
    let mut m = model_with(c);
    m.set_collapsed_sections(Default::default());
    let mut p = panel_of(&m, 420.0, 3000.0);
    let sections: Vec<_> = p.rows().iter().filter(|r| matches!(r.kind, EffectRowKind::Section(_))).cloned().collect();
    assert!(sections.len() > 1, "an effect section next to the built-in ones");
    let mut with_copy = false;
    for s in sections {
        p.context_menu(&mut m, CGPoint::new(100.0, s.y + 4.0));
        for ev in p.take_events() {
            if let PanelEvent::Menu { menu, .. } = ev {
                let items = menu.items();
                with_copy |= items.iter().any(|i| i.title == "Copy" && !i.shortcut.is_empty());
                crate::assert_menu_wording("Effect Controls section menu", &items);
            }
        }
    }
    assert!(with_copy, "a section menu with the Copy shortcut was checked");
}

#[test]
fn draws_every_row_into_the_list() {
    let m = panel_model();
    let mut p = panel_of(&m, 420.0, 2000.0);
    let mut c = canvas(420.0, 2000.0);
    p.draw(&m, &mut c, &mut UiCx::new());
    let img = SoftwareRenderer::render(&c.list, 420, 400, Color::BLACK, &Sources::default());
    // The panel fill covers the canvas (no black left at a row's empty middle).
    assert_eq!(img.pixels[(5 * 420 + 200) * 4 + 3], 255);
    assert!(img.pixels[(5 * 420 + 200) * 4] > 0);
}

#[test]
fn label_cut_ends_at_a_word_boundary() {
    let m = |t: &str| t.chars().count() as f64;
    let s = EffectControlsDrawPanel::label_cut("Repeat Edge Pixels", 14.0, m);
    assert_eq!(s, "Repeat Edge\u{2026}");
    assert_eq!(EffectControlsDrawPanel::label_cut("Scale", 20.0, m), "Scale");
}

/// Every Controls row label of the effect catalog, set in the real UI font at the label column, ends at a word boundary
/// (never "Highlig…"): the whole cut goes through the shared `fit_with_ellipsis`.
#[test]
fn no_controls_label_is_cut_mid_word() {
    let root =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    let atlas = sq_draw::GlyphAtlas::inter(&root).expect("bundled Inter loads");
    let fs = sq_draw::theme::type_size::BODY as f64;
    let measure = |t: &str| f64::from(atlas.width_of(t, fs as f32, 0));
    let mut checked = 0;
    for spec in sq_core_model::EffectCatalog::all() {
        for p in &spec.params {
            // The label column, plus the row's free room up to the value column, down to a third of it.
            let full = ControlsGrid::new(320.0).label_frame(24.0, None).width;
            for width in [full, full * 0.75, full * 0.5] {
                let shown = EffectControlsDrawPanel::label_cut(&p.title, width, measure);
                assert!(
                    !sq_draw::glyph_atlas::cuts_mid_word(&p.title, &shown),
                    "\"{}\" at {width:.0} pt shows \"{shown}\"",
                    p.title
                );
                checked += 1;
            }
        }
    }
    assert!(checked > 100, "the catalog has rows ({checked})");
}

/// A label that overflows the label column wraps into two lines when both fit ("Repeat Edge" / "Pixels"), so the checker's
/// "Repeat Edge..." never shows; only a name that cannot wrap (one long word) is cut, at a word boundary.
#[test]
fn a_long_label_wraps_to_two_lines_instead_of_an_ellipsis() {
    let m = |t: &str| t.chars().count() as f64;
    let lines = |s: &str, w: f64| EffectControlsDrawPanel::label_lines(s, w, m);
    assert_eq!(lines("Repeat Edge Pixels", 12.0), ["Repeat Edge", "Pixels"]);
    assert_eq!(lines("Scale", 12.0), ["Scale"]);
    // A first word that is too wide on its own goes to `label_cut` unchanged (it shrinks or hides when drawn).
    assert_eq!(lines("Highlight/Shadow Protect", 12.0), ["Highlight/Shadow Protect"]);
    // Three lines' worth: cut, one line.
    assert_eq!(lines("Antialiasing (Best Quality) Extra Wide", 12.0).len(), 1);
}

/// Every catalog label in the real UI font, at the label column: whole, two fitting lines, or cut at a word boundary
/// (a first word wider than the column goes on unchanged);
/// "Repeat Edge Pixels" (99 pt in an 88 pt column) is two lines.
#[test]
fn every_catalog_label_is_whole_or_wrapped_or_cut_at_a_word() {
    let root =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    let atlas = sq_draw::GlyphAtlas::inter(&root).expect("bundled Inter loads");
    let fs = sq_draw::theme::type_size::BODY;
    let measure = |t: &str| f64::from(atlas.width_of(t, fs, 0));
    let full = ControlsGrid::new(320.0).label_frame(24.0, None).width;
    let repeat = EffectControlsDrawPanel::label_lines("Repeat Edge Pixels", full, measure);
    assert_eq!(repeat, ["Repeat Edge", "Pixels"]);
    for spec in sq_core_model::EffectCatalog::all() {
        for p in &spec.params {
            let lines = EffectControlsDrawPanel::label_lines(&p.title, full, measure);
            if lines.len() == 2 {
                assert!(lines.iter().all(|l| measure(l) <= full + 0.5), "{}: {lines:?}", p.title);
                assert_eq!(lines.join(" "), p.title, "a wrap loses nothing");
            } else {
                assert!(!sq_draw::glyph_atlas::cuts_mid_word(&p.title, &lines[0]), "{} -> {lines:?}", p.title);
            }
        }
    }
}

#[test]
fn key_hue_eyedropper_sets_the_hue_once_and_a_gray_spot_only_warns() {
    let mut c = clip_of(TrackKind::Video, 4, 0);
    let id = c.add_effect(ClipEffect::ULTRA_KEY_KIND, None, &mut SequentialIds::default()).expect("effect");
    let mut m = model_with(c);
    m.set_collapsed_sections(Default::default()); // effect sections start collapsed
    let mut p = panel_of(&m, 420.0, 3000.0);
    let hue = EffectProperty::Fx {
        id,
        kind: ClipEffect::ULTRA_KEY_KIND.to_string(),
        key: ClipEffect::KEY_HUE_KEY.to_string(),
    };
    let at = row_center(
        &p,
        &EffectRowKind::Property(hue.clone()),
        ControlsGrid::value_column(1) + ControlsGrid::CONTROL_HEIGHT / 2.0,
    )
    .expect("row");
    assert_ne!(p.target_at(&m, at), Target::KeyPick(hue.clone())); // no screen sampler: no eyedropper
    p.has_key_sampler = true;
    assert_eq!(p.target_at(&m, at), Target::KeyPick(hue.clone()));
    assert_eq!(p.help(&m, at).as_deref(), Some("Pick Key Color from Monitor"));
    let mut cx = UiCx::new();
    click(&mut p, &mut m, &mut cx, at);
    assert!(matches!(p.take_events().first(), Some(PanelEvent::PickKeyColor(h)) if *h == hue));
    m.take_events();
    p.key_color_picked(&mut m, &hue, (0.1, 0.2, 0.9)); // a blue screen
    let want = m.scalar_value(&hue);
    assert!((want - 238.0).abs() <= 1.0, "{want}"); // linear light, like the Mac frame readback
    assert_eq!(edits(&mut m).len(), 1);
    p.key_color_picked(&mut m, &hue, (0.5, 0.5, 0.5));
    assert_eq!(m.scalar_value(&hue), want);
}

#[test]
fn lanes_draw_a_glyph_for_every_key() {
    let mut v = lanes_view();
    animate_opacity(&mut v);
    v.model.clear_selection();
    let mut c = canvas(900.0, 1200.0);
    v.draw(&mut c, &mut UiCx::new());
    let key_color = DrawTheme::default().keyframe();
    assert!(c.list.quads().iter().any(|q| q.color == key_color));
}

// MARK: EffectControlsDrawRowsTests

fn rows_clip(kind: TrackKind) -> Clip {
    let mut c = clip_of(kind, 10, 0);
    c.media_duration = Some(s(100));
    c
}

fn rows_model(c: Clip) -> EffectControlsModel {
    let mut m = model_with(c);
    m.set_collapsed_sections(Default::default()); // effect sections start collapsed
    m
}

/// The center of a translated row's widget in panel points.
fn widget_point(p: &EffectControlsDrawPanel, m: &EffectControlsModel, key: &str) -> CGPoint {
    let (r, w) = p.widget(m, key).expect("widget");
    CGPoint::new(w.frame.mid_x(), w.frame.mid_y() + p.row_top(&r))
}

fn click_widget(p: &mut EffectControlsDrawPanel, m: &mut EffectControlsModel, key: &str) {
    let at = widget_point(p, m, key);
    click(p, m, &mut UiCx::new(), at);
}

#[test]
fn mask_invert_toggles_and_mode_popup_picks() {
    let mut m = rows_model(rows_clip(TrackKind::Video));
    let id = m.add_mask(sq_core_model::MaskShapeKind::Ellipse).expect("mask");
    let mut p = panel_of(&m, 420.0, 3000.0);
    let row = EffectControlsDrawPanel::row_key(&EffectRowKind::MaskControls(id));
    click_widget(&mut p, &mut m, &format!("{row}.invert"));
    assert_eq!(m.clip().and_then(|c| c.mask(id)).map(|k| k.inverted), Some(true));
    click_widget(&mut p, &mut m, &format!("{row}.mode"));
    let Some(PanelEvent::Menu { menu, .. }) = p.take_events().into_iter().next() else { panic!("no menu") };
    let titles: Vec<String> = menu.items().into_iter().map(|i| i.title).collect();
    assert_eq!(titles, ["Add", "Subtract", "Intersect", "Difference"]);
    let current = m.clip().and_then(|c| c.mask(id)).map(|k| k.mode).expect("mask");
    let pick = super::MASK_MODES.iter().position(|mode| *mode != current).expect("another mode");
    menu.run(&[pick], &mut m);
    assert_eq!(m.clip().and_then(|c| c.mask(id)).map(|k| k.mode), Some(super::MASK_MODES[pick]));
    let at = widget_point(&p, &m, &format!("{row}.mode"));
    assert_eq!(p.help(&m, at).as_deref(), Some("Mask Mode"));
}

#[test]
fn color_range_tolerance_field_drags_as_one_gesture() {
    let mut m = rows_model(rows_clip(TrackKind::Video));
    let id = m.add_color_range_mask(sq_core_model::ColorRangeKey::new(0.0, 1.0, 0.0, 0.4, 0.2)).expect("mask");
    m.set_collapsed_sections(Default::default());
    let mut p = panel_of(&m, 420.0, 3000.0);
    m.take_events();
    let key = format!(
        "{}.field",
        EffectControlsDrawPanel::row_key(&EffectRowKind::ColorRangeAmount { mask: id, soft: false })
    );
    let (r, w) = p.widget(&m, &key).expect("field");
    let top = p.row_top(&r);
    let at = CGPoint::new(w.frame.min_x() + 10.0, w.frame.mid_y() + top);
    let mut cx = UiCx::new();
    p.mouse_down(&mut m, &mut cx, at, 1, InputModifiers::NONE);
    p.mouse_dragged(&mut m, &mut cx, CGPoint::new(at.x + 20.0, at.y), None);
    p.mouse_up(&mut m, &mut cx, CGPoint::new(at.x + 20.0, at.y));
    assert!(m.color_range_of(id).is_some_and(|k| k.tolerance > 0.4));
    let names: BTreeSet<String> = edits(&mut m).into_iter().map(|e| e.0).collect();
    assert_eq!(names.len(), 1);
}

#[test]
fn grade_range_timecode_commits_on_enter_and_tab_moves_on() {
    let mut c = rows_clip(TrackKind::Video);
    let mut ids = SequentialIds::default();
    c.add_effect(ClipEffect::COLOR_KIND, None, &mut ids);
    let effect = c.add_range_grade(TimeRange::new(s(2), s(4)), &mut ids).expect("grade");
    let mut m = rows_model(c);
    let mut p = panel_of(&m, 420.0, 3000.0);
    let row = EffectControlsDrawPanel::row_key(&EffectRowKind::GradeRange(effect));
    click_widget(&mut p, &mut m, &format!("{row}.start"));
    assert_eq!(p.focused_text(), Some(format!("{row}.start").as_str()));
    let fd = m.frame_duration;
    let mut cx = UiCx::new();
    for ch in sq_editor_session::MarkersPanelModel::timecode(s(1), fd).chars() {
        p.key(&mut m, &mut cx, InputKey::Character(ch), InputModifiers::NONE);
    }
    p.key(&mut m, &mut cx, InputKey::Enter, InputModifiers::NONE);
    assert_eq!(m.grade_range(effect).map(|r| r.start), Some(s(1)));
    assert!(p.focused_text().is_none());
    click_widget(&mut p, &mut m, &format!("{row}.start"));
    p.key(&mut m, &mut cx, InputKey::Character('\t'), InputModifiers::NONE);
    assert_eq!(p.focused_text(), Some(format!("{row}.end").as_str()));
    p.key(&mut m, &mut cx, InputKey::Character('\t'), InputModifiers::SHIFT);
    assert_eq!(p.focused_text(), Some(format!("{row}.start").as_str()));
}

#[test]
fn color_group_disclosure_opens_and_its_box_enables() {
    let mut c = rows_clip(TrackKind::Video);
    c.add_effect(ClipEffect::COLOR_KIND, None, &mut SequentialIds::default());
    let mut m = rows_model(c);
    let mut p = panel_of(&m, 420.0, 3000.0);
    let row = p.rows().iter().find(|r| matches!(r.kind, EffectRowKind::ColorGroup { .. })).cloned().expect("group");
    let EffectRowKind::ColorGroup { effect, key: group } = row.kind.clone() else { return };
    let key = format!("{}.disclosure", EffectControlsDrawPanel::row_key(&row.kind));
    let gid = EffectControlsModel::color_group_id(effect, &group);
    let was_open = m.open_color_groups.contains(&gid);
    let count = p.rows().len();
    click_widget(&mut p, &mut m, &key);
    assert_ne!(m.open_color_groups.contains(&gid), was_open);
    assert_ne!(p.rows().len(), count);
    let (r, w) = p.widget(&m, &key).expect("widget");
    let b = w.toggle_frame.expect("box");
    let at = CGPoint::new(b.mid_x(), b.mid_y() + p.row_top(&r));
    assert_eq!(p.target_at(&m, at), Target::WidgetToggle(key.clone()));
    let prop = EffectProperty::Fx { id: effect, kind: ClipEffect::COLOR_KIND.to_string(), key: group };
    let before = m.scalar_value(&prop) >= 0.5;
    click(&mut p, &mut m, &mut UiCx::new(), at);
    assert_ne!(m.scalar_value(&prop) >= 0.5, before);
}

#[test]
fn curves_pick_a_channel_and_add_a_point_as_one_gesture() {
    use super::effect_controls_draw_surfaces::{ColorCurvesSurface, DrawSurface};
    let mut c = rows_clip(TrackKind::Video);
    c.add_effect(ClipEffect::COLOR_KIND, None, &mut SequentialIds::default());
    let mut m = rows_model(c);
    let mut p = panel_of(&m, 420.0, 3000.0);
    if !p.rows().iter().any(|r| matches!(r.kind, EffectRowKind::Curves(_))) {
        // The Curves group starts closed: open it like a click on its disclosure.
        let header = p
            .rows()
            .iter()
            .find(|r| matches!(&r.kind, EffectRowKind::ColorGroup { key, .. } if key.to_lowercase().contains("curve")))
            .cloned()
            .expect("curves group");
        let EffectRowKind::ColorGroup { effect, key } = header.kind else { return };
        m.toggle_color_group(effect, &key);
        p.relayout(&m);
    }
    let row = p.rows().iter().find(|r| matches!(r.kind, EffectRowKind::Curves(_))).cloned().expect("curves row");
    let EffectRowKind::Curves(effect) = row.kind.clone() else { return };
    let key = format!("{}.curves", EffectControlsDrawPanel::row_key(&row.kind));
    let (r, w) = p.widget(&m, &key).expect("widget");
    let top = p.row_top(&r);
    // The red dot of the channel row.
    let dots_w = 4.0 * 9.0 + 3.0 * 10.0 + 10.0;
    let f_x = w.frame.min_x() + ((w.frame.width - dots_w) / 2.0).max(ControlsGrid::TOGGLE_X);
    let x0 = (f_x + (dots_w - (4.0 * 9.0 + 3.0 * 10.0)) / 2.0).round();
    let red = CGPoint::new(x0 + 19.0 + 4.5, w.frame.min_y() + 6.0 + 4.5 + top);
    let mut cx = UiCx::new();
    click(&mut p, &mut m, &mut cx, red);
    m.take_events();
    let plot = ColorCurvesSurface::plot(w.frame);
    let at = CGPoint::new(plot.min_x() + plot.width * 0.5, plot.min_y() + plot.height * 0.3 + top);
    p.mouse_down(&mut m, &mut cx, at, 1, InputModifiers::NONE);
    p.mouse_dragged(&mut m, &mut cx, CGPoint::new(at.x, at.y - 10.0), None);
    p.mouse_up(&mut m, &mut cx, CGPoint::new(at.x, at.y - 10.0));
    let curves = m.color_curves(effect);
    assert!(curves.red.len() == 3 && curves.master.len() == 2);
    assert!(curves.red[1].y > 0.7);
    let names: BTreeSet<String> = edits(&mut m).into_iter().map(|e| e.0).collect();
    assert_eq!(names.len(), 1);
    let rp = CGPoint::new(
        plot.min_x() + f64::from(curves.red[1].x) * plot.width,
        plot.min_y() + (1.0 - f64::from(curves.red[1].y)) * plot.height + top,
    );
    p.mouse_down(&mut m, &mut cx, rp, 2, InputModifiers::NONE);
    p.mouse_up(&mut m, &mut cx, rp);
    assert_eq!(m.color_curves(effect).red.len(), 2);
    let _: &dyn DrawSurface = &ColorCurvesSurface::new(effect);
}

#[test]
fn eq_curve_drags_a_band_and_scroll_sets_q() {
    use super::effect_controls_draw_surfaces::EqCurveSurface;
    let mut c = rows_clip(TrackKind::Audio);
    c.add_effect(ClipEffect::AUDIO_PARAMETRIC_EQ_KIND, None, &mut SequentialIds::default());
    let mut m = rows_model(c);
    let mut p = panel_of(&m, 420.0, 3000.0);
    if !p.rows().iter().any(|r| matches!(r.kind, EffectRowKind::EqCurve(_)))
        && let Some(EffectRowKind::EqCurveHeader(e)) =
            p.rows().iter().map(|r| r.kind.clone()).find(|k| matches!(k, EffectRowKind::EqCurveHeader(_)))
    {
        m.toggle_eq_curve(e);
        p.relayout(&m);
    }
    let row = p.rows().iter().find(|r| matches!(r.kind, EffectRowKind::EqCurve(_))).cloned().expect("eq row");
    let EffectRowKind::EqCurve(effect) = row.kind.clone() else { return };
    let key = format!("{}.curve", EffectControlsDrawPanel::row_key(&row.kind));
    let (r, w) = p.widget(&m, &key).expect("widget");
    assert!(matches!(w.kind, WidgetKind::Surface(_)));
    let v = m.eq_values(effect).expect("values");
    let band = (1..=7).find(|i| v.band(*i).on).expect("a band is on");
    let top = p.row_top(&r);
    let g = EqCurveSurface::geometry(w.frame);
    let at0 = EqCurveSurface::point_position(band, &v, &g);
    let at = CGPoint::new(at0.x, at0.y + top);
    let mut cx = UiCx::new();
    p.mouse_down(&mut m, &mut cx, at, 1, InputModifiers::NONE);
    p.mouse_dragged(&mut m, &mut cx, CGPoint::new(at.x + 30.0, at.y - 20.0), None);
    p.mouse_up(&mut m, &mut cx, CGPoint::new(at.x + 30.0, at.y - 20.0));
    let after = m.eq_values(effect).expect("values");
    assert!(after.band(band).hz > v.band(band).hz && after.band(band).gain_db > v.band(band).gain_db);
    let moved = EqCurveSurface::point_position(band, &after, &g);
    assert!(p.scroll(&mut m, &mut cx, CGPoint::new(moved.x, moved.y + top), 40.0, true, InputModifiers::NONE));
    let q = m.eq_values(effect).map_or(0.0, |v| v.band(band).q);
    assert!((q - after.band(band).q * 2.0).abs() < 1e-6 || q == 10.0, "{q}");
    let tip = p.help(&m, CGPoint::new(moved.x, moved.y + top));
    assert!(tip.is_some_and(|t| t.starts_with("Drag a point")));
}

#[test]
fn translated_rows_draw() {
    let mut c = rows_clip(TrackKind::Video);
    let mut ids = SequentialIds::default();
    c.add_effect(ClipEffect::COLOR_KIND, None, &mut ids);
    let mut m = rows_model(c);
    m.add_mask(sq_core_model::MaskShapeKind::Ellipse);
    let mut p = panel_of(&m, 420.0, 3000.0);
    let mut cv = canvas(420.0, 3000.0);
    p.draw(&m, &mut cv, &mut UiCx::new());
    assert!(!cv.list.quads().is_empty());
}

// MARK: Redesign R6a: line rules, easing words, Custom chip

/// Full-width 1 pt line quads (row lines and separators) of `list` as (x, y, width).
fn hairlines(c: &Canvas, t: &DrawTheme) -> Vec<(f32, f32, f32)> {
    c.list
        .quads()
        .iter()
        .filter(|q| q.rect.h <= 1.01 && (q.color == t.row_line() || q.color == t.separator() || q.color == t.hair2()))
        .map(|q| (q.rect.x, q.rect.y, q.rect.w))
        .collect()
}

#[test]
fn row_lines_run_from_the_rows_into_the_keyframe_lane_and_never_double() {
    let mut v = lanes_view();
    animate_opacity(&mut v);
    let mut c = canvas(900.0, 1200.0);
    v.draw(&mut c, &mut UiCx::new());
    let lw = v.lane_x() as f32;
    let lines = hairlines(&c, &DrawTheme::default());
    let rows: Vec<f32> = lines.iter().filter(|l| l.0 < 1.0 && l.2 <= lw + 0.5).map(|l| l.1).collect();
    let lane: Vec<f32> = lines.iter().filter(|l| l.0 >= lw - 0.5).map(|l| l.1).collect();
    assert!(rows.len() > 5, "{rows:?}");
    // Every row line of the rows column continues in the lane at the same y.
    for y in &rows {
        assert!(lane.iter().any(|ly| (ly - y).abs() < 0.5), "row line at {y} stops at the divider: {lane:?}");
    }
    // One fine line between rows and sections: no two lines closer than 2 pt in the rows column.
    let mut ys = rows.clone();
    ys.sort_by(f32::total_cmp);
    ys.dedup_by(|a, b| (*a - *b).abs() < 0.01);
    for w in ys.windows(2) {
        assert!(w[1] - w[0] >= 2.0, "double line at {} and {}", w[0], w[1]);
    }
}

/// The clip line (name and range) is a label with a tooltip, as in the Swift app: a press, a drag and a release on it do
/// nothing, and it asks for no pointing hand. The use pass lists it as a control by its tooltip; it is in
/// `scripts/use-pass-known.tsv` for this reason.
#[test]
fn the_clip_line_is_a_label_with_a_tip_and_nothing_to_click() {
    let mut v = lanes_view();
    let at = CGPoint::new(120.0, ControlsMetrics::CLIP_LINE / 2.0);
    assert_eq!(v.part_at(at), Part::Header);
    assert!(v.help(at).is_some_and(|t| t.starts_with("Video \u{b7} ")), "the tip names the kind and the duration");
    let mut cx = UiCx::new();
    v.model.take_events();
    v.mouse_down(&mut cx, at, 1, InputModifiers::NONE);
    v.mouse_dragged(&mut cx, CGPoint::new(at.x + 30.0, at.y), None);
    v.mouse_up(&mut cx, CGPoint::new(at.x + 30.0, at.y));
    assert!(v.model.take_events().is_empty(), "a click on the label changes nothing");
    assert!(cx.hover.cursor.is_none(), "the label asks for no pointing hand");
    assert!(!v.is_dragging(), "the label captures nothing");
}

#[test]
fn the_selected_item_comes_first_then_video_whole_clip() {
    let mut v = lanes_view();
    assert_eq!(v.group_title(), "Video");
    assert_eq!(v.video_header_y(), ControlsMetrics::CLIP_LINE);
    v.set_lead(60.0);
    v.relayout();
    assert_eq!(v.group_title(), "Video \u{b7} whole clip");
    // Clip line, then the leading item (60 pt), then the Video header, then the rows.
    assert_eq!(v.lead_top(), ControlsMetrics::CLIP_LINE);
    assert_eq!(v.video_header_y(), ControlsMetrics::CLIP_LINE + 60.0);
    assert_eq!(v.top(), v.video_header_y() + ControlsMetrics::HEADER);
    let lw = v.lane_x();
    assert_eq!(v.part_at(CGPoint::new(100.0, ControlsMetrics::CLIP_LINE + 30.0)), Part::Header);
    assert_eq!(v.part_at(CGPoint::new(lw + 50.0, v.video_header_y() + 4.0)), Part::Ruler);
    let mut c = canvas(900.0, 1200.0);
    v.draw(&mut c, &mut UiCx::new());
    assert!(!c.list.quads().is_empty());
}

#[test]
fn easing_words_are_linear_ease_in_ease_out_ease_in_and_out_and_custom() {
    let names: Vec<&str> = super::graph_editor_draw::EASE_CHOICES.iter().map(|c| c.1).collect();
    assert_eq!(&names[..4], ["Linear", "Ease In & Out", "Ease In", "Ease Out"]);
    assert_eq!(KeyInterpolationChoice::EaseIn.title(), "Ease In");
    assert_eq!(KeyInterpolationChoice::EasyEase.title(), "Ease In & Out");
    assert_eq!(EasingPopoverDraw::CUSTOM_LABEL, "Custom");
    for old in ["Steady", "Smooth", "Smooth In", "Smooth Out", "Soft"] {
        assert!(!names.contains(&old), "{old}");
    }
}

#[test]
fn the_custom_chip_maps_the_mini_curve_to_a_handle() {
    let base = sq_core_model::EaseShape::LINEAR;
    let left = EasingPopoverDraw::custom_shape(base, 0.25, 0.9);
    assert_eq!(left.interpolation(), sq_core_time::Interpolation::Bezier);
    assert!((left.out.dx - 0.25).abs() < 1e-9 && (left.out.dy - 0.9).abs() < 1e-9);
    assert_eq!(left.r#in, base.r#in);
    let right = EasingPopoverDraw::custom_shape(left, 0.8, 0.2);
    assert!((right.r#in.dx - 0.2).abs() < 1e-9 && (right.r#in.dy - 0.8).abs() < 1e-9);
    assert_eq!(right.out, left.out);
}

#[test]
fn dragging_the_custom_chip_is_one_gesture_and_lights_it_up() {
    let mut m = easing_model();
    m.take_events();
    let mut pop = EasingPopoverDraw::new(&m);
    let plot = EasingPopoverDraw::custom_plot();
    let at = |nx: f64, ny: f64| CGPoint::new(plot.min_x() + plot.width * nx, plot.min_y() + plot.height * (1.0 - ny));
    assert_eq!(pop.help(at(0.5, 0.5)).as_deref(), Some("Custom: drag the curve"));
    pop.mouse_down(&mut m, at(0.25, 0.9));
    pop.mouse_dragged(&mut m, at(0.3, 0.8), InputModifiers::NONE);
    pop.mouse_up(&mut m, at(0.3, 0.8));
    let names = edits(&mut m);
    assert!(names.len() >= 2 && !names[0].1 && names[1..].iter().all(|n| n.1), "{names:?}");
    let EaseReading::Common(shape) = EffectControlsModel::ease_reading(&m).expect("reading") else {
        panic!("not common")
    };
    assert!((shape.out.dx - 0.3).abs() < 0.01 && (shape.out.dy - 0.8).abs() < 0.01, "{shape:?}");
    let mut c = canvas(260.0, 200.0);
    pop.draw(&m, &mut c, &DrawTheme::default(), &mut UiCx::new());
    let tint = DrawTheme::default().accent_tint();
    assert!(
        c.list
            .quads()
            .iter()
            .any(|q| q.color == tint && (q.rect.x - EasingPopoverDraw::CUSTOM_FRAME.min_x() as f32).abs() < 0.5)
    );
}

// MARK: Curve head chips

#[test]
fn the_curve_head_chips_ease_the_selected_keys_and_the_toggle_switches_the_graph() {
    use super::graph_chips::GraphHeadLayout;
    use sq_core_model::keyframes_premiere::KeyInterpolationChoice;
    use sq_uikit::keyframe_graph_geometry::GraphMode;
    let mut m = easing_model();
    m.toggle_open(&EffectProperty::Position);
    let mut p = panel_of(&m, 400.0, 600.0);
    let row =
        p.rows().iter().find(|r| r.kind == EffectRowKind::Graph(EffectProperty::Position)).expect("graph row").clone();
    let mut cx = UiCx::new();
    // the chips are there, in the frame's order
    let chips = GraphHeadLayout::chip_frames(&p.widths.borrow());
    assert_eq!(chips.iter().map(|c| c.1).collect::<Vec<_>>(), ["Linear", "Ease In", "Ease Out", "Ease In & Out"]);
    let at = |f: CGRect| CGPoint::new(f.mid_x(), row.y + f.mid_y());
    assert_eq!(
        p.target_at(&m, at(chips[3].2)),
        Target::GraphHead(
            EffectProperty::Position,
            super::graph_chips::GraphHead::Ease(KeyInterpolationChoice::EasyEase)
        )
    );
    click(&mut p, &mut m, &mut cx, at(chips[3].2));
    let EaseReading::Common(shape) = EffectControlsModel::ease_reading(&m).expect("reading") else {
        panic!("not common")
    };
    assert!(!shape.is_approximately_equal(&EasingCurve::linear().shape()));
    click(&mut p, &mut m, &mut cx, at(chips[0].2));
    let EaseReading::Common(shape) = EffectControlsModel::ease_reading(&m).expect("reading") else {
        panic!("not common")
    };
    assert!(shape.is_approximately_equal(&EasingCurve::linear().shape()));
    // Speed / Value toggle
    let (_, speed) = GraphHeadLayout::mode_frames()[1];
    click(&mut p, &mut m, &mut cx, at(speed));
    assert_eq!(m.graph_mode_for(&EffectProperty::Position), GraphMode::Speed);
    // drawing the head does not panic and adds quads
    let mut c = canvas(400.0, 600.0);
    p.draw(&m, &mut c, &mut cx);
}

#[test]
fn the_curve_head_chips_follow_the_measured_text_and_light_the_common_easing() {
    use super::graph_chips::{GraphHead, GraphHeadLayout};
    use sq_core_model::keyframes_premiere::KeyInterpolationChoice;
    use std::collections::HashMap;
    let estimated = GraphHeadLayout::chip_frames(&HashMap::new());
    // a measured width replaces the estimate: the chip is text + 14 and the next chip moves with it
    let mut widths = HashMap::new();
    widths.insert("chip:Ease In".to_string(), 40.4);
    let frames = GraphHeadLayout::chip_frames(&widths);
    assert_eq!(frames[1].2.width, 41.0 + 14.0);
    assert_eq!(frames[0].2, estimated[0].2);
    assert_eq!(frames[2].2.min_x(), frames[1].2.max_x() + GraphHeadLayout::GAP);
    // a hit follows the measured frame, not the estimate
    let probe = CGPoint::new(frames[1].2.max_x() - 1.0, frames[1].2.mid_y());
    assert_eq!(GraphHeadLayout::hit(&widths, probe), Some(GraphHead::Ease(KeyInterpolationChoice::EaseIn)));
    // the common easing of the selected keys is the lit chip; no keys, no chip
    assert_eq!(GraphHeadLayout::active_chip(None), None);
    for choice in [KeyInterpolationChoice::Linear, KeyInterpolationChoice::EaseOut, KeyInterpolationChoice::EasyEase] {
        let reading = EaseReading::Common(choice.curve().shape());
        assert_eq!(GraphHeadLayout::active_chip(Some(reading)), Some(choice));
    }
    assert_eq!(GraphHeadLayout::active_chip(Some(EaseReading::Mixed(vec![]))), None);
}

#[test]
fn the_overflow_thumb_shows_only_while_rows_overflow_and_follows_the_scroll() {
    assert!(EffectControlsDrawView::scroll_thumb(500.0, 100.0, 300.0, 300.0, 0.0).is_none());
    let top = EffectControlsDrawView::scroll_thumb(500.0, 100.0, 300.0, 600.0, 0.0).expect("overflow");
    assert_eq!((top.x, top.y, top.width, top.height), (493.0, 100.0, 4.0, 150.0));
    let end = EffectControlsDrawView::scroll_thumb(500.0, 100.0, 300.0, 600.0, 300.0).expect("overflow");
    assert_eq!(end.y + end.height, 400.0);
}

/// Windows acceptance 2: a typed Compressor Threshold (-40, with the Minus key) is taken; out of range clamps to -60 dB.
#[test]
fn a_typed_compressor_threshold_is_taken_and_clamps_to_its_range() {
    for (typed, want) in [("-40", -40.0), ("-80", -60.0), ("5", 0.0)] {
        let mut c = clip_of(TrackKind::Audio, 4, 0);
        let id = c.add_effect(ClipEffect::AUDIO_COMPRESSOR_KIND, None, &mut SequentialIds::default()).expect("effect");
        let mut m = model_with(c);
        m.set_collapsed_sections(Default::default());
        let mut p = panel_of(&m, 420.0, 3000.0);
        let prop = EffectProperty::Fx {
            id,
            kind: ClipEffect::AUDIO_COMPRESSOR_KIND.to_string(),
            key: ClipEffect::COMP_THRESHOLD_KEY.to_string(),
        };
        let at =
            row_center(&p, &EffectRowKind::Property(prop.clone()), ControlsGrid::value_column(0) + 10.0).expect("row");
        let mut cx = UiCx::new();
        click(&mut p, &mut m, &mut cx, at);
        p.key(&mut m, &mut cx, InputKey::Character('a'), InputModifiers::COMMAND);
        for ch in typed.chars() {
            let (k, text) = match ch {
                '-' => (InputKey::Minus, "-".to_string()),
                d => (InputKey::Character(d), d.to_string()),
            };
            cx.typed_text = Some(text);
            p.key(&mut m, &mut cx, k, InputModifiers::NONE);
        }
        cx.typed_text = None;
        p.key(&mut m, &mut cx, InputKey::Enter, InputModifiers::NONE);
        assert_eq!(m.scalar_value(&prop), want, "typed {typed}");
    }
}

/// Windows acceptance 2: the eye and the reset button of an effect header each change the clip (and each is an undo step).
/// Like Swift, Reset on an effect that is on and at its defaults changes nothing and adds no undo step.
#[test]
fn the_eye_and_reset_buttons_of_an_effect_header_change_the_model() {
    let mut c = clip_of(TrackKind::Audio, 4, 0);
    let id = c.add_effect(ClipEffect::AUDIO_COMPRESSOR_KIND, None, &mut SequentialIds::default()).expect("effect");
    let mut m = model_with(c);
    let mut p = panel_of(&m, 420.0, 3000.0);
    let sec = sq_editor_session::EffectSection::Effect { id, kind: ClipEffect::AUDIO_COMPRESSOR_KIND.to_string() };
    let row = p.rows().iter().find(|r| r.kind == EffectRowKind::Section(sec.clone())).cloned().expect("header");
    let y = row.y + row.height / 2.0;
    let find = |p: &EffectControlsDrawPanel, m: &EffectControlsModel, want: Target| {
        (0..420).map(|x| CGPoint::new(f64::from(x) + 0.5, y)).find(|q| p.target_at(m, *q) == want).expect("button")
    };
    let (eye, reset) = (find(&p, &m, Target::Eye(sec.clone())), find(&p, &m, Target::SectionReset(sec.clone())));
    let mut cx = UiCx::new();
    let enabled = |m: &EffectControlsModel| m.is_effect_enabled(&sec);
    assert!(enabled(&m));
    m.take_events();
    click(&mut p, &mut m, &mut cx, eye);
    assert!(!enabled(&m), "the eye switches the effect off");
    assert_eq!(edits(&mut m).len(), 1, "one undo step");
    click(&mut p, &mut m, &mut cx, reset);
    assert!(enabled(&m), "reset switches it on again");
    assert_eq!(edits(&mut m).len(), 1, "one undo step");
    click(&mut p, &mut m, &mut cx, reset);
    assert!(edits(&mut m).is_empty(), "reset at the defaults changes nothing (Swift: commit skips an equal clip)");
}

// MARK: Pairs of fields at narrow widths

/// At the panel of the 640x400 layout (229 pt) and at every width up to the minimum, no field of a two-field row passes the
/// panel edge or gets narrower than `MIN_FIELD`; where they do not fit side by side the row is taller and stacks them, and the
/// second field is hit where it is drawn.
#[test]
fn two_field_rows_fit_the_narrowest_controls_width() {
    for w in [229.0, 260.0, 300.0, 340.0, 360.0, 420.0] {
        let m = model_with(clip_of(TrackKind::Video, 4, 0));
        let p = panel_of(&m, w, 3000.0);
        let mut seen = 0;
        for prop in [EffectProperty::Position, EffectProperty::Anchor] {
            let Some(row) = p.rows().iter().find(|r| r.kind == EffectRowKind::Property(prop.clone())).cloned() else {
                continue;
            };
            seen += 1;
            let n = m.value_components(&prop).len();
            assert_eq!(n, 2);
            let stacked = ControlsGrid::new(w).fields_stack(n, false);
            assert_eq!(
                row.height,
                if stacked { 2.0 * ControlsGrid::ROW_HEIGHT } else { ControlsGrid::ROW_HEIGHT },
                "{w}"
            );
            for i in 0..n {
                let f = p.field_frame(&m, &prop, i, row.height);
                assert!(
                    f.max_x() <= w - ControlsGrid::TRAILING + 0.01,
                    "{w}: field {i} of {prop:?} ends at {}",
                    f.max_x()
                );
                assert!(f.width >= ControlsGrid::MIN_FIELD, "{w}: field {i} is {} wide", f.width);
                let at = CGPoint::new(f.min_x() + f.width / 2.0, row.y + f.min_y() + f.height / 2.0);
                let hit = p.target_at(&m, at);
                assert!(
                    matches!(&hit, Target::Field(id) if id.component == m.value_components(&prop)[i]),
                    "{w}: {hit:?}"
                );
            }
        }
        assert_eq!(seen, 2, "{w}: Position and Anchor rows");
    }
}

// MARK: Shown shortcuts

/// The chord a menu row's shortcut text stands for: Command + a letter, or the Delete key.
fn chord_of(shortcut: &str) -> Option<(InputKey, InputModifiers)> {
    use sq_uikit::key_binding::{Key, KeyBinding, KeyModifiers};
    use sq_uikit::key_binding_text::KeyBindingText;
    let text = |k: Key, m: KeyModifiers| KeyBindingText::text(&KeyBinding::new(k, m), sq_os::Platform::current());
    if shortcut == text(Key::Delete, KeyModifiers::EMPTY) {
        return Some((InputKey::Backspace, InputModifiers::NONE));
    }
    ('a'..='z')
        .find(|c| shortcut == text(Key::Char(*c), KeyModifiers::COMMAND))
        .map(|c| (InputKey::Character(c), InputModifiers::COMMAND))
}

/// A Controls view on a clip with one Ultra Key effect, its header selected and the effect copied (so Paste is offered).
fn view_with_selected_effect() -> (EffectControlsDrawView, EffectSection) {
    let mut c = clip_of(TrackKind::Video, 4, 0);
    let id = c.add_effect(ClipEffect::ULTRA_KEY_KIND, None, &mut SequentialIds::default()).expect("effect");
    let mut v = view_of(model_with(c), 420.0, 900.0);
    let section = EffectSection::Effect { id, kind: ClipEffect::ULTRA_KEY_KIND.to_string() };
    v.model.select_effect_header(&section);
    assert!(v.model.copy_effect(&section));
    v.model.mark_effect_copied(); // what the menu's Copy row does after it
    (v, section)
}

/// "Every shown shortcut must work": each shortcut the section's right-click menu shows runs when its
/// chord reaches the panel, and the chord does what the row does.
#[test]
fn every_shortcut_the_section_menu_shows_has_a_handler_in_the_panel() {
    let (mut v, section) = view_with_selected_effect();
    let shown: Vec<(String, String)> = EffectControlsDrawPanel::new()
        .section_menu(&mut v.model, &section)
        .items()
        .into_iter()
        .filter(|i| !i.shortcut.is_empty())
        .map(|i| (i.title, i.shortcut))
        .collect();
    let titles: Vec<&str> = shown.iter().map(|(t, _)| t.as_str()).collect();
    assert_eq!(titles, ["Cut", "Copy", "Paste", "Delete"], "the rows with a shortcut changed: audit the new ones");
    for (title, shortcut) in &shown {
        let (mut v, _) = view_with_selected_effect();
        let (key, mods) = chord_of(shortcut).unwrap_or_else(|| panic!("{title}: no chord for the shown {shortcut:?}"));
        let before = v.model.clip().map(|c| c.effects.len()).unwrap_or(0);
        assert!(v.key(&mut UiCx::new(), key, mods), "{title} ({shortcut}) is shown but the panel does not take it");
        let after = v.model.clip().map(|c| c.effects.len()).unwrap_or(0);
        match title.as_str() {
            "Cut" | "Delete" => assert_eq!(after, before - 1, "{title} must remove the effect"),
            "Paste" => assert_eq!(after, before + 1, "Paste must add the copied effect"),
            _ => assert_eq!(after, before),
        }
    }
}

// MARK: Section twirl after key deletes (the section could not be closed after deleting two keys)

/// Position keyed twice with its curve row opened, in a 900 x 1200 pt view.
fn position_curve_view() -> EffectControlsDrawView {
    let mut m = easing_model();
    m.toggle_open(&EffectProperty::Position);
    view_of(m, 900.0, 1200.0)
}

/// The chevron of the first section, in view coordinates.
fn first_chevron(v: &EffectControlsDrawView) -> (EffectSection, CGPoint) {
    let row =
        v.rows_panel.rows().iter().find(|r| matches!(r.kind, EffectRowKind::Section(_))).cloned().expect("section");
    let EffectRowKind::Section(sec) = row.kind else { panic!("section") };
    (sec, CGPoint::new(ControlsGrid::HEADER_TOGGLE_MID_X, v.top() + row.y + row.height / 2.0))
}

#[test]
fn the_section_still_twirls_after_both_keys_of_an_opened_curve_are_deleted() {
    let mut v = position_curve_view();
    let mut cx = UiCx::new();
    assert!(v.model.expanded().contains(&EffectProperty::Position), "the curve row is open");
    assert!(v.key(&mut cx, InputKey::Delete, InputModifiers::NONE), "Delete handles the selected keys");
    v.relayout();
    assert!(v.model.keys(&EffectProperty::Position).is_empty(), "both keys are gone");
    let (sec, at) = first_chevron(&v);
    for closed in [true, false, true] {
        v.mouse_down(&mut cx, at, 1, InputModifiers::NONE);
        v.mouse_up(&mut cx, at);
        assert_eq!(v.model.collapsed_sections().contains(&sec), closed, "the chevron toggles the section");
        v.relayout();
    }
}

#[test]
fn the_section_twirls_when_the_session_hands_back_the_clip_without_its_keys() {
    let mut v = position_curve_view();
    let mut cx = UiCx::new();
    // The session applied the delete and echoes the clip (same id, no keys); the opened curve row had no say in it.
    v.model.set_clip(Some(clip_of(TrackKind::Video, 10, 0)), None, Vec::new(), None);
    v.relayout();
    assert!(
        !v.rows_panel.rows().iter().any(|r| matches!(r.kind, EffectRowKind::Graph(_))),
        "a curve row without keys is gone ({:?})",
        v.model.expanded()
    );
    let (sec, at) = first_chevron(&v);
    assert_eq!(v.rows_panel.target_at(&v.model, CGPoint::new(at.x, at.y - v.top())), Target::Chevron(sec.clone()));
    for closed in [true, false] {
        v.mouse_down(&mut cx, at, 1, InputModifiers::NONE);
        v.mouse_up(&mut cx, at);
        assert_eq!(v.model.collapsed_sections().contains(&sec), closed, "the chevron toggles the section");
        v.relayout();
    }
}

#[test]
fn the_section_twirls_after_the_keys_go_one_by_one_through_the_key_menu_route() {
    let mut v = position_curve_view();
    let mut cx = UiCx::new();
    for id in [21u128, 22] {
        v.model.select_key(&EffectProperty::Position, Id::from_u128(id), false);
        assert!(v.key(&mut cx, InputKey::Delete, InputModifiers::NONE), "key {id} deleted");
        v.relayout();
    }
    assert!(v.model.keys(&EffectProperty::Position).is_empty());
    let (sec, at) = first_chevron(&v);
    v.mouse_down(&mut cx, at, 1, InputModifiers::NONE);
    v.mouse_up(&mut cx, at);
    assert!(v.model.collapsed_sections().contains(&sec), "closed after the second delete");
}

// MARK: r8 WP7

#[test]
fn blend_popup_keeps_a_minimum_width_in_a_narrow_panel() {
    let m = panel_model();
    let p = panel_of(&m, 200.0, 800.0);
    assert!(p.blend_frame(24.0).width >= EffectControlsDrawPanel::BLEND_MIN_WIDTH);
}

#[test]
fn reset_shows_on_a_changed_row_or_under_the_pointer_only() {
    let m = panel_model();
    let mut p = panel_of(&m, 420.0, 800.0);
    assert!(!p.reset_shown(None, false, false));
    assert!(p.reset_shown(None, true, false));
    assert!(p.reset_shown(None, false, true));
    p.pointer_in_row = true;
    assert!(p.reset_shown(None, false, false));
}

#[test]
fn empty_state_uses_the_r8_wording() {
    assert_eq!(EffectControlsDrawPanel::EMPTY_TITLE, "No Clip Selected");
    assert!(EffectControlsDrawPanel::EMPTY_HINT.contains("keyframe its controls"));
}

#[test]
fn cut_name_tooltip_only_over_the_text() {
    let m = panel_model();
    let mut p = panel_of(&m, 420.0, 800.0);
    let row = p.rows().iter().find(|r| matches!(r.kind, EffectRowKind::Section(_))).cloned().expect("section");
    let EffectRowKind::Section(sec) = row.kind.clone() else { return };
    let top = p.row_top(&row);
    p.cut_titles.insert(sec, ("A very long name".to_string(), CGRect::new(28.0, 0.0, 60.0, row.height)));
    let over = |x: f64| p.help(&m, CGPoint::new(x, top + row.height / 2.0));
    assert_eq!(over(40.0).as_deref(), Some("A very long name"));
    assert_eq!(over(200.0), None);
}

/// The clip sections ("Keep intro and outro when trimmed") use the effect rows' label rule: a label too long for the
/// column is drawn on two lines inside the row, a short one on one line.
#[test]
fn the_shared_label_draw_wraps_a_long_clip_section_label_to_two_lines() {
    let root =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    let atlas = sq_draw::GlyphAtlas::inter(&root).expect("bundled Inter loads");
    let fs = f64::from(sq_draw::theme::type_size::BODY);
    let span = |text: &str| {
        let mut c = sq_draw::Canvas::with_size(300.0, 60.0, Some(&atlas), 1.0);
        let f = sq_uikit::controls_grid::CGRect::new(10.0, 0.0, 120.0, 24.0);
        EffectControlsDrawPanel::draw_label_lines(&mut c, text, f, 24.0, fs, sq_draw::Color::WHITE);
        let q = c.list.quads();
        let top = q.iter().map(|x| x.rect.y).fold(f32::MAX, f32::min);
        let bottom = q.iter().map(|x| x.rect.max_y()).fold(0.0, f32::max);
        (q.len(), bottom - top, bottom)
    };
    let (n1, one, _) = span("Layer");
    let (n2, two, bottom) = span("Keep intro and outro when trimmed");
    assert!(n1 > 0 && n2 > 0);
    assert!(two > one + 6.0, "two lines are taller than one: {one} vs {two}");
    assert!(bottom <= 24.0, "both lines stay inside the row: {bottom}");
}
