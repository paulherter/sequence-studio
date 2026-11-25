// Swift: ShellPasteMedia.swift
//! Paste with files or an image on the system clipboard (the Mac `AppController+PasteMedia`): the host reads the clipboard
//! through [`ShellHooks::media_clipboard`]; our own clip clipboard keeps priority.

use crate::shell_host::{ShellCx, ShellFlow, ShellHost};
use sq_editor_session::{EditorSession, PasteContent, PasteMedia, PasteOffer, PasteRoute};
use sq_uikit::focus_routing::FocusedEditTarget;
use sq_uikit::localization::SQL10n;
use std::path::PathBuf;

/// A Paste whose clipboard read runs on a worker thread, with the panel it was made in.
pub(crate) struct PendingPaste {
    rx: std::sync::mpsc::Receiver<PasteContent>,
    target: FocusedEditTarget,
}

/// Where a pasted image is written (Swift `pastedImageFolder`): an unsaved project keeps the file where it is, so it goes to
/// `<support folder>/Pasted Images` (`SQ_SUPPORT_DIR` overrides the support folder, like the app); a saved one copies the
/// file on import, so the temp folder is enough (the Preferences scratch folder is the app's to add).
pub(crate) fn pasted_image_folder_in(
    saved: bool,
    platform: sq_os::Platform,
    env: impl Fn(&str) -> Option<std::ffi::OsString>,
) -> PathBuf {
    let temp = || std::env::temp_dir().join("SQPastedImages");
    if saved {
        return temp();
    }
    let support = match env("SQ_SUPPORT_DIR").filter(|d| !d.is_empty()) {
        Some(dir) => Some(PathBuf::from(dir)),
        None => platform.data_dir(&env).map(|d| d.join("Sequence Studio")),
    };
    support.map_or_else(temp, |d| d.join("Pasted Images"))
}

impl ShellHost {
    fn has_own_clip_data(session: &EditorSession) -> bool {
        session.clipboard().is_some() || session.effect_clipboard().is_some()
    }

    /// What Paste would do with a clipboard that offers `offer` (no clipboard data is read).
    pub(crate) fn media_route(&self, session: &EditorSession, offer: PasteOffer) -> PasteRoute {
        let target = FocusedEditTarget::from_panel(self.focus);
        if target != FocusedEditTarget::Timeline && target != FocusedEditTarget::Project {
            return PasteRoute::Nothing;
        }
        if Self::has_own_clip_data(session) {
            return PasteRoute::OwnClipboard;
        }
        PasteMedia::route(target, false, offer.has_files, offer.has_image)
    }

    /// True when Paste took the clipboard. Files and pictures are read when the user pastes, not before; with a worker
    /// job the picture is encoded off the UI thread and imported by [`ShellHost::poll_paste`] as soon as it is ready.
    /// The target is fixed now: a click elsewhere while the read runs does not change where the paste goes.
    pub(crate) fn paste_media(&mut self, cx: &mut ShellCx) -> bool {
        let Some(offer) = cx.hooks.media_clipboard_offer() else { return false };
        if !matches!(self.media_route(cx.session, offer), PasteRoute::ImportFiles | PasteRoute::ImportImage) {
            return false;
        }
        if self.pending_paste.borrow().is_some() {
            self.flash("Still reading the clipboard…");
            return true;
        }
        let target = FocusedEditTarget::from_panel(self.focus);
        if let Some(job) = cx.hooks.media_clipboard_job() {
            let (tx, rx) = std::sync::mpsc::channel();
            std::thread::spawn(move || {
                let _ = tx.send(job());
            });
            *self.pending_paste.borrow_mut() = Some(PendingPaste { rx, target });
            return true;
        }
        let Some(content) = cx.hooks.media_clipboard() else { return false };
        self.import_pasted(cx, content, target)
    }

    /// True while a Paste waits for its clipboard read.
    pub fn pending_paste_waits(&self) -> bool {
        self.pending_paste.borrow().is_some()
    }

    /// Imports the clipboard a worker read for Paste, once it is ready (called every frame while one waits).
    pub fn poll_paste(&mut self, cx: &mut ShellCx) {
        let ready = self.pending_paste.borrow().as_ref().map(|p| (p.rx.try_recv(), p.target));
        match ready {
            Some((Ok(content), target)) => {
                *self.pending_paste.borrow_mut() = None;
                self.import_pasted(cx, content, target);
            }
            Some((Err(std::sync::mpsc::TryRecvError::Disconnected), _)) => {
                *self.pending_paste.borrow_mut() = None;
                self.flash("Could not read the clipboard.");
            }
            _ => {}
        }
    }

    /// Imports what the clipboard held, for the `target` that was focused at Paste time.
    fn import_pasted(&mut self, cx: &mut ShellCx, content: PasteContent, target: FocusedEditTarget) -> bool {
        let route = PasteMedia::route(target, false, !content.file_urls.is_empty(), content.image_data.is_some());
        if route == PasteRoute::Nothing {
            self.flash("Nothing to paste. The copied files are gone or the picture could not be read.");
            return true;
        }
        match route {
            PasteRoute::ImportFiles => {
                let n = content.file_urls.len() as i64;
                self.flash_raw(SQL10n::plural(n, "Importing %@ pasted file…", "Importing %@ pasted files…"));
                self.start_flow(ShellFlow::ImportMixed(content.file_urls));
                true
            }
            PasteRoute::ImportImage => {
                let Some(png) = content.image_data else { return false };
                // A saved project copies the file into its Files folder on import, so the temp folder is enough; an
                // unsaved one keeps the file where it is, so it goes somewhere that survives a restart.
                let folder = cx.hooks.pasted_image_folder(cx.session.file_url().is_some());
                match PasteMedia::write_image(&png, &folder, self.wall_now()) {
                    Ok(url) => {
                        self.flash("Importing pasted image…");
                        self.start_flow(ShellFlow::ImportMixed(vec![url]));
                    }
                    Err(e) => self
                        .flash_raw(SQL10n::format("Could not save the pasted image: %@", &[&SQL10n::error_text(&e)])),
                }
                true
            }
            PasteRoute::OwnClipboard | PasteRoute::Nothing => false,
        }
    }
}

#[cfg(test)]
mod pasted_folder_tests {
    use super::*;
    use sq_os::Platform;
    use std::ffi::OsString;

    fn env(k: &str) -> Option<OsString> {
        (k == "HOME").then(|| OsString::from("/Users/a"))
    }

    #[test]
    fn an_unsaved_project_keeps_pasted_images_in_the_support_folder() {
        assert_eq!(
            pasted_image_folder_in(false, Platform::Mac, env),
            PathBuf::from("/Users/a/Library/Application Support/Sequence Studio/Pasted Images")
        );
    }

    #[test]
    fn a_saved_project_or_no_home_uses_the_temp_folder() {
        let temp = std::env::temp_dir().join("SQPastedImages");
        assert_eq!(pasted_image_folder_in(true, Platform::Mac, env), temp);
        assert_eq!(pasted_image_folder_in(false, Platform::Mac, |_| None), temp);
    }

    #[test]
    fn the_support_override_wins() {
        let e = |k: &str| (k == "SQ_SUPPORT_DIR").then(|| OsString::from("/x"));
        assert_eq!(pasted_image_folder_in(false, Platform::Linux, e), PathBuf::from("/x/Pasted Images"));
    }
}
