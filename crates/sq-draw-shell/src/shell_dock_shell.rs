// Swift: ShellDock+Shell.swift
//! The Window menu's workspace and panel rows, the panel commands (Show <Panel>, Maximize, Reset to Saved Layout, next /
//! previous panel), Window > History on the shell (the Mac `AppController` workspace actions, `showHistory` translated).
//!
//! Not ported: Help > Welcome Tour (`showWelcome`, `presentWelcomeIfNeeded`): its text lives in `OnboardingContent`
//! (ES10, not in `sq-editor-session` yet); the arm answers "not available" until it lands.

use crate::shell_dialog::{FormValue, ShellDialog};
use crate::shell_dock::DockEvent;
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row as FormRow, ShellForm};
use crate::shell_host::{ShellCx, ShellFlow, ShellHost};
use crate::shell_menu_bar::{ShellAction, ShellMenuState};
use sq_draw::TextMeasure;
use sq_editor_session::{EditorSession, WorkspacePage};
use sq_runtime::UiRef;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::localization::SQL10n;
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};

impl ShellHost {
    /// Applies what the dock reported since the last call: the key map's scope follows the focused panel (`onFocus`), a tab
    /// menu opens in the shell's menus (`presentMenu`). The rest waits for [`ShellHost::take_dock_events`].
    pub fn sync_dock(&mut self, m: &TextMeasure) {
        for e in self.dock.take_events() {
            match e {
                DockEvent::Focus(p) => {
                    self.focus = Some(p);
                    self.dock_focus_out = Some(p);
                }
                DockEvent::PresentMenu(items, at) => self.menu_bar.controller.present(items, at, None, None, None, m),
                other => self.dock_out.push(other),
            }
        }
    }

    /// The panel the shell's dock focused since the last call; the app's own dock takes it over.
    pub fn take_dock_focus(&mut self) -> Option<PanelID> {
        self.dock_focus_out.take()
    }

    /// The dock's notices for the app (save the layouts, relayout the panels, open or raise a window), in order.
    pub fn take_dock_events(&mut self) -> Vec<DockEvent> {
        std::mem::take(&mut self.dock_out)
    }

    /// Window rows the dock owns; true when handled.
    pub(crate) fn perform_window(&mut self, cx: &mut ShellCx, a: &ShellAction) -> bool {
        match a {
            ShellAction::SelectWorkspace(name) => self.dock.choose_workspace(name),
            ShellAction::SaveWorkspaceAs => self.start_flow(ShellFlow::SaveWorkspaceAs),
            ShellAction::RenameWorkspace => self.start_flow(ShellFlow::RenameWorkspace),
            ShellAction::DeleteWorkspace => self.start_flow(ShellFlow::DeleteWorkspace),
            ShellAction::ResetLayout => self.dock.reset_layout(),
            ShellAction::ResetAllWorkspaces => self.dock.reset_all(),
            ShellAction::TogglePanel(p) => {
                self.dock.toggle(*p);
                self.focus = self.dock.focused();
            }
            ShellAction::Minimize => {
                self.emit(crate::shell_host::ShellEvent::Window(crate::shell_host::WindowOp::Minimize));
                return true;
            }
            ShellAction::Zoom => {
                self.emit(crate::shell_host::ShellEvent::Window(crate::shell_host::WindowOp::ToggleMaximize));
                return true;
            }
            ShellAction::History => self.start_flow(ShellFlow::History),
            ShellAction::WelcomeTour => self.start_flow(ShellFlow::Welcome),
            _ => return false,
        }
        self.sync_dock(&cx.measure);
        true
    }

    /// The panel commands; `None` when `c` is not one of them.
    pub(crate) fn execute_panel_command(&mut self, cx: &mut ShellCx, c: EditorCommand) -> Option<bool> {
        match c {
            EditorCommand::FocusPanel(p) => {
                // Window > Sources: the clip list lives on the Color page (the Mac `showPanel`).
                if p == PanelID::ColorClips {
                    self.dock.set_page(WorkspacePage::Color);
                }
                self.dock.show(p);
            }
            EditorCommand::MaximizePanel => {
                let Some(p) = self.dock.pointer.and_then(|at| self.dock.panel_at(at)).or(self.focus) else {
                    return Some(false);
                };
                self.dock.toggle_maximize(p);
            }
            EditorCommand::MaximizeActivePanel => {
                let Some(p) = self.focus.or(self.dock.focused()) else { return Some(false) };
                self.dock.toggle_maximize(p);
            }
            EditorCommand::ResetLayout => self.dock.reset_layout(),
            EditorCommand::SelectNextPanel | EditorCommand::SelectPreviousPanel => {
                let Some(p) = self.dock.cycle(self.focus, c == EditorCommand::SelectNextPanel) else {
                    return Some(false);
                };
                self.dock.set_focused(Some(p));
            }
            _ => return None,
        }
        self.focus = self.dock.focused().or(self.focus);
        self.sync_dock(&cx.measure);
        Some(true)
    }

    /// Fills the Window menu rows the dock knows.
    pub(crate) fn fill_window_state(&self, session: &EditorSession, s: &mut ShellMenuState) {
        s.workspaces = self.dock.store().library.names();
        s.current_workspace = Some(self.dock.store().edit_name.clone());
        s.visible_panels = self.dock.visible_panels();
        s.unavailable_panels = self.dock.transiently_hidden().clone();
        // pending: ShellStart (`startScreen == nil ? session.displayName : nil`)
        s.window_name = Some(session.display_name());
        s.can_rename_workspace = self.dock.store().can_rename_or_delete_current();
        // A floating panel is something to put back, even when the layout itself is unchanged.
        s.can_reset_workspace = self.dock.store().can_reset_current() || !self.dock.floating.panels().is_empty();
    }

    /// The values a dialog changed while it was open: the History rows jump right away, the rest waits for
    /// [`ShellHost::take_form_changes`].
    pub(crate) fn route_form_changes(&mut self, cx: &mut ShellCx, changes: Vec<(String, FormValue)>) {
        for (id, v) in changes {
            match (&self.history_base, id.as_str(), &v) {
                (Some(base), "row", FormValue::Index(i)) => {
                    cx.session.jump_to_history_row(base + i);
                }
                _ => self.form_changes.push((id, v)),
            }
        }
        if !self.form_changes.is_empty()
            && let Some(w) = self.form_waker.take()
        {
            w.wake();
        }
    }

    // MARK: Workspace dialogs

    async fn ask_workspace_name<R: ShellRoot + ?Sized>(
        h: &UiRef<R>,
        title: &str,
        info: &str,
        initial: &str,
        button: &str,
    ) -> Option<String> {
        let mut d = ShellDialog::new(title, info);
        d.form = Some(Box::new(ShellForm::new(vec![FormRow::field("name", "Name", initial)])));
        d.add_button(button, SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        if Self::ask(h, d).await? != SQDialogResponse::FIRST {
            return None;
        }
        let mut form = h.with(|r| r.shell_parts().shell.take_answered_form())??;
        form.commit_editing();
        form.text("name")
    }

    /// Window > Save as New Workspace.
    pub async fn save_workspace_as<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let initial = h.with(|r| r.shell_parts().shell.dock.store().library.suggested_new_name("My Layout"));
        let Some(initial) = initial else { return };
        let Some(name) = Self::ask_workspace_name(
            &h,
            "Save as New Workspace",
            "Saves the Edit and the Color layout together under one name.",
            &initial,
            "Save",
        )
        .await
        else {
            return;
        };
        // An existing name gets a numbered copy instead of being overwritten silently.
        let _ = h.with(|r| {
            let shell = r.shell_parts().shell;
            if shell.dock.save_as_new(&name).is_none() {
                shell.flash("That workspace name is not available.");
            }
        });
    }

    /// Window > Rename Workspace.
    pub async fn rename_workspace<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some((can, current)) = h.with(|r| {
            let s = &r.shell_parts().shell.dock;
            (s.store().can_rename_or_delete_current(), s.store().edit_name.clone())
        }) else {
            return;
        };
        if !can {
            return;
        }
        let Some(name) = Self::ask_workspace_name(&h, "Rename Workspace", "", &current, "Rename").await else { return };
        let _ = h.with(|r| {
            let shell = r.shell_parts().shell;
            if !shell.dock.rename_current(&name) {
                shell.flash("That workspace name is not available.");
            }
        });
    }

    /// Window > Delete Workspace.
    pub async fn delete_workspace<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(title) = h.with(|r| {
            let s = &r.shell_parts().shell.dock;
            s.store()
                .can_rename_or_delete_current()
                .then(|| SQL10n::format("Delete workspace “%@”?", &[&s.store().edit_name]))
        }) else {
            return;
        };
        let Some(title) = title else { return };
        let mut d = ShellDialog::new(&title, "The Editing layout is shown afterwards.");
        d.add_button("Delete", SQDialogRole::Destructive, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| r.shell_parts().shell.dock.delete_current());
    }

    // MARK: History

    /// One title per undo step, undone steps in brackets.
    pub(crate) fn history_options(session: &sq_editor_session::EditorSession) -> Vec<String> {
        let list = session.history_list();
        list.rows.iter().map(|r| if r.is_undone { format!("({})", r.title) } else { r.title.clone() }).collect()
    }

    /// The History dialog over every step (the dialog scrolls its form when the list is taller than the window).
    pub(crate) fn history_dialog(session: &sq_editor_session::EditorSession) -> ShellDialog {
        let list = session.history_list();
        let options = Self::history_options(session);
        let mut d = ShellDialog::new("History", "Click a step to go back to it. Dimmed steps were undone.");
        let mut form =
            ShellForm::new(vec![FormRow::Radio { id: "row".to_string(), options, selected: list.position as i64 }]);
        form.numbered_list = true;
        form.list_number_base = 0;
        d.form = Some(Box::new(form));
        d.add_button("Done", SQDialogRole::Default, false);
        d
    }

    /// Window > History: the undo steps as one choice list; picking a row jumps there (`jumpToHistoryRow`).
    pub async fn show_history<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(()) = h.with(|r| {
            let p = r.shell_parts();
            let d = Self::history_dialog(p.session);
            p.shell.history_base = Some(0);
            // The dialog is shown by `ask` below; nobody reads the answer.
            p.shell.history_dialog = Some(d);
        }) else {
            return;
        };
        let Some(d) = h.with(|r| r.shell_parts().shell.history_dialog.take()).flatten() else { return };
        let _ = Self::ask(&h, d).await;
        let _ = h.with(|r| r.shell_parts().shell.history_base = None);
    }
}
