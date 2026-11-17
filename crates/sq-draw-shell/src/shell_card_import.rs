// Swift: ShellCardImport.swift
//! Import from a camera card (the Mac CardImportWindow): what the card holds, which kinds to take, then Copy & Import
//! (into `<project folder>/Media`, an untitled project is saved first) or Import without Copying (the files stay on the card).
//! The files are picked in `ShellCardBrowser` (kind, sort, list or grid, preview).
//! The dialog closes when the import starts and the failed files are named in a message, as in Swift `ShellCardImport`.

use crate::shell_card_browser::ShellCardBrowser;
use crate::shell_dialog::ShellDialog;
use crate::shell_flow_env::ShellTool;
use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellEvent, ShellFlow, ShellHost};
use sq_library::card_import::{CardCandidate, CardCopier, CardMediaKind, CardScanner};
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqbyte_size::SQByteSize;
use sq_uikit::sqdialog_model::SQDialogResponse;
use std::collections::BTreeSet;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::task::Poll;
use std::time::Duration;

/// The dialog's Select All button (the third one added).
const SELECT_ALL: SQDialogResponse = SQDialogResponse::THIRD;
/// What Esc and a vanished volume answer; the header close button answers the same. Swift used `Response(-1)`; the Rust
/// dialog refuses negative responses, so this is the next free button index.
const CANCEL: SQDialogResponse = SQDialogResponse(3);

/// "12 videos (8.4 GB), 30 photos (210 MB)".
pub fn card_summary(items: &[CardCandidate]) -> String {
    let part = |k: CardMediaKind, one: &str, other: &str| -> Option<String> {
        let some: Vec<&CardCandidate> = items.iter().filter(|i| i.kind == k).collect();
        if some.is_empty() {
            return None;
        }
        Some(format!(
            "{} ({})",
            SQL10n::plural(some.len() as i64, one, other),
            SQByteSize::string(some.iter().map(|i| i.size).sum())
        ))
    };
    [part(CardMediaKind::Video, "%@ video", "%@ videos"), part(CardMediaKind::Photo, "%@ photo", "%@ photos")]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(", ")
}

fn standardized(volume: &Path) -> String {
    volume.to_string_lossy().trim_end_matches('/').to_string()
}

impl ShellHost {
    /// A card or other import volume appeared (the platform's watcher calls this when Preferences > Media > Card Import
    /// is on). One dialog per volume; a second call for the same volume while it is up does nothing.
    /// `at_launch`: a card that was already mounted when the app started is offered only once a project is open
    /// (never over the start window; the Mac app offers nothing at launch).
    pub fn open_card_import(&mut self, volume: &Path, at_launch: bool) {
        if at_launch && self.is_start_shown() {
            return;
        }
        let key = standardized(volume);
        if !self.flow_env.card_import_volumes.insert(key) {
            return;
        }
        self.start_flow(ShellFlow::Tool(ShellTool::CardImport(volume.to_path_buf())));
    }

    /// The volume went away (the platform's watcher): its import dialog closes like Cancel (the Mac window closes on unmount).
    pub fn close_card_import(&mut self, volume: &Path) {
        if self.flow_env.card_dialog.as_deref() != Some(standardized(volume).as_str()) {
            return;
        }
        if let Some(d) = self.dialog_mut() {
            d.press(CANCEL);
        }
    }

    pub(crate) async fn run_card_import<R: ShellRoot + ?Sized>(h: UiRef<R>, volume: PathBuf) {
        Self::card_import(h.clone(), &volume).await;
        let _ = h.with(|r| {
            let env = &mut r.shell_parts().shell.flow_env;
            env.card_import_volumes.remove(&standardized(&volume));
            if env.card_dialog.as_deref() == Some(standardized(&volume).as_str()) {
                env.card_dialog = None;
            }
        });
    }

    async fn card_import<R: ShellRoot + ?Sized>(h: UiRef<R>, volume: &Path) {
        let name = volume
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| volume.to_string_lossy().into_owned());
        let Some(pool) = h.with(|r| {
            let shell = &mut r.shell_parts().shell;
            shell.emit(ShellEvent::Status(SQL10n::format("Reading “%@”…", &[&name])));
            shell.flow_env.services.worker_pool()
        }) else {
            return;
        };
        let kinds: BTreeSet<CardMediaKind> = CardMediaKind::ALL.into_iter().collect();
        let items = match pool {
            Some(pool) => {
                let root = volume.to_path_buf();
                match pool.run(move |_| CardScanner::scan(&root, &kinds)).await {
                    Ok(items) => items,
                    Err(_) => return,
                }
            }
            // shortcut: the card is scanned on the UI thread when the app provides no worker pool.
            None => CardScanner::scan(volume, &kinds),
        };
        if items.is_empty() {
            let _ = h.with(|r| {
                r.shell_parts()
                    .shell
                    .emit(ShellEvent::Status(SQL10n::format("“%@” holds no videos or photos.", &[&name])));
            });
            return;
        }
        let browser = ShellCardBrowser::new(items.clone());
        let Some(d) = h.with(|r| {
            let shell = &mut r.shell_parts().shell;
            let sink = shell.event_sink();
            if let Some(poster) = shell.flow_env.card_poster.take() {
                browser.set_poster(poster);
            }
            let mut d = ShellDialog::new(&SQL10n::format("Import from %@", &[&name]), "");
            d.width = 860.0;
            // art.html 42: a muted "8 videos · 4.1 GB" caption after the title.
            let videos = items.iter().filter(|i| i.kind == CardMediaKind::Video).count() as i64;
            let photos = items.len() as i64 - videos;
            let mut parts: Vec<String> = Vec::new();
            if videos > 0 {
                parts.push(SQL10n::plural(videos, "%@ video", "%@ videos"));
            }
            if photos > 0 {
                parts.push(SQL10n::plural(photos, "%@ photo", "%@ photos"));
            }
            parts.push(SQByteSize::string(items.iter().map(|i| i.size).sum()));
            d.header_subtitle = Some(parts.join(" \u{00B7} "));
            d.content = Some(Box::new(browser.clone()));
            d.sheet_style = true;
            let status = browser.clone();
            d.footer_status = Some(Box::new(move || status.status_text()));
            d.escape_response = Some(CANCEL);
            // header close button answers like Esc
            d.close_button = true;
            d.add_button("Copy & Import", sq_uikit::sqdialog_model::SQDialogRole::Default, false);
            d.add_button("Import without Copying", sq_uikit::sqdialog_model::SQDialogRole::Normal, false);
            d.add_button("Select All", sq_uikit::sqdialog_model::SQDialogRole::Normal, true);
            // art.html 42: Select All is a plain text button
            d.ghost_buttons.insert(2);
            // Select All keeps the dialog open; an import with nothing ticked says so instead of closing.
            let gate = browser.clone();
            d.can_close = Some(Box::new(move |r| {
                if r == SELECT_ALL {
                    gate.select_all();
                    return false;
                }
                if (r == SQDialogResponse::FIRST || r == SQDialogResponse::SECOND) && gate.selected().is_empty() {
                    sink.borrow_mut().push(ShellEvent::Status(SQL10n::string("Tick the files to import first.")));
                    return false;
                }
                true
            }));
            shell.flow_env.card_dialog = Some(standardized(volume));
            d
        }) else {
            return;
        };
        let Some(r) = Self::ask(&h, d).await else { return };
        if r != SQDialogResponse::FIRST && r != SQDialogResponse::SECOND {
            return;
        }
        let sources: Vec<PathBuf> = browser.selected().into_iter().map(|c| c.url).collect();
        Self::import_from_card(h, sources, r == SQDialogResponse::FIRST).await;
    }

    /// Copies (or not) and imports into the Project panel; the failed files are named.
    pub async fn import_from_card<R: ShellRoot + ?Sized>(h: UiRef<R>, sources: Vec<PathBuf>, copy: bool) {
        let mut urls = sources.clone();
        let mut failed: Vec<String> = Vec::new();
        if copy {
            let saved = h.with(|r| r.shell_parts().session.file_url().is_some());
            if saved == Some(false) {
                let _ =
                    h.with(|r| r.shell_parts().shell.flash("Save the project first: the copies go into its folder."));
                let saved_now = Self::save_document_as(h.clone()).await;
                let has_url = h.with(|r| r.shell_parts().session.file_url().is_some()).unwrap_or(false);
                if !saved_now || !has_url {
                    let _ = h.with(|r| r.shell_parts().shell.flash("Import canceled."));
                    return;
                }
            }
            let Some(Some(dest)) = h.with(|r| {
                r.shell_parts()
                    .session
                    .file_url()
                    .map(|f| f.parent().map(Path::to_path_buf).unwrap_or_default().join("Media"))
            }) else {
                return;
            };
            let pool = h.with(|r| r.shell_parts().shell.flow_env.services.worker_pool()).flatten();
            let total = sources.len();
            let done = Arc::new(AtomicUsize::new(0));
            let result = match pool {
                Some(pool) => {
                    let (src, progress) = (sources.clone(), Arc::clone(&done));
                    let mut work =
                        Box::pin(pool.run(move |_| {
                            CardCopier::copy(&src, &dest, &mut |n, _| progress.store(n, Ordering::SeqCst))
                        }));
                    loop {
                        let polled = std::future::poll_fn(|cx| Poll::Ready(work.as_mut().poll(cx))).await;
                        if let Poll::Ready(r) = polled {
                            break r.ok();
                        }
                        let n = (done.load(Ordering::SeqCst) + 1).min(total);
                        let _ = h.with(|r| {
                            r.shell_parts().shell.emit(ShellEvent::Status(SQL10n::format(
                                "Copying %@ of %@…",
                                &[&n.to_string(), &total.to_string()],
                            )));
                        });
                        if sq_runtime::sleep(Duration::from_millis(100)).await.is_err() {
                            return;
                        }
                    }
                }
                // shortcut: the files are copied on the UI thread when the app provides no worker pool.
                None => Some(CardCopier::copy(&sources, &dest, &mut |_, _| {})),
            };
            let Some(result) = result else { return };
            urls = result.copied;
            failed = result.failed;
        }
        if !urls.is_empty() {
            let _ = h.with(|r| r.shell_parts().shell.emit(ShellEvent::Status(SQL10n::string("Importing…"))));
            // The Project panel model takes the files, as in every other import flow (no app service needed).
            Self::import_media(h.clone(), urls.clone(), false).await;
            let _ = h.with(|r| r.shell_parts().shell.emit(ShellEvent::ProjectChanged));
        }
        let _ = h.with(|r| {
            let shell = &mut r.shell_parts().shell;
            if failed.is_empty() {
                shell.emit(ShellEvent::Status(SQL10n::plural(
                    urls.len() as i64,
                    "Imported %@ file from the card.",
                    "Imported %@ files from the card.",
                )));
            } else {
                let shown: Vec<String> = failed.iter().take(5).map(|f| format!("• {f}")).collect();
                shell.present_message(
                    "Some files were not copied",
                    &format!(
                        "{}\n{}",
                        SQL10n::format(
                            "%@ of %@ files could not be copied:",
                            &[&failed.len().to_string(), &sources.len().to_string()]
                        ),
                        shown.join("\n")
                    ),
                    None,
                );
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Timestamp;

    fn item(kind: CardMediaKind, size: i64) -> CardCandidate {
        CardCandidate { url: PathBuf::from("/c/x"), kind, size, modified: Timestamp::from_unix_seconds(0.0) }
    }

    #[test]
    fn summary_lists_videos_then_photos_with_sizes() {
        let items = [
            item(CardMediaKind::Video, 1_000_000),
            item(CardMediaKind::Photo, 2_000_000),
            item(CardMediaKind::Video, 1_000_000),
        ];
        let s = card_summary(&items);
        assert!(s.starts_with("2 videos ("), "{s}");
        assert!(s.contains(", 1 photo ("), "{s}");
        assert_eq!(card_summary(&[]), "");
        assert!(!card_summary(&[item(CardMediaKind::Photo, 1)]).contains("video"));
    }

    #[test]
    fn a_volume_is_keyed_without_its_trailing_slash() {
        assert_eq!(standardized(Path::new("/Volumes/CARD/")), "/Volumes/CARD");
        assert_eq!(standardized(Path::new("/Volumes/CARD")), "/Volumes/CARD");
    }
}
