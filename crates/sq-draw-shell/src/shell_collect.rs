// Swift: ShellCollect.swift
//! File > Collect Files into Project Folder and the Project panel's Fix > Collect (the AppKit `collectFiles`): copies the
//! used media outside the project's Imported folder into it and re-points the project at the copies; not an undo step,
//! originals stay untouched. The copying is `MediaFileOps::collect`, the same on the Mac and on Windows.

use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellEvent, ShellHost};
use sq_media::media_file_ops::{MediaFileOps, MediaManagement};
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

impl ShellHost {
    /// `project_url` stands in for the session's file (the shot harness asks as an untitled project with `unsaved`).
    /// shortcut: no media watcher pause and no deferral while playing (the shared shell runs no MediaPlacement); upgrade
    /// when the shared shell gets the watcher.
    pub async fn collect_files<R: ShellRoot + ?Sized>(h: UiRef<R>, project_url: Option<PathBuf>, unsaved: bool) {
        let Some(Some((folder, media, project_id))) = h.with(|r| {
            let p = r.shell_parts();
            let url = if unsaved { None } else { project_url.or_else(|| p.session.file_url().map(Path::to_path_buf)) };
            let Some(url) = url else {
                // art.html 02: no icon
                p.shell.present_message(
                    "Save the project first",
                    "Collect Files needs a project folder. Use File > Save As… or create the project with New Project.",
                    None,
                );
                return None;
            };
            p.shell.flash("Collecting files…");
            Some((MediaManagement::imported_folder(&url), p.session.project().media.clone(), p.session.project().id))
        }) else {
            return;
        };
        let Some(pool) = h.with(|r| r.shell_parts().shell.flow_env.services.worker_pool()).flatten() else {
            let _ =
                h.with(|r| r.shell_parts().shell.flash(crate::shell_platform_text::ShellPlatformText::not_available()));
            return;
        };
        let copy_folder = folder.clone();
        let Ok(outcome) = pool.run(move |_| MediaFileOps::collect(&media, &copy_folder)).await else { return };
        let _ = h.with(|r| {
            let p = r.shell_parts();
            // another project meanwhile
            if p.session.project().id != project_id {
                return;
            }
            let paths: BTreeMap<_, _> = outcome.done.iter().map(|d| (d.id, d.destination.clone())).collect();
            p.session.relink_media_quietly(&paths);
            let n = outcome.done.iter().map(|d| d.source.as_str()).collect::<BTreeSet<_>>().len();
            let name = folder.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            let line = if outcome.failed.is_empty() {
                if n == 0 {
                    SQL10n::string("All media is already in the project folder.")
                } else {
                    SQL10n::plural_with(n as i64, "Collected %@ file into %@.", "Collected %@ files into %@.", &[&name])
                }
            } else {
                let failed: Vec<&str> = outcome.failed.iter().take(3).map(String::as_str).collect();
                SQL10n::format(
                    "Collected %@ files; could not copy: %@. Those stay where they are.",
                    &[&n.to_string(), &failed.join(", ")],
                )
            };
            p.shell.emit(ShellEvent::Status(line));
        });
    }
}
