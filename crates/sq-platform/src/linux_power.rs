//! Linux: no idle sleep while an export runs, and the progress on the launcher icon.
//!
//! The sleep lock is a `systemd-inhibit` child that holds a block inhibitor while `tail --pid=<app>` runs, so it ends
//! with the app even after a crash (the counterpart of the Mac's `caffeinate -w`). The launcher progress is the
//! `com.canonical.Unity.LauncherEntry` signal that KDE Plasma's task manager, Dash to Dock and Unity read; it goes out
//! through `gdbus emit`.
//!
//! shortcut: both go through the command line tools (no D-Bus library in the workspace); upgrade to the logind
//! `Inhibit` call and a direct signal when a D-Bus crate is adopted. A desktop without the tools shows nothing and the
//! export runs on.

use std::process::{Child, Command, Stdio};

use sq_setup_engine::Identity;

/// The desktop file of this build's channel, the id the launcher entry signal addresses (Nightly has its own entry).
pub fn desktop_id() -> String {
    desktop_id_of(Identity::build())
}

fn desktop_id_of(identity: Identity) -> String {
    format!("{}.desktop", identity.linux_id())
}

/// Arguments of the sleep inhibitor held for the process `pid`.
pub fn inhibit_args(pid: u32) -> Vec<String> {
    [
        "--what=idle:sleep",
        "--who=Sequence Studio",
        "--why=An export is running",
        "--mode=block",
        "tail",
        &format!("--pid={pid}"),
        "-f",
        "/dev/null",
    ]
    .iter()
    .map(|s| (*s).to_string())
    .collect()
}

/// Arguments of `gdbus` for the launcher progress: `None` clears it.
pub fn badge_args(percent: Option<u8>) -> Vec<String> {
    badge_args_for(&desktop_id(), percent)
}

fn badge_args_for(desktop_id: &str, percent: Option<u8>) -> Vec<String> {
    let props = match percent {
        Some(p) => format!("{{'progress': <{:.2}>, 'progress-visible': <true>}}", f64::from(p.min(100)) / 100.0),
        None => "{'progress': <0.0>, 'progress-visible': <false>}".to_string(),
    };
    let object = format!("/com/canonical/unity/launcherentry/{}", object_id(desktop_id));
    vec![
        "emit".into(),
        "--session".into(),
        "--object-path".into(),
        object,
        "--signal".into(),
        "com.canonical.Unity.LauncherEntry.Update".into(),
        format!("application://{desktop_id}"),
        props,
    ]
}

/// The D-Bus object path part of a desktop id: letters and digits stay, everything else becomes `_` hex-free
/// (`sequence-studio.desktop` -> `sequence_2dstudio_2edesktop`, the encoding the launchers use).
fn object_id(desktop_id: &str) -> String {
    let mut out = String::new();
    for b in desktop_id.bytes() {
        if b.is_ascii_alphanumeric() {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("_{b:02x}"));
        }
    }
    out
}

/// Held while the export runs; dropping it lets the machine sleep again.
pub struct SleepLock(Child);

impl SleepLock {
    /// `None` when `systemd-inhibit` cannot start (the export runs on, the machine may sleep).
    pub fn acquire() -> Option<SleepLock> {
        let child = Command::new("systemd-inhibit")
            .args(inhibit_args(std::process::id()))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        Some(SleepLock(child))
    }
}

impl Drop for SleepLock {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Sends the launcher progress; fire and forget (a reaper thread collects the child).
pub fn send_badge(percent: Option<u8>) {
    let Ok(mut child) = Command::new("gdbus")
        .args(badge_args(percent))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return;
    };
    std::thread::spawn(move || {
        let _ = child.wait();
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_inhibitor_ends_with_the_app() {
        let args = inhibit_args(42);
        assert!(args.contains(&"--pid=42".to_string()));
        assert!(args.contains(&"--mode=block".to_string()));
        assert!(args.contains(&"--what=idle:sleep".to_string()));
    }

    #[test]
    fn the_badge_goes_to_the_channels_own_entry() {
        assert_eq!(desktop_id_of(Identity::STABLE), "sequence-studio.desktop");
        assert_eq!(desktop_id_of(Identity::NIGHTLY), "sequence-studio-nightly.desktop");
        let nightly = badge_args_for(&desktop_id_of(Identity::NIGHTLY), Some(10));
        assert!(nightly.contains(&"application://sequence-studio-nightly.desktop".to_string()));
        assert_eq!(desktop_id(), desktop_id_of(Identity::build()));
    }

    #[test]
    fn the_badge_signal_carries_the_progress() {
        let args = badge_args(Some(37));
        assert_eq!(args.last().map(String::as_str), Some("{'progress': <0.37>, 'progress-visible': <true>}"));
        assert!(args.contains(&"/com/canonical/unity/launcherentry/sequence_2dstudio_2edesktop".to_string()));
        assert!(args.contains(&"application://sequence-studio.desktop".to_string()));
        assert_eq!(
            badge_args(None).last().map(String::as_str),
            Some("{'progress': <0.0>, 'progress-visible': <false>}")
        );
    }

    #[test]
    fn the_sleep_lock_is_held_and_released_when_the_tool_exists() {
        // Without systemd-inhibit (a container) there is nothing to hold; the call must still not fail.
        if let Some(lock) = SleepLock::acquire() {
            drop(lock);
        }
    }
}
