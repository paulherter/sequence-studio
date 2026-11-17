// Swift tests: TextInspectorModelTests, TextInspectorAnimatorTests, TextInspectorLayoutFillTests,
// TextInspectorSecondLineTests, TextInspectorTokenTests, TextMixedControlsTests.
use std::collections::BTreeSet;

use sq_core_edit::multi_clip_edit::CodableMerge;
use sq_core_graphics::custom_animation::AnimationSide;
use sq_core_model::StyleKit;
use sq_core_model::anchored_animation::{
    AnimationAnchor, AnimationSet, SegmentShape, TextAnimatorEffect, TextAnimatorOrder, TextAnimatorUnit,
};
use sq_core_time::{SequentialIds, Time};
use sq_text::caption_presets::CaptionPresetLibrary;
use sq_text::caption_style_looks::CaptionStyleLooks;
use sq_text::font_resolver::Axis;
use sq_text::style_kit_text::{BRAND_FONT_TOKEN, PILL_COLOR_TOKEN, StyleKitTextExt, TEXT_COLOR_TOKEN};
use sq_text::text_align_to_frame::FrameAlignment;
use sq_text::text_style::{
    BoxPadding, FontWeight, RGBAColor, StrokePosition, TextAlignment, TextDirection, TextFootageFill, TextLineStyle,
    TextListKind, TextStroke, TextStyle, TextVerticalAlignment,
};
use sq_text::text_template::TextTemplate;

use crate::text::inspector_model::{AnimatorSide, TextInspectorEvent, TextInspectorModel, TokenField};
use crate::text::style_library::TextStyleLibrary;

fn model(style: TextStyle, families: Vec<String>) -> TextInspectorModel {
    TextInspectorModel::new(
        style,
        AnimationSet::new(None, None),
        Some(CaptionPresetLibrary::built_in()),
        Box::new(move || families.clone()),
        TextStyleLibrary::default(),
        Box::new(SequentialIds::default()),
    )
}

fn make(style: TextStyle) -> TextInspectorModel {
    model(style, vec!["Helvetica".into(), "Menlo".into()])
}

/// The events as the Swift tests log them: "begin", "change", "end".
fn log(m: &mut TextInspectorModel) -> Vec<&'static str> {
    m.take_events()
        .into_iter()
        .filter_map(|e| match e {
            TextInspectorEvent::BeginEditing => Some("begin"),
            TextInspectorEvent::Change(..) => Some("change"),
            TextInspectorEvent::EndEditing => Some("end"),
            _ => None,
        })
        .collect()
}

fn named(name: &str, size: f64) -> TextStyle {
    TextStyle::new(name, size, FontWeight::Regular, RGBAColor::WHITE)
}

const BEC: [&str; 3] = ["begin", "change", "end"];

#[test]
fn loading_another_clip_closes_an_open_session() {
    let mut m = make(TextStyle::default());
    m.begin_editing();
    m.set_size(60.0);
    m.load(TextStyle::default(), AnimationSet::new(None, None));
    assert_eq!(log(&mut m), ["begin", "change", "end"]);
    m.set_size(80.0);
    assert_eq!(log(&mut m), BEC);
    m.end_editing();
    assert!(log(&mut m).is_empty());
}

#[test]
fn single_edit_wraps_in_begin_end() {
    let mut m = make(TextStyle::default());
    m.set_size(72.0);
    assert_eq!(m.style().size, 72.0);
    assert_eq!(log(&mut m), BEC);
}

#[test]
fn direction_edit_is_one_step_and_auto_clears() {
    let mut m = make(TextStyle::default());
    m.set_direction(Some(TextDirection::RightToLeft));
    assert_eq!(m.style().direction, Some(TextDirection::RightToLeft));
    assert_eq!(log(&mut m), BEC);
    m.set_direction(None);
    assert_eq!(m.style().direction, None);
    m.set_direction(None);
    assert_eq!(log(&mut m).len(), 3);
}

#[test]
fn font_axis_edits_keep_overrides_only() {
    // The axis is built by hand: the font files of the real axes are not part of the test environment.
    let wght = Axis { tag: "wght".into(), name: "wght".into(), minimum: 100.0, maximum: 900.0, default_value: 400.0 };
    let mut m = make(TextStyle::default());
    assert_eq!(m.axis_value(&wght), wght.default_value);
    m.set_font_axis(&wght, wght.maximum + 1000.0);
    assert_eq!(m.style().font_axes, Some([("wght".to_string(), wght.maximum)].into()));
    assert_eq!(m.axis_value(&wght), wght.maximum);
    m.set_font_axis(&wght, wght.default_value);
    assert_eq!(m.style().font_axes, None);
    m.set_font_axis(&wght, wght.maximum);
    m.reset_font_axes();
    assert_eq!(m.style().font_axes, None);
}

#[test]
fn static_font_has_no_axes() {
    let s = TextStyle { font_name: "Georgia".into(), ..TextStyle::default() };
    assert!(make(s).font_axes().is_empty());
}

#[test]
fn drag_session_coalesces() {
    let mut m = make(TextStyle::default());
    m.begin_editing();
    m.set_size(60.0);
    m.set_size(61.0);
    m.set_size(62.0);
    m.end_editing();
    assert_eq!(log(&mut m), ["begin", "change", "change", "change", "end"]);
    assert_eq!(m.style().size, 62.0);
}

#[test]
fn all_caps_and_stroke_position_are_one_edit_each() {
    let mut m = make(TextStyle::default());
    m.set_all_caps(true);
    assert!(m.style().all_caps);
    assert_eq!(log(&mut m), BEC);
    m.set_stroke_enabled(true);
    m.set_stroke_position(StrokePosition::Centre);
    assert_eq!(m.style().stroke.map(|s| s.position), Some(StrokePosition::Centre));
    m.set_stroke_position(StrokePosition::Centre);
    assert_eq!(log(&mut m).iter().filter(|e| **e == "change").count(), 2);
}

#[test]
fn footage_fill_is_one_edit_and_goes_back_to_color() {
    let mut m = make(TextStyle::default());
    m.set_footage_fill(Some(TextFootageFill::Stencil));
    assert_eq!(m.style().footage_fill, Some(TextFootageFill::Stencil));
    assert_eq!(log(&mut m), BEC);
    m.set_footage_fill(Some(TextFootageFill::Stencil));
    m.set_footage_fill(Some(TextFootageFill::Inverted));
    assert_eq!(m.style().footage_fill, Some(TextFootageFill::Inverted));
    m.set_footage_fill(None);
    assert_eq!(m.style().footage_fill, None);
    assert_eq!(log(&mut m).iter().filter(|e| **e == "change").count(), 2);
}

#[test]
fn line_styles_are_one_edit_each() {
    let mut m = make(TextStyle::default());
    m.set_underline(true);
    assert!(m.style().underline);
    assert_eq!(log(&mut m), BEC);
    m.set_strikethrough(true);
    m.set_overline(true);
    assert!(m.style().strikethrough && m.style().overline);
    m.set_underline(false);
    assert!(!m.style().underline && m.style().strikethrough);
}

#[test]
fn align_buttons_go_to_the_host() {
    let mut m = make(TextStyle::default());
    let all = [
        FrameAlignment::Left,
        FrameAlignment::CenterHorizontally,
        FrameAlignment::Right,
        FrameAlignment::Top,
        FrameAlignment::CenterVertically,
        FrameAlignment::Bottom,
    ];
    for a in all {
        m.align_to_frame(a);
    }
    let got: Vec<FrameAlignment> = m
        .take_events()
        .into_iter()
        .filter_map(|e| if let TextInspectorEvent::AlignToFrame(a) = e { Some(a) } else { None })
        .collect();
    assert_eq!(got, all);
}

#[test]
fn premiere_text_controls_edit_the_style() {
    let mut m = make(TextStyle::default());
    m.set_tracking(12.0);
    m.set_italic(true);
    m.set_vertical_alignment(TextVerticalAlignment::Bottom);
    assert!(
        m.style().tracking == 12.0 && m.style().italic && m.style().vertical_alignment == TextVerticalAlignment::Bottom
    );
    m.set_shadow_enabled(true);
    m.set_shadow_angle(45.0, 10.0);
    let sh = m.style().shadow.unwrap_or_else(|| panic!("no shadow"));
    assert!((sh.angle() - 45.0).abs() < 1e-6 && (sh.distance() - 10.0).abs() < 1e-9);
    m.set_shadow_opacity(0.25);
    let sh = m.style().shadow.unwrap_or_else(|| panic!("no shadow"));
    assert!(sh.color.alpha == 0.25 && (sh.distance() - 10.0).abs() < 1e-9);
    m.set_background_enabled(true);
    m.set_background_opacity(0.5);
    assert_eq!(m.style().background.map(|b| b.color.alpha), Some(0.5));
}

#[test]
fn shadow_size_is_the_spread_and_survives_angle_edits() {
    let mut m = make(TextStyle::default());
    m.set_shadow_enabled(true);
    m.set_shadow_spread(6.0);
    assert_eq!(m.style().shadow.map(|s| s.spread), Some(6.0));
    m.set_shadow_angle(90.0, 4.0);
    let sh = m.style().shadow.unwrap_or_else(|| panic!("no shadow"));
    assert!(sh.spread == 6.0 && (sh.distance() - 4.0).abs() < 1e-9);
    m.set_shadow_spread(-3.0);
    assert_eq!(m.style().shadow.map(|s| s.spread), Some(0.0));
}

#[test]
fn no_change_no_callback() {
    let mut m = make(TextStyle::default());
    let s = m.style().size;
    m.set_size(s);
    assert!(log(&mut m).is_empty());
}

#[test]
fn basic_setters() {
    let mut m = make(TextStyle::default());
    m.set_font_family("Menlo");
    m.set_weight(FontWeight::Bold);
    m.set_color(RGBAColor::rgb(1.0, 0.0, 0.0));
    m.set_alignment(TextAlignment::Left);
    m.set_line_spacing(6.0);
    assert!(
        m.style().font_name == "Menlo"
            && m.style().weight == FontWeight::Bold
            && m.style().alignment == TextAlignment::Left
    );
    assert!(m.style().color.red == 1.0 && m.style().line_spacing == 6.0);
}

#[test]
fn size_clamped() {
    let mut m = make(TextStyle::default());
    m.set_size(-5.0);
    assert_eq!(m.style().size, 1.0);
}

#[test]
fn stroke_toggle_remembers_values() {
    let mut m = make(TextStyle::default());
    assert!(m.style().stroke.is_none() && !m.stroke_enabled());
    m.set_stroke_enabled(true);
    assert!(m.style().stroke.is_some());
    m.set_stroke_width(9.0);
    m.set_stroke_color(RGBAColor::rgb(0.0, 1.0, 0.0));
    m.set_stroke_enabled(false);
    assert!(m.style().stroke.is_none());
    m.set_stroke_enabled(true);
    assert_eq!(m.style().stroke.map(|s| (s.width, s.color.green)), Some((9.0, 1.0)));
}

#[test]
fn stroke_setters_ignored_when_off() {
    let mut m = make(TextStyle::default());
    m.set_stroke_width(4.0);
    assert!(m.style().stroke.is_none() && log(&mut m).is_empty());
}

#[test]
fn background_and_shadow() {
    let mut m = make(TextStyle::default());
    m.set_background_enabled(true);
    m.set_background_padding(10.0, 5.0);
    m.set_background_radius(8.0);
    assert_eq!(m.style().background.map(|b| b.padding), Some(BoxPadding::new(10.0, 5.0)));
    assert_eq!(m.style().background.map(|b| b.corner_radius), Some(8.0));
    m.set_shadow_enabled(true);
    m.set_shadow_offset(1.0, 3.0);
    m.set_shadow_blur(7.0);
    assert_eq!(m.style().shadow.map(|s| (s.offset_x, s.offset_y, s.blur)), Some((1.0, 3.0, 7.0)));
    m.set_shadow_enabled(false);
    assert!(m.style().shadow.is_none());
}

#[test]
fn presets_apply_and_select() {
    let mut m = make(TextStyle::default());
    m.apply_preset("outline");
    assert_eq!(*m.style(), CaptionPresetLibrary::built_in().style(Some("outline")));
    assert_eq!(m.selected_preset_id().as_deref(), Some("outline"));
    assert_eq!(log(&mut m), BEC);
    m.set_size(99.0);
    assert_eq!(m.selected_preset_id(), None);
    let before = log(&mut m).len();
    m.apply_preset("does-not-exist");
    assert_eq!(log(&mut m).len() + before, before);
}

#[test]
fn save_preset() {
    let mut m = make(TextStyle::default());
    m.set_size(33.0);
    m.take_events();
    let id = m.save_current_as_preset("My Look");
    assert_eq!(id.as_deref(), Some("my-look"));
    assert_eq!(m.library().style(Some("my-look")).size, 33.0);
    assert_eq!(m.selected_preset_id().as_deref(), Some("my-look"));
    let saved = m.take_events().into_iter().filter(|e| matches!(e, TextInspectorEvent::PresetsChanged(_))).count();
    assert_eq!(saved, 1);
    m.set_size(34.0);
    let id2 = m.save_current_as_preset("My Look");
    assert!(id2.is_some() && id2 != id && id2.as_deref().is_some_and(|i| m.library().has_style(i)));
    assert_eq!(m.save_current_as_preset("   "), None);
}

#[test]
fn animation_pickers() {
    let mut m = make(TextStyle::default());
    assert!(m.in_animation_ids().contains(&"pop-in".to_string()) && m.in_animation_ids().contains(&"none".to_string()));
    assert!(
        m.out_animation_ids().contains(&"fade-out".to_string())
            && !m.out_animation_ids().contains(&"pop-in".to_string())
    );
    assert_eq!(m.selected_in_id().as_deref(), Some("none"));
    assert_eq!(m.selected_out_id().as_deref(), Some("none"));
    m.set_in_animation("pop-in");
    assert_eq!(m.animations().animation_in, Some(CaptionPresetLibrary::built_in().animation(Some("pop-in"))));
    assert_eq!(m.selected_in_id().as_deref(), Some("pop-in"));
    m.set_out_animation("fade-out");
    assert_eq!(m.selected_out_id().as_deref(), Some("fade-out"));
    m.set_out_animation("none");
    assert_eq!(m.animations().animation_out, None);
    let events = m.take_events();
    let last_set =
        events.iter().rev().find_map(|e| if let TextInspectorEvent::Change(_, a, _) = e { Some(a) } else { None });
    assert!(last_set.is_some_and(|a| a.animation_in.is_some()));
    assert_eq!(events.iter().filter(|e| **e == TextInspectorEvent::BeginEditing).count(), 3);
}

#[test]
fn zone_lengths_are_bounded_by_the_clip_and_keep_the_preset() {
    let mut m = make(TextStyle::default());
    m.set_in_animation("pop-in");
    m.set_out_animation("fade-out");
    m.clip_duration = Some(Time::new(2, 1));
    let out = m.zone_milliseconds(AnimationSide::Outro).unwrap_or(0);
    assert!(out > 0 && m.zone_milliseconds(AnimationSide::Intro).is_some());
    m.set_zone_length(5_000, AnimationSide::Intro);
    assert_eq!(m.zone_milliseconds(AnimationSide::Intro), Some(2_000 - out));
    assert_eq!(m.zone_milliseconds(AnimationSide::Outro), Some(out));
    m.set_zone_length(10, AnimationSide::Outro);
    assert_eq!(m.zone_milliseconds(AnimationSide::Outro), Some(TextInspectorModel::MINIMUM_ZONE_MILLISECONDS));
    assert_eq!(m.selected_in_id().as_deref(), Some("pop-in"));
    assert_eq!(m.selected_out_id().as_deref(), Some("fade-out"));
}

#[test]
fn font_families_includes_current_if_missing() {
    let m = make(named("Helvetica-Bold", 48.0));
    assert_eq!(m.font_families(), ["Helvetica-Bold", "Helvetica", "Menlo"]);
}

#[test]
fn external_update_does_not_fire_callbacks() {
    let mut m = make(TextStyle::default());
    m.load(named("Inter", 20.0), AnimationSet::new(None, None));
    assert_eq!(m.style().size, 20.0);
    assert!(log(&mut m).is_empty());
}

#[test]
fn applying_a_look_is_one_undo_step_and_sets_style_and_animation() {
    let mut m = make(TextStyle::default());
    let Some(pop) = CaptionStyleLooks::look("pop") else { panic!("no pop look") };
    m.apply_look(pop);
    assert_eq!(log(&mut m), BEC);
    assert_eq!(*m.style(), CaptionPresetLibrary::built_in().style(Some("title")));
    assert_eq!(m.animations().animation_in, Some(CaptionPresetLibrary::built_in().animation(Some("pop"))));
    assert_eq!(m.current_look_id().as_deref(), Some("pop"));
    m.apply_look(pop);
    assert!(log(&mut m).is_empty());
}

#[test]
fn an_exit_look_keeps_the_entrance_and_editing_leaves_the_look() {
    let mut m = make(TextStyle::default());
    let (Some(pop), Some(shrink)) = (CaptionStyleLooks::look("pop"), CaptionStyleLooks::look("shrink-out")) else {
        panic!("looks missing")
    };
    m.apply_look(pop);
    m.apply_look(shrink);
    assert!(m.animations().animation_in.is_some());
    assert_eq!(m.animations().animation_out.as_ref().map(|t| t.anchor), Some(AnimationAnchor::End));
    m.set_size(12.0);
    assert!(m.style().size == 12.0 && m.current_look_id().is_none());
}

// MARK: Animators

fn side_in() -> AnimatorSide {
    AnimatorSide::In
}

#[test]
fn choosing_an_effect_creates_an_animator_with_defaults() {
    let mut m = make(TextStyle::default());
    m.set_animator_effect(Some(TextAnimatorEffect::Fade), side_in());
    let a = m.animator(side_in()).cloned();
    assert_eq!(a.as_ref().map(|a| (a.effect, a.unit)), Some((TextAnimatorEffect::Fade, TextAnimatorUnit::Word)));
    assert_eq!(a.as_ref().map(|a| (a.duration, a.stagger)), Some((Time::new(3, 10), Time::new(2, 25))));
    assert_eq!(m.animations().animation_in.as_ref().map(|t| t.anchor), Some(AnimationAnchor::Start));
    assert_eq!(log(&mut m), BEC);
    m.set_animator_effect(Some(TextAnimatorEffect::Typewriter), AnimatorSide::Out);
    assert_eq!(m.animations().animation_out.as_ref().map(|t| t.anchor), Some(AnimationAnchor::End));
    assert_eq!(m.animator(AnimatorSide::Out).map(|a| a.effect), Some(TextAnimatorEffect::Typewriter));
}

#[test]
fn distance_and_blur_are_editable_and_clamped() {
    let mut m = make(TextStyle::default());
    m.set_animator_effect(Some(TextAnimatorEffect::Slide), side_in());
    m.set_animator_distance(120.0, side_in());
    m.set_animator_blur_radius(-5.0, side_in());
    assert_eq!(m.animator(side_in()).map(|a| (a.distance, a.blur_radius)), Some((120.0, 0.0)));
    m.set_animator_distance(f64::NAN, side_in());
    assert_eq!(m.animator(side_in()).map(|a| a.distance), Some(40.0));
    m.set_animator_distance(99_999.0, side_in());
    assert_eq!(m.animator(side_in()).map(|a| a.distance), Some(2000.0));
}

#[test]
fn pop_defaults_to_overshoot() {
    let mut m = make(TextStyle::default());
    m.set_animator_effect(Some(TextAnimatorEffect::Pop), side_in());
    assert_eq!(m.animator(side_in()).map(|a| a.easing), Some(SegmentShape::Overshoot));
}

#[test]
fn millisecond_fields_are_rational() {
    let mut m = make(TextStyle::default());
    m.set_animator_effect(Some(TextAnimatorEffect::Slide), side_in());
    m.set_animator_duration(450, side_in());
    m.set_animator_stagger(33, side_in());
    assert_eq!(m.animator(side_in()).map(|a| a.duration), Some(Time::new(450, 1000)));
    assert_eq!(m.animator(side_in()).map(|a| a.stagger), Some(Time::new(33, 1000)));
    assert_eq!(TextInspectorModel::animator_milliseconds(Time::new(1001, 30000)), 33);
    m.set_animator_stagger(-5, side_in());
    assert_eq!(m.animator(side_in()).map(|a| a.stagger), Some(Time::ZERO));
}

#[test]
fn millisecond_input_is_sanitized() {
    assert_eq!(TextInspectorModel::milliseconds(f64::INFINITY), 0);
    assert_eq!(TextInspectorModel::milliseconds(f64::NEG_INFINITY), 0);
    assert_eq!(TextInspectorModel::milliseconds(f64::NAN), 0);
    assert_eq!(TextInspectorModel::milliseconds(1e30), 60_000);
    assert_eq!(TextInspectorModel::milliseconds(12.6), 13);
    let mut m = make(TextStyle::default());
    m.set_animator_effect(Some(TextAnimatorEffect::Fade), side_in());
    m.set_animator_duration(i64::MAX, side_in());
    m.set_animator_stagger(i64::MAX, side_in());
    assert_eq!(m.animator(side_in()).map(|a| (a.duration, a.stagger)), Some((Time::new(60, 1), Time::new(60, 1))));
}

#[test]
fn unit_order_easing_edits() {
    let mut m = make(TextStyle::default());
    m.set_animator_effect(Some(TextAnimatorEffect::Blur), side_in());
    m.set_animator_unit(TextAnimatorUnit::Character, side_in());
    m.set_animator_order(TextAnimatorOrder::Center, side_in());
    m.set_animator_easing(SegmentShape::EaseInOut, side_in());
    let a = m.animator(side_in()).cloned();
    assert_eq!(
        a.map(|a| (a.unit, a.order, a.easing, a.effect)),
        Some((
            TextAnimatorUnit::Character,
            TextAnimatorOrder::Center,
            SegmentShape::EaseInOut,
            TextAnimatorEffect::Blur
        ))
    );
    m.set_animator_unit(TextAnimatorUnit::Line, AnimatorSide::Out);
    assert!(m.animator(AnimatorSide::Out).is_none());
}

#[test]
fn removing_the_effect_drops_an_animator_only_template() {
    let mut m = make(TextStyle::default());
    m.set_animator_effect(Some(TextAnimatorEffect::Fade), side_in());
    m.set_animator_effect(None, side_in());
    assert_eq!(m.animations().animation_in, None);
}

#[test]
fn preset_and_animator_live_side_by_side() {
    let mut m = make(TextStyle::default());
    m.set_in_animation("pop-in");
    m.set_animator_effect(Some(TextAnimatorEffect::Fade), side_in());
    assert_eq!(m.selected_in_id().as_deref(), Some("pop-in"));
    assert!(m.animations().animation_in.as_ref().is_some_and(|t| !t.tracks.is_empty()));
    assert_eq!(m.animator(side_in()).map(|a| a.effect), Some(TextAnimatorEffect::Fade));
    m.set_in_animation("fade");
    assert_eq!(m.selected_in_id().as_deref(), Some("fade"));
    assert_eq!(m.animator(side_in()).map(|a| a.effect), Some(TextAnimatorEffect::Fade));
    m.set_animator_effect(None, side_in());
    assert_eq!(m.selected_in_id().as_deref(), Some("fade"));
    assert!(m.animator(side_in()).is_none());
    m.set_animator_effect(Some(TextAnimatorEffect::Slide), side_in());
    m.set_in_animation("none");
    assert_eq!(m.animator(side_in()).map(|a| a.effect), Some(TextAnimatorEffect::Slide));
    assert!(m.animations().animation_in.as_ref().is_some_and(|t| t.tracks.is_empty()));
    assert_eq!(m.selected_in_id().as_deref(), Some("none"));
}

// MARK: Layout and fill

fn fill_model() -> TextInspectorModel {
    make(TextStyle::new("Helvetica", 40.0, FontWeight::Regular, RGBAColor::WHITE))
}

#[test]
fn auto_fit_and_list_toggle() {
    let mut m = fill_model();
    m.set_auto_fit(true);
    assert!(m.style().auto_fit == Some(true) && m.auto_fit_enabled());
    m.set_auto_fit(false);
    assert_eq!(m.style().auto_fit, None);
    m.set_list(Some(TextListKind::Numbered));
    assert_eq!(m.style().list, Some(TextListKind::Numbered));
    m.set_list(None);
    assert_eq!(m.style().list, None);
}

#[test]
fn gradient_starts_from_the_fill_and_is_remembered() {
    let mut m = fill_model();
    m.set_gradient_enabled(true);
    let g = m.style().gradient.unwrap_or_else(|| panic!("no gradient"));
    assert!(g.start == RGBAColor::WHITE && g.end == RGBAColor::BLACK && g.angle == 90.0);
    m.set_gradient_angle(45.0);
    m.set_gradient_end(RGBAColor::rgb(1.0, 0.0, 0.0));
    m.set_gradient_enabled(false);
    assert!(m.style().gradient.is_none());
    m.set_gradient_enabled(true);
    assert_eq!(m.style().gradient.map(|g| (g.angle, g.end)), Some((45.0, RGBAColor::rgb(1.0, 0.0, 0.0))));
}

// MARK: Second line

fn second_line_model() -> TextInspectorModel {
    make(TextStyle::new("Helvetica", 40.0, FontWeight::Regular, RGBAColor::WHITE))
}

#[test]
fn enabling_starts_big_and_bold_from_the_clip_style() {
    let mut m = second_line_model();
    assert!(!m.second_line_enabled());
    m.set_second_line_enabled(true);
    let l = m.style().second_line.clone().unwrap_or_else(|| panic!("no second line"));
    assert!(m.second_line_enabled());
    assert!(l.font_name == "Helvetica" && l.color == m.style().color);
    assert_eq!(l.size, 80.0);
    assert_eq!(l.weight, FontWeight::Bold);
    assert_eq!(log(&mut m), BEC);
}

#[test]
fn disabling_remembers_the_last_look_for_the_next_enable() {
    let mut m = second_line_model();
    m.set_second_line_enabled(true);
    m.set_second_line_size(150.0);
    m.set_second_line_enabled(false);
    assert!(m.style().second_line.is_none());
    m.set_second_line_enabled(true);
    assert_eq!(m.style().second_line.as_ref().map(|l| l.size), Some(150.0));
}

#[test]
fn each_second_line_value_is_one_edit() {
    let mut m = second_line_model();
    m.set_second_line_enabled(true);
    m.take_events();
    m.set_second_line_font("Menlo");
    m.set_second_line_weight(FontWeight::Black);
    m.set_second_line_size(0.0);
    m.set_second_line_color(RGBAColor::rgb(1.0, 0.0, 0.0));
    m.set_second_line_italic(true);
    assert_eq!(log(&mut m), BEC.repeat(5));
    let l = m.style().second_line.clone().unwrap_or_else(|| panic!("no second line"));
    assert!(l.font_name == "Menlo" && l.weight == FontWeight::Black && l.size == 1.0 && l.italic);
    assert_eq!(l.color, RGBAColor::rgb(1.0, 0.0, 0.0));
    assert!(m.style().font_name == "Helvetica" && m.style().size == 40.0);
}

#[test]
fn second_line_setters_do_nothing_while_off() {
    let mut m = second_line_model();
    m.set_second_line_size(90.0);
    m.set_second_line_color(RGBAColor::BLACK);
    assert!(m.style().second_line.is_none());
    assert!(log(&mut m).is_empty());
}

#[test]
fn loading_a_style_with_a_second_line_shows_it() {
    let mut m = second_line_model();
    let mut s = named("Inter", 30.0);
    s.second_line = Some(TextLineStyle::new("Menlo", 99.0, FontWeight::Heavy, RGBAColor::WHITE, false));
    m.load(s, AnimationSet::new(None, None));
    assert!(m.second_line_enabled() && m.style().second_line.as_ref().map(|l| l.size) == Some(99.0));
    assert!(log(&mut m).is_empty());
}

// MARK: Kit tokens

fn token_model(kit: Option<StyleKit>) -> TextInspectorModel {
    let s = TextStyle { font_name: "Menlo".into(), color: RGBAColor::BLACK, ..TextStyle::default() };
    let mut m = make(s);
    m.kit = kit;
    m
}

#[test]
fn token_names_come_from_the_kit() {
    let m = token_model(Some(StyleKit::starter()));
    assert_eq!(m.token_names(TokenField::Font), [BRAND_FONT_TOKEN]);
    assert_eq!(m.token_names(TokenField::Color), [PILL_COLOR_TOKEN, TEXT_COLOR_TOKEN]);
    assert!(token_model(None).token_names(TokenField::Font).is_empty());
}

#[test]
fn binding_takes_the_token_value_and_records_the_binding() {
    let mut m = token_model(Some(StyleKit::starter()));
    m.bind_token(TokenField::Font, Some(BRAND_FONT_TOKEN));
    m.bind_token(TokenField::Color, Some(TEXT_COLOR_TOKEN));
    assert!(m.style().font_name == TextStyle::default_font_name() && m.style().color == RGBAColor::WHITE);
    assert_eq!(m.bound_token(TokenField::Font).as_deref(), Some(BRAND_FONT_TOKEN));
    assert_eq!(m.bound_token(TokenField::Color).as_deref(), Some(TEXT_COLOR_TOKEN));
}

#[test]
fn manual_choice_releases_and_none_releases() {
    let mut m = token_model(Some(StyleKit::starter()));
    m.bind_token(TokenField::Color, Some(TEXT_COLOR_TOKEN));
    m.bind_token(TokenField::Color, None);
    assert!(m.bound_token(TokenField::Color).is_none() && m.style().color == RGBAColor::WHITE);
    m.bind_token(TokenField::Font, Some(BRAND_FONT_TOKEN));
    m.set_font_family("Menlo");
    assert!(m.bound_token(TokenField::Font).is_none() && m.style().tokens.is_none());
}

#[test]
fn unknown_token_and_missing_stroke_are_ignored() {
    let mut m = token_model(Some(StyleKit::starter()));
    m.bind_token(TokenField::Font, Some("nope"));
    m.bind_token(TokenField::StrokeColor, Some(TEXT_COLOR_TOKEN));
    assert!(m.style().tokens.is_none());
    m.set_stroke_enabled(true);
    m.bind_token(TokenField::StrokeColor, Some(TEXT_COLOR_TOKEN));
    assert_eq!(m.style().stroke.map(|s| s.color), Some(RGBAColor::WHITE));
    assert_eq!(m.bound_token(TokenField::StrokeColor).as_deref(), Some(TEXT_COLOR_TOKEN));
}

#[test]
fn binding_is_one_undo_step() {
    let mut m = token_model(Some(StyleKit::starter()));
    m.bind_token(TokenField::Font, Some(BRAND_FONT_TOKEN));
    let events: Vec<_> = m
        .take_events()
        .into_iter()
        .filter(|e| matches!(e, TextInspectorEvent::BeginEditing | TextInspectorEvent::EndEditing))
        .collect();
    assert_eq!(events, [TextInspectorEvent::BeginEditing, TextInspectorEvent::EndEditing]);
}

// MARK: Multi-select

fn mixed(paths: &[&str]) -> TextInspectorModel {
    let mut m = make(TextStyle::default());
    m.mixed_paths = paths.iter().map(|p| p.to_string()).collect();
    m
}

#[test]
fn colour_is_mixed_when_a_channel_differs() {
    assert!(mixed(&["style.color.red"]).is_mixed_color("color"));
    assert!(mixed(&["style.shadow.color.blue"]).is_mixed_color("shadow.color"));
    assert!(!mixed(&["style.color.alpha"]).is_mixed_color("color"));
    assert!(!mixed(&["style.size"]).is_mixed_color("color"));
    assert!(mixed(&["style.stroke"]).is_mixed_color("stroke.color"));
}

#[test]
fn layer_switch_is_mixed_only_when_presence_differs() {
    assert!(mixed(&["style.shadow"]).is_mixed_presence("shadow"));
    assert!(!mixed(&["style.shadow.blur"]).is_mixed_presence("shadow"));
    assert!(!mixed(&[]).is_mixed_presence("background"));
}

#[test]
fn empty_when_one_clip() {
    let m = mixed(&[]);
    assert!(!m.is_mixed_color("color") && !m.is_mixed_presence("stroke") && !m.is_mixed("italic"));
}

#[test]
fn mixed_paths_of_two_styles_drive_the_controls() {
    let mut sa = TextStyle::new("Inter", 48.0, FontWeight::Regular, RGBAColor::WHITE);
    sa.italic = true;
    let mut sb = TextStyle::new("Inter", 48.0, FontWeight::Regular, RGBAColor::BLACK);
    sb.stroke = Some(TextStroke::new(RGBAColor::BLACK, 2.0, StrokePosition::Outside));
    let a = TextTemplate::new("A", "x", sa);
    let b = TextTemplate::new("B", "x", sb);
    let paths = CodableMerge::differing_paths(&[a, b]).unwrap_or_else(|e| panic!("{e}"));
    let mut m = make(TextStyle::default());
    m.mixed_paths = paths;
    assert!(m.is_mixed_color("color"));
    assert!(m.is_mixed("italic"));
    assert!(m.is_mixed_presence("stroke"));
    assert!(!m.is_mixed("alignment"));
}

#[test]
fn unchanged_edit_of_a_mixed_field_still_fires_with_forced_paths() {
    let mut m = mixed(&["style.italic", "style.color.red"]);
    let mut fired: Vec<BTreeSet<String>> = Vec::new();
    let mut collect = |m: &mut TextInspectorModel| {
        for e in m.take_events() {
            if let TextInspectorEvent::Change(_, _, forced) = e {
                fired.push(forced);
            }
        }
    };
    let italic = m.style().italic;
    m.set_italic(italic);
    collect(&mut m);
    let color = m.style().color;
    m.set_color(color);
    collect(&mut m);
    let alignment = m.style().alignment;
    m.set_alignment(alignment);
    collect(&mut m);
    let want = |p: &str| BTreeSet::from([p.to_string()]);
    assert_eq!(fired, [want("style.italic"), want("style.color.red")]);
}

// Swift test: CaptionLookTests / CustomAnimationTests (saveCustomAnimation)
struct FakeStore {
    saved: std::cell::RefCell<Vec<sq_core_effects::keystone::Keystone>>,
    accepts: bool,
}

impl crate::ec::animation::AnimationKeystoneSource for FakeStore {
    fn offered_animations(&self, side: AnimationSide) -> Vec<sq_core_effects::keystone::Keystone> {
        use sq_core_graphics::custom_animation::KeystoneAnimationExt;
        self.saved.borrow().iter().filter(|k| k.animation_side() == Some(side)).cloned().collect()
    }
    fn can_save(&self) -> bool {
        self.accepts
    }
    fn save(&self, keystone: sq_core_effects::keystone::Keystone) -> bool {
        if self.accepts {
            self.saved.borrow_mut().push(keystone);
        }
        self.accepts
    }
}

/// Ids like a real session's (the high bits set), so a hand-made key is recognized as the side's own.
struct HighIds(u128);

impl sq_core_time::IdSource for HighIds {
    fn next_id(&mut self) -> sq_core_time::Id {
        self.0 += 1;
        sq_core_time::Id::from_u128((0xABCD_u128 << 100) + self.0)
    }
}

fn make_real_ids() -> TextInspectorModel {
    TextInspectorModel::new(
        TextStyle::default(),
        AnimationSet::new(None, None),
        Some(CaptionPresetLibrary::built_in()),
        Box::new(Vec::new),
        TextStyleLibrary::default(),
        Box::new(HighIds(0)),
    )
}

#[test]
fn saving_a_custom_side_stores_a_keystone_and_shows_it() {
    let store = std::rc::Rc::new(FakeStore { saved: Default::default(), accepts: true });
    let mut m = make_real_ids();
    m.keystones = Some(std::rc::Rc::<FakeStore>::clone(&store));
    assert!(!m.save_custom_animation(AnimationSide::Intro, "Mine"), "a side that is Off is not Custom");
    m.make_custom(AnimationSide::Intro);
    assert!(m.can_save_animations());
    assert!(m.is_custom(AnimationSide::Intro), "make_custom makes the side Custom");
    assert!(m.save_custom_animation(AnimationSide::Intro, "Mine"));
    let saved = store.saved.borrow();
    assert_eq!(saved.len(), 1);
    assert_eq!(saved[0].name, "Mine");
    let id = m.selected_in_id().expect("the side now shows the saved animation");
    assert_eq!(id, format!("mine:{}", saved[0].id));
    assert!(!m.is_custom(AnimationSide::Intro) || m.selected_in_id().is_some());
}

#[test]
fn a_refused_save_leaves_the_side_custom() {
    let store = std::rc::Rc::new(FakeStore { saved: Default::default(), accepts: false });
    let mut m = make_real_ids();
    m.keystones = Some(std::rc::Rc::<FakeStore>::clone(&store));
    m.make_custom(AnimationSide::Outro);
    let before = m.animations().clone();
    assert!(!m.save_custom_animation(AnimationSide::Outro, "Nope"));
    assert_eq!(m.animations(), &before);
    assert!(store.saved.borrow().is_empty());
    // no Library at all
    let mut bare = make_real_ids();
    bare.make_custom(AnimationSide::Outro);
    assert!(!bare.save_custom_animation(AnimationSide::Outro, "Nope"));
}

#[test]
fn the_installed_family_list_has_the_bundled_fonts_sorted_and_once() {
    let all = super::inspector_model::TextBoxDefaults::installed_families();
    assert!(all.iter().any(|f| f == "Inter"), "the bundled Inter is listed");
    let lower: Vec<String> = all.iter().map(|f| f.to_lowercase()).collect();
    let mut sorted = lower.clone();
    sorted.sort();
    sorted.dedup();
    assert_eq!(lower, sorted, "sorted case-insensitively, each family once");
}
