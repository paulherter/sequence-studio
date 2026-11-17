//! Accessibility of the Color page: the viewer header's compare modes and menu button, the buttons at the end of the
//! panels' tab strips, the Sources tiles, the Steps boxes and the grade panel's controls (sliders, wheels, tabs, menus). Each panel keeps its own geometry, so a node's rect is
//! looked up there; a click runs the control like a pointer click in its middle.

use super::{ColorPageHost, Part};
use accesskit::{Action, Node, NodeId, Role};
use sq_app_shell::{A11yAction, HostCx};
use sq_draw::{A11y, InputEvent, InputModifiers};
use sq_inspector_ui::color::color_viewer_header_draw::{ColorStripToolsDraw, StripButton, ViewerHeaderControl};
use sq_uikit::controls_grid::CGRect;

const PANEL: &str = "color-page";

/// One control: its stable key, role, label and rect in window points.
struct Target {
    key: String,
    role: Role,
    label: String,
    rect: CGRect,
}

fn button_label(b: StripButton) -> &'static str {
    match b {
        StripButton::AddStep => "Add Step",
        StripButton::Sequence => "Sequence",
        StripButton::Mode => "Edit Mode",
        StripButton::Fit => "Fit",
        StripButton::TimelineMore => "More",
        StripButton::Simple => "Simple",
        StripButton::Pro => "Pro",
        StripButton::More => "More",
    }
}

fn moved(r: CGRect, by: CGRect) -> CGRect {
    CGRect::new(r.x + by.x, r.y + by.y, r.width, r.height)
}

impl ColorPageHost {
    /// Every control the page shows right now; empty off the Color page.
    fn targets(&self) -> Vec<Target> {
        let mut out = Vec::new();
        if !self.on_color_page {
            return out;
        }
        let at = |part: Part| self.frames.get(&part).copied().filter(|f| f.width > 0.0 && f.height > 0.0);
        if let Some(f) = at(Part::Header) {
            for (control, r) in self.header.frames() {
                let (key, label) = match control {
                    ViewerHeaderControl::Compare(m) => (format!("compare:{m:?}"), m.title().to_string()),
                    ViewerHeaderControl::More => ("header-more".to_string(), "More".to_string()),
                };
                out.push(Target { key, role: Role::Button, label, rect: moved(r, f) });
            }
        }
        for (sp, strip) in &self.strips {
            for (b, r) in ColorStripToolsDraw::frames(*sp, *strip) {
                out.push(Target {
                    key: format!("strip:{sp:?}:{b:?}"),
                    role: Role::Button,
                    label: button_label(b).to_string(),
                    rect: r,
                });
            }
        }
        if let (Some(f), Some(c)) = (at(Part::Sources), &self.controller) {
            for (i, name) in self.source_names.iter().enumerate() {
                let r = self.sources.tile_rect(c, i);
                out.push(Target {
                    key: format!("source:{i}"),
                    role: Role::Button,
                    label: name.clone(),
                    rect: moved(r, f),
                });
            }
        }
        if let (Some(f), Some(model)) = (at(Part::Steps), self.controller.as_ref().and_then(|c| c.model())) {
            let layout = self.steps.canvas().layout();
            for id in &layout.order {
                let (Some(step), Some(r)) = (model.step(*id), layout.rects.get(id)) else { continue };
                let rect = moved(self.steps.canvas().view_rect(r), f);
                out.push(Target { key: format!("step:{id:?}"), role: Role::Button, label: step.label.clone(), rect });
            }
        }
        if let (Some(f), Some(c)) = (at(Part::Grade), &self.controller)
            && let Some(model) = c.model()
        {
            for (key, label, slider, rect) in self.grade.a11y_controls(model, c.steps_shown()) {
                let role = if slider { Role::Slider } else { Role::Button };
                out.push(Target { key: format!("grade:{key}"), role, label, rect: moved(rect, f) });
            }
        }
        out
    }

    /// Pushes one node per control; nothing while assistive tech is off.
    pub(super) fn push_nodes(&self, a: &mut A11y) {
        if !a.is_active() {
            return;
        }
        for t in self.targets() {
            let mut n = Node::new(t.role);
            n.set_label(t.label);
            n.add_action(Action::Click);
            a.push(PANEL, t.role, &t.key, n);
        }
    }

    /// Clicks the control `id` names; false for other ids and other actions.
    pub(super) fn run_action(&mut self, id: NodeId, action: A11yAction, cx: &mut HostCx) -> bool {
        let Some(t) = self.targets().into_iter().find(|t| A11y::node_id(PANEL, t.role, &t.key) == id) else {
            return false;
        };
        match action {
            A11yAction::Focus => true,
            A11yAction::Click => {
                let k = f64::from(cx.scale);
                let (x, y) =
                    (((t.rect.x + t.rect.width / 2.0) * k) as f32, ((t.rect.y + t.rect.height / 2.0) * k) as f32);
                self.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, cx);
                self.handle(&InputEvent::MouseUp { x, y }, cx);
                true
            }
            _ => false,
        }
    }
}
