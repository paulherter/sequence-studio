//! Draw-list asserts of the stone controls against the component specs (`01-Controls/*.json`, Dark unless noted):
//! fill, edge, shadow tokens and sizes per state, and the press / hover timing on the motion state machine.

use super::*;
use crate::draw_list::{DrawQuad, QuadKind};
use crate::stone_controls::{SLIDER_KNOB, SWITCH_KNOB, SWITCH_KNOB_PRESSED};
use sq_uikit::appearance_palette::{AppearanceMode, AppearanceSettings};

fn h(c: Color) -> u32 {
    let b = |v: f32| (v.clamp(0.0, 1.0) * 255.0).round() as u32;
    b(c.r) << 24 | b(c.g) << 16 | b(c.b) << 8 | b(c.a)
}
fn ho(c: Option<Color>) -> Option<u32> {
    c.map(h)
}
fn dark() -> DrawTheme {
    DrawTheme::default()
}
fn light() -> DrawTheme {
    DrawTheme::new(&AppearanceSettings::new(AppearanceMode::Light, 0, 50), 1.0)
}
fn grad(l: &Look) -> (u32, u32) {
    match l.fill {
        Fill::Gradient(a, b) => (h(a), h(b)),
        other => panic!("not a gradient: {other:?}"),
    }
}
fn flat(l: &Look) -> u32 {
    match l.fill {
        Fill::Flat(c) => h(c),
        other => panic!("not flat: {other:?}"),
    }
}
fn canvas() -> Canvas<'static> {
    Canvas::with_size(200.0, 100.0, None, 1.0)
}
fn quads(c: &Canvas) -> Vec<DrawQuad> {
    c.list.quads().to_vec()
}
fn fills_of(c: &Canvas, r: CGRect, radius: f32) -> Vec<DrawQuad> {
    quads(c)
        .into_iter()
        .filter(|q| {
            q.kind == QuadKind::Shape
                && q.stroke == 0.0
                && (q.rect.x, q.rect.y, q.rect.w, q.rect.h) == (r.x as f32, r.y as f32, r.width as f32, r.height as f32)
                && q.radius == radius
        })
        .collect()
}
fn near(a: u32, b: u32, tol: u32) -> bool {
    (0..4).all(|i| {
        let s = 8 * i;
        ((a >> s) & 0xFF).abs_diff((b >> s) & 0xFF) <= tol
    })
}
fn rest() -> Touch {
    Touch::default()
}

#[test]
fn raised_button_looks_match_the_spec() {
    let t = dark();
    let l = button_look(ButtonKind::Raised, Interaction::Rest, &t);
    assert_eq!(grad(&l), (0x3C3C40FF, 0x333337FF));
    assert_eq!((ho(l.top_light), ho(l.shadow), l.ring, l.inset_soft), (Some(0xFFFFFF14), Some(0x00000080), None, None));
    let l = button_look(ButtonKind::Raised, Interaction::Hover, &t);
    assert_eq!(grad(&l), (0x424246FF, 0x38383CFF));
    let l = button_look(ButtonKind::Raised, Interaction::Pressed, &t);
    assert_eq!(grad(&l), (0x2C2C30FF, 0x333337FF));
    assert_eq!((ho(l.inset_soft), ho(l.lift), l.shadow, l.top_light), (Some(0x0000008C), Some(0xFFFFFF0A), None, None));
}

#[test]
fn menu_accent_destructive_and_quiet_looks_match_the_spec() {
    let t = dark();
    assert_eq!(grad(&button_look(ButtonKind::RaisedMenu, Interaction::Rest, &t)), (0x2E2E31FF, 0x28282BFF));
    assert_eq!(grad(&button_look(ButtonKind::RaisedMenu, Interaction::Hover, &t)), (0x333336FF, 0x2C2C2FFF));
    let a = button_look(ButtonKind::Accent, Interaction::Rest, &t);
    assert_eq!(grad(&a), (0x1C8BFFFF, 0x0A6CF0FF));
    assert_eq!((ho(a.top_light), ho(a.ring), ho(a.shadow)), (Some(0xFFFFFF38), Some(0x0000002E), Some(0x00000080)));
    assert_eq!(grad(&button_look(ButtonKind::Accent, Interaction::Hover, &t)), (0x1F99FFFF, 0x0B77FFFF));
    let p = button_look(ButtonKind::Accent, Interaction::Pressed, &t);
    assert_eq!((grad(&p), ho(p.inset_soft)), ((0x0A62DAFF, 0x1478F5FF), Some(0x00000073)));
    let d = button_look(ButtonKind::Destructive, Interaction::Rest, &t);
    assert_eq!((grad(&d), ho(d.top_light)), ((0xE0443AFF, 0xC93A31FF), Some(0xFFFFFF2E)));
    assert_eq!(grad(&button_look(ButtonKind::Destructive, Interaction::Pressed, &t)), (0xBC352DFF, 0xD2433AFF));
    assert_eq!(button_look(ButtonKind::Quiet, Interaction::Rest, &t), Look::NONE);
    assert_eq!(flat(&button_look(ButtonKind::Quiet, Interaction::Hover, &t)), 0xFFFFFF0F);
    assert_eq!(flat(&button_look(ButtonKind::Quiet, Interaction::Pressed, &t)), 0x00000040);
}

#[test]
fn field_looks_match_the_spec_and_light_uses_the_light_tokens() {
    let t = dark();
    let r = field_look(FieldState::Rest, &t);
    assert_eq!(flat(&r), 0x17171AFF);
    assert_eq!((ho(r.ring), ho(r.inset_soft), ho(r.lift)), (Some(0x00000080), Some(0x00000059), Some(0xFFFFFF0B)));
    assert_eq!(ho(field_look(FieldState::Hover, &t).ring), Some(0xFFFFFF1F));
    let e = field_look(FieldState::Editing, &t);
    assert_eq!((ho(e.ring), ho(e.halo), e.inset_soft, e.lift), (Some(0x0A84FFFF), Some(0x0A84FF38), None, None));
    assert_eq!(grad(&button_look(ButtonKind::Raised, Interaction::Rest, &light())), (0xFFFFFFFF, 0xF2F2F4FF));
    assert_eq!(flat(&field_look(FieldState::Rest, &light())), 0xFFFFFFFF);
}

#[test]
fn disabled_is_forty_percent_of_every_layer() {
    let l = button_look(ButtonKind::Accent, Interaction::Rest, &dark()).faded(DISABLED_ALPHA);
    assert_eq!(grad(&l).0 & 0xFF, 102);
    assert_eq!(ho(l.shadow).map(|c| c & 0xFF), Some(51));
}

#[test]
fn a_raised_button_draws_gradient_bands_highlight_and_shadow_at_the_spec_size() {
    motion::set_snap(true);
    let t = dark();
    let mut c = canvas();
    let r = CGRect::new(10.0, 10.0, 60.0, 22.0);
    c.stone_button(r, ButtonKind::Raised, rest(), &t);
    let bands: Vec<_> = fills_of(&c, r, 4.0).into_iter().filter(|q| q.color.a == 1.0).collect();
    assert!(bands.len() >= 6 && bands.len() <= 22, "banded gradient: {}", bands.len());
    assert!(near(h(bands[0].color), 0x3C3C40FF, 2), "top {:08X}", h(bands[0].color));
    assert!(near(h(bands[bands.len() - 1].color), 0x333337FF, 2));
    // The highlight edge: the same rounded rect in #FFFFFF14, clipped to the top point.
    let top = quads(&c).into_iter().find(|q| h(q.color) == 0xFFFFFF14 && q.stroke == 0.0).expect("top light");
    assert_eq!((top.clip[1], top.clip[3]), (10.0, 11.0));
    // The shadow lies below the body in black.
    assert!(quads(&c).iter().any(|q| q.color.r == 0.0 && q.color.a > 0.0 && q.rect.max_y() > 32.0));
}

#[test]
fn pressed_button_is_scaled_to_97_percent_and_nudged_half_a_point() {
    motion::set_snap(false);
    let r = CGRect::new(0.0, 0.0, 100.0, 22.0);
    let p = pressed_rect(r, 1.0);
    assert!((p.width - 97.0).abs() < 1e-9 && (p.height - 21.34).abs() < 1e-9);
    assert!((p.mid_x() - 50.0).abs() < 1e-9 && (p.mid_y() - 11.5).abs() < 1e-9);
    assert_eq!(pressed_rect(r, 0.0), r);
    motion::set_reduce_motion(true);
    assert_eq!(pressed_rect(r, 1.0), r, "reduce motion: no scale, no offset");
    motion::set_reduce_motion(false);
}

#[test]
fn press_rises_in_60_ms_and_falls_in_160_ms_ease_out() {
    motion::set_snap(false);
    motion::set_reduce_motion(false);
    let c = canvas();
    let r = CGRect::new(0.0, 0.0, 40.0, 22.0);
    motion::begin_frame(10.0);
    assert_eq!(press_level(&c, r, false), 0.0);
    motion::begin_frame(10.1);
    press_level(&c, r, true);
    motion::begin_frame(10.13);
    assert!((press_level(&c, r, true) - 0.5).abs() < 0.01, "linear halfway at 30 ms");
    motion::begin_frame(10.16);
    assert_eq!(press_level(&c, r, true), 1.0, "down after 60 ms");
    motion::begin_frame(10.2);
    press_level(&c, r, false);
    motion::begin_frame(10.28);
    let mid = press_level(&c, r, false);
    assert!(mid < 0.1 && mid > 0.0, "ease-out: mostly released at 80 of 160 ms ({mid})");
    motion::begin_frame(10.36);
    assert_eq!(press_level(&c, r, false), 0.0, "up after 160 ms");
}

#[test]
fn hover_is_whole_on_the_first_frame_in_and_gone_on_the_first_frame_out() {
    motion::set_snap(false);
    motion::set_reduce_motion(false);
    motion::begin_frame(20.0);
    assert_eq!(hover_level(false), 0.0);
    motion::begin_frame(20.1);
    assert_eq!(hover_level(true), 1.0, "the first frame after the pointer enters is full");
    assert!(!motion::needs_frame(), "no fade, so no frame is asked for");
    motion::begin_frame(20.11);
    assert_eq!(hover_level(false), 0.0, "the first frame after it leaves is zero");
    assert!(!motion::needs_frame());
}

#[test]
fn a_hovered_button_row_and_close_x_show_the_hover_look_on_the_first_frame_without_asking_for_more() {
    motion::set_snap(false);
    motion::set_reduce_motion(false);
    let t = DrawTheme::default();
    let r = CGRect::new(0.0, 50.0, 80.0, 22.0);
    let drawn = |hover: bool, now: f64| {
        motion::begin_frame(now);
        let mut c = canvas();
        c.stone_button(r, ButtonKind::Quiet, Touch { hovering: hover, ..Touch::default() }, &t);
        c.stone_row_pill(r, false, hover, &t);
        c.close_x(r, crate::close_x::CloseXState { hovered: hover, ..Default::default() }, &t);
        (c.list.quads().iter().map(|q| u32::from(q.color.a > 0.0)).sum::<u32>(), motion::needs_frame())
    };
    let (rest, more) = drawn(false, 30.0);
    assert!(!more);
    let (hot, more) = drawn(true, 30.01);
    assert!(hot > rest, "hover adds fills on the very next frame: {rest} -> {hot}");
    assert!(!more, "and asks for no further frame");
    let (gone, more) = drawn(false, 30.02);
    assert!((gone, more) == (rest, false), "leaving takes them away on the next frame");
}

#[test]
fn motion_tokens_are_the_ones_of_the_hauptfenster_rules() {
    assert_eq!((mt::PRESS_IN_MS, mt::PRESS_OUT_MS, mt::HOVER_MS), (60.0, 160.0, 0.0), "hover has no duration");
    assert_eq!((mt::MENU_IN_MS, mt::MENU_OUT_MS), (140.0, 100.0));
    assert!((motion::duration::OPEN - f64::from(mt::MENU_IN_MS) / 1000.0).abs() < 1e-9);
    assert!((motion::duration::exit(motion::duration::OPEN) - f64::from(mt::MENU_OUT_MS) / 1000.0).abs() < 1e-9);
    assert_eq!(motion::OPEN_SCALE, 0.97);
    assert!((crate::ui_cx::TooltipLayout::DELAY - f64::from(mt::TOOLTIP_DELAY_MS) / 1000.0).abs() < 1e-9);
    assert!((crate::ui_cx::TooltipLayout::HAND_OVER_WINDOW - f64::from(mt::TOOLTIP_WARM_MS) / 1000.0).abs() < 1e-9);
    assert_eq!(crate::ui_cx::TooltipLayout::show_delay(5.0, Some(4.5)), 0.0, "warm: at once, no fade");
    assert_eq!(crate::ui_cx::TooltipLayout::show_delay(5.0, Some(3.0)), 0.6);
}

#[test]
fn focus_ring_is_two_points_wide_two_points_off_in_accent() {
    let t = dark();
    let mut c = canvas();
    let r = CGRect::new(20.0, 20.0, 50.0, 22.0);
    c.stone_focus_ring(r, 4.0, &t);
    let q = quads(&c).pop().unwrap();
    assert_eq!(h(q.color), 0x0A84FFFF);
    assert_eq!(
        (q.stroke, q.rect.x, q.rect.y, q.rect.w, q.rect.h),
        (2.0, 16.0, 16.0, 58.0, 30.0),
        "outer edge 4 pt off"
    );
    assert_eq!(q.radius, 8.0);
}

#[test]
fn field_draws_well_ring_and_editing_halo() {
    motion::set_snap(true);
    let t = dark();
    let r = CGRect::new(10.0, 10.0, 62.0, 20.0);
    let mut c = canvas();
    c.stone_field(r, 3.0, false, rest(), &t);
    assert_eq!(h(fills_of(&c, r, 3.0)[0].color), 0x17171AFF);
    assert!(quads(&c).iter().any(|q| h(q.color) == 0x00000080 && q.stroke == 1.0), "1 pt inner ring");
    let mut c = canvas();
    c.stone_field(r, 3.0, true, rest(), &t);
    assert!(quads(&c).iter().any(|q| h(q.color) == 0x0A84FFFF && q.stroke == 1.0), "accent ring");
    assert!(quads(&c).iter().any(|q| h(q.color) == 0x0A84FF38 && q.stroke == 3.0), "3 pt halo");
}

#[test]
fn switch_geometry_and_colors_match_the_spec() {
    motion::set_snap(true);
    let t = dark();
    let track = CGRect::new(10.0, 10.0, 34.0, 20.0);
    assert_eq!(Canvas::switch_knob_rect(track, 0.0, 0.0), CGRect::new(12.0, 12.0, 16.0, 16.0), "off: padding 2");
    assert_eq!(Canvas::switch_knob_rect(track, 1.0, 0.0), CGRect::new(26.0, 12.0, 16.0, 16.0), "on: right end");
    let p = Canvas::switch_knob_rect(track, 0.0, 1.0);
    assert_eq!((p.width, p.x), (SWITCH_KNOB_PRESSED, 12.0 + 0.5), "pressed: 15, padding 2.5");
    assert_eq!(SWITCH_KNOB, 16.0);
    let mut c = canvas();
    c.stone_switch(track, true, rest(), &t);
    assert_eq!(h(fills_of(&c, track, 10.0)[0].color), 0x0A6CF0FF, "on: accent fill, radius 10");
    let mut c = canvas();
    c.stone_switch(track, false, rest(), &t);
    assert_eq!(h(fills_of(&c, track, 10.0)[0].color), 0x17171AFF, "off: well");
    let knob = CGRect::new(12.0, 12.0, 16.0, 16.0);
    let bands = fills_of(&c, knob, 8.0);
    assert!(near(h(bands[0].color), 0xF4F4F6FF, 2) && near(h(bands[bands.len() - 1].color), 0xD6D6DAFF, 2));
}

#[test]
fn checkbox_radio_and_slider_sizes_and_fills() {
    motion::set_snap(true);
    let t = dark();
    let b = CGRect::new(10.0, 10.0, 14.0, 14.0);
    let mut c = canvas();
    c.stone_checkbox(b, true, rest(), &t);
    assert_eq!(h(fills_of(&c, b, 3.0)[0].color), 0x0A6CF0FF, "on: accent fill, radius field");
    let mut c = canvas();
    c.stone_checkbox(b, false, rest(), &t);
    assert_eq!(h(fills_of(&c, b, 3.0)[0].color), 0x17171AFF);
    let rr = CGRect::new(10.0, 40.0, 12.0, 12.0);
    let mut c = canvas();
    c.stone_radio(rr, true, rest(), &t);
    assert_eq!(h(fills_of(&c, rr, 6.0)[0].color), 0x0A6CF0FF);
    assert!(quads(&c).iter().any(|q| q.rect.w == 5.0 && h(q.color) == 0xFFFFFFFF), "5 pt dot");
    let s = CGRect::new(10.0, 60.0, 120.0, 12.0);
    let mut c = canvas();
    c.stone_slider_track(s, Some((10.0, 70.0)), rest(), &t);
    let track = CGRect::new(10.0, 64.0, 120.0, 4.0);
    assert_eq!(h(fills_of(&c, track, 2.0)[0].color), 0x17171AFF, "4 pt well track");
    assert!(quads(&c).iter().any(|q| q.rect.w == 60.0 && h(q.color) == 0x85858DFF), "text3 fill");
    let k = c.stone_slider_knob(70.0, 66.0, false, rest(), &t);
    assert_eq!((k.width, k.height), (SLIDER_KNOB, 12.0));
    assert_eq!(c.stone_slider_knob(70.0, 66.0, true, rest(), &t).width, 8.0, "no-fill knob is an 8 x 16 pill");
}

#[test]
fn segment_chip_and_tab_follow_the_spec() {
    motion::set_snap(true);
    let t = dark();
    let seg = CGRect::new(12.0, 12.0, 40.0, 16.0);
    let mut c = canvas();
    c.stone_segment(seg, true, rest(), &t);
    let bands = fills_of(&c, seg, 3.0);
    assert!(near(h(bands[0].color), 0x3C3C40FF, 2), "selected thumb is raised, radius field");
    let mut c = canvas();
    c.stone_segment(seg, false, rest(), &t);
    assert!(quads(&c).is_empty(), "an unselected segment has no surface at rest");
    let chip = CGRect::new(10.0, 10.0, 26.0, 18.0);
    let mut c = canvas();
    c.stone_chip(chip, false, true, rest(), &t);
    assert!(quads(&c).iter().any(|q| h(q.color) == 0xFFFFFF1A && q.stroke == 1.0), "off chip: 1 pt line2 edge");
    let mut c = canvas();
    c.stone_filter_chip(CGRect::new(10.0, 10.0, 50.0, 20.0), false, rest(), &t);
    assert!(
        quads(&c).iter().any(|q| h(q.color) == 0xFFFFFF1A && q.stroke == 1.0),
        "off filter chip: a bordered pill, not flat text"
    );
    let tab = CGRect::new(0.0, 0.0, 70.0, 28.0);
    let mut c = canvas();
    c.stone_tab_underline(tab, true, &t);
    let q = quads(&c).pop().unwrap();
    assert_eq!(
        (h(q.color), q.rect.h, q.rect.w, q.rect.y),
        (0x85858DFF, 2.0, 54.0, 26.0),
        "gray 2 pt underline, never blue"
    );
    let mut c = canvas();
    c.stone_tab_underline(tab, false, &t);
    assert!(quads(&c).is_empty());
}

#[test]
fn a_disabled_control_ignores_hover_and_press() {
    motion::set_snap(true);
    let t = dark();
    let r = CGRect::new(10.0, 10.0, 60.0, 22.0);
    let mut c = canvas();
    c.stone_button(r, ButtonKind::Raised, Touch { hovering: true, pressed: true, disabled: true, focused: false }, &t);
    let bands = fills_of(&c, r, 4.0);
    assert_eq!(bands[0].color.a, 0.4, "40 percent, not the pressed scale");
    assert!(near(h(bands[0].color) | 0xFF, 0x3C3C40FF, 2));
}

/// Renders the stone controls on black to `$SQ_STONE_SHEET/<name>.rgba` (`w h\n` then RGBA bytes) for the pixel comparison
/// with the component frames of the UI kit: `SQ_STONE_SHEET=dir cargo test -p sq-draw stone_sheet -- --ignored`.
#[test]
#[ignore = "writes files for the visual comparison"]
fn stone_sheet() {
    use crate::software::{SoftwareRenderer, Sources};
    let Ok(dir) = std::env::var("SQ_STONE_SHEET") else { return };
    motion::set_snap(true);
    let t = dark();
    let mut shots: Vec<(&str, Canvas)> = Vec::new();
    let mut add = |name: &'static str, f: &dyn Fn(&mut Canvas)| {
        let mut c = Canvas::with_size(100.0, 40.0, None, 1.0);
        f(&mut c);
        shots.push((name, c));
    };
    let b = CGRect::new(4.0, 4.0, 59.0, 22.0);
    add("Button-Raised-Default", &|c| {
        c.stone_button(b, ButtonKind::Raised, rest(), &t);
    });
    add("Button-Raised-Hover", &|c| {
        c.stone_button(b, ButtonKind::Raised, Touch { hovering: true, ..rest() }, &t);
    });
    add("Button-Raised-Pressed", &|c| {
        c.stone_button(b, ButtonKind::Raised, Touch { pressed: true, ..rest() }, &t);
    });
    let p = CGRect::new(4.0, 4.0, 84.0, 24.0);
    add("Button-Primary-Default", &|c| {
        c.stone_button(p, ButtonKind::Accent, rest(), &t);
    });
    let f = CGRect::new(4.0, 4.0, 62.0, 20.0);
    add("Field-Number-Default", &|c| c.stone_field(f, 3.0, false, rest(), &t));
    add("Field-Number-Editing", &|c| c.stone_field(f, 3.0, true, rest(), &t));
    let s = CGRect::new(4.0, 4.0, 34.0, 20.0);
    add("Switch-On", &|c| {
        c.stone_switch(s, true, rest(), &t);
    });
    add("Switch-Off", &|c| {
        c.stone_switch(s, false, rest(), &t);
    });
    let cb = CGRect::new(4.0, 4.0, 14.0, 14.0);
    add("Checkbox-On", &|c| c.stone_checkbox(cb, true, rest(), &t));
    let sg = CGRect::new(4.0, 4.0, 100.0, 24.0);
    add("Segmented-24-Two", &|c| {
        c.stone_segment_track(sg, rest(), &t);
        c.stone_segment(CGRect::new(6.0, 6.0, 48.0, 20.0), true, rest(), &t);
    });
    let sl = CGRect::new(4.0, 4.0, 120.0, 12.0);
    add("Slider-Fill", &|c| {
        c.stone_slider_track(sl, Some((4.0, 59.0)), rest(), &t);
        c.stone_slider_knob(65.0, 10.0, false, rest(), &t);
    });
    for (name, c) in shots {
        let img = SoftwareRenderer::render(&c.list, 100, 40, Color::BLACK, &Sources::default());
        let mut out = format!("{} {}\n", img.width, img.height).into_bytes();
        out.extend_from_slice(&img.pixels);
        std::fs::write(format!("{dir}/{name}.rgba"), out).unwrap();
    }
}

// ---- Shadow parameters pinned to the UI kit (specs/components/01-Controls, neu.html `#after.light`) ----

/// The kit's shadow numbers per kind: (dark rgba, light rgba). Chrome and the kit render them with sigma = blur / 2.
#[test]
fn stone_shadow_colors_are_the_kit_numbers_in_dark_and_light() {
    for (t, raised, ring, soft, lift, hover_ring) in [
        (dark(), 0x0000_0080, 0x0000_0080, 0x0000_0059, 0xFFFF_FF0B, 0xFFFF_FF1F),
        (light(), 0x0000_0024, 0x0000_0024, 0x0000_0014, 0xFFFF_FFCC, 0x0000_003D),
    ] {
        let r = button_look(ButtonKind::Raised, Interaction::Rest, &t);
        assert_eq!(ho(r.shadow), Some(raised));
        let f = field_look(FieldState::Rest, &t);
        assert_eq!((ho(f.ring), ho(f.inset_soft), ho(f.lift)), (Some(ring), Some(soft), Some(lift)));
        assert_eq!(ho(field_look(FieldState::Hover, &t).ring), Some(hover_ring));
    }
    assert_eq!(ho(button_look(ButtonKind::Raised, Interaction::Pressed, &dark()).inset_soft), Some(0x0000_008C));
    // The inset `0 1px 2px` (sigma 1) is the Gaussian averaged over the first three rows.
    assert_eq!(INSET_ROWS, [0.684, 0.316, 0.075]);
}

/// Pixel value (red channel, 8 bit) of column `x` (points) at rows `ys` (points; one sample per device row from `y`) after
/// drawing `draw` on `ground` at backing `scale`.
fn column_at(
    ground: u32,
    size: (usize, usize),
    scale: f32,
    x: usize,
    ys: &[usize],
    draw: impl Fn(&mut Canvas),
) -> Vec<u8> {
    motion::set_snap(true);
    let (w, h) = ((size.0 as f32 * scale) as usize, (size.1 as f32 * scale) as usize);
    let mut c = Canvas::with_size(w as f32, h as f32, None, scale);
    draw(&mut c);
    let img = crate::software::SoftwareRenderer::render_8bit(
        &c.list,
        w,
        h,
        Color::hex(ground, 1.0),
        &crate::software::Sources::default(),
    );
    ys.iter().map(|y| img.pixels[(y * w + x * scale as usize) * 4]).collect()
}

fn column(ground: u32, size: (usize, usize), x: usize, ys: &[usize], draw: impl Fn(&mut Canvas)) -> Vec<u8> {
    column_at(ground, size, 1.0, x, ys, draw)
}

fn within(got: &[u8], kit: &[u8], tol: u8) {
    assert!(got.iter().zip(kit).all(|(g, k)| g.abs_diff(*k) <= tol), "got {got:?}, kit {kit:?}");
}

/// Darkness (0..1) of black-on-ground rows.
fn darkness(got: &[u8], ground: u8) -> Vec<f32> {
    got.iter().map(|g| 1.0 - *g as f32 / ground as f32).collect()
}

fn near_f(got: &[f32], kit: &[f32], tol: f32) {
    assert!(got.iter().zip(kit).all(|(g, k)| (g - k).abs() <= tol), "got {got:?}, kit {kit:?}");
}

/// Kit render (`Button/Raised/Default`, `interface-studio-mcp` `studio_screenshot`): the black shadow alpha in the rows
/// below the body. Scale 1: 85, 43 of 255; scale 2: 109, 81, 47, 19, 5 of 255. At scale 2 each device row is half a point.
#[test]
fn raised_button_shadow_matches_the_kit_render_at_both_scales() {
    let r = CGRect::new(20.0, 20.0, 120.0, 28.0);
    let d1 = column_at(0x1C1C1E, (160, 70), 1.0, 80, &[48, 49, 50], |c| {
        c.stone_button(r, ButtonKind::Raised, rest(), &dark());
    });
    near_f(&darkness(&d1, 28)[..2], &[0.333, 0.169], 0.07);
    // y 48.0 to 50.5 in half points: device rows 96 to 100.
    let d2 = {
        let mut c = Canvas::with_size(320.0, 140.0, None, 2.0);
        c.stone_button(r, ButtonKind::Raised, rest(), &dark());
        let img = crate::software::SoftwareRenderer::render_8bit(
            &c.list,
            320,
            140,
            Color::hex(0x1C1C1E, 1.0),
            &crate::software::Sources::default(),
        );
        (96..101).map(|y| img.pixels[(y * 320 + 160) * 4]).collect::<Vec<_>>()
    };
    near_f(&darkness(&d2, 28), &[0.427, 0.32, 0.184, 0.075, 0.02], 0.05);
    // Kit light (`neu.html`, Chrome: 218 and 236 on #F4F4F5).
    let l = column(0xF4F4F5, (160, 70), 80, &[48, 49, 50], |c| {
        c.stone_button(r, ButtonKind::Raised, rest(), &light());
    });
    within(&l, &[218, 236, 243], 3);
}

/// Kit render (`Field/Number/Default`, scale 2, fill 23): rows from the top edge in half points 8, 9 (ring), then 20, 21, 22,
/// 23 (soft inset); darkness of the fill .65 .61 .13 .09 .04 0.
#[test]
fn field_well_matches_the_kit_render_at_scale_2() {
    let r = CGRect::new(20.0, 20.0, 62.0, 20.0);
    let mut c = Canvas::with_size(200.0, 120.0, None, 2.0);
    c.stone_field(r, 3.0, false, rest(), &dark());
    let img = crate::software::SoftwareRenderer::render_8bit(
        &c.list,
        200,
        120,
        Color::hex(0x1C1C1E, 1.0),
        &crate::software::Sources::default(),
    );
    let at = |y: usize| img.pixels[(y * 200 + 102) * 4];
    let fill = at(60) as f32;
    let got: Vec<f32> = (40..46).map(|y| 1.0 - at(y) as f32 / fill).collect();
    near_f(&got, &[0.65, 0.61, 0.13, 0.09, 0.04, 0.0], 0.05);
    // Kit light well (`neu.html`, Chrome on #FFFFFF: 207, 249, 254, 255).
    let l = column(0xF4F4F5, (160, 60), 80, &[20, 21, 22, 23], |c| {
        c.stone_field(CGRect::new(20.0, 20.0, 120.0, 20.0), 4.0, false, rest(), &light());
    });
    within(&l, &[207, 249, 254, 255], 4);
}

#[test]
fn a_stone_body_sits_on_whole_device_pixels_at_a_fractional_scale_and_is_unchanged_at_whole_ones() {
    let r = CGRect::new(10.3, 20.0, 61.0, 23.0);
    let look = Look { fill: Fill::Flat(Color::hex(0x3a3a3c, 1.0)), ..Look::NONE };
    for scale in [1.25f32, 1.5, 1.75] {
        let mut c = Canvas::with_size(200.0 * scale, 100.0 * scale, None, scale);
        c.stone_body(r, 6.0, &look);
        let q = quads(&c);
        let body = q.last().expect("the body fill");
        for v in [body.rect.x, body.rect.y, body.rect.w, body.rect.h] {
            assert_eq!(v, v.round(), "scale {scale}: {:?}", body.rect);
        }
        let (want_w, want_h) = (f64::from(body.rect.w) / f64::from(scale), f64::from(body.rect.h) / f64::from(scale));
        assert!(
            (want_w - r.width).abs() <= 1.0 / f64::from(scale) && (want_h - r.height).abs() <= 1.0 / f64::from(scale)
        );
    }
    for scale in [1.0f32, 2.0] {
        let mut c = Canvas::with_size(200.0 * scale, 100.0 * scale, None, scale);
        c.stone_body(r, 6.0, &look);
        let body = *quads(&c).last().expect("the body fill");
        assert_eq!(body.rect, c.px(r), "scale {scale} keeps the point layout as it was");
    }
}

#[test]
fn snapping_follows_the_translation_and_never_drops_a_thin_rect() {
    let mut c = Canvas::with_size(300.0, 300.0, None, 1.5);
    c.translate_by(0.5, 0.0);
    let s = c.snap_to_device(CGRect::new(10.0, 5.0, 0.2, 40.0));
    let p = c.px(s);
    assert_eq!(p.x, p.x.round());
    assert!(p.w >= 1.0, "a thin line keeps a pixel: {p:?}");
    assert_eq!(Canvas::with_size(10.0, 10.0, None, 2.0).snap_to_device(CGRect::new(0.25, 0.0, 1.0, 1.0)).x, 0.25);
}
