// Swift: ShellLocate.swift
//! Project panel > Locate… on one offline item and Reconnect Media… / Replace Media… on one item (the Mac
//! `locateOffline`/`finishLocate` and `replaceFootage` of the Project panel), as shell flows.

use crate::shell_dialog::ShellDialog;
use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellEvent, ShellHost};
use crate::shell_platform_text::ShellPlatformText;
use sq_core_model::MediaStatus;
use sq_core_time::Id;
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::path::{Path, PathBuf};

/// The folder of a stored media path when it still exists: where the chooser opens.
fn existing_folder_of(path: &str) -> Option<PathBuf> {
    let old = Path::new(path).parent()?.to_path_buf();
    old.exists().then_some(old)
}

fn file_name(url: &Path) -> String {
    url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

impl ShellHost {
    /// Locate…: choose the file of the offline item `id` (the chooser opens at the folder it was in), relink that item
    /// only, then offer the other offline items whose files sit in the same folder.
    pub async fn locate_offline<R: ShellRoot + ?Sized>(h: UiRef<R>, id: Id) {
        let Some(Some((name, start))) = h.with(|r| {
            let m = r.shell_parts().session.project().media(id)?;
            (m.status() == MediaStatus::Missing).then(|| (m.name.clone(), existing_folder_of(&m.path)))
        }) else {
            return;
        };
        let Some(ask) = h.with(|r| {
            let prompt = SQL10n::format("Locate “%@”.", &[&name]);
            r.shell_parts().files.choose_file(&prompt, start.as_deref())
        }) else {
            return;
        };
        let Some(url) = ask.await else { return };
        let Some(Some(siblings)) = h.with(|r| {
            let p = r.shell_parts();
            if !p.session.locate_media(id, &url) {
                return None;
            }
            p.shell.emit(ShellEvent::Status(SQL10n::format("Located %@.", &[&file_name(&url)])));
            let folder = url.parent().map(Path::to_path_buf).unwrap_or_default();
            // shortcut: the sibling scan runs on the UI thread (Swift awaited it); upgrade with a worker pool service.
            Some((p.session.missing_siblings(&folder, id), folder))
        }) else {
            return;
        };
        let (siblings, folder) = siblings;
        if siblings.is_empty() {
            return;
        }
        let n = siblings.len() as i64;
        let mut d = ShellDialog::new(
            &SQL10n::plural(n, "Reconnect %@ more file in this folder?", "Reconnect %@ more files in this folder?"),
            &SQL10n::format(
                if n == 1 {
                    "%@ other offline file is in “%@”."
                } else {
                    "%@ other offline files are in “%@”."
                },
                &[&n.to_string(), &file_name(&folder)],
            ),
        );
        d.add_button("Reconnect", SQDialogRole::Default, false);
        d.add_button("Not Now", SQDialogRole::Cancel, false);
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            p.session.relink_siblings(&siblings);
            p.shell.emit(ShellEvent::Status(SQL10n::plural(
                n,
                "Reconnected %@ more file.",
                "Reconnected %@ more files.",
            )));
        });
    }

    /// Reconnect Media… (offline) / Replace Media… (online): choose a file, probe it, and let it take over the item
    /// (clips, marks, label stay). One undo step.
    pub async fn replace_media<R: ShellRoot + ?Sized>(h: UiRef<R>, id: Id) {
        let Some(Some((name, start))) = h.with(|r| {
            let m = r.shell_parts().session.project().media(id)?;
            Some((m.name.clone(), existing_folder_of(&m.path)))
        }) else {
            return;
        };
        let Some(ask) = h.with(|r| {
            let prompt = SQL10n::format("Choose the file that replaces “%@”.", &[&name]);
            r.shell_parts().files.choose_file(&prompt, start.as_deref())
        }) else {
            return;
        };
        let Some(url) = ask.await else { return };
        let Some(probe) = h.with(|r| r.shell_parts().shell.flow_env.services.probe(&url)).flatten() else {
            let _ = h.with(|r| r.shell_parts().shell.flash(ShellPlatformText::not_available()));
            return;
        };
        let probed = probe.await;
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(probed) = probed else {
                p.shell.emit(ShellEvent::Status(SQL10n::format("Could not read %@.", &[&file_name(&url)])));
                return;
            };
            p.session.replace_footage(id, &probed);
            p.shell.emit(ShellEvent::Status(SQL10n::format("Replaced footage with %@.", &[&file_name(&url)])));
        });
    }
}
