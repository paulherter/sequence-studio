//! Accessibility of the menu bar: every menu and its rows are menu item nodes. A click on a row runs its action like a
//! pointer choice does; the shell performs what the action queued in `pump`.

use super::ShellHost;
use accesskit::{Action, Node, NodeId, Role};
use sq_app_shell::{A11yAction, HostCx};
use sq_draw::A11y;
use sq_draw_shell::{FormValue, ShellCx};
use sq_uikit::sqmenu_model::{SQMenuItem, SQMenuItemKind};

const PANEL: &str = "menu";
const DIALOG: &str = "dialog";
const START: &str = "start";

fn button_key(i: usize) -> String {
    format!("b{i}")
}

fn field_key(id: &str) -> String {
    format!("f:{id}")
}

/// Pushes the rows of `items` (submenus after their row) under the key path `key`.
fn push_items(a: &mut A11y, items: &[SQMenuItem], key: &str) {
    for (i, item) in items.iter().enumerate() {
        if item.kind != SQMenuItemKind::Action {
            continue;
        }
        let key = format!("{key}/{i}");
        let mut n = Node::new(Role::MenuItem);
        n.set_label(item.title.as_str());
        if !item.shortcut.is_empty() {
            n.set_keyboard_shortcut(item.shortcut.as_str());
        }
        n.set_toggled(if item.is_checked { accesskit::Toggled::True } else { accesskit::Toggled::False });
        if !item.is_enabled {
            n.set_disabled();
        }
        n.add_action(Action::Click);
        a.push(PANEL, Role::MenuItem, &key, n);
        if let Some(sub) = &item.submenu {
            push_items(a, sub, &key);
        }
    }
}

impl ShellHost {
    /// One menu bar node, then one menu item per menu title and per row.
    pub(super) fn push_nodes(&self, a: &mut A11y) {
        if !a.is_active() {
            return;
        }
        a.push(PANEL, Role::MenuBar, "bar", Node::new(Role::MenuBar));
        for (m, menu) in self.inner.menu_bar.menus().iter().enumerate() {
            let mut n = Node::new(Role::MenuItem);
            n.set_label(menu.title.as_str());
            n.add_action(Action::Click);
            a.push(PANEL, Role::MenuItem, &m.to_string(), n);
            push_items(a, &menu.items, &m.to_string());
        }
        self.push_dialog(a);
        self.push_start(a);
    }

    /// The start window: its buttons, tabs and templates, and the recent projects as list items.
    fn push_start(&self, a: &mut A11y) {
        for s in &self.start_spots {
            let (role, mut n) = if s.is_project {
                (Role::ListItem, Node::new(Role::ListItem))
            } else if s.key.starts_with("Tab(") {
                (Role::Tab, Node::new(Role::Tab))
            } else {
                (Role::Button, Node::new(Role::Button))
            };
            n.set_label(s.label.as_str());
            if s.is_project || role == Role::Tab {
                n.set_selected(s.selected);
            }
            n.add_action(Action::Click);
            a.push(START, role, &s.key, n);
        }
    }

    /// Clicks the start window control `id` names.
    fn run_start_action(&mut self, id: NodeId, action: &A11yAction, cx: &mut HostCx) -> bool {
        let Some(spot) = self.start_spots.iter().find(|s| {
            [Role::ListItem, Role::Tab, Role::Button].into_iter().any(|r| A11y::node_id(START, r, &s.key) == id)
        }) else {
            return false;
        };
        let key = spot.key.clone();
        let done = match action {
            A11yAction::Focus => true,
            A11yAction::Click => {
                let measure = cx.measure();
                let mut sc = ShellCx { session: cx.session, measure, ui: cx.ui, hooks: self.hooks.as_mut() };
                self.inner.a11y_start_click(&mut sc, &key)
            }
            _ => false,
        };
        self.route(cx);
        done
    }

    /// The open dialog: a dialog node, its buttons and its rows (text fields take SetValue).
    fn push_dialog(&self, a: &mut A11y) {
        let Some(d) = self.inner.a11y_dialog() else { return };
        let mut n = Node::new(Role::Dialog);
        n.set_label(d.title.as_str());
        if !d.note.is_empty() {
            n.set_description(d.note.as_str());
        }
        n.set_modal();
        a.push(DIALOG, Role::Dialog, "dialog", n);
        for (i, (title, enabled)) in d.buttons.iter().enumerate() {
            let mut n = Node::new(Role::Button);
            n.set_label(title.as_str());
            n.add_action(Action::Click);
            if !enabled {
                n.set_disabled();
            }
            a.push(DIALOG, Role::Button, &button_key(i), n);
        }
        for f in &d.fields {
            let (role, mut n) = match &f.value {
                FormValue::Text(t) => {
                    let mut n = Node::new(Role::TextInput);
                    n.set_value(t.as_str());
                    n.add_action(Action::SetValue);
                    (Role::TextInput, n)
                }
                FormValue::Bool(on) => {
                    let mut n = Node::new(Role::CheckBox);
                    n.set_toggled(if *on { accesskit::Toggled::True } else { accesskit::Toggled::False });
                    n.add_action(Action::Click);
                    (Role::CheckBox, n)
                }
                FormValue::Number(v) => {
                    let mut n = Node::new(Role::SpinButton);
                    n.set_numeric_value(*v);
                    n.add_action(Action::SetValue);
                    (Role::SpinButton, n)
                }
                FormValue::Index(i) => {
                    let mut n = Node::new(Role::ComboBox);
                    if let Some(o) = usize::try_from(*i).ok().and_then(|i| f.options.get(i)) {
                        n.set_value(o.as_str());
                    }
                    n.add_action(Action::SetValue);
                    (Role::ComboBox, n)
                }
            };
            n.set_label(f.label.as_str());
            n.add_action(Action::Focus);
            a.push(DIALOG, role, &field_key(&f.id), n);
        }
    }

    /// Activates the row `id` names; false for titles, disabled rows and rows without an action.
    pub(super) fn run_action(&mut self, id: NodeId, action: A11yAction, cx: &mut HostCx) -> bool {
        if self.run_dialog_action(id, &action, cx) || self.run_start_action(id, &action, cx) {
            return true;
        }
        if action != A11yAction::Click {
            return false;
        }
        if let Some(m) =
            (0..self.inner.menu_bar.menus().len()).find(|m| A11y::node_id(PANEL, Role::MenuItem, &m.to_string()) == id)
        {
            let measure = cx.measure();
            let sc = ShellCx { session: cx.session, measure, ui: cx.ui, hooks: self.hooks.as_mut() };
            self.inner.a11y_open_menu(m, &sc);
            self.route(cx);
            return true;
        }
        let run = self
            .inner
            .menu_bar
            .menus()
            .iter()
            .enumerate()
            .find_map(|(m, menu)| row_with_id(&menu.items, &m.to_string(), id))
            .filter(|r| r.is_enabled)
            .and_then(|r| r.action.clone());
        let Some(run) = run else { return false };
        run();
        self.route(cx);
        true
    }
}

impl ShellHost {
    /// A press on a dialog button or an edit of a dialog row; false when `id` is not one of them.
    fn run_dialog_action(&mut self, id: NodeId, action: &A11yAction, cx: &mut HostCx) -> bool {
        let Some(d) = self.inner.a11y_dialog() else { return false };
        if let Some(i) = (0..d.buttons.len()).find(|i| A11y::node_id(DIALOG, Role::Button, &button_key(*i)) == id) {
            let done = *action == A11yAction::Click && self.inner.a11y_press_button(i);
            self.route(cx);
            return done;
        }
        let Some(f) = d.fields.iter().find(|f| {
            let role = match f.value {
                FormValue::Text(_) => Role::TextInput,
                FormValue::Bool(_) => Role::CheckBox,
                FormValue::Number(_) => Role::SpinButton,
                FormValue::Index(_) => Role::ComboBox,
            };
            A11y::node_id(DIALOG, role, &field_key(&f.id)) == id
        }) else {
            return false;
        };
        let value = match (&f.value, action) {
            (_, A11yAction::Focus) => return true,
            (FormValue::Bool(on), A11yAction::Click) => FormValue::Bool(!on),
            (FormValue::Text(_), A11yAction::SetText(t)) => FormValue::Text(t.clone()),
            (FormValue::Text(_) | FormValue::Number(_), A11yAction::SetValue(v)) => FormValue::Number(*v),
            (FormValue::Index(_), A11yAction::SetValue(v)) => FormValue::Index(*v as i64),
            (FormValue::Index(_), A11yAction::SetText(t)) => match f.options.iter().position(|o| o == t) {
                Some(i) => FormValue::Index(i as i64),
                None => return false,
            },
            _ => return false,
        };
        let measure = cx.measure();
        let mut sc = ShellCx { session: cx.session, measure, ui: cx.ui, hooks: self.hooks.as_mut() };
        let done = self.inner.a11y_edit_field(&mut sc, &f.id, value);
        self.route(cx);
        done
    }
}

/// The row whose node id is `id` below the key path `key`.
fn row_with_id<'a>(items: &'a [SQMenuItem], key: &str, id: NodeId) -> Option<&'a SQMenuItem> {
    for (i, item) in items.iter().enumerate() {
        let key = format!("{key}/{i}");
        if item.kind == SQMenuItemKind::Action && A11y::node_id(PANEL, Role::MenuItem, &key) == id {
            return Some(item);
        }
        if let Some(found) = item.submenu.as_deref().and_then(|sub| row_with_id(sub, &key, id)) {
            return Some(found);
        }
    }
    None
}
