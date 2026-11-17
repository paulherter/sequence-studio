//! The stone look (redesign step R2): raised buttons, sunken fields and their states, from the component specs
//! (`redesign/is/specs/components/01-Controls`) and the redesign tokens. A [`Look`] is the pure description of one state
//! (fill, highlight edge, inner shadow, drop shadow, halo); [`Canvas::stone_body`] draws it; [`Canvas::stone_button`]
//! and [`Canvas::stone_field`] add the motion (press 60 ms in / 160 ms out with scale .97; hover is instant, see [`hover_level`]) and the
//! keyboard focus ring. Reduce motion drops scale and nudge and snaps the colors.

use crate::canvas::Canvas;
use crate::draw_list::Color;
use crate::motion::{self, Ease};
use crate::theme::DrawTheme;
use sq_uikit::controls_grid::CGRect;
use sq_uikit::redesign_tokens::{color as tk, motion as mt, radius as rd, size as sz};

/// Pressed scale of everything pressable (HAUPTFENSTER section 12).
pub const PRESS_SCALE: f64 = 0.97;
/// Pressed downward nudge in points (`translateY(.5px)`).
pub const PRESS_NUDGE: f64 = 0.5;
/// Alpha of a disabled control (specs: opacity .4).
pub const DISABLED_ALPHA: f32 = 0.4;
/// Keyboard focus ring: 2 pt wide, 2 pt away from the control (spec: frame padding 2, outside stroke 2).
pub const FOCUS_GAP: f64 = 2.0;

// Shadow values the specs write as literals (the token file has no variable for them): `0 1px 1.5px #00000080` under a
// raised part, the sunken ring `inset 0 0 0 1px #00000080`, the soft inner top shadow `inset 0 1px 2px #00000059`, the
// light line under a well `0 1px 0 #FFFFFF0B`, and the accent/destructive edge values.
const SHADOW: u32 = 0x0000_0080;
const WELL_RING: u32 = 0x0000_0080;
const WELL_RING_HOVER: u32 = 0xFFFF_FF1F;
const WELL_SOFT: u32 = 0x0000_0059;
const WELL_LIFT: u32 = 0xFFFF_FF0B;
const PRESS_LIFT: u32 = 0xFFFF_FF0A;
const FILLED_TOP_LIGHT: u32 = 0xFFFF_FF38;
const DESTRUCTIVE_TOP_LIGHT: u32 = 0xFFFF_FF2E;
const FILLED_RING: u32 = 0x0000_002E;
const FILLED_PRESS_SOFT: u32 = 0x0000_0073;
/// Light-palette values the kit gives (`neu.html` `#after.light`): raised `0 1px 1.5px rgba(0,0,0,.14)`, sunken ring `.14`
/// (`.24` on hover), soft top shadow `.08`, light line under a well `rgba(255,255,255,.8)`.
const LIGHT_SHADOW: u32 = 0x0000_0024;
const LIGHT_WELL_RING: u32 = 0x0000_0024;
const LIGHT_WELL_RING_HOVER: u32 = 0x0000_003D;
const LIGHT_WELL_SOFT: u32 = 0x0000_0014;
const LIGHT_WELL_LIFT: u32 = 0xFFFF_FFCC;
/// Values the kit defines for dark only: black ones are weaker on a light palette by this factor.
const LIGHT_SHADOW_FACTOR: f32 = 0.45;
/// Inset shadow `0 1px 2px` (sigma 1) as the average of the Gaussian over the first three pixel rows from the top edge.
const INSET_ROWS: [f32; 3] = [0.684, 0.316, 0.075];

/// `dark` in the dark palette, `light` (the kit's own light value) in the light one.
fn pick(dark_rgba: u32, light_rgba: u32, dark: bool) -> Color {
    let v = if dark { dark_rgba } else { light_rgba };
    Color::hex(v >> 8, (v & 0xFF) as f32 / 255.0)
}

fn lit(rgba: u32, dark: bool) -> Color {
    let c = Color::hex(rgba >> 8, (rgba & 0xFF) as f32 / 255.0);
    if dark || rgba >> 8 != 0 { c } else { c.with_alpha(c.a * LIGHT_SHADOW_FACTOR) }
}

/// What a body is filled with.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Fill {
    /// Nothing (a quiet button at rest).
    None,
    /// One color.
    Flat(Color),
    /// Top to bottom.
    Gradient(Color, Color),
}

impl Fill {
    fn ends(self) -> (Color, Color) {
        match self {
            Fill::None => (Color::CLEAR, Color::CLEAR),
            Fill::Flat(c) => (c, c),
            Fill::Gradient(a, b) => (a, b),
        }
    }
    fn mix(self, to: Fill, t: f32) -> Fill {
        if self == to || t <= 0.0 {
            return self;
        }
        if t >= 1.0 {
            return to;
        }
        let clear = |f: Fill| (f.ends().0.with_alpha(0.0), f.ends().1.with_alpha(0.0));
        let (a0, a1) = if self == Fill::None { clear(to) } else { self.ends() };
        let (b0, b1) = if to == Fill::None { clear(self) } else { to.ends() };
        Fill::Gradient(a0.mix(b0, t), a1.mix(b1, t))
    }
    fn faded(self, a: f32) -> Fill {
        match self {
            Fill::None => Fill::None,
            Fill::Flat(c) => Fill::Flat(c.with_alpha(c.a * a)),
            Fill::Gradient(x, y) => Fill::Gradient(x.with_alpha(x.a * a), y.with_alpha(y.a * a)),
        }
    }
}

/// One state of a stone surface, in the order the CSS layers are painted (under to over).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Look {
    /// The body.
    pub fill: Fill,
    /// `0 1px 0` light line below the body (a well's lower lip, a pressed button's lip).
    pub lift: Option<Color>,
    /// `0 1px 1.5px` shadow under a raised body.
    pub shadow: Option<Color>,
    /// `inset 0 1px 0`: the highlight edge along the top.
    pub top_light: Option<Color>,
    /// `inset 0 0 0 1px`: a 1 pt ring inside the edge.
    pub ring: Option<Color>,
    /// `inset 0 1px 2px`: the soft shadow inside the top (a sunken or pressed body).
    pub inset_soft: Option<Color>,
    /// The 3 pt halo outside an editing field.
    pub halo: Option<Color>,
}

fn mix_opt(a: Option<Color>, b: Option<Color>, t: f32) -> Option<Color> {
    match (a, b) {
        (None, None) => None,
        (x, y) => {
            let x = x.unwrap_or_else(|| y.unwrap_or(Color::CLEAR).with_alpha(0.0));
            let y = y.unwrap_or_else(|| x.with_alpha(0.0));
            Some(x.mix(y, t))
        }
    }
}

fn fade_opt(c: Option<Color>, a: f32) -> Option<Color> {
    c.map(|c| c.with_alpha(c.a * a))
}

impl Look {
    /// No layer at all.
    pub const NONE: Look =
        Look { fill: Fill::None, lift: None, shadow: None, top_light: None, ring: None, inset_soft: None, halo: None };

    /// The blend of two states (hover and press; `t` is 0 or 1 for hover, a press level in between).
    pub fn mix(self, to: Look, t: f32) -> Look {
        Look {
            fill: self.fill.mix(to.fill, t),
            lift: mix_opt(self.lift, to.lift, t),
            shadow: mix_opt(self.shadow, to.shadow, t),
            top_light: mix_opt(self.top_light, to.top_light, t),
            ring: mix_opt(self.ring, to.ring, t),
            inset_soft: mix_opt(self.inset_soft, to.inset_soft, t),
            halo: mix_opt(self.halo, to.halo, t),
        }
    }

    /// Every layer at `a` times its alpha (disabled: `opacity .4`).
    pub fn faded(self, a: f32) -> Look {
        Look {
            fill: self.fill.faded(a),
            lift: fade_opt(self.lift, a),
            shadow: fade_opt(self.shadow, a),
            top_light: fade_opt(self.top_light, a),
            ring: fade_opt(self.ring, a),
            inset_soft: fade_opt(self.inset_soft, a),
            halo: fade_opt(self.halo, a),
        }
    }
}

/// The kinds of button the specs define.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ButtonKind {
    /// The blue one (`Button/Primary`, Export).
    Accent,
    /// Raised stone (`Button/Raised`, dropdown field, "on" icon button).
    Raised,
    /// A raised menu button in a header (`Button/RaisedMenu`): the darker "off" stone.
    RaisedMenu,
    /// Red (`Button/Destructive`).
    Destructive,
    /// No surface at rest (`Button/Quiet`, icon buttons that are off).
    Quiet,
}

/// Which of its three looks a button shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Interaction {
    /// At rest.
    Rest,
    /// Pointer over it.
    Hover,
    /// Held down (or an open dropdown).
    Pressed,
}

fn raised(top: Color, bottom: Color, t: &DrawTheme, top_light: Color) -> Look {
    let d = t.palette.is_dark();
    Look {
        fill: Fill::Gradient(top, bottom),
        shadow: Some(pick(SHADOW, LIGHT_SHADOW, d)),
        top_light: Some(top_light),
        ..Look::NONE
    }
}

fn pressed(top: Color, bottom: Color, soft: Color, t: &DrawTheme) -> Look {
    Look {
        fill: Fill::Gradient(top, bottom),
        inset_soft: Some(soft),
        lift: Some(lit(PRESS_LIFT, t.palette.is_dark())),
        ..Look::NONE
    }
}

/// The look of `kind` in `state`, straight from the tokens and the button specs.
pub fn button_look(kind: ButtonKind, state: Interaction, t: &DrawTheme) -> Look {
    let d = t.palette.is_dark();
    let k = |x| t.token(x);
    let filled =
        |top, bottom, light: u32| Look { ring: Some(lit(FILLED_RING, d)), ..raised(top, bottom, t, lit(light, d)) };
    match (kind, state) {
        (ButtonKind::Accent, Interaction::Rest) => filled(k(tk::ACCENT_TOP), k(tk::ACCENT_FILL), FILLED_TOP_LIGHT),
        (ButtonKind::Accent, Interaction::Hover) => {
            filled(k(tk::ACCENT_HOVER_TOP), k(tk::ACCENT_HOVER_BOTTOM), FILLED_TOP_LIGHT)
        }
        (ButtonKind::Accent, Interaction::Pressed) => {
            pressed(k(tk::ACCENT_PRESSED_TOP), k(tk::ACCENT_PRESSED_BOTTOM), lit(FILLED_PRESS_SOFT, d), t)
        }
        (ButtonKind::Destructive, Interaction::Pressed) => {
            pressed(k(tk::DESTRUCTIVE_PRESSED_TOP), k(tk::DESTRUCTIVE_PRESSED_BOTTOM), lit(FILLED_PRESS_SOFT, d), t)
        }
        // The specs define no hover for the red button: it keeps its rest look.
        (ButtonKind::Destructive, _) => {
            filled(k(tk::DESTRUCTIVE_TOP), k(tk::DESTRUCTIVE_BOTTOM), DESTRUCTIVE_TOP_LIGHT)
        }
        (ButtonKind::Raised, Interaction::Rest) => raised(k(tk::RAISED_TOP), k(tk::RAISED_BOTTOM), t, k(tk::HIGHLIGHT)),
        (ButtonKind::Raised, Interaction::Hover) => {
            raised(k(tk::RAISED_HOVER_TOP), k(tk::RAISED_HOVER_BOTTOM), t, k(tk::HIGHLIGHT))
        }
        (ButtonKind::RaisedMenu, Interaction::Rest) => {
            raised(k(tk::RAISED_OFF_TOP), k(tk::RAISED_OFF_BOTTOM), t, k(tk::HIGHLIGHT))
        }
        (ButtonKind::RaisedMenu, Interaction::Hover) => {
            raised(k(tk::RAISED_HOVER_OFF_TOP), k(tk::RAISED_HOVER_OFF_BOTTOM), t, k(tk::HIGHLIGHT))
        }
        (ButtonKind::Raised | ButtonKind::RaisedMenu, Interaction::Pressed) => {
            pressed(k(tk::PRESSED_TOP), k(tk::PRESSED_BOTTOM), k(tk::EDGE_DARK), t)
        }
        (ButtonKind::Quiet, Interaction::Rest) => Look::NONE,
        (ButtonKind::Quiet, Interaction::Hover) => Look { fill: Fill::Flat(k(tk::HOVER)), ..Look::NONE },
        (ButtonKind::Quiet, Interaction::Pressed) => Look { fill: Fill::Flat(k(tk::PRESS_DIM)), ..Look::NONE },
    }
}

/// The states of a sunken field.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FieldState {
    /// At rest.
    Rest,
    /// Pointer over it: the inner ring turns light.
    Hover,
    /// Typing or dragging: a 1 pt accent ring and a 3 pt halo.
    Editing,
}

/// The look of a sunken field (`Field/*`, `Switch/Off`, `Checkbox/Off`, `Segmented`, slider track).
pub fn field_look(state: FieldState, t: &DrawTheme) -> Look {
    let d = t.palette.is_dark();
    let well = Fill::Flat(t.token(tk::WELL));
    match state {
        FieldState::Rest => Look {
            fill: well,
            ring: Some(pick(WELL_RING, LIGHT_WELL_RING, d)),
            inset_soft: Some(pick(WELL_SOFT, LIGHT_WELL_SOFT, d)),
            lift: Some(pick(WELL_LIFT, LIGHT_WELL_LIFT, d)),
            ..Look::NONE
        },
        FieldState::Hover => Look {
            fill: well,
            ring: Some(pick(WELL_RING_HOVER, LIGHT_WELL_RING_HOVER, d)),
            inset_soft: Some(pick(WELL_SOFT, LIGHT_WELL_SOFT, d)),
            lift: Some(pick(WELL_LIFT, LIGHT_WELL_LIFT, d)),
            ..Look::NONE
        },
        FieldState::Editing => {
            Look { fill: well, ring: Some(t.token(tk::ACCENT)), halo: Some(t.token(tk::ACCENT_HALO)), ..Look::NONE }
        }
    }
}

/// `rect` pressed by `level` (0...1): scaled to .97 about its center and nudged down .5 pt. Nothing moves in reduce motion.
pub fn pressed_rect(rect: CGRect, level: f32) -> CGRect {
    if level <= 0.0 || motion::reduce_motion() {
        return rect;
    }
    let l = f64::from(level);
    let s = 1.0 - (1.0 - PRESS_SCALE) * l;
    let (w, h) = (rect.width * s, rect.height * s);
    CGRect::new(rect.mid_x() - w / 2.0, rect.mid_y() - h / 2.0 + PRESS_NUDGE * l, w, h)
}

/// The press level of the control at `r`: rises in 60 ms, falls in 160 ms ease-out (`motion/press_in_ms`, `press_out_ms`).
pub fn press_level(c: &Canvas, r: CGRect, down: bool) -> f32 {
    let p = c.px(r);
    let key = motion::key_of(motion::role::PRESS, p.x, p.y, p.w, p.h);
    let (secs, ease) = if down {
        (f64::from(mt::PRESS_IN_MS) / 1000.0, Ease::Linear)
    } else {
        (f64::from(mt::PRESS_OUT_MS) / 1000.0, Ease::OutStone)
    };
    motion::with_book(|b| b.level(key, if down { 1.0 } else { 0.0 }, secs, ease))
}

/// The hover level of a control: full on the first frame the pointer is over it, zero on the first frame it is not.
/// Hover answers the pointer at once (no cross-fade, no frame asked for) on every surface used hundreds of times a day;
/// it is the one place that decides this, so a new control cannot bring a fade back by itself (`motion/hover_ms` is 0).
pub fn hover_level(over: bool) -> f32 {
    if over { 1.0 } else { 0.0 }
}

/// Pointer and keyboard state of a control.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Touch {
    /// Pointer over the control.
    pub hovering: bool,
    /// Held down (or the dropdown is open).
    pub pressed: bool,
    /// Enabled; a disabled one is dimmed to 40 percent and ignores hover and press.
    pub disabled: bool,
    /// Keyboard focus: the 2 pt accent ring.
    pub focused: bool,
}

impl Canvas<'_> {
    /// Paints one [`Look`] on `r` with corner `radius`: lift, shadow, body, highlight edge, ring, soft inner shadow, halo.
    pub fn stone_body(&mut self, r: CGRect, radius: f64, look: &Look) {
        // Every layer below hangs off this one rect, so the body edge, its ring and its shadow stay one picture.
        let r = self.snap_to_device(r);
        if let Some(c) = look.lift {
            self.fill_rounded(CGRect::new(r.x, r.y + 1.0, r.width, r.height), radius, c);
        }
        if let Some(c) = look.shadow {
            self.shadow(r, radius, 1.5, 1.0, c, true);
        }
        match look.fill {
            Fill::None => {}
            Fill::Flat(c) => self.fill_rounded(r, radius, c),
            Fill::Gradient(top, bottom) => self.fill_gradient_rounded(r, radius, top, bottom),
        }
        if let Some(c) = look.top_light {
            self.fill_band(r, radius, 0.0, 1.0, c);
        }
        if let Some(c) = look.ring {
            self.stroke_rounded(r.inset_by(0.5, 0.5), (radius - 0.5).max(0.0), 1.0, c);
        }
        if let Some(c) = look.inset_soft {
            for (i, k) in INSET_ROWS.into_iter().enumerate() {
                self.fill_band(r, radius, i as f64, i as f64 + 1.0, c.with_alpha(c.a * k));
            }
        }
        if let Some(c) = look.halo {
            self.stroke_rounded(r.inset_by(-1.5, -1.5), radius + 1.5, 3.0, c);
        }
    }

    /// The rounded rect `r` in `c`, only the part from `from` to `to` points below its top (an inside edge light).
    fn fill_band(&mut self, r: CGRect, radius: f64, from: f64, to: f64, c: Color) {
        self.save_gstate();
        self.clip_to(CGRect::new(r.x, r.y + from, r.width, (to - from).min(r.height - from).max(0.0)));
        self.fill_rounded(r, radius, c);
        self.restore_gstate();
    }

    /// A rounded rect with a vertical gradient: one clipped fill per distinct 8-bit color, so the corners stay round.
    pub fn fill_gradient_rounded(&mut self, r: CGRect, radius: f64, top: Color, bottom: Color) {
        let rows = (f64::from(self.scale) * r.height).round().max(1.0) as usize;
        let byte = |v: f32| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
        let at = |row: usize| {
            let t = (row as f32 + 0.5) / rows as f32;
            let c = top.mix(bottom, t);
            [byte(c.r), byte(c.g), byte(c.b), byte(c.a)]
        };
        let mut start = 0;
        while start < rows {
            let key = at(start);
            let mut end = start + 1;
            while end < rows && at(end) == key {
                end += 1;
            }
            let k = f64::from(self.scale);
            let band = CGRect::new(r.x, r.y + start as f64 / k, r.width, (end - start) as f64 / k);
            self.save_gstate();
            self.clip_to(band);
            self.fill_rounded(
                r,
                radius,
                Color::new(
                    f32::from(key[0]) / 255.0,
                    f32::from(key[1]) / 255.0,
                    f32::from(key[2]) / 255.0,
                    f32::from(key[3]) / 255.0,
                ),
            );
            self.restore_gstate();
            start = end;
        }
    }

    /// The 2 pt accent keyboard focus ring around a control of `r` with corner `radius` (never removed, never animated).
    pub fn stone_focus_ring(&mut self, r: CGRect, radius: f64, t: &DrawTheme) {
        let w = f64::from(sz::FOCUS_FRAME.max(2.0));
        let grow = FOCUS_GAP + w / 2.0;
        self.stroke_rounded(r.inset_by(-grow, -grow), radius + grow, w, t.token(tk::ACCENT));
    }

    /// A stone button body of `kind` with hover and press motion and the focus ring. Returns the (pressed-scaled) rect
    /// for the label and icon, which the caller centers in it.
    pub fn stone_button(&mut self, r: CGRect, kind: ButtonKind, touch: Touch, t: &DrawTheme) -> CGRect {
        self.note(crate::canvas::Probe::Control, r);
        let live = !touch.disabled;
        let hl = hover_level(touch.hovering && live && !touch.pressed);
        let pl = press_level(self, r, touch.pressed && live);
        let rest = button_look(kind, Interaction::Rest, t);
        let look =
            rest.mix(button_look(kind, Interaction::Hover, t), hl).mix(button_look(kind, Interaction::Pressed, t), pl);
        let look = if touch.disabled { look.faded(DISABLED_ALPHA) } else { look };
        let body = pressed_rect(r, pl);
        self.stone_body(body, f64::from(rd::CONTROL), &look);
        if touch.focused {
            self.stone_focus_ring(r, f64::from(rd::CONTROL), t);
        }
        body
    }

    /// A sunken scroll or scrub track: the kit's stone well (`Scrub`, 4 pt, fully rounded) with the inset 3D look.
    pub fn stone_track(&mut self, r: CGRect, t: &DrawTheme) {
        self.stone_body(r, r.height / 2.0, &field_look(FieldState::Rest, t));
    }

    /// A sunken field body. `radius` is `radius/field` (3, number fields) or `radius/control` (4, the others).
    pub fn stone_field(&mut self, r: CGRect, radius: f64, editing: bool, touch: Touch, t: &DrawTheme) {
        let hl = hover_level(touch.hovering && !touch.disabled && !editing);
        let rest = field_look(FieldState::Rest, t);
        let look =
            if editing { field_look(FieldState::Editing, t) } else { rest.mix(field_look(FieldState::Hover, t), hl) };
        let look = if touch.disabled { look.faded(DISABLED_ALPHA) } else { look };
        self.stone_body(r, radius, &look);
        if touch.focused && !editing {
            self.stone_focus_ring(r, radius, t);
        }
    }
}

#[cfg(test)]
#[path = "stone_tests.rs"]
mod tests;
