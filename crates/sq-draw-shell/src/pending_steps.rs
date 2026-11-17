//! The steps of `ShellHost` whose Swift code lives in files that are not ported yet. Each function keeps its call site in
//! the ported code and answers "not handled" until the owner of the Swift file moves the real body into its own module and
//! deletes the stub here. The list with the Swift file of each is in PORTING-NOTES.md.

use crate::shell_flows::ShellRoot;
use crate::shell_menu_bar::{AutosaveVersionRow, ShellAction};
use sq_editor_session::EditorSession;
use sq_runtime::UiRef;

/// Swift: ShellRecovery.swift `autosaveRows`.
pub(crate) fn autosave_rows(session: &EditorSession) -> Vec<AutosaveVersionRow> {
    session
        .autosave_versions()
        .into_iter()
        .map(|v| AutosaveVersionRow { path: v.path.to_string_lossy().into_owned(), date: v.date, name: v.name })
        .collect()
}

/// Swift: ShellCollect.swift `collectFiles`, ShellRelink.swift `relinkMedia`, ShellImport.swift `showImportChecklist`: the
/// flows File > Project starts.
pub(crate) async fn project_flow<R: ShellRoot + ?Sized>(h: UiRef<R>, action: ShellAction) {
    if action == ShellAction::ImportChecklist {
        // File > Import Checklist…: the card, then Reconnect Media when asked for (`showImportChecklist`).
        crate::ShellHost::show_import_checklist(h).await;
    }
}
