// Swift: ShellRecovery.swift
//! Crash recovery, autosave versions and checkpoints, translated from the Mac `AppController+Files` (Recovery, Close
//! Project / Autosave Versions): the same scanner, report, dialog texts and session calls; only the dialogs are the shell's.
//!
//! Not ported yet: `offerRecovery` / `writeCrashReports` (they need the platform's process table, log files and home
//! folder; see PORTING-NOTES.md).

use crate::shell_dialog::ShellDialog;
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::{ShellCx, ShellEvent, ShellHost};
use crate::shell_menu_bar::absolute_time;
use sq_core_project::recovery::AutosaveStore;
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};

impl ShellHost {
    /// `restoreAutosaveItem`: the version replaces the project; Undo brings back the previous state.
    pub(crate) fn restore_autosave(&mut self, cx: &mut ShellCx, path: &str) {
        let Some(v) = cx.session.autosave_versions().into_iter().find(|v| v.path.to_string_lossy() == path) else {
            return;
        };
        cx.session.stop_playback();
        match cx.session.restore_autosave(&v) {
            Ok(()) => {
                self.emit(ShellEvent::ProjectChanged);
                // Swift shows the time only (`formatted(date: .omitted, time: .standard)`).
                let stamp = absolute_time(v.date);
                let time = stamp.split(' ').nth(1).unwrap_or(&stamp);
                self.flash(&SQL10n::format(
                    "Restored the version from %@. Undo brings back the previous state.",
                    &[time],
                ));
            }
            Err(e) => self.present_error("Could not restore this version", &e),
        }
    }

    /// `saveCheckpointItem`: asks for a name, then keeps the project as it is now until the user deletes it.
    pub async fn save_checkpoint<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let mut d = ShellDialog::new(
            "Save Checkpoint",
            "A checkpoint is kept until you remove it; automatic backups never replace it.",
        );
        d.form = Some(Box::new(ShellForm::new(vec![Row::field("name", "Checkpoint", "")])));
        d.add_button("Save", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(name) = p.shell.take_answered_form().and_then(|f| f.text("name")) else { return };
            let Some(clean) = AutosaveStore::sanitized(&name) else { return };
            if p.session.save_checkpoint(&name).is_some() {
                p.shell.flash(&SQL10n::format("Checkpoint “%@” saved.", &[&clean]));
            }
        });
    }

    /// `makeRecoveryDialog` of the Mac app.
    pub fn recovery_dialog(project_name: &str, date: &str) -> ShellDialog {
        let mut d = ShellDialog::new(
            &SQL10n::format("Recover “%@”?", &[project_name]),
            &SQL10n::format(
                "Sequence Studio did not close cleanly. An autosaved version from %@ is available.",
                &[date],
            ),
        );
        d.add_button("Recover", SQDialogRole::Default, false);
        d.add_button("Discard", SQDialogRole::Normal, false);
        // Esc leaves the autosave alone (Discard), it never recovers.
        d.escape_response = Some(SQDialogResponse::SECOND);
        d
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell_dialog::FormValue;
    use crate::shell_live::test_rig::{answer_swept, type_into};
    use crate::shell_menu_bar::ShellAction;
    use crate::tests::Rig;

    #[test]
    fn checkpoint_is_named_and_restores_from_the_menu() {
        let rig = Rig::new();
        rig.cx(|h, cx| h.perform(cx, ShellAction::SaveCheckpoint));
        rig.run_flows();
        type_into(&rig, "name", FormValue::Text("Rough cut".into()));
        answer_swept(&rig, SQDialogResponse::FIRST);
        let v =
            rig.with(|r| r.session.autosave_versions().into_iter().find(|v| v.name.as_deref() == Some("Rough cut")));
        let v = v.expect("checkpoint");
        let rows = rig.with(|r| crate::pending_steps::autosave_rows(&r.session));
        assert!(
            rows.iter().any(|row| row.name.as_deref() == Some("Rough cut") && row.path == v.path.to_string_lossy())
        );
    }

    #[test]
    fn recovery_dialog_uses_the_mac_texts() {
        let d = ShellHost::recovery_dialog("Trip", "today");
        assert_eq!(d.message_text, "Recover “Trip”?");
        assert!(d.informative_text.contains("did not close cleanly"));
    }
}
