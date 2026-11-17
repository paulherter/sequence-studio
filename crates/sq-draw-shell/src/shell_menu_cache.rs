//! The main menu bar is built again only when something it shows can have changed. A build costs 4 ms on an empty
//! project and over 15 ms with 3000 clips (the rows, then one validate call each); doing it on every frame made the
//! "shell sync" phase the largest part of an idle frame.
//!
//! A [`MenuStamp`] holds every input of a build that is cheap to read each frame. The session's own state is covered by
//! its change counters; whatever the shell and the panels contribute is compared by value. A menu that opens (or closes)
//! always builds again, so the rows of the menu a user looks at are read from the live state at that moment, like the
//! Mac `validateMenuItem` at menu open. A new input of the build goes into the stamp, or the check in the tests fails.

use crate::pending_steps::autosave_rows;
use crate::shell_commands::ShellPanelFacts;
use crate::shell_host::{ShellHooks, ShellHost};
use crate::shell_menu_bar::{ShellMenu, ShellMenuState};
use sq_core_time::{Id, Timestamp};
use sq_editor_session::{Change, EditorSession};
use sq_uikit::command_map::Entry;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::panel_id::PanelID;

/// What the last built bar was made from (see the module docs).
#[derive(Clone, PartialEq)]
pub(crate) struct MenuStamp {
    project: Id,
    versions: [u64; Change::COUNT],
    /// Session state the rows read that no change counter covers (a file coming back online, the undo stacks).
    undo: (bool, bool, Option<String>, Option<String>),
    selection: std::collections::BTreeSet<Id>,
    dirty: bool,
    can_relink: bool,
    /// Paste, Paste Insert and Paste to Targets read the clipboards.
    clipboards: (bool, bool),
    /// The shell and panel side of [`ShellMenuState`]: dock, recents, dialogs, versions list, titles of running jobs.
    shell: ShellMenuState,
    facts: ShellPanelFacts,
    focus: Option<PanelID>,
    dialog: bool,
    anonymizing: bool,
    project_list: bool,
    open: Option<usize>,
    keys: Vec<Entry>,
}

impl ShellHost {
    /// The menu bar when it has to change, else `None` (the bar keeps what it has). Builds exactly like [`ShellHost::menus`].
    pub fn refresh_menus(&self, session: &EditorSession, hooks: &dyn ShellHooks) -> Option<Vec<ShellMenu>> {
        let stamp = self.menu_stamp(session, hooks);
        if self.menu_stamp.borrow().as_ref() == Some(&stamp) {
            if self.verify_menu_cache {
                let fresh = self.menus(session, hooks);
                assert!(fresh == *self.menus_built.borrow(), "{}", Self::menu_diff(&fresh, &self.menus_built.borrow()));
            }
            return None;
        }
        *self.menu_stamp.borrow_mut() = Some(stamp);
        self.menu_builds.set(self.menu_builds.get() + 1);
        let built = self.menus(session, hooks);
        if self.verify_menu_cache {
            *self.menus_built.borrow_mut() = built.clone();
        }
        Some(built)
    }

    /// The first row that differs between a fresh bar and the kept one, for the failure of `verify_menu_cache`.
    fn menu_diff(fresh: &[ShellMenu], kept: &[ShellMenu]) -> String {
        let rows = |m: &ShellMenu| m.items.iter().map(|i| (i.title.clone(), i.is_enabled)).collect::<Vec<_>>();
        for (f, k) in fresh.iter().zip(kept) {
            if let Some((a, b)) = rows(f).into_iter().zip(rows(k)).find(|(a, b)| a != b) {
                return format!(
                    "menu bar kept stale: {} > fresh {a:?}, kept {b:?}; add that input to MenuStamp",
                    f.title
                );
            }
        }
        "menu bar kept stale (rows differ in more than title and enabled); add that input to MenuStamp".to_string()
    }

    /// How many times the bar was built through [`ShellHost::refresh_menus`] (tests and the frame log).
    pub fn menu_builds(&self) -> u64 {
        self.menu_builds.get()
    }

    fn menu_stamp(&self, session: &EditorSession, hooks: &dyn ShellHooks) -> MenuStamp {
        // The parts of `menu_state` that do not read the session's heavy state (undo names, disabled reasons, project and
        // view facts follow the change counters). The same calls as there, in the same order.
        let mut shell = ShellMenuState {
            recents: self.recents.entries().to_vec(),
            modal_shown: self.dialog().is_some() || self.shortcuts.is_some(),
            chooser_shown: self.start.is_some(),
            autosave_versions: autosave_rows(session),
            now: self.wall_now(),
            ..ShellMenuState::default()
        };
        let anonymizing = self.flow_env.services.anonymize_running();
        if anonymizing {
            shell.titles.insert(EditorCommand::Anonymize, "Cancel Anonymize".to_string());
        }
        self.analysis_titles(&mut shell);
        self.fill_window_state(session, &mut shell);
        // Version labels count minutes: only a new minute can change one.
        shell.now = if shell.autosave_versions.is_empty() {
            Timestamp::from_unix_seconds(0.0)
        } else {
            Timestamp::from_unix_seconds((shell.now.unix_seconds() / 60.0).floor() * 60.0)
        };
        MenuStamp {
            project: session.project().id,
            versions: *session.versions(),
            undo: (
                session.can_undo(),
                session.can_redo(),
                session.undo_name().map(str::to_string),
                session.redo_name().map(str::to_string),
            ),
            selection: session.selection().clone(),
            dirty: session.is_dirty(),
            can_relink: session.can_relink(),
            clipboards: (session.clipboard().is_some(), session.can_paste_effect_clipboard()),
            shell,
            facts: self.current_facts_uncached(session, hooks),
            focus: self.focus,
            dialog: self.dialog().is_some(),
            anonymizing,
            project_list: hooks.has_project_list(),
            open: self.menu_bar.open(),
            keys: self.map.entries.clone(),
        }
    }
}
