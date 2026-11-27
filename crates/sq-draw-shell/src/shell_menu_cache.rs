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
use sq_core_time::{EaseSide, EasingCurve, Id, Timestamp};
use sq_editor_session::{Change, EditorLookCommands, EditorSession};
use sq_uikit::command_map::Entry;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqmenu_model::SQMenuItem;

/// What the last built bar was made from (see the module docs).
#[derive(Clone, PartialEq)]
pub(crate) struct MenuStamp {
    project: Id,
    /// The session's change counters without the playhead one: a seek or a play tick bumps it on every frame, and the
    /// rows that read the playhead are in `at_playhead` by value.
    versions: [u64; Change::COUNT],
    /// The rows whose enabled state depends on where the playhead is (Edit Marker, Jump Cut, Mark Overhang, the speed
    /// point rows). Computed from the session each frame (a scan of the clips, far cheaper than a build).
    at_playhead: [bool; 9],
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
        /// The first leaf row (with its path of titles) whose fields differ between two lists of rows.
        fn row_diff(path: &str, fresh: &[SQMenuItem], kept: &[SQMenuItem]) -> Option<String> {
            for (a, b) in fresh.iter().zip(kept) {
                if a == b {
                    continue;
                }
                let at = format!("{path} > {}", a.title);
                if let (Some(x), Some(y)) = (&a.submenu, &b.submenu)
                    && x != y
                    && let Some(found) = row_diff(&at, x, y)
                {
                    return Some(found);
                }
                return Some(format!(
                    "{at}: fresh (enabled {}, checked {}, shortcut {:?}, help {:?}, icon {:?}), kept (enabled {}, checked {}, shortcut {:?}, help {:?}, icon {:?})",
                    a.is_enabled,
                    a.is_checked,
                    a.shortcut,
                    a.help,
                    a.icon,
                    b.is_enabled,
                    b.is_checked,
                    b.shortcut,
                    b.help,
                    b.icon
                ));
            }
            None
        }
        for (f, k) in fresh.iter().zip(kept) {
            if let Some(found) = row_diff(&f.title, &f.items, &k.items) {
                return format!("menu bar kept stale: {found}; add that input to MenuStamp");
            }
        }
        format!(
            "menu bar kept stale (menu or row count differ: {} vs {}); add that input to MenuStamp",
            fresh.len(),
            kept.len()
        )
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
        let versions = versions_without_playhead(session);
        MenuStamp {
            project: session.project().id,
            versions,
            at_playhead: [
                session.can_edit_marker_at_playhead(),
                EditorLookCommands::enabled(&EditorCommand::AddFrameHold, session).unwrap_or(false),
                session.jump_cut_enabled(),
                session.can_mark_overhang(),
                session.can_add_speed_point(),
                session.speed_point_accepts_ease(&EasingCurve::linear(), EaseSide::Both),
                session.speed_point_accepts_ease(&EasingCurve::ease_in_out(), EaseSide::Both),
                session.speed_point_accepts_ease(&EasingCurve::ease_in(), EaseSide::In),
                session.speed_point_accepts_ease(&EasingCurve::ease_out(), EaseSide::Out),
            ],
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

/// The session's change counters with the playhead one zeroed: a seek or a play tick bumps it on every frame, and nothing
/// that is cached on these counters (the menu stamp, the Angles clip scan) reads the playhead.
pub(crate) fn versions_without_playhead(session: &EditorSession) -> [u64; Change::COUNT] {
    let mut versions = *session.versions();
    if let Some(i) = Change::PLAYHEAD.index() {
        versions[i] = 0;
    }
    versions
}
