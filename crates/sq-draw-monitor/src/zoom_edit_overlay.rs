// Swift: ZoomEditOverlay.swift
//! Dynamic Zoom editor on the Program monitor (the Mac `ZoomEditOverlayView` on the draw list): the Start and End windows
//! of the clip's picture with corner handles (a corner resizes, the body moves), the "End zoom" field and Done at the
//! bottom center. Geometry is `ZoomEditGeometry`; the host writes the windows into the clip (one undo step per drag).
//! Coordinates are window points, like the rest of `MonitorPanel`.

use crate::transform_overlay::Phase;
use sq_core_effects::dynamic_zoom::ZoomRect;
use sq_core_model::ClipTransform;
use sq_core_time::Vec2;
use sq_draw::canvas::Canvas;
use sq_draw::inspector::scrub_field_control::Event as FieldEvent;
use sq_draw::monitor::transform_overlay_geometry::TransformOverlayGeometry;
use sq_draw::monitor::zoom_edit_geometry::{Hit, Which, ZoomEditGeometry};
use sq_draw::theme::{DrawTheme, radius, spacing, type_size};
use sq_draw::{InputKey, InputModifiers, InspectorDraw, ScrubFieldControl, TextAlign, UiCx};
use sq_editor_session::EditorSession;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};

/// What the editor reports.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ZoomEditEvent {
    /// A window changed (live): the host writes it into the clip's stage.
    Change(Phase, ZoomRect, ZoomRect),
    /// Done was pressed, or Esc closed the editor.
    Done,
}

/// The Dynamic Zoom editor.
pub struct ZoomEditOverlay {
    /// The geometry over the picture, set by the host.
    pub geometry: ZoomEditGeometry,
    /// The Start window.
    pub start: ZoomRect,
    end: ZoomRect,
    /// What the editor reported since the owner last took it.
    pub events: Vec<ZoomEditEvent>,
    field: ScrubFieldControl,
    drag: Option<(Hit, CGPoint, (ZoomRect, ZoomRect))>,
    field_pressed: bool,
    done_pressed: bool,
    field_rect: CGRect,
    done_rect: CGRect,
}

impl Default for ZoomEditOverlay {
    fn default() -> Self {
        Self::new()
    }
}

impl ZoomEditOverlay {
    /// Width of the "End zoom" field.
    pub const FIELD_WIDTH: f64 = 150.0;
    /// Width of Done.
    pub const DONE_WIDTH: f64 = 60.0;
    /// Height of both.
    pub const CONTROL_HEIGHT: f64 = 24.0;

    /// An editor over a 1920 x 1080 layer, Start = the full picture, End = 125 %.
    pub fn new() -> ZoomEditOverlay {
        let mut f = ScrubFieldControl::new(125.0);
        f.unit = "%".to_string();
        f.range = 100.0..=10_000.0;
        f.step = 5.0;
        f.default_value = Some(EditorSession::DYNAMIC_ZOOM_AMOUNT * 100.0);
        let layer = TransformOverlayGeometry::new(
            CGSize::new(1920.0, 1080.0),
            CGRect::default(),
            16.0 / 9.0,
            ClipTransform::IDENTITY,
            None,
        );
        let mut o = ZoomEditOverlay {
            geometry: ZoomEditGeometry::new(layer),
            start: ZoomRect::FULL,
            end: ZoomRect::centred(1.25, Vec2::new(0.5, 0.5)),
            events: Vec::new(),
            field: f,
            drag: None,
            field_pressed: false,
            done_pressed: false,
            field_rect: CGRect::default(),
            done_rect: CGRect::default(),
        };
        o.sync_field();
        o
    }

    /// The End window.
    pub fn end(&self) -> ZoomRect {
        self.end
    }

    /// Sets the End window (the field follows).
    pub fn set_end(&mut self, e: ZoomRect) {
        self.end = e;
        self.sync_field();
    }

    /// The "End zoom" field.
    pub fn field(&self) -> &ScrubFieldControl {
        &self.field
    }

    /// Where the field sits.
    pub fn field_rect(&self) -> CGRect {
        self.field_rect
    }

    /// Where Done sits.
    pub fn done_rect(&self) -> CGRect {
        self.done_rect
    }

    /// A drag, the field or Done is pressed.
    pub fn is_dragging(&self) -> bool {
        self.drag.is_some() || self.field_pressed || self.done_pressed
    }

    fn sync_field(&mut self) {
        if !self.field.is_dragging() && !self.field.is_editing() {
            self.field.value = (self.end.zoom() * 100.0).round();
        }
    }

    /// Lays the field and Done out at the bottom center of `slot` (window points).
    pub fn layout(&mut self, slot: CGRect) {
        let h = Self::CONTROL_HEIGHT;
        let gap = spacing::SM as f64;
        let x = (slot.mid_x() - (Self::FIELD_WIDTH + Self::DONE_WIDTH + gap) / 2.0).round();
        let y = slot.max_y() - h - spacing::MD as f64;
        self.field_rect = CGRect::new(x, y, Self::FIELD_WIDTH, h);
        self.done_rect = CGRect::new(x + Self::FIELD_WIDTH + gap, y, Self::DONE_WIDTH, h);
    }

    // MARK: Events (window points; `scale` = pixels per point for the field)

    /// True when the press was the editor's (a window, a handle, the field or Done). A press elsewhere on the picture
    /// ends a typed field edit and goes on.
    pub fn mouse_down(&mut self, p: CGPoint, click_count: i64, scale: f32) -> bool {
        if self.field_rect.contains(p) {
            self.field_pressed = true;
            let ev = self.field.mouse_down(p.x as f32 * scale, click_count);
            self.apply(ev);
            return true;
        }
        if self.field.is_editing() {
            let ev = self.field.commit_editing();
            self.apply(ev);
        }
        if self.done_rect.contains(p) {
            self.done_pressed = true;
            return true;
        }
        let Some(hit) = self.geometry.hit_test(p, &self.start, &self.end, 8.0) else { return false };
        self.drag = Some((hit, p, (self.start, self.end)));
        self.events.push(ZoomEditEvent::Change(Phase::Began, self.start, self.end));
        true
    }

    /// The pointer moved with the button down.
    pub fn mouse_dragged(&mut self, p: CGPoint, modifiers: InputModifiers, scale: f32, cx: &mut UiCx) {
        if self.field_pressed {
            let ev = self.field.mouse_dragged(p.x as f32 * scale, modifiers, scale, cx);
            self.apply(ev);
            return;
        }
        let Some((hit, press, base)) = self.drag else { return };
        (self.start, self.end) = self.geometry.dragged(hit, press, p, base);
        self.events.push(ZoomEditEvent::Change(Phase::Changed, self.start, self.end));
    }

    /// The button went up.
    pub fn mouse_up(&mut self, p: CGPoint, cx: &mut UiCx) {
        if self.field_pressed {
            self.field_pressed = false;
            let ev = self.field.mouse_up(cx);
            self.apply(ev);
            return;
        }
        if self.done_pressed {
            self.done_pressed = false;
            if self.done_rect.contains(p) {
                self.events.push(ZoomEditEvent::Done);
            }
            return;
        }
        if self.drag.take().is_none() {
            return;
        }
        self.events.push(ZoomEditEvent::Change(Phase::Ended, self.start, self.end));
    }

    /// Typing in the field (Enter commits, Esc cancels); Esc with nothing open closes the editor. False: not the editor's.
    pub fn key(&mut self, k: InputKey, modifiers: InputModifiers, now: f64, cx: &mut UiCx) -> bool {
        if self.field.is_editing() || self.field.is_dragging() {
            let ev = self.field.key(k, modifiers, now, cx);
            self.apply(ev);
            return true;
        }
        if k == InputKey::Escape {
            if let Some((_, _, base)) = self.drag.take() {
                (self.start, self.end) = base;
                self.events.push(ZoomEditEvent::Change(Phase::Ended, self.start, self.end));
                return true;
            }
            self.events.push(ZoomEditEvent::Done);
            return true;
        }
        false
    }

    fn apply(&mut self, events: Vec<FieldEvent>) {
        for e in events {
            match e {
                FieldEvent::Begin => self.events.push(ZoomEditEvent::Change(Phase::Began, self.start, self.end)),
                FieldEvent::Live(v) | FieldEvent::Change(v) => {
                    self.end = self.end.with_zoom(v / 100.0);
                    self.events.push(ZoomEditEvent::Change(Phase::Changed, self.start, self.end));
                }
                FieldEvent::End(v) | FieldEvent::Cancel(v) => {
                    self.end = self.end.with_zoom(v / 100.0);
                    self.events.push(ZoomEditEvent::Change(Phase::Ended, self.start, self.end));
                }
            }
        }
        self.sync_field();
    }

    // MARK: Drawing

    /// Draws both windows, the move between them, the field and Done.
    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        for (which, r) in [(Which::Start, self.start), (Which::End, self.end)] {
            let q = self.geometry.quad_of(&r);
            let color = if which == Which::End { t.accent() } else { t.on_picture_stroke() };
            c.stroke_polygon(&q, 3.0, t.on_picture_shadow());
            if which == Which::Start {
                c.stroke_dashed(&q, true, 1.5, 5.0, 4.0, 0.0, color);
            } else {
                c.stroke_polygon(&q, 1.5, color);
            }
            for p in &q {
                let h = CGRect::new(p.x - 4.0, p.y - 4.0, 8.0, 8.0);
                c.fill_ellipse(h, color);
                c.stroke_ellipse(h, 1.0, t.on_picture_shadow());
            }
            let label = format!(
                "{}{} %",
                if which == Which::Start { "Start " } else { "End " },
                (r.zoom() * 100.0).round() as i64
            );
            c.draw_text(
                &label,
                CGPoint::new(q[0].x + 6.0, q[0].y + 4.0),
                type_size::CAPTION as f64,
                color,
                f64::INFINITY,
                0,
            );
        }
        // The move from the Start window to the End window.
        c.stroke_line(self.geometry.centre_of(&self.start), self.geometry.centre_of(&self.end), 1.0, t.guide());
        let fr = self.field_rect;
        c.fill_rounded(fr.inset_by(-2.0, -2.0), radius::CONTROL as f64, t.viewer_hud());
        c.draw_text_in(
            "End zoom",
            CGRect::new(fr.min_x(), fr.min_y(), 64.0, fr.height),
            type_size::BODY as f64,
            t.label2(),
            TextAlign::Left,
            6.0,
            0,
        );
        self.field.draw(
            c,
            CGRect::new(fr.min_x() + 64.0, fr.min_y(), fr.width - 64.0, fr.height),
            t,
            self.field.is_editing(),
            cx,
        );
        InspectorDraw::button(c, "Done", self.done_rect, false, self.done_pressed, true, true, 22.0, t);
    }
}
