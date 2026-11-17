// Swift: MacShell/ExportNotificationDelegate.swift (a click on the notification shows the file)
//! WinRT toast notifications: a click shows the file in Explorer. An unpackaged app needs an AppUserModelID that Windows
//! knows: the installer's Start-menu shortcut carries it, and `register_app_id` writes the same id under
//! `HKCU\Software\Classes\AppUserModelId` at run time, so a portable copy or a dev build shows toasts as well.
//! The click arrives through the toast's `Activated` event, so it works while the app runs; after quitting, Windows
//! shows the toast but a click only brings up the Action Center.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use windows::Data::Xml::Dom::XmlDocument;
use windows::Foundation::TypedEventHandler;
use windows::UI::Notifications::{ToastNotification, ToastNotificationManager, ToastNotifier};
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, REG_SZ, RegSetKeyValueW};
use windows::Win32::UI::Shell::SetCurrentProcessExplicitAppUserModelID;
use windows::core::{HSTRING, IInspectable, PCWSTR};

/// The id of the app for Windows notifications and the taskbar; the installer shortcut uses the same text.
pub const APP_USER_MODEL_ID: &str = "SequenceStudio.App";

/// Toasts still alive keep their click handler; older ones are dropped.
const KEEP: usize = 8;

fn set_string(subkey: &str, name: &str, value: &str) -> bool {
    let key = HSTRING::from(subkey);
    let name = HSTRING::from(name);
    let data: Vec<u16> = value.encode_utf16().chain(std::iter::once(0)).collect();
    // SAFETY: the strings and the data buffer live for the call; the size is the buffer's byte length.
    let status = unsafe {
        RegSetKeyValueW(
            HKEY_CURRENT_USER,
            PCWSTR(key.as_ptr()),
            PCWSTR(name.as_ptr()),
            REG_SZ.0,
            Some(data.as_ptr().cast()),
            (data.len() * 2) as u32,
        )
    };
    status.is_ok()
}

/// Makes the id known (display name and icon) and names it as this process's id. False when the registry refused.
pub fn register_app_id(exe: &Path) -> bool {
    let key = format!("Software\\Classes\\AppUserModelId\\{APP_USER_MODEL_ID}");
    let ok = set_string(&key, "DisplayName", "Sequence Studio") && set_string(&key, "IconUri", &exe.to_string_lossy());
    // SAFETY: the id string is alive for the call.
    let named = unsafe { SetCurrentProcessExplicitAppUserModelID(&HSTRING::from(APP_USER_MODEL_ID)) }.is_ok();
    ok && named
}

/// What Explorer is asked to show: the file selected, or its folder when the file is gone.
pub fn reveal_arguments(file: &Path, exists: bool) -> OsString {
    if exists {
        let mut arg = OsString::from("/select,");
        arg.push(file);
        arg
    } else {
        file.parent().map(Path::as_os_str).unwrap_or_default().to_os_string()
    }
}

fn reveal(file: &Path) {
    use std::os::windows::process::CommandExt;
    let arg = reveal_arguments(file, file.exists());
    // Raw: `/select,"path"`; a whole-argument quote makes Explorer open its default folder.
    if file.exists() {
        let mut raw = OsString::from("/select,\"");
        raw.push(file);
        raw.push("\"");
        let _ = std::process::Command::new("explorer").raw_arg(raw).spawn();
        return;
    }
    // Explorer exits with 1 even when it worked: only a failed start matters, and there is nobody to tell.
    let _ = std::process::Command::new("explorer").arg(arg).spawn();
}

/// A toast sender. `None` from `new` when WinRT refuses (very old Windows, policy): the caller keeps the balloon.
pub struct ToastSender {
    notifier: ToastNotifier,
    alive: Vec<ToastNotification>,
}

impl ToastSender {
    pub fn new(exe: &Path) -> Option<ToastSender> {
        if !register_app_id(exe) {
            return None;
        }
        let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(APP_USER_MODEL_ID)).ok()?;
        Some(ToastSender { notifier, alive: Vec::new() })
    }

    /// Shows the toast built from `xml`; a click reveals `reveal` in Explorer. False when Windows refused.
    pub fn show(&mut self, xml: &str, reveal_file: Option<PathBuf>) -> bool {
        self.try_show(xml, reveal_file).is_some()
    }

    fn try_show(&mut self, xml: &str, reveal_file: Option<PathBuf>) -> Option<()> {
        let doc = XmlDocument::new().ok()?;
        doc.LoadXml(&HSTRING::from(xml)).ok()?;
        let toast = ToastNotification::CreateToastNotification(&doc).ok()?;
        if let Some(file) = reveal_file {
            toast
                .Activated(&TypedEventHandler::<ToastNotification, IInspectable>::new(move |_, _| {
                    reveal(&file);
                    Ok(())
                }))
                .ok()?;
        }
        self.notifier.Show(&toast).ok()?;
        self.alive.push(toast);
        if self.alive.len() > KEEP {
            self.alive.remove(0);
        }
        Some(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explorer_selects_an_existing_file_and_opens_the_folder_of_a_gone_one() {
        let f = Path::new("C:\\out\\Film.mp4");
        assert_eq!(reveal_arguments(f, true), OsString::from("/select,C:\\out\\Film.mp4"));
        assert_eq!(reveal_arguments(f, false), OsString::from("C:\\out"));
    }

    #[test]
    fn a_toast_for_an_unregistered_sender_is_accepted_or_refused_never_a_panic() {
        // The real Windows session decides; the call must come back either way.
        if let Some(mut s) = ToastSender::new(Path::new("C:\\Windows\\explorer.exe")) {
            let _ = s.show(
                "<toast><visual><binding template=\"ToastGeneric\"><text>t</text></binding></visual></toast>",
                None,
            );
        }
    }

    /// By hand in a signed-in session: `cargo test -p sq-platform-win real_toast -- --ignored`, then look at the corner.
    #[test]
    #[ignore = "needs a desktop session"]
    fn real_toast() {
        let exe = std::env::current_exe().unwrap();
        let mut s = ToastSender::new(&exe).expect("sender");
        let xml = "<toast><visual><binding template=\"ToastGeneric\"><text>Export finished</text><text>Film.mp4</text></binding></visual></toast>";
        assert!(s.show(xml, Some(exe)));
        std::thread::sleep(std::time::Duration::from_secs(12));
    }
}
