//! Accessibility of the monitor card: the header popups (content, safe zone, zoom, quality, more) and the footer buttons
//! (mark, step, play, ..). A click runs the control like a pointer click in its middle, so popups open through the same
//! deferred menu event and the buttons through the same footer events.

use super::MonitorHost;
use accesskit::{Action, Node, NodeId, Role};
use sq_app_shell::{A11yAction, AppHost, HostCx};
use sq_draw::monitor::monitor_modes::MonitorAction;
use sq_draw::{A11y, InputEvent, InputModifiers};
use sq_draw_monitor::monitor_panel::HeaderControl;
use sq_uikit::controls_grid::CGRect;

const PANEL: &str = "monitor-card";

fn header_key(c: HeaderControl) -> String {
    format!("h:{c:?}")
}

fn footer_key(a: MonitorAction) -> String {
    format!("f:{a:?}")
}

impl MonitorHost {
    /// Pushes a popup button per header control and a button per footer action.
    pub(super) fn push_nodes(&self, a: &mut A11y) {
        if !a.is_active() {
            return;
        }
        for (ctl, _) in self.panel.header_controls() {
            let mut n = Node::new(Role::Button);
            n.set_label(self.panel.header_tip(*ctl));
            n.add_action(Action::Click);
            a.push(PANEL, Role::Button, &header_key(*ctl), n);
        }
        for (act, _) in self.panel.footer().buttons() {
            let title = sq_draw::monitor::monitor_footer::MonitorFooter::symbol(*act)
                .map_or_else(|| format!("{act:?}"), |s| s.1.to_string());
            let mut n = Node::new(Role::Button);
            n.set_label(title);
            n.add_action(Action::Click);
            a.push(PANEL, Role::Button, &footer_key(*act), n);
        }
    }

    /// The rect of the control `id` names, in panel points.
    fn control_rect(&self, id: NodeId) -> Option<CGRect> {
        let header = self
            .panel
            .header_controls()
            .iter()
            .find(|(c, _)| A11y::node_id(PANEL, Role::Button, &header_key(*c)) == id)
            .map(|(_, r)| *r);
        header.or_else(|| {
            self.panel
                .footer()
                .buttons()
                .iter()
                .find(|(a, _)| A11y::node_id(PANEL, Role::Button, &footer_key(*a)) == id)
                .map(|(_, r)| *r)
        })
    }

    /// Clicks the control `id` names; false for other ids and other actions.
    pub(super) fn run_action(&mut self, id: NodeId, action: A11yAction, cx: &mut HostCx) -> bool {
        let Some(r) = self.control_rect(id) else { return false };
        match action {
            A11yAction::Focus => true,
            A11yAction::Click => {
                let k = f64::from(self.panel.scale());
                let (x, y) = (((r.x + r.width / 2.0) * k) as f32, ((r.y + r.height / 2.0) * k) as f32);
                self.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, cx);
                self.handle(&InputEvent::MouseUp { x, y }, cx);
                true
            }
            _ => false,
        }
    }
}
