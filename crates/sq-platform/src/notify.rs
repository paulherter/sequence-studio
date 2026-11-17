// Swift: SharedUIController+Jobs.swift `ExportNotifier`, MacShell/ExportNotificationDelegate.swift
//! Notifications: what is said and when, portable; how it reaches the system is a `Notifier` (Mac UserNotifications,
//! Windows tray balloon, a fake in tests). Same rule as Swift: a notification is posted only while the app is not the
//! active app, "Export failed" shows the first failure, "Export finished" the first file, and a click on a finished
//! export shows the file in the file manager.

use std::path::{Path, PathBuf};

/// One notification.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Notification {
    pub title: String,
    pub body: String,
    /// The file a click shows in Finder / Explorer (`None`: a click only brings the app forward).
    pub reveal: Option<PathBuf>,
}

/// A system's way to post a notification. Never blocks, never panics: a system that refuses drops it.
pub trait Notifier {
    fn post(&mut self, note: &Notification);
}

/// The notification for exports that ended, if one is due: none while the app is active (the window already says it),
/// none when nothing finished.
pub fn export_finished(done: &[PathBuf], failed: &[String], app_active: bool) -> Option<Notification> {
    if app_active {
        return None;
    }
    if let Some(first) = failed.first() {
        return Some(Notification { title: "Export failed".into(), body: first.clone(), reveal: None });
    }
    let url = done.first()?;
    let name = url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    Some(Notification { title: "Export finished".into(), body: name, reveal: Some(url.clone()) })
}

/// What a click shows: the file, or its folder when the file is gone (Swift `ExportNotificationDelegate`).
pub fn reveal_target(file: &Path) -> (PathBuf, bool) {
    if file.exists() {
        (file.to_path_buf(), true)
    } else {
        (file.parent().map(Path::to_path_buf).unwrap_or_default(), false)
    }
}

/// A notifier that can say it failed (the toast service refused), so a plainer one can take over.
pub trait TryNotifier {
    fn try_post(&mut self, note: &Notification) -> bool;
}

/// Tries `primary`; when it fails the `fallback` posts instead (Windows: WinRT toast, then the tray balloon).
pub struct Fallback<P: TryNotifier> {
    pub primary: P,
    pub fallback: Box<dyn Notifier>,
}

impl<P: TryNotifier> Notifier for Fallback<P> {
    fn post(&mut self, note: &Notification) {
        if !self.primary.try_post(note) {
            self.fallback.post(note);
        }
    }
}

/// The toast document: a two-line text toast. XML-escaped, so a file name with `&` or `<` stays text.
pub fn toast_xml(note: &Notification) -> String {
    fn esc(t: &str) -> String {
        t.chars()
            .map(|c| match c {
                '&' => "&amp;".to_string(),
                '<' => "&lt;".to_string(),
                '>' => "&gt;".to_string(),
                '"' => "&quot;".to_string(),
                '\'' => "&apos;".to_string(),
                c if (c as u32) < 0x20 && !matches!(c, '\t' | '\n' | '\r') => String::new(),
                c => c.to_string(),
            })
            .collect()
    }
    format!(
        "<toast><visual><binding template=\"ToastGeneric\"><text>{}</text><text>{}</text></binding></visual></toast>",
        esc(&note.title),
        esc(&note.body)
    )
}

/// Posts nothing; keeps what it was asked to (tests, and systems without a notification service).
#[derive(Default)]
pub struct RecordingNotifier {
    pub posted: Vec<Notification>,
}

impl Notifier for RecordingNotifier {
    fn post(&mut self, note: &Notification) {
        self.posted.push(note.clone());
    }
}

/// The system's notifier for this window (Mac: UserNotifications, Windows: a tray balloon, else nothing is posted).
pub fn system_notifier(window: &winit::window::Window) -> Box<dyn Notifier> {
    crate::backend::system_notifier(window)
}

/// Whether this app is the one in front (Swift `NSApp.isActive`).
pub fn app_is_active(window: &winit::window::Window) -> bool {
    crate::backend::app_is_active(window)
}

#[cfg(test)]
mod tests;
