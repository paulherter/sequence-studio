// Swift: TrimBar.swift
//! Trim mode's controls on the shared toolkit, translated from the Mac `TrimMonitorView` control row (52 pt): the side
//! switch Before / After / Both on the left, -5 -1 +1 +5 centered, the result note and Done on the right. The host
//! shows it while `TrimModeModel::is_active` and passes the actions to the model.

use sq_core_edit::timeline_trim_mode::{TrimPoint, TrimSide};
use sq_core_model::ClipEdge;
use sq_draw::{Canvas, DrawTheme, InputEvent, InspectorDraw, InspectorTokens, TextAlign};
use sq_editor_session::{EdgeRef, EdgeSelection, TrimModeModel};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{metrics, spacing, type_size};
use sq_uikit::localization::SQL10n;
use sq_uikit::redesign_tokens::color;

/// What a press on the trim bar asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrimBarAction {
    Side(TrimSide),
    Step(i64),
    Done,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Part {
    Side(TrimSide),
    Step(i64),
    Done,
}

/// The trim bar.
pub struct TrimBar {
    pub theme: DrawTheme,
    side: TrimSide,
    sides: Vec<TrimSide>,
    note: String,
    /// The bar in window points.
    frame: CGRect,
    scale: f32,
    hovered: Option<Part>,
    pressed: Option<Part>,
}

impl TrimBar {
    pub const HEIGHT: f64 = 52.0;
    const SEGMENT_WIDTH: f64 = 58.0;
    const STEP_WIDTH: f64 = 40.0;
    const DONE_WIDTH: f64 = 56.0;
    const SIDE_ORDER: [(TrimSide, &'static str); 3] =
        [(TrimSide::Outgoing, "Before"), (TrimSide::Incoming, "After"), (TrimSide::Roll, "Both")];

    pub fn new(theme: DrawTheme) -> Self {
        TrimBar {
            theme,
            side: TrimSide::Roll,
            sides: Vec::new(),
            note: String::new(),
            frame: CGRect::new(0.0, 0.0, 0.0, 0.0),
            scale: 1.0,
            hovered: None,
            pressed: None,
        }
    }

    pub fn side(&self) -> TrimSide {
        self.side
    }

    pub fn sides(&self) -> &[TrimSide] {
        &self.sides
    }

    pub fn note(&self) -> &str {
        &self.note
    }

    pub fn frame(&self) -> CGRect {
        self.frame
    }

    /// Reads the side, the sides the edit has and the note from the model.
    pub fn update(&mut self, m: &TrimModeModel) {
        self.side = m.side();
        self.sides = [TrimSide::Outgoing, TrimSide::Incoming, TrimSide::Roll]
            .into_iter()
            .filter(|s| m.point().is_some_and(|p| p.supports(*s)))
            .collect();
        self.note = m.note().to_string();
    }

    /// The bar fills `rect` (window points).
    pub fn layout(&mut self, rect: CGRect, scale: f32) {
        self.frame = rect;
        self.scale = scale;
    }

    fn rects(&self) -> Vec<(Part, CGRect)> {
        let gap = f64::from(spacing::SM);
        let xs = f64::from(spacing::XS);
        let h = f64::from(metrics::PANEL_HEADER) - 6.0;
        let y = self.frame.min_y() + ((self.frame.height - h) / 2.0).round();
        let mut out = Vec::new();
        for (i, s) in Self::SIDE_ORDER.iter().enumerate() {
            out.push((
                Part::Side(s.0),
                CGRect::new(self.frame.min_x() + gap + i as f64 * Self::SEGMENT_WIDTH, y, Self::SEGMENT_WIDTH, h),
            ));
        }
        let steps = TrimModeModel::STEPS;
        let row_w = steps.len() as f64 * Self::STEP_WIDTH + (steps.len() as f64 - 1.0) * xs;
        let mut x = (self.frame.mid_x() - row_w / 2.0).round();
        for n in steps {
            out.push((Part::Step(n), CGRect::new(x, y, Self::STEP_WIDTH, h)));
            x += Self::STEP_WIDTH + xs;
        }
        out.push((Part::Done, CGRect::new(self.frame.max_x() - gap - Self::DONE_WIDTH, y, Self::DONE_WIDTH, h)));
        out
    }

    fn note_rect(&self) -> CGRect {
        let steps = TrimModeModel::STEPS.len() as f64;
        let row_w = steps * Self::STEP_WIDTH + (steps - 1.0) * f64::from(spacing::XS);
        let x = self.frame.mid_x() + row_w / 2.0 + f64::from(spacing::SM);
        let right = self.frame.max_x() - f64::from(spacing::SM) * 2.0 - Self::DONE_WIDTH;
        CGRect::new(x, self.frame.min_y(), (right - x).max(0.0), self.frame.height)
    }

    fn part_at(&self, p: CGPoint) -> Option<Part> {
        self.rects().into_iter().find(|(_, r)| r.contains(p)).map(|(part, _)| part)
    }

    fn is_enabled(&self, part: Part) -> bool {
        match part {
            Part::Side(s) => self.sides.contains(&s),
            _ => true,
        }
    }

    pub fn contains(&self, x: f32, y: f32) -> bool {
        self.frame.contains(CGPoint { x: f64::from(x / self.scale), y: f64::from(y / self.scale) })
    }

    fn point(&self, x: f32, y: f32) -> CGPoint {
        let k = f64::from(self.scale.max(0.01));
        CGPoint { x: f64::from(x) / k, y: f64::from(y) / k }
    }

    /// Presses on the bar; `None` = not the bar's (pointer moves always go on).
    pub fn handle(&mut self, e: &InputEvent) -> Option<Vec<TrimBarAction>> {
        match *e {
            InputEvent::MouseDown { x, y, .. } => {
                let p = self.point(x, y);
                if !self.frame.contains(p) {
                    return None;
                }
                self.pressed = self.part_at(p).filter(|part| self.is_enabled(*part));
                Some(Vec::new())
            }
            InputEvent::MouseDragged { x, y, .. } => {
                self.pressed?;
                self.hovered = self.part_at(self.point(x, y));
                Some(Vec::new())
            }
            InputEvent::MouseUp { x, y } => {
                let was = self.pressed.take()?;
                if self.part_at(self.point(x, y)) != Some(was) {
                    return Some(Vec::new());
                }
                Some(vec![match was {
                    Part::Side(s) => TrimBarAction::Side(s),
                    Part::Step(n) => TrimBarAction::Step(n),
                    Part::Done => TrimBarAction::Done,
                }])
            }
            InputEvent::MouseMoved { x, y } => {
                let p = self.point(x, y);
                self.hovered = if self.frame.contains(p) { self.part_at(p) } else { None };
                None
            }
            _ => None,
        }
    }

    pub fn draw(&self, c: &mut Canvas) {
        if self.frame.width <= 0.0 {
            return;
        }
        let t = &self.theme;
        c.fill(self.frame, t.token(color::GROUP));
        c.fill(CGRect::new(self.frame.min_x(), self.frame.min_y(), self.frame.width, 1.0), t.token(color::ROW_LINE));
        for (part, r) in self.rects() {
            let (title, accent) = match part {
                Part::Side(s) => {
                    (Self::SIDE_ORDER.iter().find(|o| o.0 == s).map_or("", |o| o.1).to_string(), s == self.side)
                }
                Part::Step(n) => (if n > 0 { format!("+{n}") } else { n.to_string() }, false),
                Part::Done => ("Done".to_string(), false),
            };
            InspectorDraw::button(
                c,
                &SQL10n::string(&title),
                r,
                self.hovered == Some(part),
                self.pressed == Some(part),
                self.is_enabled(part),
                accent,
                f64::from(InspectorTokens::CAPSULE),
                t,
            );
        }
        if !self.note.is_empty() {
            c.draw_text_in(
                &SQL10n::string(&self.note),
                self.note_rect(),
                f64::from(type_size::BODY),
                t.label2(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
    }

    /// The edit and the trimmed side as the timeline's edge selection (the Mac `syncTrimMode`): the outgoing tail, the
    /// incoming head, or both for a roll; a side trim ripples. `None` when the edit lacks that side.
    pub fn edges(p: &TrimPoint, side: TrimSide) -> Option<EdgeSelection> {
        let mut edges = Vec::new();
        match side {
            TrimSide::Outgoing => {
                if let Some(o) = p.outgoing {
                    edges = vec![EdgeRef::new(o, ClipEdge::Tail)];
                }
            }
            TrimSide::Incoming => {
                if let Some(i) = p.incoming {
                    edges = vec![EdgeRef::new(i, ClipEdge::Head)];
                }
            }
            TrimSide::Roll => {
                if let (Some(o), Some(i)) = (p.outgoing, p.incoming) {
                    edges = vec![EdgeRef::new(o, ClipEdge::Tail), EdgeRef::new(i, ClipEdge::Head)];
                }
            }
        }
        if edges.is_empty() { None } else { Some(EdgeSelection::new(edges, side != TrimSide::Roll, true)) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::{Id, Time};
    use sq_draw::InputModifiers;

    fn point(out: bool, inc: bool) -> TrimPoint {
        TrimPoint {
            track: Id::from_u128(1),
            outgoing: out.then(|| Id::from_u128(2)),
            incoming: inc.then(|| Id::from_u128(3)),
            time: Time::new(1, 1),
        }
    }

    fn bar() -> TrimBar {
        let mut b = TrimBar::new(DrawTheme::default());
        b.layout(CGRect::new(0.0, 0.0, 600.0, TrimBar::HEIGHT), 1.0);
        b.sides = vec![TrimSide::Outgoing, TrimSide::Incoming, TrimSide::Roll];
        b
    }

    fn click(b: &mut TrimBar, p: CGPoint) -> Option<Vec<TrimBarAction>> {
        let (x, y) = (p.x as f32, p.y as f32);
        b.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE });
        b.handle(&InputEvent::MouseUp { x, y })
    }

    fn center(b: &TrimBar, part: Part) -> CGPoint {
        let r = b.rects().into_iter().find(|(p, _)| *p == part).map(|(_, r)| r).unwrap_or_default();
        CGPoint { x: r.mid_x(), y: r.mid_y() }
    }

    #[test]
    fn edges_follow_the_trimmed_side() {
        let both = point(true, true);
        let roll = TrimBar::edges(&both, TrimSide::Roll);
        assert_eq!(roll.as_ref().map(|e| (e.edges.len(), e.ripple)), Some((2, false)));
        let out = TrimBar::edges(&both, TrimSide::Outgoing);
        assert_eq!(out.as_ref().map(|e| (e.edges[0].edge, e.ripple)), Some((ClipEdge::Tail, true)));
        let inc = TrimBar::edges(&both, TrimSide::Incoming);
        assert_eq!(inc.as_ref().map(|e| e.edges[0].edge), Some(ClipEdge::Head));
        assert!(TrimBar::edges(&point(true, false), TrimSide::Roll).is_none());
        assert!(TrimBar::edges(&point(false, true), TrimSide::Outgoing).is_none());
    }

    #[test]
    fn a_press_and_release_on_one_part_reports_it() {
        let mut b = bar();
        let c = center(&b, Part::Step(-5));
        assert_eq!(click(&mut b, c), Some(vec![TrimBarAction::Step(-5)]));
        let c = center(&b, Part::Done);
        assert_eq!(click(&mut b, c), Some(vec![TrimBarAction::Done]));
        let c = center(&b, Part::Side(TrimSide::Incoming));
        assert_eq!(click(&mut b, c), Some(vec![TrimBarAction::Side(TrimSide::Incoming)]));
    }

    #[test]
    fn releasing_elsewhere_or_on_a_disabled_side_reports_nothing() {
        let mut b = bar();
        b.sides = vec![TrimSide::Roll];
        let c = center(&b, Part::Side(TrimSide::Outgoing));
        // A disabled side takes the press but never becomes pressed, so the release is not the bar's.
        assert_eq!(click(&mut b, c), None);
        let down = center(&b, Part::Step(1));
        b.handle(&InputEvent::MouseDown { x: down.x as f32, y: down.y as f32, modifiers: InputModifiers::NONE });
        assert_eq!(b.handle(&InputEvent::MouseUp { x: 5.0, y: 5.0 }), Some(Vec::new()));
    }

    #[test]
    fn presses_outside_the_bar_are_not_the_bars() {
        let mut b = bar();
        assert_eq!(b.handle(&InputEvent::MouseDown { x: 10.0, y: 200.0, modifiers: InputModifiers::NONE }), None);
        assert_eq!(b.handle(&InputEvent::MouseUp { x: 10.0, y: 200.0 }), None);
        assert!(b.contains(10.0, 10.0) && !b.contains(10.0, 200.0));
    }

    #[test]
    fn layout_puts_sides_left_steps_centered_and_done_right() {
        let b = bar();
        let rects = b.rects();
        assert_eq!(rects.len(), 8);
        let side0 = rects[0].1;
        let done = rects[7].1;
        assert_eq!(side0.x, 8.0);
        assert_eq!(done.max_x(), 600.0 - 8.0);
        let step_first = rects[3].1;
        let step_last = rects[6].1;
        assert!(((step_first.x + step_last.max_x()) / 2.0 - 300.0).abs() <= 1.0);
        assert!(b.note_rect().width > 0.0);
    }
}
