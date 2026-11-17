// Swift: ShellFocusedEdit.swift
//! Cut, Copy, Paste, Select All and Delete follow the focused panel (the AppKit `executeFocusedEdit`, one table:
//! `CommandRouting::edit_route`). A panel that has no such command swallows the key, so it never reaches the timeline's
//! clips; the Graphics and Captions panels run their own action (`ShellHooks::edit_action`, set by their hosts).
//!
//! Mapping: the Swift `projectList` reference is the hooks' `has_project_list` / `delete_project_selection` (the Project
//! list belongs to the app root); `editActions[a]?()` is `ShellHooks::edit_action(a)`.

use crate::shell_host::{ShellCx, ShellHost};
use sq_editor_session::{CommandRouting, EditAction};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::focus_routing::{EditVerb, FocusedEditTarget};

impl ShellHost {
    /// Delete Project Items, and Edit > Delete with the Project or Library focused, remove the selected items (the AppKit
    /// `CommandRouting.editRoute` target `.project`). False = not this route.
    pub(crate) fn run_focused_delete(&mut self, cx: &mut ShellCx, c: EditorCommand) -> bool {
        if !self.focused_deletes_project(c) || !cx.hooks.has_project_list() {
            return false;
        }
        cx.hooks.delete_project_selection(self, cx.session);
        true
    }

    pub(crate) fn focused_deletes_project(&self, c: EditorCommand) -> bool {
        c == EditorCommand::DeleteProjectItems
            || (c == EditorCommand::Delete
                && CommandRouting::edit_route(FocusedEditTarget::from_panel(self.focus), EditVerb::Delete).action
                    == EditAction::DeleteProjectItems)
    }

    /// `None` = this route does not decide (timeline, Effect Controls, Project): the generic path goes on.
    pub(crate) fn run_focused_edit(&mut self, cx: &mut ShellCx, c: EditorCommand) -> Option<bool> {
        let verb = EditVerb::from_command(&c)?;
        let facts = self.current_facts(cx.session, &*cx.hooks);
        if facts.text_editing || CommandRouting::focus_override(&c, self.focus).is_some() {
            return None;
        }
        if CommandRouting::deletes_monitor_layers(c, self.focus, facts.graphics_has_selection.unwrap_or(false)) {
            cx.hooks.edit_action(EditAction::DeleteGraphicsLayers);
            return Some(true);
        }
        let route = CommandRouting::edit_route(FocusedEditTarget::from_panel(self.focus), verb);
        match route.action {
            EditAction::Swallow => Some(true),
            EditAction::DeleteGraphicsLayers | EditAction::SelectAllGraphicsLayers | EditAction::DeleteCaptions => {
                if self.menu_enabled(cx.session, &*cx.hooks, c) {
                    cx.hooks.edit_action(route.action);
                }
                Some(true)
            }
            EditAction::EffectControls => {
                // With nothing to act on the panel does nothing: Controls has the focus, so the key must not reach the clips.
                cx.hooks.edit_effect_controls(c);
                Some(true)
            }
            EditAction::FallThrough | EditAction::DeleteProjectItems | EditAction::PasteMedia => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell_host::{ShellHooks, ShellHost};
    use sq_uikit::panel_id::PanelID;

    #[derive(Default)]
    struct Hooks {
        actions: Vec<EditAction>,
        deleted: bool,
        list: bool,
    }

    impl ShellHooks for Hooks {
        fn has_project_list(&self) -> bool {
            self.list
        }
        fn delete_project_selection(&mut self, _host: &mut ShellHost, _session: &mut sq_editor_session::EditorSession) {
            self.deleted = true;
        }
        fn edit_action(&mut self, a: EditAction) {
            self.actions.push(a);
        }
    }

    #[test]
    fn delete_project_items_always_targets_the_project() {
        let (mut host, mut session): (ShellHost, sq_editor_session::EditorSession) =
            (crate::test_support::shell(), crate::test_support::session());
        assert!(host.focused_deletes_project(EditorCommand::DeleteProjectItems));
        host.focus = Some(PanelID::Project);
        assert!(host.focused_deletes_project(EditorCommand::Delete));
        host.focus = Some(PanelID::Timeline);
        assert!(!host.focused_deletes_project(EditorCommand::Delete));
        let mut hooks = Hooks { list: true, ..Hooks::default() };
        let mut ui = sq_draw::UiCx::default();
        let mut cx = ShellCx {
            session: &mut session,
            measure: sq_draw::TextMeasure::new(None, 1.0),
            ui: &mut ui,
            hooks: &mut hooks,
        };
        assert!(host.run_focused_delete(&mut cx, EditorCommand::DeleteProjectItems));
        assert!(hooks.deleted);
    }

    #[test]
    fn a_panel_without_the_command_swallows_the_key() {
        let (mut host, mut session): (ShellHost, sq_editor_session::EditorSession) =
            (crate::test_support::shell(), crate::test_support::session());
        host.focus = Some(PanelID::Effects);
        let mut hooks = Hooks::default();
        let mut ui = sq_draw::UiCx::default();
        let mut cx = ShellCx {
            session: &mut session,
            measure: sq_draw::TextMeasure::new(None, 1.0),
            ui: &mut ui,
            hooks: &mut hooks,
        };
        assert_eq!(host.run_focused_edit(&mut cx, EditorCommand::Copy), Some(true));
    }
}
