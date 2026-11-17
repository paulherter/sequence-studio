//! Accessibility of the Library: a list with one item per file, preset and section heading. A click selects the item like
//! a pointer click; a preset also runs its double-click action (place the template, insert the title, apply the effect).

use super::LibraryHost;
use accesskit::{Action, Node, NodeId, Role};
use sq_app_shell::{A11yAction, HostCx};
use sq_draw::{A11y, InputModifiers};
use sq_draw_library::library::library_draw_panel::Cell;
use sq_uikit::controls_grid::CGPoint;

const PANEL: &str = "library";

fn title(c: &Cell) -> String {
    match c {
        Cell::Header(g) => g.title.clone(),
        Cell::Item(it) => it.entry.name().to_string(),
        Cell::Preset(p) => p.name().to_string(),
    }
}

impl LibraryHost {
    /// Pushes the list and its cells (the ones in the cell list, scrolled out or not).
    pub(super) fn push_nodes(&self, a: &mut A11y) {
        if !a.is_active() {
            return;
        }
        let panel = &self.inner.panel;
        let mut list = Node::new(Role::List);
        list.set_label("Library");
        a.push(PANEL, Role::List, "list", list);
        for c in panel.cells() {
            let header = c.is_header();
            let mut n = Node::new(if header { Role::Heading } else { Role::ListItem });
            n.set_label(title(c));
            if !header {
                n.set_selected(panel.selected().contains(&c.key()));
                n.add_action(Action::Click);
            }
            a.push(PANEL, if header { Role::Heading } else { Role::ListItem }, &c.key(), n);
        }
    }

    /// Clicks the cell `id` names: selects it, and activates a preset; false for other ids, actions and hidden cells.
    pub(super) fn run_action(&mut self, id: NodeId, action: A11yAction, cx: &mut HostCx) -> bool {
        let panel = &mut self.inner.panel;
        let Some((index, cell)) = panel
            .cells()
            .iter()
            .enumerate()
            .find(|(_, c)| !c.is_header() && A11y::node_id(PANEL, Role::ListItem, &c.key()) == id)
            .map(|(i, c)| (i, c.clone()))
        else {
            return false;
        };
        match action {
            A11yAction::Focus => true,
            A11yAction::Click => {
                // Scroll the cell into view (the wheel moves the offset by -dy), then press and release in its middle.
                let Some(placed) = panel.placed().into_iter().find(|p| p.index == index) else { return false };
                let list = panel.list_rect();
                let top = panel.cell_rect(&placed).min_y();
                if top < list.min_y() || top > list.max_y() - 1.0 {
                    let mid = CGPoint::new(list.x + list.width / 2.0, list.y + list.height / 2.0);
                    panel.scroll_at(mid, None, list.min_y() + list.height / 2.0 - top);
                }
                let r = panel.cell_rect(&placed);
                let p = CGPoint::new(r.x + r.width / 2.0, r.y + r.height / 2.0);
                panel.mouse_down(p, InputModifiers::NONE, cx.ui.now);
                panel.mouse_up(p);
                if let Cell::Preset(preset) = &cell {
                    panel.activate(preset);
                }
                self.route(cx);
                true
            }
            _ => false,
        }
    }
}
