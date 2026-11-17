// Swift: ShellReconnect.swift
//! Reconnect from one found file (the Mac `reconnectMedia` + `ReconnectSheet`): pick a file you found, every offline item
//! is scored against what is around it, and a checklist shows one row per proposed match. Strong matches start ticked,
//! weak ones unticked; nothing is linked until Reconnect. On the Mac it hangs off the Project panel's health line; the
//! shell offers it in the Reconnect Media dialog ("Found a File…").

use crate::shell_dialog::{DialogForm, ShellDialog};
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::{ShellEvent, ShellHost};
use sq_core_project::media_path_resolver::MediaPathResolver;
use sq_core_project::relink_scoring::{RelinkProposal, RelinkScorerResult, Tier};
use sq_core_time::Id;
use sq_editor_session::MediaWorkers;
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::cell::Cell;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;

impl ShellHost {
    /// The checklist's rows: one check per proposal (name) and its detail line (tier, signals, path).
    pub(crate) fn reconnect_rows(result: &RelinkScorerResult, names: &BTreeMap<Id, String>) -> Vec<Row> {
        result
            .proposals
            .iter()
            .enumerate()
            .map(|(i, p)| {
                let title = names.get(&p.media_id).cloned().unwrap_or_else(|| MediaPathResolver::file_name_of(&p.path));
                Row::check(&format!("p{i}"), &title, p.is_checked())
            })
            .collect()
    }

    /// The second line of each checklist item (strength, signals, path), keyed like the rows.
    pub(crate) fn reconnect_details(result: &RelinkScorerResult) -> Vec<(String, String)> {
        result
            .proposals
            .iter()
            .enumerate()
            .map(|(i, p)| {
                let tier = if p.tier() == Tier::Strong { "Strong" } else { "Weak" };
                (format!("p{i}"), format!("{tier} \u{b7} {} \u{b7} {}", SQL10n::string(&p.signal_text()), p.path))
            })
            .collect()
    }

    /// The ticked proposals of a checklist form.
    pub(crate) fn ticked_proposals(result: &RelinkScorerResult, form: &dyn DialogForm) -> Vec<RelinkProposal> {
        result
            .proposals
            .iter()
            .enumerate()
            .filter(|(i, _)| form.bool(&format!("p{i}")) == Some(true))
            .map(|(_, p)| p.clone())
            .collect()
    }

    /// Asks for one found file, proposes matches around it and shows the checklist. Returns how many were reconnected.
    /// `volumes` `None` = the mounted volumes (tests pass none).
    pub async fn reconnect_from_found_file<R: ShellRoot + MediaWorkers + ?Sized>(
        h: UiRef<R>,
        volumes: Option<Vec<PathBuf>>,
    ) -> usize {
        let Some(Some((ask, missing))) = h.with(|r| {
            let p = r.shell_parts();
            let missing = p.session.missing_media();
            if missing.is_empty() {
                p.shell.flash("All media is online.");
                return None;
            }
            let old = Path::new(&missing[0].path).parent().map(Path::to_path_buf).unwrap_or_default();
            let directory = old.exists().then_some(old);
            let prompt = SQL10n::string("Choose one file you found. SQ looks around it for the other missing media.");
            Some((p.files.choose_file(&prompt, directory.as_deref()), missing))
        }) else {
            return 0;
        };
        let Some(url) = ask.await else { return 0 };
        let _ = h.with(|r| {
            let shell = r.shell_parts().shell;
            if let Some(dir) = url.parent() {
                shell.remember_relink_folder(dir);
            }
            shell.flash("Searching…");
        });
        let result = sq_editor_session::EditorSession::propose_reconnect(UiRef::clone(&h), url, volumes).await;
        if result.proposals.is_empty() {
            let _ = h.with(|r| r.shell_parts().shell.flash("No matching files found around that location."));
            return 0;
        }
        let names: BTreeMap<Id, String> = missing.iter().map(|m| (m.id, m.name.clone())).collect();
        Self::ask_reconnect(h, result, missing.len(), names).await
    }

    /// The checklist card (`dialogs.html` "Found 3 of 4 missing files", 520 wide).
    pub(crate) fn reconnect_dialog(form: ShellForm, title: &str, note: &str) -> ShellDialog {
        let mut d = ShellDialog::new(title, note);
        d.width = 520.0;
        d.kit_layout = true;
        d.form = Some(Box::new(form));
        d.add_button("Reconnect", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        d
    }

    /// The checklist dialog; applies the ticked rows (one undo step).
    pub(crate) async fn ask_reconnect<R: ShellRoot + ?Sized>(
        h: UiRef<R>,
        result: RelinkScorerResult,
        total: usize,
        names: BTreeMap<Id, String>,
    ) -> usize {
        let unmatched = result.unmatched.len();
        let mut form = ShellForm::new(Self::reconnect_rows(&result, &names));
        form.helps.extend(Self::reconnect_details(&result));
        // Reconnect needs a ticked row (the Mac button is disabled at zero); the dialog cannot read the form it owns, so
        // the change reaction keeps the count.
        let ticked = Rc::new(Cell::new(result.proposals.iter().filter(|p| p.is_checked()).count()));
        let (count, n_rows) = (Rc::clone(&ticked), result.proposals.len());
        form.on_change = Some(Box::new(move |form, _id, _v| {
            count.set((0..n_rows).filter(|i| form.bool(&format!("p{i}")) == Some(true)).count());
        }));
        let note = if unmatched == 0 {
            SQL10n::string("Untick any match you do not trust. Weak matches start unticked.")
        } else {
            SQL10n::format(
                "%@ still missing after this. Untick any match you do not trust; weak matches start unticked.",
                &[&unmatched.to_string()],
            )
        };
        let mut d = Self::reconnect_dialog(form, &result.found_text(total), &note);
        d.can_close = Some(Box::new(move |r| r != SQDialogResponse::FIRST || ticked.get() > 0));
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return 0;
        }
        h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return 0 };
            let n = p.session.apply_reconnect(&Self::ticked_proposals(&result, &*form));
            if n > 0 {
                p.shell.emit(ShellEvent::ProjectChanged);
                p.shell.flash_raw(SQL10n::plural(
                    n as i64,
                    "Reconnected %@ media file.",
                    "Reconnected %@ media files.",
                ));
            }
            n
        })
        .unwrap_or(0)
    }
}
