//! Stone controls built on [`crate::stone`]: switch, checkbox, radio, segmented control, slider, chip, tab underline
//! (`03-choices.json`, `04-navigation-marks.json`). Every value is a token or a number of the specs.

use crate::canvas::Canvas;
use crate::draw_list::Color;
use crate::motion::{self, Ease};
use crate::stone::{
    ButtonKind, DISABLED_ALPHA, FieldState, Interaction, Look, Touch, button_look, field_look, hover_level,
    press_level,
};
use crate::theme::DrawTheme;
use sq_uikit::controls_grid::{CGPoint, CGRect};
/// r8 `.check` width and height.
const CHECKBOX_SIZE: f64 = 18.0;
use sq_uikit::redesign_tokens::{color as tk, motion as mt, radius as rd, size as sz};

/// Switch knob side at rest, and while pressed (`Switch/Pressed`: 15, padding 2.5).
pub const SWITCH_KNOB: f64 = 16.0;
/// Switch knob side while pressed.
pub const SWITCH_KNOB_PRESSED: f64 = 15.0;
/// Space between switch track and knob.
pub const SWITCH_PAD: f64 = 2.0;
/// Checkbox box side (`Checkbox`: 14 pt, radius `field`).
pub const CHECKBOX: f64 = 14.0;
/// Radio ring side.
pub const RADIO: f64 = 12.0;
/// Radio dot side.
pub const RADIO_DOT: f64 = 5.0;
/// Slider knob (round) side; the no-fill slider has an 8 x 16 pill with radius 3.
pub const SLIDER_KNOB: f64 = 12.0;
/// Segment thumb inset in its track (track 20 holds a 16 thumb, track 24 a 20 thumb).
pub const SEGMENT_INSET: f64 = 2.0;
/// Soft shadow literals of the specs (`0 0 0 .5px #00000080` ring, `0 1px 2px #00000080` under a knob).
const KNOB_SHADOW: Color = Color::new(0.0, 0.0, 0.0, 128.0 / 255.0);
const SLIDER_KNOB_RING: Color = Color::new(0.0, 0.0, 0.0, 153.0 / 255.0);
/// The kit's light values: ring `0 0 0 .5px rgba(0,0,0,.35)`, shadow `0 1px 2px rgba(0,0,0,.2)`.
const LIGHT_KNOB_SHADOW: Color = Color::new(0.0, 0.0, 0.0, 0.2);
const LIGHT_KNOB_RING: Color = Color::new(0.0, 0.0, 0.0, 0.35);
const ON_SOFT: Color = Color::new(0.0, 0.0, 0.0, 77.0 / 255.0);

/// Kit `Timeline/ZoomBar`: bar height and knob side.
pub const ZOOM_BAR_HEIGHT: f64 = 8.0;

/// The zoom bar's raised stone track (`raised_off` gradient, radius 4, top light, `0 1px 1.5px` shadow) with a round knob
/// of `ZOOM_BAR_HEIGHT` at each end of the visible span `xl...xh` (kit `Timeline/ZoomBar`). `bounds` centers the 8 pt bar.
pub fn zoom_bar_stone(c: &mut Canvas, bounds: CGRect, inset: f64, xl: f64, xh: f64, t: &DrawTheme) {
    let d = t.palette.is_dark();
    let bar = CGRect::new(
        bounds.x + inset,
        bounds.mid_y() - ZOOM_BAR_HEIGHT / 2.0,
        bounds.width - 2.0 * inset,
        ZOOM_BAR_HEIGHT,
    );
    let look = Look {
        fill: crate::stone::Fill::Gradient(t.token(tk::RAISED_OFF_TOP), t.token(tk::RAISED_OFF_BOTTOM)),
        shadow: Some(Color::new(0.0, 0.0, 0.0, if d { 0.5 } else { 0.2 })),
        top_light: Some(Color::new(1.0, 1.0, 1.0, if d { 0.08 } else { 0.6 })),
        ..Look::NONE
    };
    c.stone_body(bar, bar.height / 2.0, &look);
    let ring = if d { Color::new(0.0, 0.0, 0.0, 0.6) } else { Color::new(0.0, 0.0, 0.0, 0.35) };
    for x in [xl, xh] {
        let knob = CGRect::new(x - ZOOM_BAR_HEIGHT / 2.0, bar.y, ZOOM_BAR_HEIGHT, ZOOM_BAR_HEIGHT);
        c.fill_ellipse(knob.inset_by(-0.5, -0.5), ring);
        c.fill_gradient_rounded(knob, ZOOM_BAR_HEIGHT / 2.0, t.token(tk::ZOOM_KNOB_TOP), t.token(tk::ZOOM_KNOB_BOTTOM));
    }
}

/// A knob's hover and press shade: `shade` > 0 lifts away from the page (hover), < 0 darkens (press, ui-gefuehl: darker).
fn knob_shade(c: Color, shade: f32, t: &DrawTheme) -> Color {
    if shade >= 0.0 {
        c.mix(if t.palette.is_dark() { Color::WHITE } else { Color::BLACK }, shade * if t.palette.is_dark() { 0.25 } else { 0.06 })
    } else {
        c.mix(Color::BLACK, -shade * 0.18)
    }
}

fn faded(c: Color, disabled: bool) -> Color {
    if disabled { c.with_alpha(c.a * DISABLED_ALPHA) } else { c }
}

impl Canvas<'_> {
    /// A round knob: token gradient, a half-point ring and a 1 pt shadow (`Switch` and `Slider` knobs).
    fn stone_knob(&mut self, r: CGRect, radius: f64, ring: Color, disabled: bool, shade: f32, t: &DrawTheme) {
        let a = if disabled { DISABLED_ALPHA } else { 1.0 };
        let (ring, drop) = if t.palette.is_dark() { (ring, KNOB_SHADOW) } else { (LIGHT_KNOB_RING, LIGHT_KNOB_SHADOW) };
        self.fill_rounded(r.inset_by(-0.5, -0.5), radius + 0.5, faded(ring, disabled));
        self.shadow(r, radius, 2.0, 1.0, faded(drop, disabled), true);
        let (top, bottom) = (t.token(tk::KNOB_TOP), t.token(tk::KNOB_BOTTOM));
        let (top, bottom) = (knob_shade(top, shade, t), knob_shade(bottom, shade, t));
        self.fill_gradient_rounded(r, radius, top.with_alpha(top.a * a), bottom.with_alpha(bottom.a * a));
    }

    /// The knob rect of a switch at `level` (0 = off end, 1 = on end), `pressed_level` 0...1 shrinking it from 16 to 15.
    pub fn switch_knob_rect(track: CGRect, level: f64, pressed_level: f64) -> CGRect {
        let side = SWITCH_KNOB - (SWITCH_KNOB - SWITCH_KNOB_PRESSED) * pressed_level;
        let travel = track.width - 2.0 * SWITCH_PAD - SWITCH_KNOB;
        let cx = track.x + SWITCH_PAD + SWITCH_KNOB / 2.0 + travel * level;
        CGRect::new(cx - side / 2.0, track.mid_y() - side / 2.0, side, side)
    }

    /// The switch (`Switch/On`, `Off`, `Pressed`, `OnPressed`), 34 x 20 with a 160 ms knob slide (instant in reduce motion).
    /// Returns the knob level that was drawn.
    pub fn stone_switch(&mut self, track: CGRect, on: bool, touch: Touch, t: &DrawTheme) -> f32 {
        let p = self.px(track);
        let key = motion::key_of(motion::role::SELECT, p.x, p.y, p.w, p.h);
        let level = motion::with_book(|b| {
            b.level(key, if on { 1.0 } else { 0.0 }, f64::from(mt::SWITCH_MS) / 1000.0, Ease::OutStone)
        });
        let pl = press_level(self, track, touch.pressed && !touch.disabled);
        let hl = hover_level(touch.hovering && !touch.disabled && !touch.pressed);
        let radius = f64::from(rd::SWITCH);
        let off = field_look(FieldState::Rest, t).mix(field_look(FieldState::Hover, t), hl);
        let on_look =
            Look { fill: crate::stone::Fill::Flat(t.token(tk::ACCENT_FILL)), inset_soft: Some(ON_SOFT), ..Look::NONE };
        let look = off.mix(on_look, level);
        self.stone_body(track, radius, &if touch.disabled { look.faded(DISABLED_ALPHA) } else { look });
        let knob = Self::switch_knob_rect(track, f64::from(level), f64::from(pl));
        self.stone_knob(knob, knob.width / 2.0, KNOB_SHADOW, touch.disabled, 0.0, t);
        if touch.focused {
            self.stone_focus_ring(track, radius, t);
        }
        level
    }

    /// The checkbox box (18 pt rounded square, radius `field` = 6): well when off, accent when on with a white check (10 pt).
    pub fn stone_checkbox(&mut self, r: CGRect, on: bool, touch: Touch, t: &DrawTheme) {
        // r8 `.check`: always an 18 px rounded square (r-check 6), centered in the caller's slot.
        let r = CGRect::new(r.mid_x() - CHECKBOX_SIZE / 2.0, r.mid_y() - CHECKBOX_SIZE / 2.0, CHECKBOX_SIZE, CHECKBOX_SIZE);
        let radius = f64::from(rd::FIELD);
        if on {
            let on = Look { fill: crate::stone::Fill::Flat(t.token(tk::ACCENT_FILL)), ..Look::NONE };
            let down = Look { fill: crate::stone::Fill::Flat(t.token(tk::ACCENT_PRESSED_BOTTOM)), ..Look::NONE };
            let pl = press_level(self, r, touch.pressed && !touch.disabled);
            let look = on.mix(down, pl);
            let look = if touch.disabled { look.faded(DISABLED_ALPHA) } else { look };
            self.stone_body(r, radius, &look);
            let (w, h) = (r.width, r.height);
            let white = faded(t.token(tk::ON_ACCENT), touch.disabled);
            self.stroke_polyline(
                &[
                    CGPoint { x: r.min_x() + w * 0.27, y: r.min_y() + h * 0.52 },
                    CGPoint { x: r.min_x() + w * 0.43, y: r.min_y() + h * 0.70 },
                    CGPoint { x: r.min_x() + w * 0.75, y: r.min_y() + h * 0.30 },
                ],
                1.5,
                white,
            );
            if touch.focused {
                self.stone_focus_ring(r, radius, t);
            }
        } else {
            // r8 `.check`: no body, a 1.5 pt inset outline in text-tertiary (text-secondary on hover); pressed darkens the inside.
            // text-secondary and text-tertiary are the same gray in r8, so hover shows as a faint tint inside the outline.
            let edge = if touch.hovering && !touch.disabled { t.label2() } else { t.label3() };
            if touch.hovering && !touch.disabled && !touch.pressed {
                self.fill_rounded(r, radius, edge.with_alpha(0.12));
            }
            self.stone_press_shade(r, radius, touch);
            self.stroke_rounded(r.inset_by(0.75, 0.75), radius - 0.75, 1.5, faded(edge, touch.disabled));
            if touch.focused {
                self.stone_focus_ring(r, radius, t);
            }
        }
    }

    /// The pressed look of an off checkbox or radio: the inside darkens (never smaller), 60 ms in, 160 ms out like a button.
    fn stone_press_shade(&mut self, r: CGRect, radius: f64, touch: Touch) {
        let pl = press_level(self, r, touch.pressed && !touch.disabled);
        if pl > 0.0 {
            self.fill_rounded(r, radius, Color::BLACK.with_alpha(0.16 * pl));
        }
    }

    /// The radio (12 pt ring, 5 pt dot).
    pub fn stone_radio(&mut self, r: CGRect, on: bool, touch: Touch, t: &DrawTheme) {
        let radius = r.width / 2.0;
        if on {
            let on = Look { fill: crate::stone::Fill::Flat(t.token(tk::ACCENT_FILL)), ..Look::NONE };
            let down = Look { fill: crate::stone::Fill::Flat(t.token(tk::ACCENT_PRESSED_BOTTOM)), ..Look::NONE };
            let look = on.mix(down, press_level(self, r, touch.pressed && !touch.disabled));
            self.stone_body(r, radius, &if touch.disabled { look.faded(DISABLED_ALPHA) } else { look });
            let d = RADIO_DOT;
            self.fill_ellipse(
                CGRect::new(r.mid_x() - d / 2.0, r.mid_y() - d / 2.0, d, d),
                faded(t.token(tk::ON_ACCENT), touch.disabled),
            );
            if touch.focused {
                self.stone_focus_ring(r, radius, t);
            }
        } else {
            self.stone_field(r, radius, false, touch, t);
            self.stone_press_shade(r, radius, touch);
        }
    }

    /// The track of a segmented control (a well, radius `control`).
    pub fn stone_segment_track(&mut self, r: CGRect, touch: Touch, t: &DrawTheme) {
        // The ring belongs to the segment that has the keyboard, not to the track.
        self.stone_field(r, f64::from(rd::CONTROL), false, Touch { hovering: false, focused: false, ..touch }, t);
    }

    /// The selected segment: a raised thumb (radius `field`) with the highlight edge and shadow; a hovered unselected one
    /// gets the quiet hover fill.
    pub fn stone_segment(&mut self, r: CGRect, selected: bool, touch: Touch, t: &DrawTheme) {
        let radius = f64::from(rd::FIELD);
        let kind = if selected { ButtonKind::Raised } else { ButtonKind::Quiet };
        let state = if touch.pressed {
            Interaction::Pressed
        } else if touch.hovering && !selected {
            Interaction::Hover
        } else {
            Interaction::Rest
        };
        let look = button_look(kind, state, t);
        self.stone_body(r, radius, &if touch.disabled { look.faded(DISABLED_ALPHA) } else { look });
        if touch.focused {
            self.stone_focus_ring(r, radius, t);
        }
    }

    /// A slider track (4 pt well, radius 2) with an optional gray fill (`text3`) up to `fill_to` (x).
    pub fn stone_slider_track(&mut self, r: CGRect, fill: Option<(f64, f64)>, touch: Touch, t: &DrawTheme) {
        let track =
            CGRect::new(r.x, r.mid_y() - f64::from(sz::SLIDER_TRACK) / 2.0, r.width, f64::from(sz::SLIDER_TRACK));
        self.stone_field(track, 2.0, false, Touch { hovering: false, focused: false, ..touch }, t);
        if let Some((x0, x1)) = fill {
            let c = faded(t.token(tk::TEXT3), touch.disabled);
            self.fill_rounded(CGRect::new(x0, track.y, (x1 - x0).max(0.0), track.height), 2.0, c);
        }
    }

    /// The slider knob: a 12 pt ball (`Slider/Fill`) or, `pill`, the 8 x 16 knob with radius 3 (`Slider/NoFill`), centered at `cx`.
    pub fn stone_slider_knob(&mut self, cx: f64, cy: f64, pill: bool, touch: Touch, t: &DrawTheme) -> CGRect {
        let (w, h, radius) = if pill { (8.0, 16.0, 3.0) } else { (SLIDER_KNOB, SLIDER_KNOB, SLIDER_KNOB / 2.0) };
        let r = CGRect::new(cx - w / 2.0, cy - h / 2.0, w, h);
        let live = !touch.disabled;
        let shade = hover_level(touch.hovering && live && !touch.pressed) - press_level(self, r, touch.pressed && live);
        self.stone_knob(r, radius, SLIDER_KNOB_RING, touch.disabled, shade, t);
        if touch.focused {
            self.stone_focus_ring(r, radius, t);
        }
        r
    }

    /// A filter or track chip: raised when on (radius `field` for the 26 x 18 chip, `control` for the 20 pt filter), flat
    /// when off with a 1 pt `line2` edge for the small chip only.
    pub fn stone_chip(&mut self, r: CGRect, on: bool, edged: bool, touch: Touch, t: &DrawTheme) {
        let radius = f64::from(if edged { rd::FIELD } else { rd::CONTROL });
        let state = if touch.pressed {
            Interaction::Pressed
        } else if touch.hovering && !on {
            Interaction::Hover
        } else {
            Interaction::Rest
        };
        let look = button_look(if on { ButtonKind::Raised } else { ButtonKind::Quiet }, state, t);
        self.stone_body(r, radius, &if touch.disabled { look.faded(DISABLED_ALPHA) } else { look });
        if edged && !on {
            self.stroke_rounded(r.inset_by(0.5, 0.5), radius - 0.5, 1.0, faded(t.token(tk::LINE2), touch.disabled));
        }
        if touch.focused {
            self.stone_focus_ring(r, radius, t);
        }
    }

    /// The `surface-toggle` pill of an active toggle (r8:131, 276; tools, Snap, Link, Bold, Italic): flat grey, hover and
    /// press shift the fill. One part for the timeline and the inspector panels.
    pub fn stone_toggle_pill(&mut self, r: CGRect, hot: bool, pressed: bool, t: &DrawTheme) {
        let fill = if pressed {
            t.pressed()
        } else if hot {
            t.raised_hover()
        } else {
            t.raised()
        };
        self.fill_rounded(r, f64::from(rd::CONTROL), fill);
    }

    /// The Library's filter chip (kit Panels/Chip): 20 pt, radius `control`, raised when on, a 1 pt `line2` edge when off.
    pub fn stone_filter_chip(&mut self, r: CGRect, on: bool, touch: Touch, t: &DrawTheme) {
        self.stone_chip(r, on, false, touch, t);
        if !on {
            let line = faded(t.token(tk::LINE2), touch.disabled);
            self.stroke_rounded(r.inset_by(0.5, 0.5), f64::from(rd::CONTROL) - 0.5, 1.0, line);
        }
    }

    /// The tab underline: a 2 pt bar in gray `text3` under the active tab, `label_width` wide plus 8 pt each side. Blue is
    /// only for the panel focus ring.
    pub fn stone_tab_underline(&mut self, tab: CGRect, active: bool, t: &DrawTheme) {
        if !active {
            return;
        }
        let h = f64::from(sz::TAB_UNDERLINE);
        self.fill(CGRect::new(tab.x + 8.0, tab.max_y() - h, (tab.width - 16.0).max(0.0), h), t.token(tk::TEXT3));
    }
}
