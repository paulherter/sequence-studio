//! Help > Check for Updates, the part after "Download": the download with its progress, the check of the file, the
//! "Restart to Update" question and the failure card. The states and every transition live in
//! `sq_editor_session::UpdateFlow`; this only draws them and runs their effects. A system that cannot install in place
//! (or a feed without a verifiable installer) opens the link as before.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::shell_dialog::{ShellDialog, SlotIcon, Tone};
use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellEvent, ShellHost};
use sq_editor_session::{
    DownloadProgress, PendingUpdate, UpdateEffect, UpdateEvent, UpdateFailure, UpdateFlow, UpdateInstall,
    UpdateRelease, UpdateTrust, progress_line,
};
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};

type Verdict = Arc<Mutex<Option<Result<(), UpdateFailure>>>>;

impl ShellHost {
    /// The Download button of the update dialog.
    pub(crate) async fn download_and_install_update<R: ShellRoot + ?Sized>(h: UiRef<R>, release: UpdateRelease) {
        let (can_apply, cache) = h
            .with(|r| {
                let s = &r.shell_parts().shell;
                (s.update_install && UpdateTrust::key().is_some(), s.update_cache.clone())
            })
            .unwrap_or((false, None));
        let (mut flow, effect) = UpdateFlow::Available(release.clone())
            .step(UpdateEvent::Download { can_apply: can_apply && cache.is_some() });
        let (install, Some(cache)) = (
            match effect {
                Some(UpdateEffect::OpenUrl(url)) => {
                    let _ = h.with(|r| r.shell_parts().shell.emit(ShellEvent::OpenUrl(url)));
                    return;
                }
                Some(UpdateEffect::StartDownload(install)) => install,
                _ => return,
            },
            cache,
        ) else {
            return;
        };
        // A new download replaces any update chosen with "Later": a quit during it never applies a half file.
        let _ = h.with(|r| r.shell_parts().shell.pending_update = None);
        let Some(staged) = UpdateTrust::staged_path(&cache, &release.version, &install) else {
            Self::update_failed(&h, UpdateFailure::Download("the file name is not valid".into())).await;
            return;
        };
        if let Some(dir) = staged.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::remove_file(&staged);
        let progress = DownloadProgress::new();
        progress.report(0, install.size.unwrap_or(0));
        let shown = Arc::clone(&progress);
        let mut d = update_dialog(
            &SQL10n::format("Downloading version %@", &[&release.version]),
            "Sequence Studio checks the download before it installs it.",
        );
        d.footer_status = Some(Box::new(move || {
            let (done, total) = shown.snapshot();
            progress_line(done, total)
        }));
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        let staged_for_download = staged.clone();
        let url = install.url.clone();
        let _ask = h.with(|r| {
            let p = r.shell_parts();
            p.files.download(&url, &staged_for_download, Arc::clone(&progress));
            p.shell.present(d)
        });
        // Download.
        let downloaded = loop {
            if sq_runtime::sleep(Duration::from_millis(100)).await.is_err() || !Self::update_dialog_open(&h) {
                progress.cancel();
                let _ = std::fs::remove_file(&staged);
                let _ = h.with(|r| r.shell_parts().shell.close_dialog(SQDialogResponse::FIRST));
                return;
            }
            if let Some(result) = progress.take_result() {
                break result;
            }
            let (done, total) = progress.snapshot();
            flow = flow.step(UpdateEvent::Progress { done, total }).0;
            // The footer line reads the progress when it draws; nothing else asks for that frame.
            h.with(|r| r.shell_parts().shell.request_frame());
        };
        let event = match downloaded {
            Ok(()) => UpdateEvent::Downloaded(staged.clone()),
            Err(why) => UpdateEvent::DownloadFailed(why),
        };
        let (next, effect) = flow.step(event);
        flow = next;
        let Some(UpdateEffect::Verify { file, install }) = effect else {
            Self::close_update_dialog(&h);
            if let UpdateFlow::Failed(why) = flow {
                let _ = std::fs::remove_file(&staged);
                Self::update_failed(&h, why).await;
            }
            return;
        };
        // Verify: the signature file, then both checks off the UI thread.
        let _ = h.with(|r| {
            if let Some(d) = r.shell_parts().shell.dialog_mut() {
                d.message_text = SQL10n::format("Checking version %@", &[&release.version]);
                d.footer_status = Some(Box::new(|| "Verifying\u{2026}".to_string()));
            }
        });
        let (verdict, signature) = Self::verify_update(&h, &file, &install).await;
        let (event, open) = match verdict {
            Some(Ok(())) => (UpdateEvent::Verified(Ok(())), Self::update_dialog_open(&h)),
            Some(Err(UpdateFailure::SignatureMissing)) => (UpdateEvent::SignatureUnavailable, true),
            Some(Err(why)) => (UpdateEvent::Verified(Err(why)), true),
            None => (UpdateEvent::Cancel, false),
        };
        if !open {
            let _ = std::fs::remove_file(&file);
            Self::close_update_dialog(&h);
            return;
        }
        let (next, effect) = flow.step(event);
        flow = next;
        if let Some(UpdateEffect::Discard(f)) = effect {
            let _ = std::fs::remove_file(f);
        }
        Self::close_update_dialog(&h);
        match flow {
            UpdateFlow::Failed(why) => Self::update_failed(&h, why).await,
            ready @ UpdateFlow::ReadyToInstall { .. } => {
                let pending = PendingUpdate { file, version: release.version.clone(), install, signature };
                Self::update_ready(h, ready, pending).await;
            }
            _ => {}
        }
    }

    fn update_dialog_open<R: ShellRoot + ?Sized>(h: &UiRef<R>) -> bool {
        h.with(|r| r.shell_parts().shell.dialog().is_some()).unwrap_or(false)
    }

    fn close_update_dialog<R: ShellRoot + ?Sized>(h: &UiRef<R>) {
        let _ = h.with(|r| r.shell_parts().shell.close_dialog(SQDialogResponse::FIRST));
    }

    /// Fetches the signature and checks the file. `None` when the dialog was closed meanwhile.
    async fn verify_update<R: ShellRoot + ?Sized>(
        h: &UiRef<R>,
        file: &std::path::Path,
        install: &UpdateInstall,
    ) -> (Option<Result<(), UpdateFailure>>, Vec<u8>) {
        let Some(key) = UpdateTrust::key() else { return (None, Vec::new()) };
        let Some(ask) = h.with(|r| r.shell_parts().files.fetch(&install.sig_url)) else { return (None, Vec::new()) };
        let signature = ask.await;
        if !Self::update_dialog_open(h) {
            return (None, Vec::new());
        }
        let Some(signature) = signature else { return (Some(Err(UpdateFailure::SignatureMissing)), Vec::new()) };
        let kept = signature.clone();
        let verdict: Verdict = Arc::new(Mutex::new(None));
        let (slot, file, install) = (Arc::clone(&verdict), file.to_path_buf(), install.clone());
        std::thread::spawn(move || {
            let result = UpdateTrust::verify_file(&file, &install, Some(&signature), &key);
            if let Ok(mut s) = slot.lock() {
                *s = Some(result);
            }
        });
        loop {
            if sq_runtime::sleep(Duration::from_millis(50)).await.is_err() || !Self::update_dialog_open(h) {
                return (None, Vec::new());
            }
            if let Some(result) = verdict.lock().ok().and_then(|mut s| s.take()) {
                return (Some(result), kept);
            }
        }
    }

    /// "Restart to Update" or "Later" for a verified file.
    async fn update_ready<R: ShellRoot + ?Sized>(h: UiRef<R>, mut flow: UpdateFlow, pending: PendingUpdate) {
        let UpdateFlow::ReadyToInstall { release, .. } = &flow else { return };
        let version = release.version.clone();
        loop {
            let mut d = update_dialog(
                &SQL10n::format("Version %@ is ready", &[&version]),
                "Sequence Studio restarts to finish the update. Later installs it when you quit.",
            );
            d.add_button("Restart to Update", SQDialogRole::Default, false);
            d.add_button("Later", SQDialogRole::Cancel, true);
            let answer = Self::ask(&h, d).await;
            let (event, effect_after) = if answer == Some(SQDialogResponse::FIRST) {
                let unsaved = h.with(|r| r.shell_parts().session.is_dirty()).unwrap_or(false);
                (UpdateEvent::Install { unsaved }, true)
            } else {
                (UpdateEvent::Later, false)
            };
            let (next, mut effect) = flow.step(event);
            flow = next;
            if effect == Some(UpdateEffect::AskToSave) {
                let proceed = Self::confirm_discard_changes(h.clone()).await;
                let (next, e) = flow.step(UpdateEvent::SaveAnswered(proceed));
                flow = next;
                effect = e;
                if !proceed {
                    continue;
                }
            }
            match effect {
                Some(UpdateEffect::Apply { .. }) if effect_after => {
                    let update = pending.clone();
                    let _ = h.with(|r| r.shell_parts().shell.emit(ShellEvent::ApplyUpdate { update, restart: true }));
                }
                Some(UpdateEffect::ApplyOnQuit { .. }) => {
                    let update = pending.clone();
                    let _ = h.with(|r| r.shell_parts().shell.pending_update = Some(update));
                }
                _ => {}
            }
            return;
        }
    }

    /// The failure card.
    async fn update_failed<R: ShellRoot + ?Sized>(h: &UiRef<R>, why: UpdateFailure) {
        let mut d = ShellDialog::new("The update did not finish", &why.message());
        d.header_icon = Some(Tone::Error);
        d.add_button("OK", SQDialogRole::Default, false);
        let _ = Self::ask(h, d).await;
    }
}

/// A dialog of the update flow: informational, so a Cancel or Later button does not turn it into a warning.
pub(crate) fn update_dialog(title: &str, text: &str) -> ShellDialog {
    let mut d = ShellDialog::new(title, text);
    d.slot = Some(SlotIcon::Info);
    d
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn update_dialogs_are_informational_even_with_a_cancel_button() {
        let mut d = update_dialog("Downloading version 1", "");
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        assert_eq!(d.slot_icon(), SlotIcon::Info);
    }

    /// A task presents the update offer when the feed answers and no input follows: presenting and answering a dialog must
    /// ask the app for a frame, or the window stays as it was until the next pointer move.
    #[test]
    fn a_dialog_presented_by_a_task_asks_the_app_for_a_frame() {
        let mut shell = crate::test_support::shell();
        let _ = shell.take_frame_request();
        let _ask = shell.present(update_dialog("Version 2 is available", ""));
        assert!(shell.take_frame_request(), "presenting asks for a frame");
        shell.close_dialog(SQDialogResponse::FIRST);
        assert!(shell.take_frame_request(), "closing asks for a frame");
    }
}
