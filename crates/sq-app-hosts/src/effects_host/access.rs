//! Accessibility of the Effects panel: a list with one item per row (folders and headings open and close, items are
//! selected and applied by a click, the way a double click does).

use super::EffectsHost;
use accesskit::{Action, Node, NodeId, Role};
use sq_app_shell::A11yAction;
use sq_draw::A11y;

const PANEL: &str = "effects";

impl EffectsHost {
    /// Pushes the list and its rows.
    pub(super) fn push_nodes(&self, a: &mut A11y) {
        if !a.is_active() {
            return;
        }
        let panel = &self.inner.panel;
        let mut list = Node::new(Role::List);
        list.set_label("Effects");
        a.push(PANEL, Role::List, "list", list);
        for r in panel.rows() {
            let mut n = Node::new(Role::ListItem);
            n.set_label(r.title.as_str());
            if !r.subtitle.is_empty() {
                n.set_description(r.subtitle.as_str());
            }
            if r.is_folder || r.is_header {
                n.set_expanded(r.is_expanded);
            } else {
                n.set_selected(panel.selected_id() == Some(r.id.as_str()));
            }
            n.add_action(Action::Click);
            a.push(PANEL, Role::ListItem, &r.id, n);
        }
    }

    /// Clicks the row `id` names; false for other ids and other actions.
    pub(super) fn run_action(&mut self, id: NodeId, action: A11yAction) -> bool {
        let panel = &mut self.inner.panel;
        let Some(row) =
            panel.rows().iter().find(|r| A11y::node_id(PANEL, Role::ListItem, &r.id) == id).map(|r| r.id.clone())
        else {
            return false;
        };
        match action {
            A11yAction::Focus => true,
            A11yAction::Click => {
                let done = panel.a11y_activate(&row);
                self.route();
                done
            }
            _ => false,
        }
    }
}
